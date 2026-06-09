---
title: "nixidy part 3: Reusable templates for recurring application patterns"
date: 2026-06-08T11:00:00Z
tags:
  - nix
  - kubernetes
  - gitops
  - argocd
  - tutorial
series:
  - nixidy
---

The third time I write a Deployment + Service + Ingress trio I start to notice the shape: selector labels that match the pod template labels, a service port that mirrors the container port, an ingress that references the service by name. Every field is wired to every other field, and a typo in one label breaks the chain silently. By the fifth web application I'm copying an existing module and changing five values and hoping I changed all five.

nixidy's template system captures that pattern once, with typed options for the variables and an `output` function that generates the resources. I can instantiate it with different `image`, `port`, and `replicas` values and get a complete application each time. No duplication, no missed wiring.

<!--more-->

By the end of this part we'll have a `webApp` template that generates a Deployment, Service, and optional Ingress from four typed options, and we'll use it to deploy two applications (a frontend and an API) with different configurations.

## What you'll build

We're going to build a `webApp` template defined in `modules/templates.nix`, imported globally via `flake.nix`'s shared `modules` list. Two applications (`frontend` and `api`) instantiated from the template with different images, ports, and replica counts.

## Prerequisites

- [Parts 1](/posts/nixidy-part-1-introduction/) and [2](/posts/nixidy-part-2-multi-env-and-helm-charts/) complete: you have a multi-environment project with shared modules
- The same toolchain: **Nix** and **nixidy**

## A template with typed options

A template has two parts: `options` and `output`. The `options` block declares what each instance can configure, using the same `lib.mkOption` I'd use in a NixOS module. The `output` block is a function that receives the instance's `name` and resolved `config`, and returns a set of nixidy resources.

Let's create `modules/templates.nix`:

```nix
{ lib, ... }:
{
  templates.webApp = {
    options = {
      image = lib.mkOption {
        type = lib.types.str;
        description = "Container image to deploy";
      };

      replicas = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Number of pod replicas";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Application port (container, service, and ingress)";
      };

      ingressHost = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Ingress hostname. Set to null (the default) to skip Ingress creation.";
      };
    };

    output = { name, config, ... }: let
      labels = {
        "app.kubernetes.io/name" = name;
        "app.kubernetes.io/instance" = name;
      };
    in {
      deployments.${name}.spec = {
        replicas = config.replicas;
        selector.matchLabels = labels;
        template = {
          metadata.labels = labels;
          spec.containers.${name} = {
            image = config.image;
            ports.http.containerPort = config.port;
          };
        };
      };

      services.${name}.spec = {
        selector = labels;
        ports.http = {
          port = config.port;
          targetPort = config.port;
        };
      };

      ingresses = lib.mkIf (config.ingressHost != null) {
        ${name}.spec.rules = [{
          host = config.ingressHost;
          http.paths = [{
            path = "/";
            pathType = "Prefix";
            backend.service = {
              name = name;
              port.number = config.port;
            };
          }];
        }];
      };
    };
  };
}
```

Let me walk through the structure:

- **`templates.webApp`**: The name `webApp` is what you reference later. It's an arbitrary identifier, pick something that describes the pattern.
- **`options`**: Four typed options. `image` has no default, so every instance *must* set it and omitting it is a build error. `replicas`, `port`, and `ingressHost` have defaults, so instances only set them when they need to override.
- **`output`**: A function receiving `{ name, config, ... }`. `name` is the instance identifier (you'll see how that works in a moment). `config` holds the resolved option values for this specific instance. The function returns an attribute set of resources in the same shape as `applications.<name>.resources`, but relative to the application that uses the template.
- **`lib.mkIf`**: Conditionally includes the `ingresses` block only when `ingressHost` is not null. This is the standard NixOS module system conditional and the ingress simply doesn't exist when the host is null.

/// admonition | Templates vs. shared modules
    type: tip
    
A shared module (like `modules/nginx.nix` from [Part 2](/posts/nixidy-part-2-multi-env-and-helm-charts/)) defines *one* application's resources and lets environments override specific fields. A template defines a *pattern* (Deployment + Service + Ingress) and lets you instantiate it N times with different parameters. If you have one nginx, use a shared module. If you have five web applications that all follow the same Deployment-Service-Ingress shape, use a template.
///

## Using the template in an application

Now let's add `modules/templates.nix` to the shared `modules` list in `flake.nix`:

```nix
      nixidyEnvs = nixidy.lib.mkEnvs {
        inherit pkgs;
        modules = [
          ./modules/templates.nix
          ./modules/nginx.nix
          ./modules/traefik.nix
        ];
        envs = {
          dev.modules = [ ./env/dev.nix ];
          staging.modules = [ ./env/staging.nix ];
          prod.modules = [ ./env/prod.nix ];
        };
      };
```

Now let's create a new application module that uses the template. Create `modules/webapps.nix`:

```nix
{ lib, ... }:
{
  applications.frontend = {
    namespace = "frontend";
    createNamespace = true;

    templates.webApp.frontend = {
      image = "frontend:v1.2.3";
      replicas = 3;
      port = 3000;
      ingressHost = "app.example.com";
    };
  };

  applications.api = {
    namespace = "api";
    createNamespace = true;

    templates.webApp.api = {
      image = "api:v2.0.1";
      replicas = lib.mkDefault 2;
      port = 8080;
    };
  };
}
```

The template instantiation syntax is `templates.<templateName>.<instanceName>`. Here's what each part means:

- `templates.webApp.frontend`: Use the `webApp` template, create an instance called `frontend`. The `name` argument in the `output` function receives `"frontend"`.
- `{ image = "frontend:v1.2.3"; replicas = 3; port = 3000; ingressHost = "app.example.com"; }`: Set the options. `image` is required (no default), so omitting it would be a build error. `port` overrides the default of `8080` to `3000`. `ingressHost` triggers the `lib.mkIf` and generates an Ingress resource.

For the `api` instance, `ingressHost` is left at its default (`null`), so no Ingress is generated and the API is cluster-internal. `replicas = lib.mkDefault 2` means environments can override it with a plain assignment (priority `100` beats the default `1000`), same composition mechanism from [Part 2](/posts/nixidy-part-2-multi-env-and-helm-charts/).

Let's add `modules/webapps.nix` to the shared modules in `flake.nix`:

```nix
modules = [
  ./modules/templates.nix
  ./modules/webapps.nix
  ./modules/nginx.nix
  ./modules/traefik.nix
];
```

Then let's build the dev environment and review the output.

```bash
nix run github:arnarg/nixidy -- build .#dev
tree result -l
```

It should show that the `frontend` and `api` resources were generated.

```
result
├── api
│   ├── Deployment-api.yaml
│   ├── Namespace-api.yaml
│   └── Service-api.yaml
└── frontend
    ├── Deployment-frontend.yaml
    ├── Ingress-frontend.yaml
    ├── Namespace-frontend.yaml
    └── Service-frontend.yaml
```

## Patching template-generated resources

Template output is regular nixidy resources and I can override individual fields the same way I'd override a shared module. If the frontend needs a memory limit that the template doesn't expose as an option:

```nix
applications.frontend = {
  namespace = "frontend";
  createNamespace = true;

  templates.webApp.frontend = {
    image = "frontend:v1.2.3";
    replicas = 3;
    port = 3000;
    ingressHost = "app.example.com";
  };

  resources.deployments.frontend.spec.template.spec.containers.frontend.resources = {
    requests.memory = "64Mi";
    limits.memory = "128Mi";
  };
};
```

The template generates the Deployment. The `resources.deployments.frontend` block merges with the generated output and adds resource limits without touching the template.

Now if we build the dev environment and look at the `frontend` deployment.

```bash
nix run github:arnarg/nixidy -- build .#dev
cat result/frontend/Deployment-frontend.yaml
```

It should show you a `Deployment` with resource requests and limits added.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/instance: frontend
      app.kubernetes.io/name: frontend
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: frontend
        app.kubernetes.io/name: frontend
    spec:
      containers:
        - image: frontend:v1.2.3
          name: frontend
          ports:
            - containerPort: 3000
              name: http
          resources:
            limits:
              memory: 128Mi
            requests:
              memory: 64Mi
```

## What's next

Templates close the last duplication gap for resource definitions. However I can still only define and override core Kubernetes resources (such as Deployments, Services and Ingresses). In [part 4](/posts/nixidy-part-4-typed-resource-options/) I'll cover how to generate typed resource options from CRDs (both plain YAML files and a Helm chart), so that we can define and override `CiliumNetworkPolicies`, cert-manager's `Certificates` or prometheus `ServiceMonitors` in `applications.<name>.resources`.

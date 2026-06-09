---
title: "nixidy part 4: Typed resource options and CRD generation"
date: 2026-06-08T11:30:00Z
tags:
  - nix
  - kubernetes
  - gitops
  - argocd
  - tutorial
series:
  - nixidy
---

Every Kubernetes resource we've defined so far (Deployments, Services, Ingresses, Namespaces, ConfigMaps) has been typed. We didn't install anything extra to make that happen, nixidy ships with typed options for all core Kubernetes resources, generated from the official JSON schemas. When I write `replicas = 3`, the module system checks that `3` is an integer. When I write `replicas = "three"`, the build fails with a type error naming the exact option and the type it expected.

That type checking extends beyond built-in resources too. nixidy includes a code generator that produces typed Nix options from any Custom Resource Definition, so my Cilium network policies, cert-manager certificates, and Prometheus service monitors get the same build-time validation as a plain Deployment. This part covers how the built-in types work under the hood, how to generate types from CRDs, and how to handle resources that don't fit the typed model.

<!--more-->

By the end of this part we'll understand the typed resource option system end-to-end: the alias mapping from short names to group/version/kind paths, how to generate typed options from CRDs (both standalone and from Helm charts), and how to include raw YAML for resources that bypass the type system.

## What you'll build

We're going to add a Cilium `CiliumNetworkPolicy` resource with full type safety, generated from Cilium's CRDs using nixidy's `fromCRD` generator. Plus an understanding of when to use typed resources vs. raw YAML vs. Helm output.

## Prerequisites

- [Part 1](/posts/nixidy-part-1-introduction/), [2](/posts/nixidy-part-2-multi-env-and-helm-charts/) and [3](/posts/nixidy-part-3-reusable-templates/) complete
- The same toolchain: **Nix** and **nixidy**

## How typed resources work

Every Kubernetes resource in nixidy lives under `applications.<name>.resources`. The full path follows the Kubernetes API group, version, and kind:

```
resources.core.v1.Service
resources.apps.v1.Deployment
resources."networking.k8s.io".v1.Ingress
```

Typing those paths every time is verbose. nixidy provides aliases, which are the plural camelCase form of the kind:

| Full path | Alias |
|---|---|
| `resources.core.v1.Service` | `resources.services` |
| `resources.apps.v1.Deployment` | `resources.deployments` |
| `resources."networking.k8s.io".v1.Ingress` | `resources.ingresses` |
| `resources.core.v1.ConfigMap` | `resources.configMaps` |
| `resources.batch.v1.CronJob` | `resources.cronJobs` |

We've been using these aliases throughout [Part 1](/posts/nixidy-part-1-introduction/), [2](/posts/nixidy-part-2-multi-env-and-helm-charts/) and [3](/posts/nixidy-part-3-reusable-templates/). The aliases resolve to the same typed options, so `resources.services.nginx` and `resources.core.v1.Service.nginx` produce identical output.

/// admonition | info
    type: info
    
The alias is the plural camelCase of the `kind` field, not the `resources` field from the Kubernetes API. `CronJob` becomes `cronJobs`, `NetworkPolicy` becomes `networkPolicies`, `ClusterRole` becomes `clusterRoles`. When in doubt, check the [nixidy options search](https://nixidy.dev/options/search).
///

The types themselves are generated from the official Kubernetes JSON schemas with a code generator that was forked from [kubenix](https://github.com/hall/kubenix/). Every field in the schema becomes a Nix option with a type: strings, integers, booleans, attribute sets, lists of submodules. The result is that `nixidy build` catches the same class of errors a `kubectl apply --dry-run` would catch, but at Nix evaluation time, which is faster and doesn't require cluster access.

## What happens to untyped resources

Not every resource has typed options. CRDs from third-party operators (Cilium, cert-manager, Prometheus) aren't included by default. Resources without typed options fall into three categories:

1. **Rendered by Helm**: nixidy parses Helm chart output into typed resources where types exist. Untyped resources pass through to the output as-is. We can't patch them via `resources.*`, but they appear in the final manifests.
2. **Included via `yamls`**: nixidy parses these into typed resources the same way. Untyped resources pass through.
3. **Included via `extraRawYamls`**: these are copied verbatim. nixidy never parses them, never strips fields, never attempts to type-check. This is the escape hatch for [SOPS](https://github.com/getsops/sops)-encrypted manifests and other resources with non-standard structure.

The key constraint: if a resource doesn't have a typed option definition for its group, version, and kind, we can't reference it under `resources.*`. It goes straight to the output. The fix is to generate typed options from the CRD.

## Generating typed options from CRDs

nixidy ships a generator called [`fromCRD`](https://nixidy.dev/user_guide/typed_resources/) that reads a CRD YAML file and produces a Nix module with typed options for that resource. The generated module integrates into nixidy via `nixidy.applicationImports`. Once imported, the CRD's resources become available under `resources.*` with full type checking.

Let's generate types for Cilium's `CiliumNetworkPolicy`. Let's add the generator to `flake.nix`:

```nix
{
  description = "My Kubernetes cluster managed with nixidy";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixidy.url = "github:arnarg/nixidy";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    nixidy,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
    in {
      nixidyEnvs = nixidy.lib.mkEnvs {
        inherit pkgs;
        modules = [
          ./modules/templates.nix
          ./modules/webapps.nix
          ./modules/nginx.nix
          ./modules/traefik.nix
        ];
        envs = {
          dev.modules = [ ./env/dev.nix ];
          staging.modules = [ ./env/staging.nix ];
          prod.modules = [ ./env/prod.nix ];
        };
      };

      packages.generators.cilium =
        nixidy.packages.${system}.generators.fromCRD {
          name = "cilium";
          src = pkgs.fetchFromGitHub {
            owner = "cilium";
            repo = "cilium";
            rev = "v1.15.6";
            hash = "sha256-oC6pjtiS8HvqzzRQsE+2bm6JP7Y3cbupXxCKSvP6/kU=";
          };
          crds = [
            "pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml"
          ];
        };
    });
}
```

Run the generator:

```bash
nix build .#generators.cilium
cat result
```

The output is a Nix file: a module that defines typed options for `CiliumNetworkPolicy`. Copy it into the project:

```bash
mkdir -p generated
cp result generated/cilium.nix
```

Then register it via `nixidy.applicationImports` in one of the shared modules. For example, add to `modules/nginx.nix` or create a dedicated `modules/crd-imports.nix`:

```nix
{
  nixidy.applicationImports = [ ../generated/cilium.nix ];
}
```

/// admonition | warning
    type: warning
    
`nixidy.applicationImports` is different from the shared `modules` list in `flake.nix`. The shared `modules` list feeds into the environment-level module system. `nixidy.applicationImports` feeds into the *per-application* module system, meaning it makes the generated resource types available inside `applications.<name>.resources.*`. If you put the import in the wrong place, the types won't be visible and you'll get "attribute missing" errors.
///

Now the Cilium network policy resource is available with full type safety. Let's create `modules/cilium-policies.nix`:

```nix
{ lib, ... }:
{
  applications.network-policies = {
    namespace = "kube-system";
    createNamespace = false;

    resources.ciliumNetworkPolicies.allow-dns.spec = {
      endpointSelector = {};
      egress = [{
        toEndpoints = [{
          matchLabels."k8s:io.kubernetes.pod.namespace" = "kube-system";
        }];
        toPorts = [{
          ports = [{ port = "53"; protocol = "UDP"; }];
        }];
      }];
    };
  };
}
```

The `resources.ciliumNetworkPolicies` path (the alias for the generated CRD type) only exists because `generated/cilium.nix` was imported via `nixidy.applicationImports`. Without it, `ciliumNetworkPolicies` would be an unrecognized attribute, and the resource would have to be included via `yamls` or `extraRawYamls` without type checking.

Now if we build the dev environment and look at the generated `CiliumNetworkPolicy`.

```bash
nix run github:arnarg/nixidy -- build .#dev
cat result/network-policies/CiliumNetworkPolicy-allow-dns.yaml
```

It should show you the generated manifest like below.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: kube-system
spec:
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
  endpointSelector: {}
```

## Generating types from Helm chart CRDs

Some CRDs are only available inside Helm charts, or it's preferable to keep them in sync with the chart version you're deploying. The [`fromChartCRD`](https://nixidy.dev/user_guide/typed_resources/) generator handles this: it templates the Helm chart, extracts CRDs from the rendered output, and generates typed options.

As an example, let's generate types for cert-manager's `Certificate` CRD:

```nix
packages.generators.cert-manager =
  nixidy.packages.${system}.generators.fromChartCRD {
    name = "cert-manager";
    chartAttrs = {
      repo = "https://charts.jetstack.io";
      chart = "cert-manager";
      version = "v1.19.1";
      chartHash = "sha256-fs14wuKK+blC0l+pRfa//oBV2X+Dr3nNX+Z94nrQVrA=";
    };
    crds = [ "Certificate" ];
  };
```

The workflow is the same: `nix build .#generators.cert-manager`, copy the output into `generated/`, and register via `nixidy.applicationImports`. The `crds` list is optional, leave it empty to generate types for all CRDs the chart produces.

/// admonition | info
    type: info
    
`fromChartCRD` also handles CRDs that contain Helm templating within their definitions, something `fromCRD` can't process because it reads raw YAML from the source tree rather than rendering a chart.
///

## Resolving naming conflicts

Two operators might define a CRD with the same `kind`, two different `Database` types for instance. Both would try to generate the alias `resources.databases`, producing a conflict.

The `fromCRD` generator accepts a `namePrefix` to disambiguate:

```nix
generators.postgres = nixidy.packages.${system}.generators.fromCRD {
  name = "postgres-operator";
  namePrefix = "postgres";
  # ...
};

generators.mysql = nixidy.packages.${system}.generators.fromCRD {
  name = "mysql-operator";
  namePrefix = "mysql";
  # ...
};
```

This produces `resources.postgresDatabases` and `resources.mysqlDatabases` with no collision.

`namePrefix` is a blunt instrument, it prefixes every generated attribute name. When two CRDs within the *same* chart collide, or when I want a more readable name than a prefix produces, `attrNameOverrides` gives direct control. It's an attribute set that maps a CRD's `<plural>.<group>` identifier to the exact attribute name to use under `resources.*`.

The key on the left side is not the CRD's `kind`, it's the plural name followed by the API group, exactly as it appears in the CRD's `spec.names.plural` and `spec.group` fields. For example, a Keycloak Crossplane provider might ship two CRDs that both resolve to the plural `groups` under different sub-groups, producing a collision on `resources.groups`. The override disambiguates:

```nix
generators.keycloak = nixidy.packages.${system}.generators.fromCRD {
  name = "keycloak";
  src = pkgs.fetchFromGitHub { /* ... */ };
  crds = [
    "package/crds/authenticationflow.keycloak.crossplane.io_bindings.yaml"
    "package/crds/group.keycloak.crossplane.io_groups.yaml"
    "package/crds/user.keycloak.crossplane.io_groups.yaml"
  ];
  namePrefix = "keycloak";
  attrNameOverrides = {
    # The CRD "groups" under the "user.keycloak.crossplane.io" group
    # would collide with the one under "group.keycloak.crossplane.io".
    # Map it to a distinct name.
    "groups.user.keycloak.crossplane.io" = "keycloakUserGroups";
  };
};
```

The right-hand side (`"keycloakUserGroups"`) is the attribute name to use: `resources.keycloakUserGroups.my-instance`. It takes precedence over both `namePrefix` and the auto-generated plural alias. `attrNameOverrides` can be used without `namePrefix` if only specific CRDs need renaming, or combined when a prefix is wanted as a default with targeted overrides.

/// admonition | warning
    type: warning

The left-hand key format is `<plural>.<group>`. It's easy to get wrong. If the override doesn't take effect, check the CRD YAML's `spec.names.plural` and `spec.group` fields and concatenate them with a dot. A mismatch (wrong plural, wrong group, missing sub-group) silently falls back to the auto-generated name.
///

## Raw YAML for edge cases

Some resources don't fit the typed model, SOPS-encrypted Secrets are the canonical example. The `sops` metadata block at the top level isn't a valid Kubernetes field, and the `ENC[...]` ciphertext values would be reformatted by a parse/emit round-trip, breaking decryption.

For these, use `extraRawYamls`:

```nix
applications.my-app = {
  namespace = "my-app";
  extraRawYamls = [ ./encrypted-secret.yaml ];
};
```

The file is copied verbatim into the application's output directory. nixidy never parses it, never strips fields, never type-checks it. The trade-off is that it can't be patched through `resources.*`, and `nixidy apply` (the direct `kubectl` path) skips it. Only Argo CD with a SOPS plugin will apply it.

/// admonition | warning
    type: warning
    
Basenames in `extraRawYamls` must be unique within an application and must not collide with typed-resource output filenames (e.g., `Secret-myapp.yaml`). Both cases produce build-time assertion failures, nixidy catches the conflict before it reaches the cluster.
///

## The full picture

Here's how the three resource paths compare:

| Path | Type-checked | Patchable via `resources.*` | Parsed by nixidy |
|---|---|---|---|
| `resources.*` (built-in alias) | Yes | Yes | Yes |
| `resources.*` (CRD-generated) | Yes | Yes | Yes |
| `resources.*` (Helm output, typed) | Yes | Yes | Yes |
| Helm output, untyped kind | No | No | Yes (pass-through) |
| `yamls` | If types exist | If types exist | Yes |
| `extraRawYamls` | No | No | No (verbatim copy) |

The rule of thumb: if a resource has typed options (built-in or generated), define it under `resources.*` and get build-time validation. If it doesn't, generate the types from the CRD. If generation isn't feasible (encrypted manifests, non-standard structures), fall back to `extraRawYamls`.

## What's next

Typed resources give me confidence that what I write is what Kubernetes expects in terms of the type of data for each field of a manifest. What it can't ensure is broader requirements such as minimum replicas for some or all deployments or when application A is deployed then application B *must* also be deployed. In [part 5](/posts/nixidy-part-5-assertions-and-warnings/) we will cover build-time assertions and warnings which can be used to define such requirements.

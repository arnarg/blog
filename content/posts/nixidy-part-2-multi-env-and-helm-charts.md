---
title: "nixidy part 2: Multi-environments and Helm charts"
date: 2026-06-08T10:30:00Z
tags:
  - nix
  - kubernetes
  - gitops
  - argocd
  - tutorial
series:
  - nixidy
---

In [the previous part](/posts/nixidy-part-1-introduction/) we created a single nixidy application. The nginx `Deployment` in `dev.nix` is 20 lines. When I add `staging.nix` and `prod.nix` I'll have three copies of those 20 lines, and they'll be identical except for `replicas` and maybe an annotation or two. Change the container port in one, forget it in another, and I've got a silent divergence that no CI check will catch.

The NixOS module system solves this the same way it solves duplicate NixOS host configs: shared base modules, `imports`, and priority primitives that let me express "same app, different scale" in two lines instead of a full file copy. This part covers that composition, then adds a Helm chart to the mix (because most real clusters run at least one piece of software that only ships as a Helm chart).

<!--more-->

By the end of this part we'll have three environments (dev, staging, prod) sharing a single nginx definition with per-environment overrides, plus a Traefik ingress controller pulled from a Helm chart and patched with nixidy's typed resources.

## What you'll build

We're going to build a project with a shared `modules/nginx.nix` imported by `env/dev.nix`, `env/staging.nix`, and `env/prod.nix`, each overriding `replicas` via `lib.mkDefault` and `lib.mkForce`. We'll also add a second application, Traefik, rendered from an upstream Helm chart with nixidy-managed patches.

## Prerequisites

- [Part 1](/posts/nixidy-part-1-introduction/) complete: you have a working nixidy project with `env/dev.nix`
- The same toolchain: **Nix** and **nixidy**

## Refactor the nginx application into a shared module

The nginx definition currently lives inline in `env/dev.nix`. Let's pull it out into its own module so every environment can import it. Create `modules/nginx.nix`:

```nix
{ lib, ... }:
{
  applications.nginx = {
    namespace = "nginx";
    createNamespace = true;

    resources = {
      deployments.nginx.spec = {
        replicas = lib.mkDefault 2;
        selector.matchLabels.app = "nginx";
        template = {
          metadata.labels.app = "nginx";
          spec.containers.nginx = {
            image = "nginx:1.25.1";
            ports.http.containerPort = 80;
          };
        };
      };

      services.nginx.spec = {
        selector.app = "nginx";
        ports.http.port = 80;
      };
    };
  };
}
```

One change from [Part 1](/posts/nixidy-part-1-introduction/): `replicas = 2` became `replicas = lib.mkDefault 2`. This sets the default priority, so any module that imports this one can override it with a plain assignment or with `lib.mkForce`.

/// admonition | tip
    type: tip

The NixOS module system has three priority tiers you'll use constantly: `lib.mkDefault` (`1000`, which is easily overridden), a plain value (`100`, which is the normal priority), and `lib.mkForce` (`50`, which wins against everything). Two modules setting the same option at the same priority is an error and the system forces you to be explicit about which one wins.
///

Now I need to update `flake.nix` to pull in the shared module via `mkEnvs`'s `modules` list:

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
        modules = [ ./modules/nginx.nix ];
        envs.dev.modules = [ ./env/dev.nix ];
      };
    });
}
```

The `modules` list at the top level of `mkEnvs` is a shared import and every environment gets these modules automatically. This is equivalent to adding them to each environment's `imports` list by hand. As the project grows, adding a new shared module here is one line instead of N lines across N environment files.

Then I can rewrite `env/dev.nix` (no import needed, since `flake.nix` already handles it):

```nix
{
  nixidy.target.repository = "https://github.com/YOUR_USERNAME/my-cluster.git";
  nixidy.target.branch = "main";
  nixidy.target.rootPath = "./manifests/dev";
}
```

Let's build the dev environment:

```bash
nix run github:arnarg/nixidy -- build .#dev
tree result
```

The output is identical to [Part 1](/posts/nixidy-part-1-introduction/) (four files, same content). The module system merged the shared definition with the (empty) dev-specific overrides and produced the same result.

## A staging environment with a different replica count

Now let's add a second environment. The shared modules list in `flake.nix` already covers nginx, so `env/staging.nix` only needs environment-specific config:

```nix
nixidyEnvs = nixidy.lib.mkEnvs {
  inherit pkgs;
  modules = [ ./modules/nginx.nix ];
  envs = {
    dev.modules = [ ./env/dev.nix ];
    staging.modules = [ ./env/staging.nix ];
  };
};
```

Let's create `env/staging.nix`:

```nix
{
  nixidy.target.repository = "https://github.com/YOUR_USERNAME/my-cluster.git";
  nixidy.target.branch = "main";
  nixidy.target.rootPath = "./manifests/staging";

  applications.nginx.resources.deployments.nginx.spec.replicas = 3;
}
```

The plain assignment `replicas = 3` has priority `100`, which beats `mkDefault`'s `1000`. Staging gets 3 replicas and a single line expresses that.

Let's build it:

```bash
nix run github:arnarg/nixidy -- build .#staging
cat result/nginx/Deployment-nginx.yaml | grep replicas
```

You should see `replicas: 3`.

## A production environment with forced overrides

Now let's create `env/prod.nix`:

```nix
{ lib, ... }:
{
  nixidy.target.repository = "https://github.com/YOUR_USERNAME/my-cluster.git";
  nixidy.target.branch = "main";
  nixidy.target.rootPath = "./manifests/prod";

  applications.nginx = {
    resources.deployments.nginx.spec = {
      replicas = lib.mkForce 10;
      template.spec.containers.nginx.resources = {
        requests.memory = "128Mi";
        limits.memory = "256Mi";
      };
    };

    syncPolicy.autoSync = {
      enable = true;
      prune = true;
      selfHeal = true;
    };
  };
}
```

There are two things happening here:

- `lib.mkForce 10` sets replicas at priority `50`. This wins against any accidental override from another imported module. In production, that guarantee matters as a stray `mkDefault` from a shared module won't silently scale you down.
- `syncPolicy.autoSync` configures the generated Argo CD `Application` to automatically sync changes, prune deleted resources, and self-heal when the cluster drifts from the desired state. This is an Argo CD feature nixidy exposes as a typed option. You set it in Nix, not in the Argo CD UI.

/// admonition | `lib.mkForce` as a safety rail
    type: tip

In a large project with many shared modules, it's easy for two modules to set the same option at the same priority. The module system catches this at build time and two plain values for `replicas` is a conflict error, not a silent override. `mkForce` enforces the value. Use it sparingly (production replicas, resource limits, security contexts). Overusing it defeats the composition model because every `mkForce` is a value that can't be overridden elsewhere.
///

Let's update `flake.nix` once more to include all three environments. I'll add the Traefik module to the shared list at the same time:

```nix
nixidyEnvs = nixidy.lib.mkEnvs {
  inherit pkgs;
  modules = [
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

## A Helm chart integrated as a nixidy application

Most Kubernetes software ships as Helm charts and refusing to use them means maintaining hundreds of lines of Kubernetes resources by hand. nixidy can render Helm charts at build time and make the output available as typed resources that can be patched.

Let's add Traefik as a second application. Create `modules/traefik.nix`:

```nix
{ lib, ... }:
{
  applications.traefik = {
    namespace = "traefik";
    createNamespace = true;

    helm.releases.traefik = {
      chart = lib.helm.downloadHelmChart {
        repo = "https://traefik.github.io/charts/";
        chart = "traefik";
        version = "25.0.0";
        chartHash = "sha256-ua8KnUB6MxY7APqrrzaKKSOLwSjDYkk9tfVkb1bqkVM=";
      };

      values = {
        ingressClass.enabled = true;
      };
    };

    resources.deployments.traefik.spec.template.spec.containers.traefik.image =
      lib.mkForce "traefik:v3.0.0";
  };
}
```

Let me walk through the new pieces:

- **`helm.releases.traefik`**: Declares a Helm release. nixidy runs `helm template` at build time, captures the rendered manifests, and makes them available as typed resources.
- **`lib.helm.downloadHelmChart`**: Fetches the chart into the Nix store. The `chartHash` pins the exact chart artifact. Change the version without updating the hash and the build fails, same reproducibility guarantee as `fetchFromGitHub`.
- **`values`**: Standard Helm values, but expressed as a Nix attribute set.
- **`resources.deployments.traefik...`**: Patches a field *after* Helm rendering. The Helm chart produces the Traefik Deployment, nixidy parses it into typed resources, and you override the container image with `lib.mkForce`.

/// admonition | warning
    type: warning
    
The `chartHash` is critical. It's the SHA-256 of the `.tgz` archive. If you change `version` to `"25.0.1"` without updating the hash, the build fails with a hash mismatch. To get the correct hash, set it to `lib.fakeHash` or an empty string (`"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="`), run the build, and copy the *expected* hash from the error message. This is the poor man's Nix workflow for pinned fetches.
///

The shared `modules` list in `flake.nix` already covers nginx and Traefik, so `env/dev.nix` stays minimal:

```nix
{
  nixidy.target.repository = "https://github.com/YOUR_USERNAME/my-cluster.git";
  nixidy.target.branch = "main";
  nixidy.target.rootPath = "./manifests/dev";
}
```

Every environment file is now just target configuration and environment-specific overrides. Adding a new shared module means one line in `flake.nix` and not one line in every environment file.

## The project structure so far

After these changes the project looks like this:

```
my-cluster/
├── flake.nix
├── flake.lock
├── modules/
│   ├── nginx.nix          # shared nginx definition
│   └── traefik.nix        # traefik from Helm chart
├── env/
│   ├── dev.nix            # target config + overrides (modules via flake.nix)
│   ├── staging.nix        # target config + overrides
│   └── prod.nix           # target config + overrides + autosync
└── manifests/             # generated output
    ├── dev/
    ├── staging/
    └── prod/
```

Each environment file contains only target configuration and environment-specific overrides. The shared application modules live in `flake.nix`'s `modules` list, which feeds them into every environment automatically. Adding a fourth environment is just creating one new file with target config and overrides.

## What's next

Now we have three environments with a nixidy defined application and a Helm chart. But the nginx application is still defined from scratch while real clusters have recurring patterns: a web app that always gets a Deployment, a Service, and an Ingress with the same shape. [Part 3](/posts/nixidy-part-3-reusable-templates/) covers nixidy's template system, which lets us define that pattern once with typed options and instantiate it across applications with different images, ports, and replica counts.

---
title: "nixidy part 1: Introduction to nixidy"
date: 2026-06-08T10:00:00Z
tags:
  - nix
  - kubernetes
  - gitops
  - argocd
  - tutorial
series:
  - nixidy
---

I have managed many GitOps repositories for Kubernetes with ArgoCD and I'm sure I'm not alone in having opened a Helm values override file that was 600 lines of YAML and still not being sure which values actually made it into the rendered manifests. I've run `helm template`, piped it through `grep`, given up, committed it anyway and hoped the staging diff would catch anything my eyes missed.

That gap between what you *think* you're deploying and what actually lands in the cluster is exactly what [nixidy](https://github.com/arnarg/nixidy) is meant to close. I wrote it to replace Helm value files, Kustomize overlays, and raw YAML with a single Nix expression per environment. Every field is typed, every build is reproducible, and the output is plain YAML you can `git diff` before it ever touches a cluster.

<!--more-->

By the end of this part we'll have a working nixidy project that defines an nginx Deployment and Service, generates Argo CD `Application` manifests automatically, and deploys to your cluster through GitOps.

## What you'll build

We're going to build a nixidy environment called `dev` containing one application deployed to your cluster via Argo CD. The project structure will be the skeleton you'd extend to manage an entire production cluster.

## Prerequisites

- **Nix** installed with flakes enabled ([download](https://nixos.org/download.html))
- **A Kubernetes cluster** with **Argo CD** installed
- **A Git repository** for your Kubernetes manifests (GitHub, GitLab, etc.)
- **Basic familiarity** with Kubernetes Deployments, Services, and Namespaces
- **Basic familiarity** with Argo CD `Application` resources

/// admonition | info
    type: info

nixidy implements the [Rendered Manifests Pattern](https://akuity.io/blog/the-rendered-manifests-pattern/) where your CI generates plain YAML, you review it in PRs, and Argo CD deploys it. If you've used Argo CD with raw YAML or Kustomize before, the deployment side is identical. The difference is entirely in *how the YAML is produced*.
///

## A Nix expression that builds a Kubernetes manifest

The core idea behind nixidy is that every Kubernetes resource is a typed Nix option. A Deployment isn't a blob of YAML, it's a structured attribute set where `replicas` is an integer, `image` is a string, and a typo in `selector` is a build error, not a runtime surprise.

Let's start by creating the project:

```bash
mkdir my-cluster && cd my-cluster
git init
```

Now create `flake.nix`, this is the entry point that wires nixidy into your Nix flake:

```nix
{
  description = "My Kubernetes cluster managed with nixidy";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixidy.url = "github:arnarg/nixidy/latest";
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
        envs.dev.modules = [ ./env/dev.nix ];
      };
    });
}
```

A couple things worth noting:

- `nixidy.lib.mkEnvs` takes a set of named environments and returns Nix derivations that build YAML manifests. The key `dev` becomes the attribute you reference with `.#dev`.
- Each environment takes a list of NixOS-style modules which are plain `.nix` files that set options. This is the same module system that powers NixOS, which means you get `imports`, `lib.mkDefault`, `lib.mkForce`, and all the composition primitives you'd expect.

/// admonition | info
    type: info
    
If you've configured a NixOS system before, the shape is identical: a list of modules that set options, merged by the module system. The difference is that the options describe Kubernetes resources instead of system services.
///

## An environment module with one application

Now let's create the environment directory and the dev module:

```bash
mkdir -p env
```

Write `env/dev.nix`. Make sure to replace the repository URL with your own (this is where nixidy will tell Argo CD to look for rendered manifests):

```nix
{
  nixidy.target.repository = "https://github.com/YOUR_USERNAME/my-cluster.git";
  nixidy.target.branch = "main";
  nixidy.target.rootPath = "./manifests/dev";

  applications.nginx = {
    namespace = "nginx";
    createNamespace = true;

    resources = {
      deployments.nginx.spec = {
        replicas = 2;
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

Let me walk through what this declares:

- **`nixidy.target.*`**: Where the generated YAML ends up in your Git repo. Argo CD `Application` manifests will reference this repo, branch, and path.
- **`applications.nginx`**: One logical application. An application gets its own directory in the output and its own Argo CD `Application` manifest.
- **`namespace = "nginx"`**: All resources in this application are deployed to the `nginx` namespace.
- **`createNamespace = true`**: Nixidy generates a `Namespace` manifest automatically. Without this, you'd need to create the namespace out-of-band.
- **`resources.deployments.nginx`**: A typed Deployment. The `spec` attribute follows the [Kubernetes Deployment spec](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/deployment-v1/), but enforced at Nix evaluation time.
- **`resources.services.nginx`**: A typed Service, same idea.

/// admonition | Why not just write the YAML?
    type: info

Two reasons.

1. Type errors become build errors. Set `replicas = "two"` in the module above and `nixidy build` fails immediately, not 15 minutes into a deployment rollout.
2. Composition. When you add a `prod.nix` that imports this same module and sets `replicas = lib.mkForce 10`, you're expressing "same app, different scale" in two lines instead of copying an entire YAML file and changing one number. The NixOS module system (`imports`, `lib.mkDefault`, `lib.mkForce`) gives you this for free, and it's the same mechanism that handles multi-environment NixOS configs.
///

## Build the manifests

Run the build:

```bash
nix run github:arnarg/nixidy/latest -- build .#dev
```

/// admonition | info
    type: info

The first run downloads nixidy and its dependencies into the Nix store. Subsequent runs are instant if nothing changed.
///

Inspect the output:

```bash
tree result
```

You should see:

```
result/
├── apps/
│   └── Application-nginx.yaml
└── nginx/
    ├── Deployment-nginx.yaml
    ├── Namespace-nginx.yaml
    └── Service-nginx.yaml
```

Look at the generated Deployment:

```bash
cat result/nginx/Deployment-nginx.yaml
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - image: nginx:1.25.1
          name: nginx
          ports:
            - containerPort: 80
              name: http
```

And the Argo CD `Application` that nixidy generated for you:

```bash
cat result/apps/Application-nginx.yaml
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx
  namespace: argocd
spec:
  destination:
    namespace: nginx
    server: https://kubernetes.default.svc
  project: default
  source:
    path: ./manifests/dev/nginx
    repoURL: https://github.com/YOUR_USERNAME/my-cluster.git
    targetRevision: main
```

Every `applications.*` block produces exactly one Argo CD `Application` pointing at the directory containing its rendered manifests. This is the rendered manifests pattern: Argo CD syncs plain YAML, not templates, not Helm releases, just static files it can diff against the cluster state.

## Commit the rendered manifests

The `nixidy switch` command copies the built manifests into your repository at the `rootPath` you configured:

```bash
nix run github:arnarg/nixidy/latest -- switch .#dev
```

This creates `./manifests/dev/` with the same directory tree as `result/`. Commit and push:

```bash
git add .
git commit -m "Add nginx application via nixidy"
git push
```

The rendered YAML is now in your repository. Argo CD can see it.

## Deploy to your cluster

### Bootstrap with Argo CD

If Argo CD is already running in your cluster, one command creates an "app of apps" (a parent `Application` that manages all your nixidy applications):

```bash
nix run github:arnarg/nixidy/latest -- bootstrap .#dev | kubectl apply -f -
```

This outputs an Argo CD `Application` manifest that points at `manifests/dev/apps/` in your repo. Argo CD reads that directory, discovers `Application-nginx.yaml`, creates the nginx `Application`, which then syncs the Deployment, Service, and Namespace into your cluster.

### Or: apply directly (for testing)

If you want to skip Argo CD temporarily, a local `kind` cluster for instance:

```bash
nix run github:arnarg/nixidy/latest -- apply .#dev
```

This runs `kubectl apply --prune` with the correct label selectors, so resources removed from your nixidy config are also removed from the cluster on the next apply (if resources have been removed).

## What's next

We now have one application in one environment. Real clusters have a dozen applications across dev, staging, and production and I don't want to copy-paste the same Deployment into three files. In [Part 2](/posts/nixidy-part-2-multi-env-and-helm-charts/) we'll refactor the nginx application into a shared module, override `replicas` per environment with `lib.mkDefault` and `lib.mkForce`, and integrate a Helm chart without giving up type safety.

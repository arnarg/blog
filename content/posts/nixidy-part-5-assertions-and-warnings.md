---
title: "nixidy part 5: Build-time assertions and warnings"
date: 2026-06-08T12:00:00Z
tags:
  - nix
  - kubernetes
  - gitops
  - argocd
  - tutorial
series:
  - nixidy
---

Type checking catches the wrong shape of data: a string where an integer belongs, a missing required field. But it can't catch semantic errors like a production Deployment with zero replicas, a namespace that isn't being created, or two applications that must always be deployed together. These are invariants about the cluster configuration that no schema can express.

nixidy borrows the NixOS assertion and warning system for exactly this. Assertions are build-time hard constraints: if one fails, the build stops. Warnings are advisory, they print to stderr but don't block the build. Both are evaluated during `nixidy build`, before any YAML reaches the repository or the cluster.

<!--more-->

By the end of this part we'll have per-application assertions that enforce production hardening rules, global assertions that validate cross-application invariants, and warnings that surface potential misconfigurations without blocking iteration.

## What you'll build

We're going to add assertions on the `nginx` and `webapp` applications that enforce resource limits in production and reject zero-replica Deployments. Plus a global assertion that verifies all production applications have auto-sync enabled, and warnings that flag missing resource requests in dev and staging.

## Prerequisites

- [Part 1](/posts/nixidy-part-1-introduction/), [2](/posts/nixidy-part-2-multi-env-and-helm-charts/), [3](/posts/nixidy-part-3-reusable-templates/) and [4](/posts/nixidy-part-4-typed-resource-options/) complete
- The same toolchain: **Nix** and **nixidy**

## Per-application assertions

An assertion is a boolean condition and a message. If the condition evaluates to `false`, the build fails and prints the message. Assertions live under `applications.<name>.assertions`.

Let's open `modules/nginx.nix` and add an assertion that rejects zero replica counts:

```nix
{ lib, config, ... }:
{
  applications.nginx = {
    namespace = "nginx";
    createNamespace = true;

    assertions = [
      {
        assertion =
          config.applications.nginx.resources.deployments.nginx.spec.replicas > 0;
        message = "nginx must have at least 1 replica, got ${
          toString config.applications.nginx.resources.deployments.nginx.spec.replicas
        }";
      }
    ];

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

A couple things to notice:

- The module function now takes `config` in addition to `lib`. The `config` argument gives access to the fully-resolved option values, so `config.applications.nginx.resources.deployments.nginx.spec.replicas` is the merged, priority-resolved value after all modules have been evaluated.
- The assertion references the full option path, not a local variable. This is deliberate: the assertion checks the *final* value, after `mkDefault` and `mkForce` have been resolved. If `env/prod.nix` sets `replicas = lib.mkForce 0`, the assertion catches it.

Let's test it. Temporarily set `replicas = 0` in `env/dev.nix`:

```nix
applications.nginx.resources.deployments.nginx.spec.replicas = 0;
```

Build:

```bash
nix run github:arnarg/nixidy -- build .#dev
```

Expected output:

```
error: failed assertions:
- assertion(nginx): nginx must have at least 1 replica, got 0
```

The `assertion(nginx)` prefix tells us which application's assertion block failed. Revert the change and rebuild and the build succeeds again.

/// admonition | info
    type: info
    
Assertions are evaluated during *every* `nixidy build`, `nixidy switch`, and `nixidy apply`. They don't just guard CI, they guard the local workflow too. If I add an assertion that production deployments must have resource limits, `nixidy build .#prod` will fail on my laptop before I ever commit. That's the point: the invariant is enforced by the build system, not by review discipline.
///

## Assertions that reference other applications

The `config` argument is global, it contains *all* applications, not just the one where the assertion is defined. This means assertions can be written that span multiple applications.

A common pattern is a shared module that all environments import, containing global invariants. Let's create `modules/assertions.nix`:

```nix
{ lib, config, ... }:
{
  nixidy.assertions = [
    {
      assertion =
        lib.all
          (app: app.syncPolicy.autoSync.enable or false)
          (lib.attrValues config.applications);
      message = "All applications must have auto-sync enabled in this project";
    }
  ];
}
```

This is a global assertion, defined under `nixidy.assertions` instead of under a specific application. It iterates over every application in the environment and checks that `syncPolicy.autoSync.enable` is `true`. If any application doesn't have it set, the build fails.

/// admonition | Per-application vs. global assertions
    type: tip

Per-application assertions (`applications.<name>.assertions`) are scoped, they check invariants about a single application and the error message includes the application name. Use them for rules like "must have at least one Deployment" or "replicas must be positive."

Global assertions (`nixidy.assertions`) check invariants that span the entire environment. Use them for rules like "all applications must have auto-sync" or "every namespace used by an application must exist." The error message is prefixed with `global` instead of an application name.

The boundary is pragmatic: if the assertion only makes sense in the context of one application, put it there. If it requires comparing multiple applications, make it global.
///

## Warnings for non-blocking checks

Not every misconfiguration should block the build. A missing resource request in dev is worth flagging (it might be intentional for fast iteration). A missing resource request in production is a different story, but that's what assertions are for.

Warnings print a message to stderr during evaluation but don't fail the build. They come in two forms: conditional and unconditional.

Conditional warning (only prints when `when` evaluates to `true`):

```nix
applications.nginx = {
  namespace = "nginx";
  createNamespace = true;

  warnings = [
    {
      when = !config.applications.nginx.createNamespace;
      message = "nginx is not creating its namespace, make sure it exists on the cluster";
    }
  ];

  # ... resources ...
};
```

Unconditional warning (always prints). Useful for deprecation notices during a migration:

```nix
applications.nginx.warnings = [
  "nginx is using a deprecated image tag pattern. Migrate to 'nginx:1.25.x' before upgrading internal-app to v0.20.0."
];
```

Global warnings work the same way as global assertions:

```nix
nixidy.warnings = [
  {
    when = config.nixidy.target.branch != "main";
    message = "Target branch is '${config.nixidy.target.branch}', not 'main'. Make sure this is intentional";
  }
];
```

/// admonition | tip
    type: tip

An unconditional warning is shorthand for `{ when = true; message = "..."; }`. nixidy expands it internally. Use the shorthand for migration notices and persistent reminders, and the conditional form for checks that should only fire in specific configurations.
///

## A production hardening module

The real power of assertions is encoding organizational policy as build-time checks. Let's create `modules/production-hardening.nix`:

```nix
{ lib, config, ... }:
{
  nixidy.assertions = [
    {
      assertion =
        lib.all
          (app:
            let
              deploys = app.resources.deployments or {};
            in
              lib.all
                (dep:
                  let
                    spec = dep.spec or {};
                    containers = spec.template.spec.containers or {};
                  in
                    lib.all
                      (c: c.resources ? limits && c.resources ? requests)
                      containers)
                (lib.attrValues deploys))
          (lib.attrValues config.applications);
      message = "All containers in all deployments must have resource requests and limits set";
    }
  ];
}
```

This walks every application, every Deployment, and every container and asserts that each one has both `requests` and `limits` defined. It's a mouthful, but it only needs to be written once in a shared module. Every environment that imports it gets the check for free.

I'll import it only in `env/prod.nix` since dev and staging don't need this gate:

```nix
{ lib, ... }:
{
  imports = [ ../modules/production-hardening.nix ];

  nixidy.target.repository = "https://github.com/YOUR_USERNAME/my-cluster.git";
  nixidy.target.branch = "main";
  nixidy.target.rootPath = "./manifests/prod";

  # ... prod overrides ...
}
```

Build `.#dev` and it succeeds without the hardening check. Build `.#prod` and if any container is missing resource limits, the build fails with a clear message.

## What's next

Assertions close the last gap between "the types are correct" and "the configuration is correct." But the rendered manifests still need to reach the Git repository and the cluster. [Part 6](/posts/nixidy-part-6-ci-workflow/) covers CI integration: the `arnarg/nixidy/actions/build` and `arnarg/nixidy/actions/switch` GitHub Actions, the promotion workflow from Nix changes to reviewed YAML diffs, and the `nixidy diff` command for comparing environments before promotion.

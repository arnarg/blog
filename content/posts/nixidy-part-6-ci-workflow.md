---
title: "nixidy part 6: CI integration and the promotion workflow"
date: 2026-06-08T12:30:00Z
tags:
  - nix
  - kubernetes
  - gitops
  - argocd
  - tutorial
series:
  - nixidy
---

Every change we've made so far has been local: edit a Nix file, run `nixidy build`, inspect `result/`, run `nixidy switch` to copy manifests into the repo, commit, push. That workflow works for one person. It breaks the moment a second person needs to review what's being deployed, because they see a Nix diff, not a YAML diff, and they have to trust that `nixidy build` produces what they expect.

The rendered manifests pattern exists to solve this. CI builds the YAML from the Nix files and commits it to a known location in the repository (a promotion branch, a subdirectory on main, or a separate repository entirely). The reviewer sees a plain `git diff` of Kubernetes YAML. Argo CD picks up the change and deploys it. The Nix files are the source of truth; the YAML is the review artifact.

<!--more-->

By the end of this part we'll have a GitHub Actions workflow that builds the `dev` environment on every push to `main`, opens a pull request with the rendered manifests, and lets the team review the exact YAML that will reach the cluster before merging.

## What you'll build

We're going to build a single GitHub Actions workflow file that runs `nixidy build` on push, copies the output into `manifests/dev/`, and opens a promotion PR. Plus a local `nixidy diff` workflow for comparing environments before pushing.

## Prerequisites

- [Part 1](/posts/nixidy-part-1-introduction/), [2](/posts/nixidy-part-2-multi-env-and-helm-charts/), [3](/posts/nixidy-part-3-reusable-templates/), [4](/posts/nixidy-part-4-typed-resource-options/) and [5](/posts/nixidy-part-5-assertions-and-warnings/) complete
- The same toolchain: **Nix** and **nixidy**

## The promotion workflow

The core idea: Nix files change on `main`, CI renders them to YAML, and the YAML lands in a PR that a human reviews before it reaches Argo CD. This is the [rendered manifests pattern](https://akuity.io/blog/the-rendered-manifests-pattern/) that nixidy is built around. CI is the bridge between "Nix changed" and "YAML is ready to deploy."

Let's create `.github/workflows/promote-dev.yaml`:

```yaml
name: Promote to dev

on:
  push:
    branches:
      - main
    paths-ignore:
      - manifests/**

jobs:
  promote:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: |
            extra-experimental-features = nix-command flakes

      - uses: arnarg/nixidy/actions/build@main
        id: build
        with:
          environment: .#dev

      - shell: bash
        run: |
          rsync --recursive --delete '${{ steps.build.outputs.out-path }}/' manifests/dev

      - uses: EndBug/add-and-commit@v9
        id: commit
        with:
          default_author: github_actions
          message: "chore: promote to dev ${{ github.sha }}"
          fetch: false
          new_branch: promote/env/dev
          push: --set-upstream origin promote/env/dev --force

      - uses: thomaseizinger/create-pull-request@1.4.0
        if: ${{ steps.commit.outputs.pushed == 'true' }}
        with:
          github_token: ${{ github.token }}
          head: promote/env/dev
          base: main
          title: "chore: promote to dev ${{ github.sha }}"
```

Let me walk through each step:

- **`paths-ignore: manifests/**`**: prevents infinite loops. When the promotion PR merges and the rendered manifests land on `main`, this workflow *doesn't* trigger again. Only changes to Nix files (or anything outside `manifests/`) trigger a build.
- **`arnarg/nixidy/actions/build`**: nixidy's [official GitHub Action](https://nixidy.dev/user_guide/github_actions/). Runs `nixidy build .#dev` and exposes the output path as `steps.build.outputs.out-path`. Unlike running `nixidy build` directly, this action doesn't create a `result` symlink, it returns the Nix store path.
- **`rsync --recursive --delete`**: copies the built manifests into `manifests/dev/`, mirroring the directory structure. The `--delete` flag removes stale files, so if a resource was removed from the Nix config it disappears from the output too.
- **`EndBug/add-and-commit`**: commits the manifests to `promote/env/dev` (an orphan branch, not `main`). The `--force` push keeps the branch clean, each promotion overwrites the previous one.
- **`thomaseizinger/create-pull-request`**: opens a PR from `promote/env/dev` into `main`. The PR diff is exactly the rendered YAML changes. Reviewers see `Deployment-nginx.yaml` with `replicas: 3` changed to `replicas: 5`, not the Nix expression that produced it.

/// admonition | warning
    type: warning
    
The `arnarg/nixidy/actions/build` action requires flakes support even if the project doesn't use flakes, because the action internally uses `nix run` to invoke the nixidy CLI. That's why `extra-experimental-features = nix-command flakes` is necessary in the `install-nix-action` config.
///

### The switch action

The `build` action produces the output path but doesn't write to disk. You can use the `switch` action instead which will automatically `rsync` the manifests to the configured `nixidy.target.rootPath`, as a result it's really only useful if your manifests live on the same branch as the nixidy modules and flake.nix.

```yaml
- uses: arnarg/nixidy/actions/switch@main
  with:
    environment: .#dev
```

## Which Git strategy for which environment?

The [Git Strategies docs](https://nixidy.dev/user_guide/git_strategies/) describe three patterns:

- **Monorepo**: everything on `main`. Rendered manifests go into `manifests/<env>/`. Fast local iteration (`nixidy switch`, `git diff`). Requires `CODEOWNERS` or branch protection to prevent direct edits to generated YAML.
- **Environment branches**: orphan branches (`env/dev`, `env/staging`, `env/prod`). Each branch holds only rendered manifests. Simpler access control via branch protection.
- **Environment repositories**: separate repos entirely. Strongest isolation, each repo has its own access control and CI pipeline.

The promotion workflow above uses the monorepo strategy with a PR gate. The same `build` action works for all three, only the commit and PR steps change. Pick the strategy that matches the team's access control needs, not technical preferences.

## Comparing environments with nixidy diff

Before promoting from staging to production it's useful to see what's different. Not the Nix source, the rendered YAML. `nixidy diff` compares two build outputs:

```bash
nix run github:arnarg/nixidy/latest -- diff .#staging --env .#prod
```

This builds both environments and prints the diff of their rendered manifests. The output shows exactly which fields change between staging and production: replicas, resource limits, sync policies, image tags.

Compare against the manifests already in your repository:

```bash
nix run github:arnarg/nixidy/latest -- diff .#dev --path manifests/dev
```

This builds `.#dev` and compares it against the YAML already committed in `manifests/dev/`. If the output is empty, nothing changed and the local Nix edits don't affect the rendered manifests. If it shows changes, those are the exact diffs that will appear in the promotion PR.

/// admonition | tip
    type: tip

`nixidy diff` is particularly useful before a `nixidy switch`. Run the diff, review the changes, then switch.
///

## Conclusion

Six parts in and the tutorial has covered the full lifecycle: defining applications, composing environments, templating patterns, generating typed CRD options, asserting invariants, and promoting through CI. Nix files are the source, assertions guard the build, CI renders to YAML, PRs gate the review, and Argo CD deploys the result.

Documentation pages worth exploring:

- [Using nixhelm](https://nixidy.dev/user_guide/using_nixhelm/)
- [Transformers](https://nixidy.dev/user_guide/transformers/)
- [CLI reference](https://nixidy.dev/cli_reference/)
- [Configuration options](https://nixidy.dev/options/)

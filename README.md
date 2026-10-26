<p align="center">
    <img src="https://panfactum.com/logo.svg" height="150" alt="Panfactum logo">
</p>

---

# Implentio fork of the Panfactum Stack

This is [Implentio](https://github.com/implentio)'s fork of [Panfactum/stack](https://github.com/Panfactum/stack). It holds the Panfactum modules that [implentio/stack](https://github.com/implentio/stack) changes, so those changes live in one place instead of in local copies.

## Branches

| Branch | Contents |
|---|---|
| `implentio` (default) | Upstream [`40b40dbe`](https://github.com/Panfactum/stack/tree/40b40dbe93c68794803097d6f0d233f51ccd71e9) plus every Implentio change. implentio/stack deploys from this branch. |
| `main` | An unchanged mirror of upstream `Panfactum/stack` `main`. Use it only to sync with upstream. Never commit Implentio changes to it. |

`40b40dbe` is the `pf_stack_version` in implentio/stack's `environments/{development,production}/environment.yaml`. Units that aren't forked still load that commit from `modules.panfactum.com`. So every module on `implentio` must stay compatible with `40b40dbe`.

## What differs from upstream `40b40dbe`

Run `git log 40b40dbe..implentio` for the full history. Each PR into `implentio` says why it was made and when it can be dropped.

- Forked modules, deployed directly by implentio/stack units: `kube_alloy`, `kube_argo`, `kube_aws_ebs_csi`, `kube_buildkit`, `kube_cilium`, `kube_ingress_nginx`, `kube_karpenter`, `kube_karpenter_node_pools`, `kube_linkerd`, `kube_logging`, `kube_monitoring`, `kube_open_cost`, `kube_pvc_autoresizer`, `kube_velero`, `kube_vpa`.
- Implentio-only modules, not in upstream: `kube_kata_container` (Kata Containers VM runtime, `runtimeClassName: kata`).
- Shared submodules taken unchanged from upstream [`8fe2e40a`](https://github.com/Panfactum/stack/tree/8fe2e40a5f3174679470209208133a32698a2f66), because production `kube_argo` runs on them: `kube_constants` (argo-events `patch-54`), `kube_sa_auth_aws`, `kube_ingress`, `kube_pg_cluster`.
- `kube_pod`, `kube_stateful_set`: optional `seccomp_profile_type`, backported from upstream `34d827f2` for `kube_buildkit`. When it is unset, pods render exactly as on `40b40dbe`.

Forked modules call their siblings with relative paths (`source = "../<module>"`), as upstream does. So a unit that loads a forked module gets all of its submodules from this branch too.

## How implentio/stack uses it

A forked unit's `terragrunt.hcl` sets:

```hcl
terraform {
  source = "git::https://github.com/implentio/panfactum-stack.git//packages/infrastructure/<module>?ref=implentio"
}
```

`?ref=implentio` follows the branch. So whatever merges here reaches the next plan or apply of every unit that loads the changed module or one of its submodules.

Locally, terragrunt may reuse a cached download after the branch moves. Pass `--terragrunt-source-update` to force a fresh fetch.

## Changing a module

1. Branch off `implentio` and edit `packages/infrastructure/<module>`. Keep sibling sources as `"../<module>"`.
2. Run `tofu init -backend=false` and `tofu validate` in the module.
3. Plan each unit that uses the module, from your checkout, with nothing applied:
   ```bash
   cd environments/production/us-west-2/<unit>   # in implentio/stack
   terragrunt plan -lock=false --terragrunt-source <checkout>/packages/infrastructure//<module>
   ```
   A change to a shared submodule, such as `kube_constants` or `kube_sa_auth_aws`, reaches every forked unit that calls it. Plan all of them.
4. Open a PR into `implentio`. Say why, what differs from upstream, and when the change can be dropped. Include the plan results.
5. After the merge, apply the affected units from implentio/stack.

`forks/` in implentio/stack is a scratch area for quick local edits. A change there must land here before a unit uses it.

## Syncing with upstream

1. Update `main` from upstream: `gh repo sync implentio/panfactum-stack -b main`.
2. To move `implentio` to a newer upstream commit, merge that commit into a branch off `implentio` and resolve conflicts in the forked modules.
3. Change `pf_stack_version` in implentio/stack to the same commit in the same rollout, so forked and unforked units share one base.
4. Plan every unit before merging.

---


# Panfactum Stack
[![Discord](https://img.shields.io/discord/1230306857604616303?logo=discord&label=Discord)](https://discord.gg/MJQ3WHktAS)
[![CLA assistant](https://cla-assistant.io/readme/badge/Panfactum/stack)](https://cla-assistant.io/Panfactum/stack)

The Panfactum Stack is an integrated set of OpenTofu (Terraform) modules and local tooling aimed at providing
the best experience for building, deploying, and managing software on AWS and Kubernetes.

Check out our demos [here.](https://panfactum.com/stack/demo/live)

## Installation

If you'd like to add the Panfactum stack to your organization, see our [deployment guide.](https://panfactum.com/docs/edge/guides/bootstrapping/overview)

If you'd like to connect to an existing stack, see the [new user guide.](https://panfactum.com/docs/edge/guides/getting-started/overview)

## Structure

This repository contains the following components of the panfactum architecture which are all versioned
together to ensure internal consistency:

- [Panfactum Local Development Environment](packages/nix/mkDevShells)

- [Infrastructure Modules](packages/infrastructure)

- [Documentation Website](packages/website)

- [Reference Architecture](packages/reference)

- [Bastion Host](packages/bastion)

## Licensing

Unless an alternative license is supplied in a specific directory, all files in this repository
are governed by [this license](./LICENSE). If a directory contains an alternative license,
all files contained in that directory (and it's descendants) are governed by that alternative
license exclusively.

## Maintainers

- [fullykubed](https://github.com/fullykubed)


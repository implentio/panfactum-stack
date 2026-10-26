# Kube Kata Container

Runs pods in lightweight VMs with [Kata Containers](https://katacontainers.io). A pod that sets `runtimeClassName: kata` gets its own guest kernel, booted by QEMU on the node. A container escape lands in that guest, not on the node. Use it for untrusted code: AI agents with a shell tool, Docker-in-Docker, user-supplied builds.

## What it creates

| Resource | Purpose |
| --- | --- |
| `EC2NodeClass/kata` | AL2023 nodes with `cpuOptions.nestedVirtualization: enabled`, which exposes `/dev/kvm` on EC2 |
| `NodePool/kata` | amd64 `c8i`/`m8i`/`r8i`, spot and on-demand, tainted `implentio.com/kata=true:NoSchedule` |
| `helm_release/kata-deploy` | DaemonSet in `kube-system` that installs the Kata runtime and registers the `kata-qemu-runtime-rs` containerd handler on Kata nodes only |
| `RuntimeClass/kata` | Handler `kata-qemu-runtime-rs`, 320Mi/250m pod overhead, schedules onto ready Kata nodes and tolerates the taint |

## Usage

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sandboxed
  annotations:
    linkerd.io/inject: disabled
spec:
  runtimeClassName: kata
  containers:
    - name: main
      image: public.ecr.aws/docker/library/alpine:3.20
      command: ["uname", "-r"] # prints the guest kernel, not the node's
```

The RuntimeClass adds the node selector and toleration, so the pod spec needs neither. A pending Kata pod is what makes Karpenter launch a Kata node.

## How a node becomes ready

1. Karpenter launches a nested-virt instance with three startup taints: cilium, linkerd, and `katacontainers.io/kata-runtime`.
2. The `userData` loads `kvm_intel`, so `/dev/kvm` exists.
3. kata-deploy installs the runtime and labels the node `katacontainers.io/kata-runtime=true`, then removes its startup taint.
4. The RuntimeClass selects that label, so Kata pods only land on nodes where the runtime is installed.

## Constraints

- Nodes run AL2023, not Bottlerocket. kata-deploy writes binaries and containerd config to the host, and Bottlerocket's root is read-only with no Kata variant ([bottlerocket#4070](https://github.com/bottlerocket-os/bottlerocket/issues/4070)). These are the first non-Bottlerocket nodes in the cluster.
- Nested virtualization at launch is 8th-gen Intel only (`c8i`, `m8i`, `r8i` and their flex variants). There is no arm64 support.
- Karpenter must be `>= 1.13.0` for `cpuOptions` (dev and prod run 1.14.1).
- Kata 4.x ships the Rust shim (`runtime-rs`). The handler is `kata-qemu-runtime-rs`, not the 3.x `kata-qemu`.
- Disable linkerd injection on Kata pods. The proxy's iptables redirect has not been tested through the Kata VM network.
- The container rootfs is shared into the VM over virtiofs. SQLite in WAL mode is not safe on it: Hermes logs a corruption warning for its `state.db`. Put databases and other write-heavy state on a block-mode PVC, which Kata hot-plugs into the VM as a real disk.
- Docker-in-Docker needs `privileged: true` inside the VM, and `/sys/fs/cgroup` mounted as cgroup2 before `dockerd` starts. The guest already boots on cgroup v2. "Privileged" applies to the guest, not the node.

## Proof (development, 2026-10-21)

Each test ran on a throwaway `c8i.large` spot instance in the dev account (the cheapest nested-virt type in a dev subnet AZ) using the EKS AL2023 1.36 AMI and Kata 4.2.0 via `ctr`, then was terminated.

| Test | Result |
| --- | --- |
| `/dev/kvm` with nested virtualization | present, `vmx` in `/proc/cpuinfo` |
| busybox under runc vs Kata | host kernel `6.18.54-amzn2023` vs guest kernel `6.18.35` |
| Docker-in-Docker + `docker compose` (nginx + client) | Docker 29.9.2, Compose v5.6.1, overlayfs on an EBS volume hot-plugged into the VM as a block device; client fetched `Welcome to nginx!`; host saw 0 inner containers |
| Hermes agent (`nousresearch/hermes-agent`, `openai/gpt-6-luna` via OpenRouter) | terminal tool ran inside the guest and returned `6.18.35`, 1 vCPU, 1.9 GB |
| [nono](https://nono.sh) 0.80.0 inside Kata | Landlock V6 detected; write outside allowlist denied; read of `/root/secret` denied; `--block-net` denies `socket()` |

The NodeClass, NodePool and RuntimeClass passed `kubectl apply --dry-run=server --validate=strict` against `development-primary`.

## Verify after apply

```bash
kubectl get nodepool kata
kubectl -n kube-system get ds kata-deploy
kubectl run kata-check --rm -it --restart=Never --image=public.ecr.aws/docker/library/alpine:3.20 \
  --overrides='{"spec":{"runtimeClassName":"kata"}}' --annotations=linkerd.io/inject=disabled -- uname -r
```

The last command must print a kernel that differs from `kubectl get node -o wide` for that node.

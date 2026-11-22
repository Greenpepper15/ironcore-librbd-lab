# Development context

## Where we are

- [x] 1. Check ironcore-in-a-box against the use case (`ironcore-in-a-box-fit.md`)
- [x] 2. Lab layer: toolbox, bring-up through the submodule, free loop device
- [x] 3. Volume provider built on a Ceph image, rolled out, `rbd` of the build reachable
- [x] 4. Encrypted volume on a running VM, with the upstream provider and with the lab-built one
- [ ] **5. First run with a build from Clyso's build system** (TODO 1 and 3 of `design-decisions.md`)
- [ ] 6. Quick start on macOS and on Windows with WSL2 (TODO 5)
- [ ] 7. First rotation variant end to end: Go binding, call in the provider, new
      passphrase on the VM side (TODO 6)
- [ ] 8. Proposals to ironcore-in-a-box (TODO 9)

## Where things live

| What | Where |
|---|---|
| ironcore-in-a-box | submodule `ironcore-in-a-box`, pinned at `8263add` |
| IronCore components | [ironcore](https://github.com/ironcore-dev/ironcore), [ceph-provider](https://github.com/ironcore-dev/ceph-provider), [libvirt-provider](https://github.com/ironcore-dev/libvirt-provider); local checkouts are named in `lab.env` |
| Ceph image recipes of Clyso's build system | [cbs-components](https://github.com/clyso/cbs-components) |
| Stand-in for the build under test | `quay.io/ceph/ceph:v21.2.0`, RPMs at `https://download.ceph.com/rpm-21.2.0/el10` |
| State of a run | `.lab/` (rendered overlays, OSD device), `.kube/`, `.cache/`, all ignored by git |

## What was run

One host, 2026-11-22. Linux arm64 VM, Ubuntu 22.04, kernel 5.15.0-202, Docker
29.1.3 without the BuildKit plugin, 8 CPUs, 31 GiB memory, no `/dev/kvm`,
`/dev/loop0` to `loop5`, `loop7` and `loop8` in use by snaps. No make, Go,
kind or kubectl on the host.

| Check | Result |
|---|---|
| `./lab cluster` | kind cluster up in 2 min 48 s, node image already pulled |
| `./lab up-ironcore` | all pods Running after 5 min 13 s |
| `./lab up-storage` | Ceph `HEALTH_OK`, OSD on `/dev/loop6`, about 3 min |
| Upstream provider v0.6.0 at start | `pool ceph-volume-provider not found`, crash loop, fine after a restart |
| Encrypted Volume, upstream provider | `Available`. Image starts with the LUKS magic, 1 GiB in 260 objects |
| Machine with that Volume | `Running`, volume `Attached` after about 2 min 45 s. Domain type `qemu`, disk `<encryption format='luks2' engine='librbd'>`, one watcher on the image |
| `./lab build-ceph-volume-provider` | 4 min 37 s the first time. ceph-provider `4c61421`, go-ceph v0.41.0, linked against `/lib64/librbd.so.1` of `librbd1-21.2.0-0.el10.aarch64` |
| `./lab deploy` | 2 min 32 s, most of it loading the image into the node. The VM kept running |
| Second encrypted Volume, lab-built provider | `Available` within 30 s |
| Hot-attach of it to the running Machine | `Attached` within 20 s. Formatted by librbd 21.2.0, opened by QEMU's librbd 18.2.7 |
| `rbd --version` in the provider at the 256Mi limit | kernel log `Memory cgroup out of memory`, `rbd` and the provider killed |
| The same at 2Gi | works. `./lab rbd ls -l` shows both images with an exclusive lock |
| `./lab down` | cluster gone, loop device released |
| `./lab down`, then `./lab up` and the example, from nothing | down 35 s, up 7 min 32 s with all images already pulled, lab-built provider deployed by `up` itself. Machine `Running` with the encrypted volume `Attached` 3 min 30 s after the apply |

## Assumed, not run

- A build from Clyso's build system behaves like the upstream el10 image. The
  recipe says el10 and an RPM repository per architecture; no such build was
  used.
- macOS and WSL2. The toolbox reaches the cluster over the kind network, which
  should not depend on the host. The uid handling in `lab` differs there.
- x86_64.
- Replacing the other five images. Same code path as the provider.
- The rotation itself. No build with rotation was at hand, so nothing here
  says how QEMU's librbd 18.2.7 behaves while the provider rewrites the header.

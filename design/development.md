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

### Header rewrite check

A stand-in for the rotation (TODO 10 and 11 of `design-decisions.md`), run on
a second encrypted Volume that was attached to the running VM. In the
provider pod (librbd 21.2.0, cryptsetup 2.8.1) the first 16 MiB of the image
were copied into a file with python3-rbd, `cryptsetup` changed the copy, and
the 4 KiB blocks that differed were written back to the image. The I/O of the
VM was sent through the QEMU monitor with `qemu-io -d` on the device of the
disk, which is the path guest I/O takes. The guest itself did not use the
disk. On the VM side were QEMU 10.0.13, librbd 18.2.7 and libcryptsetup
2.7.5. Monitor commands leave the domain marked as tainted in libvirt until
the VM restarts.

| Check | Result |
|---|---|
| Header of a volume formatted by the provider | LUKS2, data at 16 MiB, the image is the volume size plus 16 MiB. One keyslot, argon2id with 64 MiB, time cost 4, 4 threads |
| Unlock with the Secret value as text, then with its decoded bytes | the text unlocks, the decoded bytes are refused |
| `cryptsetup luksAddKey` on the copy | 18.5 s, peak of the child 71 MiB, memory of the pod from 226 to 292 MiB, no OOM event at 2Gi |
| Write-back of the new keyslot under an I/O loop on the VM's disk | 67 blocks in 3 runs (both copies of the header, the keyslot area) in 0.86 s. 85 rounds of write, flush and read without error. Two writes took 0.61 s and 0.45 s, the mean was 0.13 s |
| Exclusive lock around a write-back | afterwards the image has no lock owner, QEMU takes the lock again at its next write |
| Volume removed from the Machine and added again, old passphrase | gone from the VM after 16 s, `Attached` again after 4 s, earlier data readable |
| `cryptsetup luksKillSlot` for the old keyslot, write-back while attached | 3.6 s, memory of the pod +66 MiB, write-back 0.27 s, I/O continues |
| Secret changed to the new passphrase | a Machine reconcile 3 s later sent detach and attach. The disk was gone from the VM for 52 s, until the next resync of libvirt-provider, and came back with the new passphrase. Earlier data readable |
| Second change of the Secret, an added key | no Machine reconcile within 14 minutes |
| Fresh open from the kind node with each passphrase | the old one fails with `encryption load fail: Operation not permitted`, the new one reads the data |
| Clean-up | test Volume, Secret and image removed, the example volume still `Attached` |

## Assumed, not run

- A build from Clyso's build system behaves like the upstream el10 image. The
  recipe says el10 and an RPM repository per architecture; no such build was
  used.
- macOS and WSL2. The toolbox reaches the cluster over the kind network, which
  should not depend on the host. The uid handling in `lab` differs there.
- x86_64.
- Replacing the other five images. Same code path as the provider.
- The rotation itself. No build with rotation was at hand. The header rewrite
  check stands in for it with `cryptsetup` on a copy of the header, and its
  I/O did not come from a guest with a mounted filesystem.

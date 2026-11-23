# Does ironcore-in-a-box fit a librbd prototype?

Short answer. It is the right base, and it is not enough as it is. It brings
up everything the prototype needs to see (IronCore API, volume provider, Ceph,
a VM with an encrypted volume attached). It has no way to put a different
librbd into the volume provider, it can replace only one component by a local
build, and its storage setup fails on a host that already uses `/dev/loop0`.

Checked against ironcore-in-a-box
[`8263add`](https://github.com/ironcore-dev/ironcore-in-a-box/tree/8263adde111d43b0d7bd68d6e0701dcb530db2cd),
ceph-provider
[`4c61421`](https://github.com/ironcore-dev/ceph-provider/tree/4c614216a8b33f5a65aa843aef896844f7f6b8e3)
(three commits after v0.7.0; ironcore-in-a-box deploys v0.6.0), libvirt-provider
[`e32613e`](https://github.com/ironcore-dev/libvirt-provider/tree/e32613e2f9df843d30fa7b859789289b5b16e30f)
and cbs-components
[`a55965a`](https://github.com/clyso/cbs-components/tree/a55965a871f1167192e5f377c86e5f6dea741589).
Each point says whether it was run or only read.

## What it gives

- `make up-storage` deploys Rook with one monitor and one OSD, the
  ceph-volume-provider with its volumepoollet, and the libvirt-provider with
  its machinepoollet, all in one kind node. Run, see `development.md`.
- Encrypted volumes work. A Volume with `spec.encryption.secretRef` is
  formatted as LUKS2 by the provider, and a Machine that references it gets
  it attached. Run. The examples of ironcore-in-a-box do not cover this case,
  and its tests do not deploy storage (no `storage` or `volume` in `tests/`).
- VMs run without KVM, in software emulation. Run on a host without
  `/dev/kvm`, the libvirt domain is of type `qemu`.

## Where librbd is, and why neither place can be swapped today

The picture is in the top-level `README.md`. Two processes link librbd.

**The volume provider.** It calls librbd through go-ceph, a cgo binding
([`go.mod:7`](https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/go.mod#L7),
the format call is at
[`image_controller.go:719`](https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/internal/controllers/image_controller.go#L719)).
Its image is built from Debian packages of upstream Ceph
([`Dockerfile:38`](https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/Dockerfile#L38))
and then 55 shared libraries are copied one by one from the Debian 12 build
stage into a distroless image
([`Dockerfile:113`](https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/Dockerfile#L113)).
A Ceph build that comes as RPMs does not fit into this file. For example, an
el10 `librbd.so.1` would have to be unpacked by hand next to the copied C
library of Debian 12 (glibc 2.36), which is older than the one it was built
with (2.39). Read, not tried.

**QEMU.** The libvirt-provider links no Ceph library. It writes a libvirt disk
with `<encryption format='luks2' engine='librbd'>`
([`machine_controller_volumes.go:817`](https://github.com/ironcore-dev/libvirt-provider/blob/e32613e2f9df843d30fa7b859789289b5b16e30f/internal/controllers/machine_controller_volumes.go#L817)),
and QEMU opens the image through its own librbd. QEMU and libvirt run inside
the kind node, installed with apt into the node image
([`Dockerfile:13`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/Dockerfile#L13)).
Read from the published node image: Debian 13, QEMU 10.0.13, librbd1 18.2.7.

**The Ceph build under test.** Clyso's build system builds Ceph 20 and later
for el10 only
([`cbs.component.yaml:32`](https://github.com/clyso/cbs-components/blob/a55965a871f1167192e5f377c86e5f6dea741589/components/ceph/cbs.component.yaml#L32)),
as a signed RPM repository and a container image on Rocky Linux 10. Read, no
such build was at hand. The upstream image `quay.io/ceph/ceph:v21.2.0` has the
same shape (Rocky Linux 10.2, RPMs under `<repo>/<arch>/`) and stood in for it.

So the build under test is el10, the provider image is Debian by hand-picked
library, and the kind node is Debian by package. Decisions 2 and 3 in
`design-decisions.md` say what the lab does about each.

## What else is missing

1. **Only libvirt-provider can come from a local checkout.**
   `LIBVIRT_PROVIDER_CONFIG_DIR` and `LIBVIRT_PROVIDER_IMAGE_TAG` are the only
   overrides
   ([`prepare-local-config.sh:33`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/hack/prepare-local-config.sh#L33)).
   ironcore, the poollets and the ceph-volume-provider are pinned to release
   tags
   ([`base/ceph-volume-provider/kustomization.yaml:8`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/base/ceph-volume-provider/kustomization.yaml#L8)).
   A rotation feature touches all of them. For example, after a rotation the
   libvirt secret of a running VM still holds the old passphrase, which is a
   change in machinepoollet or libvirt-provider, not in the volume provider.
   Read.

2. **Storage takes `/dev/loop0` without asking.** The kind node mounts the
   host's `/dev`
   ([`kind-config.yaml:6`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/kind/kind-config.yaml#L6)).
   The setup script attaches its file to loop0 only if loop0 is unused
   ([`setup-storage.sh:14`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/hack/setup-storage.sh#L14)),
   and Rook is told to use loop0 in any case
   ([`cluster.yaml:32`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/base/rook-cluster/cluster.yaml#L32)).
   On Ubuntu with snaps loop0 is a snap. On the test host it was
   `snapd_28331.snap`, so Rook would have been pointed at a device that is not
   ours. Read, and deliberately not run against the snap. No issue for this
   exists upstream as of 2026-11-22.

3. **The provider starts before its pool exists.** The pool and the provider
   are applied together, the provider exits with `pool ceph-volume-provider
   not found` and comes back only after the crash loop back-off. Run: 8
   restarts until a manual restart.

4. **The provider's memory limit is 256Mi**
   ([`patch-manager-deployment.yaml:21`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/base/ceph-volume-provider/patch-manager-deployment.yaml#L21)).
   Enough for the upstream image to format a volume. Run: the provider built
   against Ceph 21 uses about 200 MiB at rest, and one `rbd --version` in the
   same container got both processes killed by the kernel (`Memory cgroup out
   of memory`). A keyslot operation with argon2id needs several hundred MiB
   on top.

5. **The host needs make and Go**, and the Makefile installs kind and cmctl
   with `go install`. Not a fault, but more than "Docker only".

6. **The wait for the address of the Ceph monitor is 100 s.** Before the
   provider is deployed, a script reads the address from a ConfigMap of
   Rook, 20 tries 5 s apart
   ([`detect-ceph-mon-enpoints.sh:11`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/hack/detect-ceph-mon-enpoints.sh#L11-L12)).
   In that time the kind node pulls the Rook image and the Ceph image. Run:
   55 and 60 s of the 100 on the Linux test host, and a timeout on a Mac,
   where the Ceph cluster was ready 90 s after it (decision 10). A second
   run on that Mac needed 102 s.

Points 2, 3 and 6 are plain fixes that could go upstream. Point 1 is a feature
ironcore-in-a-box could grow, its `hack/mutate-*.sh` pattern is made for it.
None of this has been proposed upstream yet.

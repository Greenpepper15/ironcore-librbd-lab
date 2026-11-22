# Design decisions

Each entry gives the decision in one sentence, then the problem, why it won,
the alternatives that lost, what we accept, and an implementation note.
Entries are never renumbered or deleted. A revised one is marked "Superseded
by". Open work is under TODO at the end.

The findings behind the decisions are in `ironcore-in-a-box-fit.md`.

## 1. The lab is a layer on top of ironcore-in-a-box, pinned as a submodule

**Problem.** The prototype needs IronCore, Ceph and a VM on one laptop.
ironcore-in-a-box provides that, but misses a few things (fit document,
"What else is missing").

**Why.** The IronCore developers know ironcore-in-a-box and keep it working.
A layer keeps their bring-up unchanged, so a problem can be reproduced with
plain `make up-storage`, and a new upstream commit is one submodule bump.

**Alternatives that lost.**
- A fork of ironcore-in-a-box with the changes inside. Closest to how its
  users work, but a fork of a public repository is public, and the fork would
  mix this prototype with fixes that belong upstream.
- An own bring-up from scratch (kind plus manifests). Full control, and the
  networking part alone (dpservice, metalnet, metalbond) is more than the lab
  is worth.

**What we accept.** The lab reaches into files that ironcore-in-a-box
generates (`.tmp/config/cluster/local/<component>`) and repeats two of its
Makefile targets (`rook`, `ceph-volume-provider`) with changes. A submodule
bump can break that and has to be tested.

**Implementation.** Submodule `ironcore-in-a-box` at `8263add`.
`hack/apply-overrides.sh` renders a kustomize overlay per component into
`.lab/overlays/` with the generated ironcore-in-a-box config as its base.
`Makefile` targets `up-ironcore` (calls `make up` of the submodule) and
`up-storage` (own sequence).

## 2. The volume provider is built on top of the Ceph image under test

**Problem.** The provider has to call the librbd of a Ceph build that exists
as an el10 container image and an RPM repository. The upstream provider image
is assembled from Debian packages and cannot take it.

**Why.** With the Ceph image as build stage and as runtime base, librbd and
all its dependencies are the set that was built and tested together. The
`-devel` packages are installed in exactly the version of the `librbd1` in
the image, so headers and library cannot drift apart. The pod also contains
the `rbd` tool of the build, which makes a new `rbd` subcommand testable
against a live volume before any Go code exists.

**Alternatives that lost.**
- Unpack the RPMs into the upstream distroless image. Keeps the image small,
  needs a hand-kept list of libraries per build, and mixes two distributions.
- A slim image, Rocky Linux plus `librbd1` and `librados2` only. Smaller
  (the Ceph image is about 2.4 GB), but then `rbd` is missing, or
  `ceph-common` pulls most of the size back in.

**What we accept.** A large provider image. Loading it into the kind node
took about two and a half minutes on the test host. The image is for the
lab only.

**Implementation.** `images/ceph-volume-provider/Dockerfile`, build context
is a ceph-provider checkout, arguments `CEPH_IMAGE`, `CEPH_REPO_URL`,
`CEPH_REPO_GPGKEY`, `GO_BUILD_TAGS`. `hack/build-ceph-volume-provider.sh`
prints the `librbd1` package and the libraries the binary resolved. Checked
with `quay.io/ceph/ceph:v21.2.0` and ceph-provider `4c61421`: go-ceph v0.41.0
compiles against the Ceph 21 headers without build tags.

## 3. QEMU in the kind node keeps its Debian librbd

**Problem.** The VM's I/O goes through a second librbd, the one QEMU loads
inside the kind node (Debian 13, librbd 18.2.7). Should the lab replace it by
the build under test as well?

**Why not.** The rotation variants under test change what the provider does
to the LUKS header. QEMU only has to keep the image open while that happens,
which an unchanged librbd is expected to do (not run in this lab yet, no
build with rotation was at hand). An IronCore hypervisor in production also
runs the librbd of its own distribution, not the one of the provider image,
so two different versions on the two sides is the realistic case. And the
build comes as el10 RPMs while a kind node has to be the Debian based
`kindest/node` image.

**Alternatives that lost.**
- Unpack the el10 libraries into the node and point QEMU at them. Two
  distributions in one process, a fragile image nobody else would run.
- Run libvirt and QEMU in an el10 container next to the node. Clean
  packaging, but it moves VM networking (tap devices of dpservice) across a
  container boundary and changes ironcore-in-a-box deeply.

**What we accept.** A variant that needs new librbd code on the QEMU side
cannot be tried in this lab as it is. An example would be attaching a volume
with the volume key instead of a passphrase, which also needs changes in QEMU
and libvirt.

**Implementation.** Nothing to build. `hack/status.sh` prints both versions.
Checked: a volume formatted by librbd 21.2.0 in the provider was hot-attached
to a running VM whose QEMU uses librbd 18.2.7.

## 4. The Ceph cluster stays on the version ironcore-in-a-box pins

**Problem.** Should Rook run the build under test too?

**Why not by default.** librbd is a client library and LUKS happens on the
client. The cluster only stores the bytes. Keeping the pinned image (19.2.3)
leaves the Rook part exactly as ironcore-in-a-box ships it.

**What we accept.** A client that is two major versions ahead of the cluster.

**Implementation.** `CEPH_CLUSTER_IMAGE` replaces the image for whoever wants
it. Not run with a Ceph 21 image, Rook v1.18.9 may not accept it.

## 5. Components are replaced by image, through settings in `lab.env`

**Problem.** A rotation feature spans several repositories. Each way of
integrating librbd should be quick to roll out and to roll back.

**Why.** Every IronCore component in the cluster is one container image. One
setting per image, and one `./lab deploy`, covers all six with the same code
path. A locally built image is loaded under a tag made from its image ID, so
a rebuild changes the Deployment and rolls out by itself, and an unchanged
image is a no-op.

**Alternatives that lost.**
- `kubectl set image` after the bring-up. Shorter, but the next apply of
  ironcore-in-a-box silently reverts it.
- Tilt or Skaffold. They do this loop well and add a tool the team would have
  to learn for a prototype.

**What we accept.** Manifests still come from the pinned release tags. A
change that needs new RBAC rules or flags has to be patched by hand for now
(TODO 2).

**Implementation.** `hack/apply-overrides.sh`, settings in `lab.env.example`.
Run for the ceph-volume-provider only. The other five images use the same
code path and were not exercised.

## 6. All tools run in a toolbox container

**Problem.** ironcore-in-a-box needs make and Go on the host and installs
kind, kubectl and cmctl from there. The lab should run on Linux, macOS and
Windows laptops with as little setup as possible.

**Why.** With the tools in one image the host needs Docker and bash, and
everybody runs the same versions. The toolbox reaches the cluster over the
kind Docker network by the node's name, which does not depend on how the
host publishes ports.

**Alternatives that lost.**
- Install the tools on the host, as upstream documents. One more list of
  prerequisites per operating system.
- Host networking for the toolbox. Simple on Linux, behaves differently on
  Docker Desktop.

**What we accept.** `./lab` in front of every command, and a toolbox with
access to the Docker socket. The BuildKit plugin comes with the toolbox,
because a host Docker may lack it (the test host did).

**Implementation.** `toolbox/Dockerfile`, `lab`. On Linux the toolbox runs
with the caller's uid so files stay owned by the caller. The macOS and WSL2
paths of `lab` are written and not run.

## 7. The OSD gets a free loop device, not `/dev/loop0`

**Problem.** ironcore-in-a-box gives Rook `/dev/loop0`, which on a host with
snaps belongs to something else (fit document, point 2).

**Why.** Asking the kernel for a free device works on every host and is one
line. The name is patched into the CephCluster.

**What we accept.** The lab repeats the `rook` target of ironcore-in-a-box
instead of calling it.

**Implementation.** `hack/storage.sh` creates a sparse 10 GiB file in the
node, attaches it with `losetup -f`, writes the device to `.lab/osd-device`.
`./lab down` detaches it. On the test host the device was `/dev/loop6`.

## 8. The lab raises the provider's memory limit and restarts it once

**Problem.** Points 3 and 4 of the fit document: the provider crash-loops
until its pool exists, and 256Mi do not hold the provider plus one `rbd`
call.

**Why.** Both are needed for a first run to succeed without manual steps.

**Implementation.** `hack/apply-overrides.sh` sets the limit of the
`ceph-volume-provider` container to `CEPH_VOLUME_PROVIDER_MEMORY` (default
2Gi). `Makefile` waits for the CephBlockPool, then restarts the Deployment.
The default is a guess with headroom. It has not been measured against a
keyslot operation (TODO 4).

## TODO

Deferred work and open questions. Numbers stay.

1. **A real build from Clyso's build system.** Everything was run with the
   upstream 21.2.0 image. Open: does its RPM repository carry `librbd-devel`
   under `<url>/<arch>/` as the upstream one does, which signing key applies,
   and how do people outside Clyso get pull access to image and repository.
2. **Manifests from a local checkout.** Only images are replaced. For
   libvirt-provider the `LIBVIRT_PROVIDER_CONFIG_DIR` of ironcore-in-a-box
   could be passed through. The other components need the same.
3. **Architectures.** Apple silicon laptops need an aarch64 build of Ceph,
   other laptops x86_64. Open whether both are built.
4. **Memory during a keyslot operation.** Measure the provider while it adds
   a keyslot, then set the default limit from that.
5. **macOS and Windows.** Run the quick start on Docker Desktop and on WSL2.
6. **go-ceph bindings for new librbd calls.** A prototype that adds C calls
   needs them in Go. Open whether through a go-ceph fork named in the
   provider's `go.mod` or a small cgo file in the provider.
7. **Variants that need privileges in the provider pod.** Mapping an image
   with krbd or rbd-nbd inside the pod needs a privileged container and
   kernel modules on the laptop. Not prepared.
8. **A provider-only mode.** For work on the provider API alone, IronCore
   plus storage without networking and VMs would start faster and avoid the
   kernel requirements of dpservice. Not tried.
9. **Upstream.** Propose the loop device fix and the start-up order fix to
   ironcore-in-a-box, and ask whether overrides for all components would be
   welcome there.

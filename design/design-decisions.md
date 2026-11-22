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
which an unchanged librbd did in a check with a stand-in for the rotation
(see Implementation). An IronCore hypervisor in production also
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
to a running VM whose QEMU uses librbd 18.2.7. Checked with a stand-in for
the rotation (TODO 10): the I/O of the VM went on while a keyslot was added
to the header and another one removed from inside the provider pod, and the
next attach through QEMU's librbd unlocked the rewritten header.

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
The default is a guess with headroom. A keyslot operation was measured with
a stand-in only (TODO 4).

## TODO

Deferred work and open questions. Numbers stay.

1. **A real build from Clyso's build system.** Everything was run with the
   upstream 21.2.0 image. Read in the Ceph recipe and in the source of the
   build system, not run:
   - The RPM repository has the layout the provider image expects,
     `<repository>/<arch>/`
     ([`build_rpms.sh:149`](https://github.com/clyso/cbs-components/blob/a55965a871f1167192e5f377c86e5f6dea741589/components/ceph/scripts/rpm/build_rpms.sh#L149)).
     The repository of a build ends in
     `ceph/rpm-<version>/el10-<arch>.clyso`, so `CEPH_REPO_URL` differs
     between architectures.
   - The repository file that a build ships turns the signature check on
     ([`build_rpms.sh:87`](https://github.com/clyso/cbs-components/blob/a55965a871f1167192e5f377c86e5f6dea741589/components/ceph/scripts/rpm/build_rpms.sh#L87)).
     Packages are signed when the build system has a signing key configured.
     The image recipe reads the public key from `keys/release.asc` below the
     base URL of the artifacts, not below the repository
     ([`image.yaml:33`](https://github.com/clyso/cbs-components/blob/a55965a871f1167192e5f377c86e5f6dea741589/components/ceph/images/v21/image.yaml#L33)).
     Its URL goes into `CEPH_REPO_GPGKEY`.

   Access to the image and the repository comes with the build, from the
   person who provides it. Open until the first real build are the public
   URL and whether the repository needs a login. If it does, the image build
   needs a way to pass it.
2. **Manifests from a local checkout.** Only images are replaced. For
   libvirt-provider the `LIBVIRT_PROVIDER_CONFIG_DIR` of ironcore-in-a-box
   could be passed through. The other components need the same.
3. **Architectures.** The provider container runs on the CPU of the laptop.
   Apple silicon laptops need an aarch64 build of Ceph, other laptops x86_64.
   Read in the source of the build system, not run. It builds natively, so
   an aarch64 build needs an aarch64 build machine, and the Ceph recipe sets
   no limit on the architecture. Open whether such a machine is available.
   When both are built, each architecture needs its own image tag, because
   the tag carries no architecture and a build is skipped when its tag
   exists. The repository URL differs as well (TODO 1). Without an aarch64
   build see TODO 5.
4. **Memory during a keyslot operation.** Measure the provider while it adds
   a keyslot, then set the default limit from that. Measured so far with a
   stand-in, `cryptsetup luksAddKey` as a child process in the provider pod
   (`development.md`, "Header rewrite check"). The memory of the pod rose by
   66 MiB, to 292 MiB at a limit of 2Gi, and the call took 18.5 s at the
   pod's CPU limit of 200m.

   The 66 MiB follow from the keyslot, which uses argon2id with 64 MiB.
   librbd leaves the choice to libcryptsetup outside its test mode
   ([`Header.cc:155`](https://github.com/ceph/ceph/blob/b060042deb05d33e6cc358970cfb8221240bcf3e/src/librbd/crypto/luks/Header.cc#L155)),
   and libcryptsetup measures the CPU when the keyslot is created. 64 MiB is
   the lowest result of that measurement
   ([`pbkdf_check.c:47`](https://gitlab.com/cryptsetup/cryptsetup/-/blob/9cfdd6ba068b375a2b6cda429b3f92388448dd67/lib/crypto_backend/pbkdf_check.c#L47)),
   the highest is 1 GiB by default
   ([`meson_options.txt:20`](https://gitlab.com/cryptsetup/cryptsetup/-/blob/9cfdd6ba068b375a2b6cda429b3f92388448dd67/meson_options.txt#L20)).
   A provider with more CPU is therefore expected to create keyslots that
   need more memory to open, not run.

   Open: the same with the provider process calling librbd itself, with a
   higher CPU limit, and at the 256Mi of ironcore-in-a-box.
5. **macOS and Windows.** Run the quick start on Docker Desktop and on WSL2.
   If a build exists for x86_64 only, a Mac with Apple silicon has three
   routes, none of them tried:
   - A whole x86_64 Linux VM under QEMU, for example with
     [Lima](https://lima-vm.io/docs/config/multi-arch/). The lab should run
     unchanged in it and very slowly, since the VM of the example is then
     emulated twice.
   - An arm64 Linux VM in which only the provider pod runs through QEMU
     user-mode emulation.
   - The same with Rosetta. el10 binaries need the x86-64-v3 CPU level and
     Rosetta is reported to stop at v2 (`Fatal glibc error: CPU does not
     support x86-64-v3`,
     [RHEL-33471](https://issues.redhat.com/browse/RHEL-33471), read
     2026-11-22), so this route is expected to fail for a build on el10.

   The last two also need the lab to build or pull the provider image for
   another architecture and to load it into the kind node. Neither is
   prepared.
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
10. **QEMU's old librbd against a rewritten header.** Decision 3 relies on
    two things. The I/O of a running VM continues while the provider
    rewrites the LUKS header, and at the next attach QEMU's librbd 18.2.7
    unlocks the header with the new passphrase. Both held in a check with a
    stand-in for the rotation (`development.md`, "Header rewrite check").
    The stand-in was `cryptsetup` 2.8.1 on a copy of the header in the
    provider pod, with the changed blocks written to the image through
    librbd 21.2.0. The other side was QEMU 10.0.13 with librbd 18.2.7 and
    libcryptsetup 2.7.5.
    - Writing the header takes the exclusive lock of the image away from
      QEMU. QEMU takes it back at its next write. Two writes of the VM
      waited about half a second for that.
    - A header in which the newer libcryptsetup had added one keyslot and
      removed another was unlocked by the older one with the new
      passphrase. The old passphrase was refused.

    Open: the same with a build whose librbd does the rotation itself, and
    with a guest that writes to a mounted filesystem. The I/O of the check
    was sent through the QEMU monitor.
11. **The new passphrase on the VM side.** QEMU's librbd gets the passphrase
    at every attach, from the Secret that the Volume names. After a rotation
    that Secret has to hold the new one. Seen in the header rewrite check,
    with ironcore v0.6.1 and libvirt-provider v0.5.0:
    - The passphrase is the value of `encryptionKey` as it is. If the value
      is base64 text, the text is the passphrase and the decoded bytes are
      refused.
    - machinepoollet compares the whole data of the Secret with what the
      machine runtime holds
      ([`machine_controller_volume.go:202`](https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L202),
      [`:318`](https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L318)).
      On a difference it detaches the volume and attaches it again
      ([`:340`](https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L340)),
      and the disk leaves the running VM. In the check it was gone for 52 s,
      until libvirt-provider's next resync, which runs once a minute. The
      guest did not use the disk.
    - A change of the Secret does not start this. The Secret watch of
      machinepoollet covers the ignition Secret only
      ([`util.go:68`](https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/api/compute/v1alpha1/util.go#L68)),
      and a second change was not picked up within 14 minutes. It happens at
      the next reconcile of the Machine. In the check one came 3 s after the
      first change, and what started it was not found.
    - An attach with a passphrase whose keyslot is gone fails (`encryption
      load fail`). So the old keyslot may only go when nothing attaches with
      the old passphrase any more.

    Open: the order of the steps of a rotation (new keyslot, Secret, old
    keyslot) and what tells the provider that every VM has moved on. Also
    whether the disk has to leave the VM at all. QEMU keeps working with the
    volume key it has, and machinepoollet carries a note for an update in
    place
    ([`:372`](https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L372)).

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
with the caller's uid so files stay owned by the caller. The macOS path ran
on Docker Desktop: the toolbox runs as root there and the files it wrote
into the clone belong to the user (`development.md`, "macOS"). The WSL2
path is written and not run.

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

## 9. A build for another architecture runs through emulation, in the provider pod only

**Problem.** The provider container runs on the CPU of the host. A Ceph build
may exist for one architecture only (TODO 3), for example x86_64 while the
laptop is an Apple silicon Mac or the host is an arm64 server.

**Why.** Only the provider has to run the build under test (decisions 3 and
4). With `CEPH_PLATFORM` the lab builds the provider image for the
architecture of the Ceph build and loads it into the node, and the kernel of
the host starts the programs of that image through QEMU's user-mode
emulation. The cluster, IronCore and the VM stay native, and the Dockerfile
and the manifests are the same in both cases.

**Alternatives that lost.**
- Wait for a build of the host's architecture. Still the answer for anything
  that is measured, and it blocks every arm64 host until such a build exists.
- A whole x86_64 Linux VM under QEMU, for example with
  [Lima](https://lima-vm.io/docs/config/multi-arch/). The lab runs unchanged
  in it, but the kind node, Ceph and the example VM are then all emulated,
  the example VM twice.
- Compile the provider natively with a cross compiler and emulate only when
  it runs. A faster image build, paid for with a second toolchain and a copy
  of the image's libraries to link against, kept in step with every build.
- Rosetta on Apple silicon. el10 binaries need the x86-64-v3 CPU level and
  Rosetta was reported to stop at v2 (`Fatal glibc error: CPU does not
  support x86-64-v3`,
  [RHEL-33471](https://issues.redhat.com/browse/RHEL-33471), read
  2026-11-22), so it was expected to fail for a build on el10. A run on a
  Mac showed the opposite, see the implementation note. Rosetta is
  therefore not an alternative that lost. It is the emulator that Docker
  Desktop uses on such a Mac unless its setting is turned off.

**What we accept.**
- The kernel of the host needs the emulation registered in `binfmt_misc`.
  The lab does not do that by itself. On a plain Linux host it is one
  privileged container run and lasts until the next reboot.
- An emulated provider is slow, and its timings and memory figures say
  nothing about a native one.
- The emulation is one more thing that can fail under a Go program with
  many threads that calls into librbd.

**Implementation.** `CEPH_PLATFORM` in `lab.env`, for example `linux/amd64`.
Empty means the architecture of the host and changes nothing.
`hack/build-ceph-volume-provider.sh` passes it to `docker build`. Before
that it starts one program of the Ceph image and stops with a hint when the
emulation is missing. `hack/apply-overrides.sh` loads the provider image
with `docker save --platform` and `kind load image-archive`, because `kind
load docker-image` fails for an image of another platform in its `docker
save` step (`unable to create manifests file: NotFound: content digest ...
not found`, Docker 29.1.3 with the containerd image store).

Checked on the arm64 host of `development.md` with the x86_64 variant of
the upstream 21.2.0 image, QEMU 10.2.3 registered by `docker run
--privileged --rm tonistiigi/binfmt --install amd64` ("Emulated provider"
in `development.md`). The el10 userland starts there, so this QEMU offers
the x86-64-v3 level.

Checked on 2026-11-22 on Docker Desktop 4.76.0 on a Mac with Apple silicon
(`development.md`, "macOS"), with the same x86_64 image and `docker run
--platform linux/amd64` only. `rpm` and `rbd` of the el10 userland start
there without a registration step. Docker Desktop has Rosetta and QEMU
10.0.4 registered. Rosetta ran the programs and offers the x86-64-v3 level.

Run there on 2026-11-23 with the first build from Clyso's build system, for
x86_64. The image build took 3 min 43 s, and inside the cluster Rosetta
starts the provider (`/run/rosetta/rosetta /ceph-volume-provider`). It
created an encrypted Volume in 15 s and did not restart. Not run there: the
same with the Rosetta setting turned off.

With `CEPH_PLATFORM` set, `hack/apply-overrides.sh` also raises the CPU
limit of the provider container, to `CEPH_VOLUME_PROVIDER_CPU` (default 2).
At the 200m of ironcore-in-a-box an emulated provider with librbd 22 was
throttled nearly all the time and the pod restarted in a loop. At 2 it was
not throttled ("Build with rotation commands" in `development.md`). Without
`CEPH_PLATFORM` the limit stays as ironcore-in-a-box sets it, unless
`CEPH_VOLUME_PROVIDER_CPU` is set.

The CPU limit has a side effect on the volumes. A provider with more CPU
creates keyslots that need more memory to open, 732 MiB under Rosetta at a
limit of 2 against 64 MiB at 200m (TODO 4).

## 10. The lab waits 15 minutes for the address of the Ceph monitor, not 100 seconds

**Problem.** The provider is deployed with the address of the Ceph monitor.
ironcore-in-a-box reads it from a ConfigMap that Rook writes once the
monitor runs. Its script asks 20 times, 5 s apart, and then gives up
([`detect-ceph-mon-enpoints.sh:11`](https://github.com/ironcore-dev/ironcore-in-a-box/blob/8263adde111d43b0d7bd68d6e0701dcb530db2cd/hack/detect-ceph-mon-enpoints.sh#L11-L12)).
In those 100 s the kind node has to pull the Rook image and the Ceph image,
and Rook has to find the Ceph version and start the monitor. The node is new
with every cluster, so it pulls these images at every `./lab up`.

Example. The first `./lab up` on a Mac stopped after 9 min 24 s with `Error:
timed out waiting for ceph mon endpoints`. The Ceph cluster was ready 90 s
later, and a second `./lab up-storage` passed in 59 s. On the Linux test
host the same wait took 55 and 60 s of the 100.

**Why.** The script takes the number of tries from the environment
(`MAX_RETRIES`), so the lab sets it where it calls the script, and the
submodule stays as it is. 15 minutes is the limit that the next step of
`up-storage`, the wait for the pool, already has.

**Alternatives that lost.**
- Tell the reader to run `./lab up-storage` a second time. It works, and a
  quick start whose first command fails loses the reader.
- Wait for the CephCluster to be `Ready` with `kubectl wait` before the
  script runs. That is a second wait in front of the first, and it also
  waits for the OSD, which the script does not need.
- Pull the two images on the host and load them into the node. The wait
  would no longer depend on the link after the first run. It needs a list
  of image names that has to follow the submodule, and loading a large
  image into the node takes minutes as well, two and a half for the
  provider image (decision 2).

**What we accept.** A storage setup that is really broken reports that after
15 minutes instead of 100 s, with one line every 5 s until then.

**Implementation.** `Makefile`, target `up-storage`, calls the script with
`MAX_RETRIES=180`. Checked on the Linux test host: the script honours the
variable. A copy of it with a `kubectl` that always fails gave up after 3
tries with `MAX_RETRIES=3`. The changed line, run in the toolbox against
the running cluster, found the address at the first try. That the node
pulls the images at every cluster creation was read from the containerd log
of the node.

Run on 2026-11-23 on the Mac (`development.md`, "macOS"). `./lab up` from
nothing passed in one go. The script printed 20 waits and found the address
at the 21st try, 102 s after the first, so the 100 s would have failed
again. 80 s of that were the pull of the Rook image. The Ceph image of the
cluster then took 1.3 s, because the Rook image is built on it. Not run:
`./lab up` from nothing with the longer wait on the Linux host.

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
   person who provides it. Known from the first build, 2026-11-22, checked
   from the lab host: the RPM repository is readable without a login, its
   packages are signed, and `rpm -K` accepts them with the key at
   `keys/release.asc` of the artifact store. The image is in a private
   project of the registry and needs a login.

   Run with that build on 2026-11-22 ("Build with rotation commands" in
   `development.md`). The provider image built against it as it does
   against the upstream image, with the signature check on. The login does
   not have to reach the toolbox. After `docker login` and `docker pull` on
   the host the image build used the local copy. Open: a build on a host of
   its own architecture.
2. **Manifests from a local checkout.** Only images are replaced. For
   libvirt-provider the `LIBVIRT_PROVIDER_CONFIG_DIR` of ironcore-in-a-box
   could be passed through. The other components need the same.
3. **Architectures.** The provider container runs on the CPU of the laptop.
   Apple silicon laptops need an aarch64 build of Ceph, other laptops x86_64.
   Read in the source of the build system, not run. It builds natively, so
   an aarch64 build needs an aarch64 build machine, and the Ceph recipe sets
   no limit on the architecture. On 2026-11-22 the build system had an x86_64
   build machine only, as reported by the person who builds, not checked from
   the lab. A build is handed only to a machine of its own architecture, so
   an aarch64 build submitted then stays queued and shows no error.
   When both are built, each architecture needs its own image tag, because
   the tag carries no architecture and a build is skipped when its tag
   exists. The repository URL differs as well (TODO 1). Without a build for
   the host's architecture see decision 9.
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
   need more memory to open.

   Run on 2026-11-23 (`development.md`, "macOS" and "Keyslot cost and the
   CPU limit"). The measurement of cryptsetup gave 64 MiB at a CPU limit of
   0.2, 557 MiB at 2 and 668 MiB without a limit, natively on the Linux
   host. On a Mac the x86_64 provider, through Rosetta at a limit of 2,
   created a keyslot with 732 MiB, and QEMU's librbd opened it at attach.
   So the CPU limit of the provider sets the memory that every later open
   of a Volume needs, in QEMU and in the provider, and decision 9 raises
   that limit for an emulated provider. With cryptsetup alone, an open of
   a keyslot with 455 MiB was killed at a memory limit of 256 MiB, and so
   was a format with free CPU at that limit. What this asks of IronCore is
   point 8 of `ironcore-rotation-gaps.md`.

   With the first build that has the commands, `rbd encryption luksAddKey`
   as a child process in the emulated provider pod at a CPU limit of 2: the
   memory of the pod rose by 284 MiB, to 557 MiB, of which the emulated
   `rbd` process alone needs about 230 MiB before it derives a key. The new
   keyslot got the settings of the existing one, 64 MiB, and not the result
   of a measurement on that host. Emulated figures, they do not set the
   default.

   Open: the same with the provider process calling librbd itself, on a
   native provider, and at the 256Mi of ironcore-in-a-box. A keyslot
   command on a Volume whose keyslot needs several hundred MiB, where the
   command gives the new keyslot the cost of the existing one.
5. **macOS and Windows.** Run the quick start on Docker Desktop and on WSL2.
   If a build exists for x86_64 only, a Mac with Apple silicon uses
   decision 9. Open there: whether Docker Desktop starts an el10 x86_64
   image when Rosetta is turned off in its settings, and which QEMU it then
   uses.

   Checked on 2026-11-22 on the Linux host, without a Mac or a Windows
   machine.
   - `lab` is the only script that runs on the host, everything else runs
     in the toolbox. With a stand-in for `docker` it produced the same
     `docker run` call under bash 3.2.57, the bash that macOS ships, as
     under bash 5.2.
   - The WSL2 kernel for x86_64 has `CONFIG_LWTUNNEL` turned off at its
     latest release, 6.18.58.1
     ([`config-wsl:1947`](https://github.com/microsoft/WSL2-Linux-Kernel/blob/a989171929bed4ea681be8d77333845ce1c1732a/arch/x86/configs/config-wsl#L1947)),
     and ironcore-in-a-box lists that option as required. A Windows laptop
     with an x86_64 CPU is therefore expected to need the custom kernel of
     the ironcore-in-a-box guide, not run. The arm64 config has all three
     options
     ([`config-wsl-arm64:2040`](https://github.com/microsoft/WSL2-Linux-Kernel/blob/a989171929bed4ea681be8d77333845ce1c1732a/arch/arm64/configs/config-wsl-arm64#L2040)).
     A running WSL2 kernel shows its options in `/proc/config.gz`.

   Run on 2026-11-22 on a Mac with Apple silicon, Docker Desktop 4.76.0 on
   macOS 27.2 (`development.md`, "macOS"), without a build under test. The
   quick start works there with the upstream provider image, once
   `./lab up-storage` was run a second time (decision 10). The toolbox runs
   as root and the files it writes belong to the user. With the Rosetta
   setting on, the el10 x86_64 programs of the upstream 21.2.0 image start
   through `docker run`, and Rosetta offers the x86-64-v3 level.

   Run on 2026-11-23 on the same Mac, with the longer wait of decision 10
   and with the first build under test, for x86_64 (`development.md`,
   "macOS"). `./lab up` passed from nothing in 6 minutes. The provider
   image was built in under 4 minutes and the provider runs through Rosetta
   inside the cluster. `/bin/bash ./lab status` works under the bash
   3.2.57 of macOS. The run with a build under test took 16 GiB of disk.

   Open on macOS: the Rosetta setting turned off, which is the question
   above, and `./lab up` with `lab.env` in place from the start.

   Open for the WSL2 run. On Linux `lab` starts the toolbox with the
   caller's uid and with the group that the Docker socket has on the host.
   With Docker Desktop behind WSL2 the socket inside the toolbox may belong
   to another group, and `docker` in the toolbox would then be refused.
   `./lab shell` followed by `docker version` shows it.
6. **go-ceph bindings for new librbd calls.** A prototype that adds C calls
   needs them in Go. Open whether through a go-ceph fork named in the
   provider's `go.mod` or a small cgo file in the provider.
7. **Variants that need privileges in the provider pod.** Mapping an image
   with krbd or rbd-nbd inside the pod needs a privileged container and
   kernel modules on the laptop. Not prepared.
8. **A provider-only mode.** For work on the provider API alone, IronCore
   plus storage without networking and VMs would start faster and avoid the
   kernel requirements of dpservice. Not tried.
9. **Upstream.** Propose the loop device fix, the start-up order fix and a
   longer wait for the monitor address (decision 10) to ironcore-in-a-box,
   and ask whether overrides for all components would be welcome there.
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

    Repeated on 2026-11-22 with a build whose `rbd` changes the header
    through librbd 22 ("Build with rotation commands" in `development.md`).
    The second point held: QEMU's librbd 18.2.7 unlocked the rewritten
    header with the new passphrase at the next attach. The first did not
    hold every time, see TODO 13.

    Open: a guest that writes to a mounted filesystem. The I/O of both
    checks was sent through the QEMU monitor.
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

    What IronCore would need to change for this is collected in
    `ironcore-rotation-gaps.md`.

    Open: the order of the steps of a rotation (new keyslot, Secret, old
    keyslot) and what tells the provider that every VM has moved on. Also
    whether the disk has to leave the VM at all. QEMU keeps working with the
    volume key it has, and machinepoollet carries a note for an update in
    place
    ([`:372`](https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L372)).
12. **Image build time under emulation.** With `CEPH_PLATFORM` the whole
    image build is emulated, and the Go compile of the provider took 48
    minutes on the test host, against under 5 minutes natively. Idea, not
    tried: take the Go toolchain for the architecture of the host
    (`FROM --platform=$BUILDPLATFORM`) and set `GOARCH` to the target, so
    that only the C compiler and the linker of the Ceph image run emulated.
    A second build on the same host took 4 minutes, the Go compile 114 s
    of it, because the build cache of the first one was still there.
    Under Rosetta on a Mac the first build took 3 min 43 s, the Go compile
    133 s of it, so the idea matters for hosts that emulate with QEMU.
13. **A header command can hang while the VM writes.** Seen with the build
    `22.0.0-143-g9cce574d9dc7` ("Build with rotation commands" in
    `development.md`). Five of seven runs of `rbd encryption luksAddKey`,
    `keyslot add`, `keyslot remove` and `luksKillSlot` did not return while
    the VM wrote to the disk. The `rbd` process kept the exclusive lock of
    the image, and the VM's write waited until the process was killed, in
    one run 775 s. With an idle VM every command returned within 8 s.

    Example. `luksAddKey` changes three ranges of the header: the two copies
    of the metadata and the area of the new keyslot. They are written one
    after the other, lowest offset first. After the kill the image had both
    metadata copies with the new keyslot in them and no key material for
    it. The new passphrase was refused, the old one still unlocked.

    From the librbd log of one run, with the source of that build (paths in
    the Ceph tree at commit `9cce574d9dc7`): the command starts each write
    as an operation that is already in flight
    (`src/librbd/crypto/luks/HeaderSession.cc:183`). When QEMU asks for the
    lock back between two of them, the next write is held back until the
    lock is taken again (`src/librbd/exclusive_lock/ImageDispatch.cc:138`),
    and the release of the lock flushes first
    (`src/librbd/exclusive_lock/PreReleaseRequest.cc:228`), which waits for
    all operations in flight (`src/librbd/io/AsyncOperation.cc:79`). A
    write through the public API is counted as in flight only after the
    lock layer (`src/librbd/io/ImageDispatch.cc:23`), which fits the
    stand-in of TODO 10 not hanging.

    Confirmed on 2026-11-22 outside the lab ("Cause of the hang" in
    `development.md`). A native build of the same commit hangs in the same
    place when a second librbd client writes and the lock request of that
    client lands between two header writes, in 4 of 5 runs. A debugger on
    the hung process shows the lock in its release step, one write held
    back in the lock layer and the flush of the release waiting for that
    write. When the command no longer marks the write as in flight and
    leaves that to the core layer, as for a write through the public API,
    it returned in 8 of 8 runs. In 7 of them it gave the lock to the other
    client between two header writes and took it back. Emulation is
    therefore not the cause. It makes each write slower, which widens the
    gap that the lock request has to hit.

    A caller can avoid the hang with the build as it is. It takes the
    exclusive lock in transient mode around the write-back of the header
    (`rbd_lock_acquire` with `RBD_LOCK_MODE_EXCLUSIVE_TRANSIENT`, then
    `rbd_lock_release`). The other client then waits for the release
    instead of getting the lock between two header writes. Natively this
    returned in 8 of 8 runs, around the commit of `luksAddKey` and around
    the typed call `encryption_luks_keyslot_add`. Around the commit the
    other client's write waited 0.3 s, around the typed call 2.2 to 2.8 s,
    because that call also derives the key. The handle should be one that
    is opened for the header command only, because after a manual lock a
    handle no longer takes the lock by itself. Not tested with QEMU's
    librbd 18.2.7 as the waiting client. This belongs into the Go binding
    of TODO 6.

    Open for the librbd change, not for the lab: with the one call changed
    the other client writes between two header writes of one command. The
    typed call (`UpdateHeaderRequest.cc` in `src/librbd/crypto/luks/`) has
    the same call and hung natively in 4 of 5 runs.
    `HeaderRestoreRequest.cc` has it too and was not tested. The same
    cycle also occurred with code that upstream ships, in 1 of 90 runs of
    `encryption_format` on a handle that writes at the same time, so the
    cause is not specific to this build.

    With that first build, run the header commands only while the VM does
    not write, call them through a caller that takes the transient lock, or
    expect to kill them. After the kill
    QEMU needed just under 30 s to take the lock, then the VM's I/O went on.

    Run on 2026-11-23 with a second build, `22.0.0-146-g2fd833e9b5ec`
    ("Build with the fix for the hang" in `development.md`). It no longer
    marks the reads and writes of the header as in flight when it creates
    them, and its `rbd` holds the transient lock around the write-back of
    `luksAddKey`, `luksChangeKey` and `luksKillSlot`. 30 of 30 header
    commands returned while the VM wrote, five commands in six cycles. In
    a control right before, the first build hung in 2 of 3 runs of
    `luksAddKey`. 18 of the 30 were `keyslot add`, `keyslot remove` and
    `header restore`, which take no lock of their own, so the change in
    librbd is enough for them. The other 12 had QEMU's librbd 18.2.7 wait
    for the transient lock, which closes the "not tested" above.

    Open: the same check with the provider calling librbd, and whether the
    order of the writes should put the keyslot area before the metadata, so
    that a stop in between leaves the old header.

14. **A fixed keyslot cost when a Volume is created.** Deferred on
    2026-11-23. The format call of librbd takes no cost
    ([`librbd.h:443`](https://github.com/ceph/ceph/blob/b060042deb05d33e6cc358970cfb8221240bcf3e/src/include/rbd/librbd.h#L443-L447)),
    so libcryptsetup measures the CPU of the provider and the result
    differs from host to host (TODO 4). Until this is done the rotation is
    the one place that can give a Volume a known cost (point 8 of
    `ironcore-rotation-gaps.md`).

    Example. The same Volume gets a keyslot with 64 MiB from a provider at
    a CPU limit of 0.2 and one with 557 MiB at a limit of 2. Opening the
    second one needs more memory than a provider at 256Mi has.

    Two ways were looked at. Cost fields in the format options of librbd
    are the direction so far, not decided. The options of the keyslot call
    in the build under test have such fields already, the format options
    have the cipher and the passphrase only. The other way is a header that
    the caller builds with libcryptsetup and writes with the header restore
    call of that build, run on an image that was never formatted
    (`development.md`, "Keyslot cost and the CPU limit").

    Open. Which way, and which cost. How librbd tells format options with
    the new fields from the ones that callers pass today. For the second
    way an attach through QEMU's librbd 18.2.7 and the same on a clone.

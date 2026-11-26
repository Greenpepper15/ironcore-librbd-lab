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

## 11. The ceph-provider source is a submodule, pinned to the commit the lab was run with

**Problem.** The lab builds the volume provider from source, and
`CEPH_PROVIDER_DIR` had to name a checkout that everyone made by themselves.
Nothing recorded which commit of ceph-provider belongs to a state of the
lab, and a changed provider had no place to be fetched from.

Example. All runs up to 2026-11-23 used commit `4c61421` of ceph-provider,
three commits after v0.7.0. A clone of upstream on that day gave `34f0942`,
a provider that the lab had never run.

**Why.** A submodule pins the provider source per commit of the lab, the
way decision 1 pins ironcore-in-a-box, and the one clone of the quick start
brings everything a build needs. The submodule points at a fork of
ceph-provider, so a prototype is a branch there and a new pin here.
`CEPH_PROVIDER_DIR` stays and wins when it is set, for work in a checkout
of one's own.

**Alternatives that lost.**
- A line in the README that names the commit to clone. Nothing checks it,
  and it is one more step for every reader.
- The provider source copied into the lab. A change could then not go back
  to ceph-provider as a commit.

**What we accept.** A change to the provider takes two pushes, one to the
fork and one for the new pin. The fork is public, so text in its commits
follows the rules for upstream text. The manifests still come from the
version that ironcore-in-a-box names, v0.6.0, while the source is 16
commits newer (TODO 2).

**Implementation.** Submodule `ceph-provider`, its URL is in `.gitmodules`,
pinned at `4c61421`, and since decision 14 one commit further. Since
decision 16 the pin is `463eacd`, on a branch that starts at
ceph-provider `main` of 2026-11-24.
`hack/build-ceph-volume-provider.sh` builds from it
when `CEPH_PROVIDER_DIR` is empty, and says how to fetch it when the
directory is empty.

Checked on 2026-11-23 on the Linux test host. The tree of the submodule at
`4c61421` equals the tree of the checkout that all earlier runs used. With
`CEPH_PROVIDER_DIR` unset, `./lab build-ceph-volume-provider` printed
`ceph-provider source: /lab/ceph-provider` and built in 11 s from the build
cache. The provider binary in that image has the same SHA-256 and size as
the one in the image that the lab runs with the second build under test.
With an empty directory as source the script stops with the hint to fetch
the submodule. A clone from nothing with `--recurse-submodules` brought the
submodule at `4c61421` with the same tree, and the build script found the
source in it. Not run: a host that has a directory `ceph-provider` in the
clone already.

## 12. The provider is built with go-ceph from a submodule, a fork that takes the new bindings

**Problem.** The provider calls librbd through go-ceph, in the version its
`go.mod` names. A librbd call that only the build under test has is in no
go-ceph release, and its binding compiles only where the header of that
build is, which is the image build of the lab (TODO 6).

Example. The build under test has a keyslot call in `librbd.h`. go-ceph
v0.41.0, which the provider names, has `EncryptionFormat` and
`EncryptionLoad` and nothing for keyslots, so the provider cannot call it.

**Why.** With go-ceph as a pinned submodule the source of a binding is in
the clone, and the image build takes go-ceph from there. A binding can be
changed and built without a push and without a release. The submodule
points at a fork of go-ceph, so a set of bindings is a branch there and a
new pin here, the way decision 11 does it for the provider. `GO_CEPH_DIR`
names a checkout of one's own and wins when it is set.

**Alternatives that lost.**
- The fork named in the `go.mod` of the provider, with a `replace` line.
  A provider branch then builds anywhere. But every change to a binding
  has to be pushed to the fork, and the `go.mod` of the provider moved,
  before it compiles for the first time.
- A cgo file in the provider for the new calls. No second repository, but
  the bindings then sit apart from the encryption calls that go-ceph has,
  and would have to be moved to be offered to go-ceph. It stays an option
  for calls outside librbd (TODO 6).

**What we accept.** The lab builds the provider from two forks. Nothing
keeps a fork or a pin in step with upstream, so both fall behind unless
someone moves them (TODO 15). A provider branch that calls a new binding
builds in the lab only, until its `go.mod` names the fork as well. Two
places can name a go-ceph version, the pin here and the `go.mod` of the
provider, and in the lab the pin wins. A go-ceph commit that needs other
modules than the version in `go.mod` stops the build, because the `go.sum`
of the provider is not written anew.

**Implementation.** Submodule `go-ceph`, its URL is in `.gitmodules`,
pinned at `e7e4b0b`, the commit of v0.41.0, and since decision 13 one
commit further, since decision 15 two (`128f391`). The provider at the
pin of decision 16 names go-ceph v0.42.1 in its `go.mod`. The lab builds
it with the fork, which is v0.41.0 plus the two commits, and that
provider built and ran.
`hack/build-ceph-volume-provider.sh` hands the directory to the image
build as the named build context `go-ceph`.
`images/ceph-volume-provider/Dockerfile` copies it to `/go-ceph` and
points the module at it with `go mod edit -replace`, before the modules
are fetched. `lab` mounts `GO_CEPH_DIR` and passes it on.

Checked on 2026-11-23 on the Linux test host. With `GO_CEPH_DIR` unset,
`./lab build-ceph-volume-provider` printed `go-ceph source: /lab/go-ceph`
and built the provider for the second build under test, x86_64 under
emulation, in 7.5 minutes, 7 of them in the Go build. The build
information of the binary names go-ceph as `v0.41.0 => /go-ceph`, where
the binary that the lab runs names the released module with its checksum.
The new binary links the librbd of the image and starts. `go.sum` needed
no change. The same was run before on the stand-in image without
emulation, in 64 s. With an empty directory as go-ceph source the script
stops with the hint to fetch the submodule. On 2026-11-24 a clone from
nothing with `--recurse-submodules` brought both submodules at their pins
with the same trees, and the build script found both sources in it. Not
run: a deploy of such an image and a go-ceph commit other than v0.41.0.

## 13. The header session gets a thin go-ceph binding behind a build tag of its own, and the caller decides how the lock is held

**Revised in part by decision 15.** The binding gives the path of the
staged header, `Path()`, in place of the descriptor number, `Fd()`. The
lock and the build tag are as decided here.

**Problem.** The second build under test can hand out the LUKS header of
an image as a file. librbd stages a copy and returns a file descriptor,
the caller changes the copy with libcryptsetup, and a commit writes the
changed parts back. These are three calls in `librbd.h`, open, commit and
close, and go-ceph has none of them. A binding has to say what Go code
sees of such a session, who takes the exclusive lock around the commit,
and how a provider that uses the binding still builds against a Ceph
without the calls.

Example. The quick start uses the upstream image of Ceph 21.2.0, whose
`librbd.h` lacks the three calls. A Go file that names one of them stops
the build there with `could not determine what
C.rbd_encryption_luks_header_open refers to`.

**Why.** One Go type stands for the session.
`(*Image).EncryptionLUKSHeaderOpen()` returns an `*EncryptionLUKSHeader`
with the methods `Fd()`, `Commit()` and `Close()`. Each of the three
librbd calls has one method, named and documented the way go-ceph does it
for `EncryptionLoad2`
([`encryption_load2.go:59`](https://github.com/ceph/go-ceph/blob/e7e4b0b8b5047658c44c4c6f9c7e5db471f7a23f/rbd/encryption_load2.go#L59)).
`Close` also closes the descriptor, so one deferred call releases
everything. The session keeps its image and refuses a commit once the
image is closed, as `Watch` does
([`watchers.go:128`](https://github.com/ceph/go-ceph/blob/e7e4b0b8b5047658c44c4c6f9c7e5db471f7a23f/rbd/watchers.go#L128)),
because librbd would use a freed image there.

The caller decides how the lock is held. `Commit` makes no lock call, as
the C call makes none, and go-ceph has the calls that a caller needs,
[`LockAcquire`](https://github.com/ceph/go-ceph/blob/e7e4b0b8b5047658c44c4c6f9c7e5db471f7a23f/rbd/locks.go#L33)
and
[`LockRelease`](https://github.com/ceph/go-ceph/blob/e7e4b0b8b5047658c44c4c6f9c7e5db471f7a23f/rbd/locks.go#L139).
There are three ways, and all three were run in the lab while a VM wrote
to the image (`development.md`, "Go bindings under a writing VM").

- No lock call. librbd takes the lock for each write of the header and
  hands it to the other client in between. The commit took 1.2 s, and
  the header was half written twice, for 0.4 s each.
- `LockAcquire(LockModeExclusiveTransient)` before the commit and
  `LockRelease` after. The other client waits. The commit took 0.2 s and
  no write of the VM failed. The `rbd` tool of the build does this
  (`src/tools/rbd/action/EncryptionLuks.cc:106-120`), and it is the way
  for the provider.
- `LockAcquire(LockModeExclusive)`. The lock is kept as well, but the
  writes of the VM failed with "Read-only file system" meanwhile.

Every method of the binding stays one librbd call.

The binding sits behind a build tag of its own,
`ceph_luks_header_session`. The calls are in no Ceph release and not in
Ceph `main`, so neither of go-ceph's tags for new calls, `ceph_preview`
and `ceph_main`, says where they exist. The provider file that calls the
binding carries the same tag. A build without the tag has neither, and
the quick start keeps working.

The branch starts at the pin, `e7e4b0b`. The `master` of the fork is 77
commits further, and a go-ceph that needs other modules stops the build
of the provider (decision 12).

**Alternatives that lost.**
- The lock inside `Commit`. No caller could forget it. But `Commit` would
  make three librbd calls and behave unlike the C call it is named after,
  and an image without the exclusive-lock feature would be a special case
  inside the binding.
- One function that opens the session, hands the file to a callback,
  commits and closes. Short for the caller. But a session can commit more
  than once, and a rotation uses that: add a keyslot, commit, test,
  remove the old one, commit.
- An `*os.File` in place of the descriptor number. libcryptsetup takes a
  path, `/proc/self/fd/<fd>`, and a second owner of the descriptor is one
  more way to close it twice.
- `ceph_preview` alone. It breaks the build of the example for every
  provider that sets it.
- Bindings for the header dump and restore calls of the build as well.
  Nothing calls them yet. They can follow when a variant needs them.

**What we accept.** Three things are left to the caller, and nothing in
the binding checks them: taking the lock around the commit, freeing the
libcryptsetup handle before the commit, and closing the session before
the image. librbd asks its callers to serialize header updates, and the
binding passes that on. A caller can pick a way to hold the lock that is
wrong for an image in use, and the binding does not stop it. Its names
follow the C calls of a prototype and
change with them. It is not listed in `docs/api-status.json` of go-ceph
and can be offered there only after librbd has the calls. Its test runs
against a local build of the same Ceph commit, not against the packaged
build (TODO 16).

**Implementation.** Branch `luks-header-session` of the go-ceph fork, from
`e7e4b0b`, with `rbd/encryption_luks_header.go` and
`rbd/encryption_luks_header_test.go`, both with
`//go:build ceph_luks_header_session`. A build under test that has the
calls sets `CEPH_PROVIDER_GO_BUILD_TAGS=ceph_luks_header_session` in
`lab.env`. The lab pins the submodule at `e0f6508`, one commit after
`e7e4b0b`. `Fd()` returns a `uintptr` as `os.File` does. A session that
was closed answers with `ErrEncryptionLUKSHeaderClosed`.

The test formats an image with LUKS2, opens a session and checks nine
cases. The file starts with the LUKS magic. A commit without a change
succeeds, twice. A changed file is written back: the header of a second
image, copied into the file and committed under the lock, makes the first
image load with the passphrase of the second and no longer with its own.
An empty file is refused with `EINVAL` and the image keeps its header. A
commit on an image opened read-only is refused with `EROFS`. A closed
session and a session whose image was closed first refuse the commit, and
the second can still be closed. An image without a LUKS header gets no
session. go-ceph does not link libcryptsetup, so a keyslot change is
tested with the wrapper of decision 14.

Checked on 2026-11-24 on the Linux test host, natively. The client was a
local build of the second build's commit (`2fd833e9b5ec`), the cluster
Ceph 21.2.0 in a container, started with the `micro-osd.sh` of go-ceph.
The nine cases passed in 46 s. With the commit taken out of the third
case the test failed in both of its checks, so it can tell a commit that
writes nothing. Without the tag the test is not built, and a Go program
that names the three calls stops against the `librbd.h` of v21.2.0 with
the error of the example.

The image build of the lab, with the tag set, built the provider against
the packaged header of the second build under test in 6 minutes, x86_64
under emulation. The binary records the tag and refers to
`rbd_encryption_luks_header_open` of the image's librbd. Nothing in the
provider calls the binding yet.

Run in the lab on the same day, in the provider pod while a VM wrote to
the image (`development.md`, "Go bindings under a writing VM"). With the
transient lock a commit took 0.2 s and QEMU waited. Without a lock call
it took 1.2 s, and the lock went to QEMU between the header writes. With
`LockModeExclusive` the writes of the VM failed. Not run: the test
against the packaged build (TODO 16).

## 14. The provider gets a small cgo package for libcryptsetup, with the calls of a rotation and nothing that orders them

**Revised in part by decisions 15 and 16.** The test on an RBD image
moved to the package of decision 15. Since decision 16 the provider
imports the package, and the image build of the lab installs the header
package, see the last paragraph of the implementation note.

**Problem.** With the header session (decision 13) librbd hands out the
LUKS header as a file, and the caller changes the keyslots in it with
libcryptsetup. The provider is written in Go and has no code that calls
libcryptsetup.

Example. To store a second passphrase the caller needs `crypt_init` on
`/proc/self/fd/<fd>`, `crypt_load`, `crypt_set_pbkdf_type` for the cost
of the new keyslot, and `crypt_keyslot_add_by_passphrase`. None of the
four can be called from the provider today.

**Why.** A package `internal/cryptsetup` in the provider wraps these calls
with cgo. The library is in the upstream image of the provider already,
because librbd links it
([`Dockerfile:118`](https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/Dockerfile#L118)).
The package has what a rotation in two steps needs: open a header, list
the keyslots in use with their cost, set the cost of keyslots created
from then on without a measurement on the host, add a keyslot, find the
keyslot that a passphrase opens, and remove a keyslot. It does not order
these steps and knows nothing of librbd, so it works on any file with a
LUKS header.

Three things it does by itself. It refuses to remove the last keyslot in
use, which libcryptsetup would do. It keeps passphrases in memory that
libcryptsetup wipes when it is freed. And it puts the error messages of
libcryptsetup into the error it returns, where the library would print
them to the output of the provider.

The package sits behind the build tag of decision 13. A provider built
without the tag needs no header files of libcryptsetup and is the
provider of today.

**Alternatives that lost.**
- The `rbd` tool of the build as a child process. It ran by hand in the
  lab. But the provider starts no process today, and its upstream image
  has no `rbd`.
- A second container next to the provider that runs the tool. An image, a
  memory limit and a protocol of its own.
- The Go binding
  [martinjungblut/go-cryptsetup](https://github.com/martinjungblut/go-cryptsetup).
  Its last commit is from May 2022, and it has no call to remove a
  keyslot, to list keyslots or to set the cost of a new one.
- A wrapper for `crypt_keyslot_change_by_passphrase`, which replaces a
  passphrase in one step. A change that is cut off between the two
  writes of the header can leave no passphrase that opens the image.

**What we accept.** The key derivation runs inside the provider process.
Its memory limit has to cover the provider plus the cost of the keyslot
that is opened or created (TODO 4). A libcryptsetup handle is not safe
for use from two goroutines at once, and the package does not guard it.
A build with the tag needs the header package of libcryptsetup: the
image build of the lab needs `cryptsetup-devel` and the upstream
Dockerfile `libcryptsetup-dev`. Neither is added yet, because nothing in
the provider imports the package so far. When a header cannot be opened
at all, libcryptsetup still prints one line to the output of the
provider, because the package has no handle yet to catch it with.

**Implementation.** Branch `luks-header-rotation` of the ceph-provider
fork, from `4c61421`. `internal/cryptsetup/cryptsetup.go` has the type
`Device` with `Open`, `Close`, `Type`, `Keyslots`, `SetPBKDF`,
`AddKeyslot`, `CheckPassphrase` and `RemoveKeyslot`. A failed call
returns an error that wraps the errno of libcryptsetup, for example
`syscall.EPERM` for a passphrase that opens no keyslot. Its tests need a
LUKS header in a file, and Go allows no cgo in test files, so
`internal/cryptsetup/cryptsetuptest` creates one. All files carry
`//go:build ceph_luks_header_session`. The lab pins the submodule at
`8f93bdc`, one commit after `4c61421`.

`cryptsetup_test.go` runs the steps on a file: add a keyslot with a fixed
cost, check both passphrases, remove the old keyslot, check again, open
the file anew. `headersession_test.go` does the same on an RBD image with
the binding of decision 13, in two commits, and asks librbd after each
whether the image loads with the old and with the new passphrase. It
needs a cluster, named by `CEPH_CONFIG_FILE`, and is skipped without.

Checked on 2026-11-24 on the Linux test host, natively, with
libcryptsetup 2.8.6 and as a user without privileges. The five tests on
a file passed in 3 s. A keyslot added after `SetPBKDF` with argon2id, 4
iterations, 64 MiB and 4 threads reads back with exactly these values.
Without `SetPBKDF` the same test failed, because libcryptsetup measured
the host and gave the keyslot 653 MiB. The test on an RBD image passed in
25 s against the cluster of decision 13: after the first commit the image
loaded with both passphrases, after the second with the new one only.

The package was built with `cryptsetup-devel` 2.8.6 of el10 and run in
the provider pod while a VM wrote to the image (`development.md`, "Go
bindings under a writing VM"): a keyslot added and one removed, with the
cost as set. Not run: the provider pod at a memory limit below 2Gi, and a
LUKS1 header.

Since 2026-11-25 `images/ceph-volume-provider/Dockerfile` installs
`cryptsetup-devel` in its build stage, from the CRB repository of the
distribution. The first image build of a provider that imports the
package had stopped with `libcryptsetup.h: No such file or directory`.
With the package, `cryptsetup-devel-2.8.6-2.el10`, the build passed in
5 min 44 s, x86_64 under emulation. The Dockerfile of ceph-provider is
unchanged.

## 15. The binding gives the path of the staged header, and one provider package joins the binding and the libcryptsetup package

**Problem.** The binding of decision 13 hands out the staged header as a
descriptor number, and the package of decision 14 opens a path. Code that
changes a header has to turn the one into the other, and it has to keep
three rules that nothing checks (decision 13, "What we accept"). The code
that orders a rotation should see none of this. And the libcryptsetup
package should stay free of librbd, as decision 14 has it.

Example. The test of decision 14 and the check program of the lab each
contain the line
`cryptsetup.Open(fmt.Sprintf("/proc/self/fd/%d", hdr.Fd()))`. The
rotation code would hold the third copy. A caller that keeps the number
after `Close` can name another file with it, and a caller that wraps it
in an `os.File` closes it twice.

**Why.** Each layer keeps what belongs to it, in three small changes.

```
rotation code                    the image and the passphrases
   |  luksheader.Change(img, change)
   v
internal/luksheader              the order of the steps and the lock
   |  hdr.Path()            |  cryptsetup.Open(path)
   v                        v
go-ceph binding            internal/cryptsetup
   the descriptor             any file with a LUKS header
   |                        |
   v                        v
librbd                     libcryptsetup
```

The binding gives a path. `Path()` takes the place of `Fd()` and returns
`/proc/self/fd/<fd>`. That librbd hands out the header as a descriptor of
a file without a name is a detail of librbd, and its Go binding is the
place for it. The number is not exported any more.

A package `internal/luksheader` in the provider has one function.
`Change(img, change)` opens the session, opens libcryptsetup on the path,
runs `change` with the `*cryptsetup.Device`, frees the libcryptsetup
handle, takes the transient lock, commits, releases the lock and closes
the session. The three rules of decision 13 are kept in this one place.
It is the only package that imports both go-ceph and
`internal/cryptsetup`, and what passes between the two is a string.

librbd marks both descriptors of the staged header as close-on-exec, so a
process that the caller starts does not inherit the header. Go opens its
own files that way.

A rotation is two calls of `Change`. The first adds the new keyslot. The
second checks the new passphrase and removes the old keyslot. Each call
has a session of its own, so the check reads the header that the image
stores and not the staged copy of the first call.

The form is a usual one. For a descriptor Go has
`syscall.RawConn.Control`, which hands it to a function and takes it back
when the function returns, and the documentation of `os.File.Fd` points
there. C libraries return the descriptor of an object without a name, as
`fileno` does, so the calls in `librbd.h` stay as they are.

**Alternatives that lost.**
- The caller builds the path, as today. Every caller repeats a detail of
  librbd.
- `internal/cryptsetup` takes the number. The number stays exported, and
  the package would learn where its file comes from.
- `Change` inside `internal/cryptsetup`, or a method of the binding that
  returns a libcryptsetup handle. Either one ties the two together.
- librbd returns the path. No call in `librbd.h` returns a path, and C
  libraries do that for objects with a name of their own, such as a
  device.
- librbd takes and returns the header as bytes. The provider would stage
  its own file and build the same path, and the calls in librbd and the
  binding would be written again.
- A named file on tmpfs. Any process of the user can open it by name, and
  it stays after a crash.
- One session with two commits for a rotation. The binding still allows
  it (decision 13), `Change` does not use it.

**What we accept.** A path under `/proc` is still built, in one place,
and the binding works on Linux only, as the staged file of librbd does.
A rotation reads the header from the image twice and loads it into
libcryptsetup twice. `change` can keep the handle it was given; every
later call on it returns `ErrClosed`. Close-on-exec stops inheritance and
nothing else: a process of the same user that knows the process ID and
the number can still open the file. A caller of librbd that wants to run
the `cryptsetup` program on the file has to pass the descriptor on
purpose. `Change` always takes the transient lock, and what it does with
an image without the exclusive-lock feature is open. The pushed commit of
the binding changes.

**Implementation.**
- go-ceph fork, branch `luks-header-session`: `Path()` in
  `rbd/encryption_luks_header.go` returns the path, or
  `ErrEncryptionLUKSHeaderClosed` after `Close`. `Fd()` is removed, and
  the two uses in `rbd/encryption_luks_header_test.go` follow.
- ceph-provider fork, branch `luks-header-rotation`, and since decision
  16 `luks-header-rotation-iri`: package `internal/luksheader` with
  `Change`. The test on an RBD image moves there from
  `internal/cryptsetup/headersession_test.go` and calls it.
- Lab: `hack/header-session-check/main.go` takes the path from `Path()`.
  It keeps its own sequence, because it measures the three ways to hold
  the lock (decision 13).
- librbd, not done: the close-on-exec flag on the staged file and on its
  duplicate in `src/librbd/crypto/luks/Header.cc`. It is a patch of three
  hunks that is not on the Ceph branch, and it needs a new build. The
  other three changes run against the second build under test.

`TestChange` runs three changes on an image. The first adds a keyslot
and then fails: the image does not load with the new passphrase, and the
handle that the function kept answers with `ErrClosed`. The second adds
the keyslot: the image loads with both passphrases. The third finds the
new keyslot with its cost in the header that came back from the image,
checks the new passphrase and removes the old keyslot: the image loads
with the new passphrase only.

Checked on 2026-11-25 on the Linux test host, natively, with the client
and the cluster of decision 13. The nine cases of the binding passed in
40 s, `TestChange` in 32 s, the five tests of the libcryptsetup package
on a file in 3 s. With `Change` altered to commit a change that failed,
`TestChange` failed at its first check. `go list -deps -test
./internal/cryptsetup` names no go-ceph package, and
`internal/luksheader` with its test is the only package of the provider
that imports both.

The changed `Header.cc` compiles with the compile command of a local
build of the same Ceph commit. It was not linked and not run.

A short Python program on the same host, not librbd, showed what the
flag does. A child process reads a file of this kind through
`/proc/self/fd/<fd>` when the flag is missing and gets "No such file or
directory" when it is set. With the flag set the child still reads and
writes the file through `/proc/<parent>/fd/<fd>`.

The image build of the lab took the changed binding on 2026-11-25, for
the provider of decision 16. The check program with `Path()` was built
on 2026-11-26 against both pins, in 1 min 24 s, and not run.

Not run: the check program with the changed binding, `Change` while the
guest writes to the disk, and a test that a child process of the
provider does not have the descriptor.

## 16. A rotation starts at the Volume API, and the IronCore side of it comes as two images of the branch that carries it

**Problem.** A user rotates a passphrase by pointing
`spec.encryption.secretRef` of a Volume at a new Secret. The passphrase in
the LUKS header has to follow. The provider code of decisions 13 to 15 can
change the header, and nothing in released IronCore asks it to.

Example. With ironcore v0.6.1 a patch of `secretRef` on an encrypted
Volume is refused, because the field cannot change after the Volume was
created
([`volume.go:126`](https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/internal/apis/storage/validation/volume.go#L126)).
The interface between volumepoollet and the provider (IRI) has no call
for a new passphrase either.

**Why.** The missing parts exist as a branch,
[`key-rotation`](https://github.com/gonzolino/ironcore/tree/206f2c28c9986090ea1a8b4accfd2351552603d6)
in a fork of ironcore, three commits on ironcore `main` of 2026-11-19. It
lets `spec.encryption` change, adds the IRI call `RotateVolumeEncryption`,
and has volumepoollet call it when the Secret of a Volume differs from the
passphrase that the provider reports. A provider branch of the same fork
has the handler for the call, and the provider that the lab pins is built
on that branch.

```
kubectl patch volume ...          secretRef names the new Secret
   |
   v
ironcore-apiserver                image of the branch, accepts the change
   |
   v
volumepoollet                     image of the branch, sees that the Secret
   |                              differs from what the provider reports
   |  IRI RotateVolumeEncryption
   v
ceph-volume-provider              built by the lab from the pinned source
   |  handler                     records the wanted passphrase
   |  reconcile 1                 luksheader.AddPassphrase, new keyslot
   |  reconcile 2                 luksheader.RemovePassphrase, old keyslot
   v
LUKS header of the RBD image
```

The fork publishes one image per component of the branch, for both
architectures. The lab replaces components by image (decision 5), so two
settings bring the IronCore side in, `IRONCORE_APISERVER_IMAGE` and
`VOLUMEPOOLLET_IMAGE`, and nothing has to be built for it.

In the provider the handler only records the wanted passphrase
([`volume_rotate_encryption.go:15`](https://github.com/Greenpepper15/ceph-provider/blob/463eacdc0baf730ad0b397fd515f5668d5b08dbe/internal/volumeserver/volume_rotate_encryption.go#L15)).
The reconciler changes the header in two runs
([`image_controller.go:579`](https://github.com/Greenpepper15/ceph-provider/blob/463eacdc0baf730ad0b397fd515f5668d5b08dbe/internal/controllers/image_controller.go#L579)).
The first adds a keyslot for the wanted passphrase, the second removes
the keyslot of the one before, and each is one call of the package of
decision 15. The record of the image lists the passphrases that the
header accepts, so between the two runs it lists both. The provider
reports the first of the list to volumepoollet
([`volume.go:84`](https://github.com/Greenpepper15/ceph-provider/blob/463eacdc0baf730ad0b397fd515f5668d5b08dbe/internal/volumeserver/volume.go#L84)),
which stops calling once the header has the new passphrase.

**Alternatives that lost.**
- The two images built from the `ironcore` submodule of decision 17,
  whose pin holds the same three commits. Nothing would then depend on a
  registry of someone else. It is two more builds of about 7 minutes each
  for images that exist, and it stays the way out when they are gone.
- All components from the branch, controller-manager and machinepoollet
  as well. The lab changes what a rotation needs and nothing else.
  machinepoollet needs a change that the branch does not have (decision
  17).
- A rotation started from inside the provider pod, as the check program
  of decision 13 does. It shows that the header can be changed and skips
  everything a user would touch.

**What we accept.**
- The two images belong to a fork of someone else. The tag
  `key-rotation` moves when the branch moves, and the branch is marked as
  not to be merged, so it can be rewritten. The digests that the lab ran
  are in the implementation note. Not tried: a digest in `lab.env` in
  place of the tag.
- The cluster runs mixed versions. The branch starts 32 commits after
  v0.6.1, controller-manager stays at v0.6.1, and the manifests are the
  ones ironcore-in-a-box names (TODO 2).
- The provider has to be replaced first. Read in the code, not run: the
  volumepoollet of the branch against a provider without the call fails
  the update of every encrypted Volume.
- The record of an image changes its form, and an older provider cannot
  read it. Read in the code, not run: going back to an older provider
  image needs every Volume deleted that the new one has written.
- The provider reports the passphrase of the header in plain with every
  list of volumes, because volumepoollet compares it with the Secret.
- The call carries the wanted passphrase only. The enhancement proposal
  for key rotation
  ([IEP-24](https://github.com/ironcore-dev/enhancements/pull/62)) sends
  the current one as well and reports a reference to the key, not the
  key. The lab follows the branch.
- Two errors repeat in the log of the provider without a rotation. An
  encrypted image that was attached once is 16 MiB larger than its
  Volume, and the size step refuses it as a shrink at every reconcile. A
  Volume from before this provider has no passphrase listed until its
  first rotation is asked for, and until then each reconcile of it stops
  with an error in front of the size step.

**Implementation.**
- Provider: submodule `ceph-provider` at `463eacd`, branch
  `luks-header-rotation-iri` of the fork. That is ceph-provider `main` of
  2026-11-24 (`67212d3`) plus 13 commits: three for the packages of
  decisions 14 and 15, four of the provider branch named above (the
  handler and the list of passphrases in the record), and six that join
  them.
  Its `go.mod` takes ironcore from the branch with a `replace` line.
- `lab.env.example` has the settings of a rotation run: the build tag of
  decision 13, the two images of the branch, and the machinepoollet image
  of decision 17.
- `images/ceph-volume-provider/Dockerfile` installs `cryptsetup-devel`,
  see the note at decision 14.

Run on 2026-11-25 on the Linux test host, with the second build under
test. The provider of the first run was built without the order fix
(`ea4182f`), the provider of the others from the tree of the pin. The
images of the branch were
`ghcr.io/gonzolino/ironcore-apiserver@sha256:cf0295685573676c90921625c079ab63011a7611d18079228b04721eb14b934c`
and
`ghcr.io/gonzolino/ironcore-volumepoollet@sha256:443011da7245516881c9ed021e19c9024390fcdc93d52bda4cb41fbd0202ba01`.

- A Volume that no VM uses, 1 GiB, pointed at a second Secret.
  volumepoollet called the provider once. The provider logged "Updated
  encryption header" 9 s and 16 s after the patch. Afterwards the header
  had one keyslot, with argon2id, 64 MiB, 4 iterations and 4 threads,
  the new Secret opened it and the old one did not (`rbd encryption
  luksOpen --test-passphrase`).
- The same Volume with its image grown by 16 MiB, as an attached image
  is, and pointed back at the first Secret. Without the order fix the
  rotation did not start, in 17 reconciles over 5.5 minutes. With the
  pin both header steps ran, and the first Secret opened the header
  again.
- A Volume attached to the running VM. The header steps came 9 s and
  16 s after the patch, the VM kept running, and the header had the new
  passphrase only. What the machine side did meanwhile is decision 17.
- Volumes that an older provider had created stayed `Available` after
  the swap.

Not run: a rotation while the guest writes to the disk, a cold start of
the VM after a rotation, the provider at a memory limit below 2Gi, and
the two cases marked "not run" above.

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
   needs them in Go. Decided on 2026-11-23: they go to the go-ceph fork
   that the provider is built with (decision 12). No binding is written
   yet. A small cgo file in the provider stays an option for calls outside
   librbd, for example a wrapper around libcryptsetup. The stand-in image
   has `cryptsetup-libs` 2.8.1, which its librbd links. Not looked at: the
   header package that a build against it needs.
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

15. **The forks fall behind upstream.** The provider and go-ceph come from
    forks (decisions 11 and 12), and nothing moves a fork or a pin when
    upstream moves.

    Example. On 2026-11-23 the pin of ceph-provider was 21 commits behind
    upstream `main`, and the pin of go-ceph 77 commits behind upstream
    `master`. go-ceph has released v0.42.0 and v0.42.1 since that pin. A
    fix from those is not in a provider built here.

    Open. Who moves the pins and when, for example with each new build
    under test. Whether a prototype branch is rebased on upstream before
    it is shown to anyone. Whether the lab should say so when a pin is
    behind.

16. **The test of a binding against the packaged build.** go-ceph runs
    its tests in a container of its own, on the Ceph image that
    `CEPH_IMG` and `CEPH_TAG` name
    ([`Dockerfile:1`](https://github.com/ceph/go-ceph/blob/e7e4b0b8b5047658c44c4c6f9c7e5db471f7a23f/testing/containers/Dockerfile#L1)).
    Read, not run: its package step installs the header packages from the
    repository file of the image when there is one, and otherwise from
    download.ceph.com or from Ceph's CI
    ([`setup-pkgs.sh:22`](https://github.com/ceph/go-ceph/blob/e7e4b0b8b5047658c44c4c6f9c7e5db471f7a23f/testing/containers/setup-pkgs.sh#L22)),
    and it compares the Ceph version of the image with a release name.

    Open. Whether that container builds on the image of a build under
    test, and how long its test cluster takes under emulation. Until then
    the test of decision 13 runs against a local build of the same
    commit.

17. **A keyslot removal that stops half way leaves the key material in the
    image.** The commit of the header session writes the changed ranges
    lowest offset first and does not take a written range back when a
    later one fails. For a removal that puts the two copies of the
    metadata before the wipe of the key material. Tested on 2026-11-25
    with librbd of commit `2fd833e9b5e`, go-ceph `128f391` and
    ceph-provider `a6b2cbb`. The commit was stopped after its first or
    its second range, by a kill of the process and by a blocklist of the
    client, four rounds in all.

    Example. A rotation removes keyslot 0, and the commit stops after the
    two copies of the metadata. The header no longer lists keyslot 0, so
    the old passphrase opens nothing and the removal looks done. A second
    call of `luksheader.Rotate` finds no keyslot for the old passphrase
    and returns without error. The 258048 bytes of key material of
    keyslot 0 are still in the image. Behind the 32 KiB of metadata from
    before the rotation they open with the old passphrase, in 4 of 4
    rounds. After a full commit the same check opens nothing.

    The add side held in the same test. A stopped add leaves the old
    keyslot whole (4 of 4 rounds), and the header keeps one keyslot that
    no passphrase opens.

    Open, deferred by David on 2026-11-25: "We work on this after the
    changes are approved." libcryptsetup writes the key material first
    and the metadata last, for a removal
    ([`luks2_keyslot.c:707`, `:730`](https://gitlab.com/cryptsetup/cryptsetup/-/blob/ff3f1723e0e65003e35b82094642b0f0a3583ddb/lib/luks2/luks2_keyslot.c#L707-L730))
    and for an add
    ([`luks2_keyslot_luks2.c:585`, `:589`](https://gitlab.com/cryptsetup/cryptsetup/-/blob/ff3f1723e0e65003e35b82094642b0f0a3583ddb/lib/luks2/luks2_keyslot_luks2.c#L585-L589)).
    The same order in the commit of the session would turn a stopped
    removal into a wiped keyslot that is still listed, and a stopped add
    into no change. Not built, not tested.

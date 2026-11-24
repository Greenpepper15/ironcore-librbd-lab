# ironcore-librbd-lab

A lab for trying a Ceph build with changes in librbd inside IronCore, on one
laptop, without building Ceph.

It runs [ironcore-in-a-box](https://github.com/ironcore-dev/ironcore-in-a-box)
(IronCore in a local kind cluster, with a Rook Ceph cluster and VMs) and adds
three things on top.

- The volume provider is built against the librbd of a Ceph build that you
  were given as a container image and an RPM repository, and runs with it.
- Any IronCore component can be replaced by an image built from a local
  checkout, with one setting and one command.
- The `rbd` tool of the build under test can be called against the lab
  cluster.

The first use is a prototype of LUKS passphrase rotation for a volume that
stays attached to a running VM. Several ways of doing this in librbd are being
compared, and each of them needs changes in IronCore that should be quick to
try.

## State

Run on two machines so far. On a Linux arm64 VM (Ubuntu 22.04, kernel 5.15,
Docker 29.1, 8 CPUs, no KVM) `./lab up` and the example below work with the
upstream Ceph 21.2.0 image standing in for the build under test. A first
image from Clyso's build system, for x86_64, was run there as well, through
emulation.

On a Mac with Apple silicon (macOS 27.2, Docker Desktop 4.76) `./lab up`
and the example work as well, `up` in 6 minutes from nothing. The image for
x86_64 was run there too. Docker Desktop starts its provider through
Rosetta, and the provider image was built in under 4 minutes.

Not run yet: Windows with WSL2 and a host with x86_64 CPUs.
`design/development.md` lists what was checked and what is assumed.

## What you need

- Docker with about 8 GiB of memory for it, and bash. Nothing else is
  installed on the host. make, Go, kind and kubectl run in a toolbox
  container that `./lab` builds on first use.
- Free disk for the images. A run with a build under test took 16 GiB on
  a Mac.
- The kernel features that ironcore-in-a-box asks for. Its README covers
  Linux, macOS and the custom kernel that WSL2 needs.

## Quick start

```sh
git clone --recurse-submodules <this repository>
cd ironcore-librbd-lab
./lab up                                              # 8 to 12 minutes on the two test hosts
./lab kubectl apply -f examples/encrypted-volume.yaml # VM with a LUKS2 data volume
./lab kubectl get volume,machine
./lab status                                          # which librbd runs where
./lab down
```

With no `lab.env` this is plain ironcore-in-a-box with storage, at the commit
the submodule pins.

## Where librbd runs

librbd is the client library that reads and writes RBD images. LUKS
encryption of an image happens inside it, on the client. In IronCore two
different processes use it on the same image.

```
 Volume (IronCore API)                     Machine (IronCore API)
        |                                          |
   volumepoollet                             machinepoollet
        | IRI                                      | IRI
 +------v----------------+               +---------v------------+
 | ceph-volume-provider  |               | libvirt-provider     |
 |   go-ceph (cgo)       |               |   writes domain XML  |
 |   librbd  <-- (1)     |               +---------+------------+
 +------+----------------+                         | libvirt
        |                                +---------v------------+
        | creates the image,             | QEMU in the kind node|
        | formats LUKS2,                 |   librbd  <-- (2)    |
        | would rotate the passphrase    +---------+------------+
        |                                          | opens the image with the
        |                                          | passphrase, does the VM's I/O
 +------v------------------------------------------v------------+
 |                Ceph cluster (Rook, one OSD)                  |
 +--------------------------------------------------------------+
```

1. The provider image. Upstream it carries Debian packages of Ceph. The lab
   builds it on top of the Ceph image under test instead
   (`images/ceph-volume-provider/Dockerfile`).
2. The kind node image of ironcore-in-a-box, Debian 13 with QEMU 10.0 and
   librbd 18.2.7. The lab leaves it as it is, see decision 3 in
   `design/design-decisions.md`.

`./lab status` prints the versions of both and of the cluster.

## Using the Ceph build under test

```sh
cp lab.env.example lab.env
```

Set in `lab.env`:

```sh
CEPH_IMAGE=<container image of the build>
CEPH_REPO_URL=<RPM repository of the same build>
CEPH_REPO_GPGKEY=<its signing key, or empty>
CEPH_VOLUME_PROVIDER_IMAGE=lab/ceph-volume-provider:dev
```

The provider is built from two submodules, `ceph-provider` and `go-ceph`
(the Go bindings for librbd), which the lab pins to the commits it was run
with. To build from checkouts of your own, add
`CEPH_PROVIDER_DIR=/path/to/ceph-provider` or
`GO_CEPH_DIR=/path/to/go-ceph`.

If the image needs a login, run `docker login` and `docker pull` for it on
the host first. The build then uses the local copy.

Then:

```sh
./lab build-ceph-volume-provider   # prints the librbd it linked against
./lab deploy                       # loads the image into the node, rolls it out
./lab status
./lab rbd ls -l                    # rbd of the build, with the provider's credentials
```

`./lab rbd` runs inside the provider pod. A new `rbd` subcommand of the build
under test can be tried this way against an image that a VM has open, before
any Go code exists.

After a change in the provider source or in go-ceph, repeat
`build-ceph-volume-provider` and `deploy`. The VM keeps running while the
provider is replaced.

### The provider sources are forks

Both submodules point at forks, not at the upstream repositories. Their
URLs are in `.gitmodules`. A prototype is a branch on a fork and a new pin
here.

| Submodule | Fork of | Pinned at | Behind upstream on 2026-11-23 |
|---|---|---|---|
| `ceph-provider` | [ceph-provider](https://github.com/ironcore-dev/ceph-provider) | `8f93bdc`, which is `4c61421` (v0.7.0 plus 3 commits) plus one commit of the lab | 21 commits |
| `go-ceph` | [go-ceph](https://github.com/ceph/go-ceph) | `e0f6508`, which is `e7e4b0b` (v0.41.0) plus one commit of the lab | 77 commits |

Nothing keeps a fork or a pin in step with upstream. They fall behind
unless someone moves them, and a fix that upstream made after the pin is
missing in a provider built here. go-ceph, for example, has released
v0.42.0 and v0.42.1 since its pin. To see how far a pin is behind:

```sh
git -C go-ceph fetch -q https://github.com/ceph/go-ceph.git master
git -C go-ceph rev-list --count HEAD..FETCH_HEAD
```

See TODO 15 in `design/design-decisions.md`.

### A build for another architecture than the host

A build may exist for x86_64 only while the host is arm64, for example an
Apple silicon Mac. Name its platform in `lab.env` as well:

```sh
CEPH_PLATFORM=linux/amd64
```

The provider image is then built for that platform and its pod runs through
QEMU's user-mode emulation. Everything else stays native (decision 9 in
`design/design-decisions.md`). This is slow, the first image build took 51
minutes on the test host, and timings of the provider mean nothing in this
mode. The lab gives the emulated provider 2 CPUs instead of the 200m of
ironcore-in-a-box. A Linux host needs the emulation registered once per boot:

```sh
docker run --privileged --rm tonistiigi/binfmt --install amd64
```

Docker Desktop on a Mac brings the emulation along and uses Rosetta unless
that setting is turned off. An x86_64 provider on an el10 Ceph image runs
there through Rosetta, and its image build took under 4 minutes.

### CPU and memory of the provider belong together

When a volume is created, libcryptsetup measures how fast the provider
derives a key and stores a memory cost in the keyslot, between 64 MiB and
1 GiB. Every later open of that volume needs this memory again, in QEMU at
attach and in the provider for a keyslot command, and it takes longer on
less CPU. At the 200m of ironcore-in-a-box the cost stays at 64 MiB. With
2 CPUs it was 557 MiB on the Linux test host and 732 MiB on a Mac.

So when you raise the CPU limit (`CEPH_VOLUME_PROVIDER_CPU`, or
`CEPH_PLATFORM`, which sets it to 2), whatever opens the volume needs its
own memory plus up to 1 GiB. The lab's 2Gi for the provider leaves room
for that. The 256Mi of ironcore-in-a-box do not. A keyslot of 455 MiB could
not be opened at that limit. The measurements are in
`design/development.md`, "Keyslot cost and the CPU limit".

## Changing other IronCore components

Each of these images can be replaced. Build it from your checkout with the
Dockerfile of its repository, name it in `lab.env`, run `./lab deploy`.

| Setting | Component | Build |
|---|---|---|
| `CEPH_VOLUME_PROVIDER_IMAGE` | ceph-volume-provider | `./lab build-ceph-volume-provider` |
| `VOLUMEPOOLLET_IMAGE` | volumepoollet | ironcore, `docker build --target volumepoollet` |
| `MACHINEPOOLLET_IMAGE` | machinepoollet | ironcore, `docker build --target machinepoollet` |
| `IRONCORE_APISERVER_IMAGE` | ironcore-apiserver | ironcore, `docker build --target apiserver` |
| `IRONCORE_CONTROLLER_MANAGER_IMAGE` | ironcore-controller-manager | ironcore, `docker build --target manager` |
| `LIBVIRT_PROVIDER_IMAGE` | libvirt-provider | libvirt-provider, `docker build` |

An image that exists in the local Docker is loaded into the kind node under a
tag made from its image ID. A rebuild therefore always rolls out, and
`./lab status` shows which build runs.

Only the images are replaced. A change to the manifests of a component (RBAC,
flags) is not covered yet, see TODO in `design/design-decisions.md`.

## Commands

| Command | What it does |
|---|---|
| `./lab up` | cluster, IronCore, networking, libvirt-provider, Rook Ceph, volume provider |
| `./lab up-ironcore` | the same without storage |
| `./lab up-storage` | Rook Ceph and the volume provider |
| `./lab build-ceph-volume-provider` | provider image from the `ceph-provider` and `go-ceph` submodules, or `CEPH_PROVIDER_DIR` and `GO_CEPH_DIR`, against `CEPH_IMAGE` |
| `./lab deploy` | roll out the images named in `lab.env` |
| `./lab status` | librbd versions and deployed images |
| `./lab kubectl ...` | kubectl against the lab cluster |
| `./lab rbd ...` | rbd of the build under test, in the provider pod |
| `./lab shell` | a shell in the toolbox |
| `./lab down` | delete the cluster, release the loop device |

To use your own kubectl, point it at `.kube/config.host`.

## Layout

```
lab                  entry point, starts the toolbox container
Makefile             the targets above, run inside the toolbox
lab.env.example      all settings
toolbox/             image with make, Go, git and the Docker CLI
images/              Dockerfile of the provider built against a Ceph image
hack/                scripts behind the targets
examples/            a VM with an encrypted data volume
ironcore-in-a-box/   submodule, pinned
ceph-provider/       submodule, pinned, source of the provider image
go-ceph/             submodule, pinned, Go bindings for librbd in that image
design/              why the lab is built this way, what was checked
```

`design/` leads. Read `design/ironcore-in-a-box-fit.md` for what
ironcore-in-a-box does and does not cover, and `design/design-decisions.md`
for the choices made here.

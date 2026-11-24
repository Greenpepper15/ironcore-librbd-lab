# Development context

## Where we are

- [x] 1. Check ironcore-in-a-box against the use case (`ironcore-in-a-box-fit.md`)
- [x] 2. Lab layer: toolbox, bring-up through the submodule, free loop device
- [x] 3. Volume provider built on a Ceph image, rolled out, `rbd` of the build reachable
- [x] 4. Encrypted volume on a running VM, with the upstream provider and with the lab-built one
- [x] 5. First run with a build from Clyso's build system, x86_64 under
      emulation ("Build with rotation commands" below, TODO 1, 3 and 13 of
      `design-decisions.md`). A second build no longer hangs in a header
      command while the VM writes ("Build with the fix for the hang")
- [ ] **6. Quick start on macOS and on Windows with WSL2** (TODO 5). Run on
      a Mac with the upstream provider image and with the first build under
      test, x86_64 through Rosetta ("macOS" below). Open: WSL2
- [ ] 7. First rotation variant end to end: Go binding, call in the provider, new
      passphrase on the VM side (TODO 6)
- [ ] 8. Proposals to ironcore-in-a-box (TODO 9)

## Where things live

| What | Where |
|---|---|
| ironcore-in-a-box | submodule `ironcore-in-a-box`, pinned at `8263add` |
| ceph-provider source | submodule `ceph-provider`, a fork of ceph-provider, pinned at `8f93bdc` (`4c61421`, which is v0.7.0 plus 3 commits, plus the package of decision 14), decision 11 |
| go-ceph source | submodule `go-ceph`, a fork of go-ceph, pinned at `e0f6508` (v0.41.0 plus the binding of decision 13), decision 12 |
| IronCore components | [ironcore](https://github.com/ironcore-dev/ironcore), [ceph-provider](https://github.com/ironcore-dev/ceph-provider), [libvirt-provider](https://github.com/ironcore-dev/libvirt-provider); local checkouts are named in `lab.env` |
| Ceph image recipes of Clyso's build system | [cbs-components](https://github.com/clyso/cbs-components) |
| Stand-in for the build under test | `quay.io/ceph/ceph:v21.2.0`, RPMs at `https://download.ceph.com/rpm-21.2.0/el10` |
| First build under test | Ceph `22.0.0-143-g9cce574d9dc7` from Clyso's build system, x86_64, el10. Image and RPM repository come with the build |
| Second build under test | Ceph `22.0.0-146-g2fd833e9b5ec`, the first one plus three commits against the hang of TODO 13 |
| State of a run | `.lab/` (rendered overlays, OSD device), `.kube/`, `.cache/`, all ignored by git |

## What was run

Two hosts, on 2026-11-22 unless a section names another day. Everything
except the section "macOS" ran on the Linux host. It is an arm64 VM with
Ubuntu 22.04, kernel
5.15.0-202, Docker 29.1.3 without the BuildKit plugin, 8 CPUs, 31 GiB
memory, no `/dev/kvm`, `/dev/loop0` to `loop5`, `loop7` and `loop8` in use
by snaps. No make, Go, kind or kubectl on the host.

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
the VM restarts. The scripts are in `hack/header-rewrite-check/`.

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

### Emulated provider

Decision 9, run 2026-11-22 on the same arm64 host. The provider image was
built for `linux/amd64` on the x86_64 variant of the stand-in
(`librbd1-21.2.0-0.el10.x86_64`) and ran through QEMU 10.2.3 user-mode
emulation. Everything else stayed native. The numbers show what the
emulation costs. They say nothing about librbd.

| Check | Emulated | Native, from the tables above |
|---|---|---|
| A memory-hard hash by hand, scrypt with 64 MiB in the el10 image | 2.0 s | 0.26 s |
| `./lab build-ceph-volume-provider` | 51 min 18 s, of it 48 min 21 s the Go compile and 1 min 40 s the package install | 4 min 37 s |
| `./lab deploy` | 2 min 31 s. Pod `Running`, its process is `/usr/bin/qemu-x86_64 /ceph-volume-provider`. The volumepoollet container restarted twice, the provider's socket was not there yet | 2 min 32 s |
| `./lab rbd --version`, `./lab rbd ls -l` | 5.8 s and 14.5 s. New line `warning: unable to disable THP: (22) Invalid argument` | not timed |
| Encrypted Volume | `Available` after 110 s, 86 s of it in the encryption format. Keyslot as before: argon2id, 64 MiB, time cost 4, 4 threads | within 30 s |
| `cryptsetup luksAddKey` on a copy of the header | 148.2 s, peak of the child 82 MiB, memory of the pod from 274 to 349 MiB, no OOM event at 2Gi | 18.5 s, 71 MiB, 226 to 292 MiB |
| Hot-attach of that Volume to the running Machine | `Attached` after 11 s. QEMU's librbd 18.2.7 opened the header that the emulated librbd wrote | within 20 s |

Seen on the way, on the native side: the attach grows the RBD image of an
encrypted Volume by the 16 MiB of the LUKS header, here from 1024 to 1040
MiB. From then on the provider logs `failed to update image: failed to
shrink image: not supported` at every reconcile of that image, because it
compares the raw image size with the size of the Volume
(ceph-provider `4c61421`, `internal/controllers/image_controller.go:520`).
Which component resizes was not pinned down.

### Build with rotation commands

Run 2026-11-22 on the same arm64 host, with the first build from Clyso's
build system: Ceph `22.0.0-143-g9cce574d9dc7` for x86_64, an el10 image on
Rocky Linux 10.3 with cryptsetup 2.8.6. Its `rbd` has commands that change
the LUKS header of an image. The provider ran emulated (decision 9). The
commands were run as `rbd` in the provider pod, with the provider's Ceph
access, on a second encrypted Volume that was attached to the running VM.
The provider itself does not call them yet (TODO 6). The VM side and the
I/O through the QEMU monitor were the same as in the header rewrite check:
QEMU 10.0.13, librbd 18.2.7, libcryptsetup 2.7.5, rounds of write, flush
and read on the disk, about eight per second. All timings are emulated.

Bring-up.

| Check | Result |
|---|---|
| `docker login` and `docker pull --platform linux/amd64` on the host | 2 min 34 s. The image has `librbd1-22.0.0-143.g9cce574d9dc7.el10.clyso.x86_64` and `ceph-common`, `python3-rbd`, `rbd-nbd` of the same build |
| `./lab build-ceph-volume-provider` | 4 min 16 s. The toolbox has no login and used the copy of the image that the host had pulled. The `-devel` packages came from the RPM repository of the build with the signature check on, 77 s. The Go compile took 114 s with the build cache of the emulated run above. go-ceph v0.41.0 compiles against the headers of Ceph 22 |
| `./lab deploy` at the CPU limit of 200m | 3 min 50 s, then a restart loop. The provider was throttled in 319 of 322 scheduler periods. volumepoollet gave up with `error waiting for volume class mapper to sync: context deadline exceeded`, and the kubelet restarted the provider as well, because the liveness probe of the provider container points at port 8081, which volumepoollet serves |
| The same at a CPU limit of 2 | no throttled period, the provider was not restarted, volumepoollet stayed up after two restarts at the start |
| `./lab status` | provider `librbd1-22.0.0-143.g9cce574d9dc7.el10.clyso.x86_64`, QEMU librbd 18.2.7, cluster 19.2.3 |

Commands on the attached Volume while the VM did no I/O.

| Check | Result |
|---|---|
| `rbd encryption keyslot list`, `luksDump` | work on the image that the VM has open, 5 s. One keyslot, argon2id with 64 MiB, time cost 4, 4 threads |
| `luksOpen --test-passphrase` | the passphrase of the Secret unlocks keyslot 0 in 5.0 s, another one is refused |
| `header dump` | a file of 16 MiB in 2.6 s |
| `luksAddKey` | 7.5 s, `Key slot 1 created`. The new keyslot has the settings of the first one. Peak of the `rbd` process 287 MiB, memory of the pod from 274 to 557 MiB, no OOM event at 2Gi. Both passphrases unlock |
| `header restore` with the dump from before | 4.3 s, one keyslot again |
| `volume-key get` | 4.7 s, a file of 64 bytes |
| Exclusive lock | after a command the image has no lock owner. QEMU holds the lock again after its next write |

The same commands while the VM wrote.

| Check | Result |
|---|---|
| `luksAddKey`, two runs | both hung. The `rbd` process held the exclusive lock and waited, the OSD had no operation pending. The VM's write waited until the process was killed, 775 s in the first run and 110 s in the second, which had a kill after 90 s. QEMU had the lock back 27 to 29 s after the kill, and the VM saw no I/O error. Left behind was a header that lists keyslot 1 while the key material of that keyslot was not written. The new passphrase is refused, the old one unlocks |
| `header restore` | 4.6 s, the slowest write of the VM took 0.74 s |
| `keyslot add`, two runs | the first took 5.9 s, the slowest write of the VM 0.33 s, the new passphrase unlocks. The second hung, the VM's write waited 67 s with a kill after 45 s |
| `keyslot remove` | hung, the VM's write waited 70 s |
| `luksKillSlot` for the old keyslot | hung, the VM's write waited 67 s. Afterwards the header lists the new keyslot only, the old passphrase is refused and the new one unlocks. The bytes of the removed keyslot are still in the keyslot area |

Where it hangs, from the librbd log of the second `luksAddKey` run (`--debug-rbd=20`).
The command writes the changed ranges of the header one after the other.
The first write takes the exclusive lock from QEMU. QEMU asks for it back
for its next write, and librbd starts to release it. The command's next
write is started in that moment. It is held back until the lock is taken
again, and the release waits for every started operation, this write
included. Neither moves. Five of the seven runs that wrote the header ended
this way, so it depends on timing. The stand-in of the header rewrite check
wrote through the public API of librbd and did not hang. Details and code
references are in TODO 13 of `design-decisions.md`. A native build confirmed
this reading, see "Cause of the hang" below.

The next attach.

| Check | Result |
|---|---|
| Secret changed to the new passphrase | nothing within 73 s. The VM keeps the disk, the libvirt secret and the machine store hold the old passphrase |
| Volume removed from the Machine and added again | gone from the VM after 13 s, `Attached` 8 s after it was added. The libvirt secret and the machine store hold the new passphrase. QEMU's librbd 18.2.7 unlocked the header that librbd 22 had rewritten, and the data written before the rotation read back |

### Cause of the hang

Run 2026-11-22 on the same arm64 host, without the lab and without
emulation, to check the reading of the librbd log above. The parts were a
native debug build of the same Ceph commit (`9cce574d9dc7`), a test cluster
with one OSD that keeps its data in memory, and a second librbd client in
place of QEMU. That client is a Python program that loads the encryption,
then writes 4 KiB and flushes every 0.11 s. Each run formats a fresh image
of 64 MiB and runs `rbd encryption luksAddKey` with a time limit of 30 s.
"Slow writes" below means that the command ran with `--rbd-cache=false
--ms-inject-delay-type=osd --ms-inject-delay-probability=1
--ms-inject-delay-max=0.05`, so each of its header writes waits for the OSD
and the reply is delayed by up to 50 ms. In the lab the writes of the
emulated command are slow enough without these options.

| Check | Result |
|---|---|
| No second client | returned in 2 of 2 runs, 4.5 and 4.6 s |
| Second client writes, default options | returned in 8 of 8 runs, 4.5 to 5.0 s |
| No second client, slow writes | returned in 2 of 2 runs, 5.4 and 5.5 s |
| Second client writes, slow writes | hung in 4 of 5 runs. The write of the second client waited until the kill. The librbd log ends like the one from the lab, the release of the lock starts its flush and the flush does not return. In the run that returned, the lock request arrived after the last header write had passed the lock layer |
| Debugger on a hung process | the lock is in its release step. The lock layer requires the lock for writes and holds one write back. Two operations are in flight, and the flush of the release waits on the older one, which is the write that is held back |
| The first, second and fourth check with one call changed | returned in all runs, with the second client and slow writes in 8 of 8, 5.8 to 8.1 s. In 7 of those 8 a header write was held back, the release went through, the second client wrote, and the command took the lock again and finished. The slowest write of the second client took 0.34 s. The added passphrase unlocked after every run |

The changed call is in `HeaderSession::write_next`
(`src/librbd/crypto/luks/HeaderSession.cc:183`). The build creates the
write with `io::AioCompletion::create_and_start`, which marks it as in
flight at once. The changed code uses `io::AioCompletion::create` and
`init_time`, so the core layer marks the write when it gets there
(`src/librbd/io/ImageDispatch.cc:23`). A write that waits for the lock is
then not in flight, and the release does not wait for it.

More checks of the same day, all with the second client writing and slow
writes.

| Check | Result |
|---|---|
| Typed call `encryption_luks_keyslot_add` through the Python binding, original code | hung in 4 of 5 runs. The added passphrase was refused after each kill |
| The same inside `lock_acquire(RBD_LOCK_MODE_EXCLUSIVE_TRANSIENT)` and `lock_release()` | returned in 8 of 8 runs. The second client asked for the lock once or twice per run and got it after the release. Its slowest write took 2.2 to 2.8 s, the time of the whole call |
| `rbd encryption luksAddKey`, original code, with that lock around the commit only | returned in 8 of 8 runs. The lock was held for 0.14 to 0.23 s, the slowest write of the second client took 0.33 s |
| Code that upstream ships: `encryption_format` on a handle that writes from a second thread | 89 of 90 runs returned, 1 hung with the same sequence in its log |

The check needs a Ceph build tree and a test cluster, so its scripts are
not part of the lab.

### Build with the fix for the hang

Run 2026-11-23 on the same arm64 host, with a second build from Clyso's
build system: Ceph `22.0.0-146-g2fd833e9b5ec` for x86_64, three commits on
top of the first build. Two of them change how librbd creates the reads and
the writes of the header, as described under "Cause of the hang". The third
makes `rbd encryption luksAddKey`, `luksChangeKey` and `luksKillSlot` hold
the exclusive lock in transient mode while they write the header back. The
setup was the one of "Build with rotation commands": the provider emulated
at a CPU limit of 2, `rbd` in the provider pod, the same Volume attached to
the same VM, and the same rounds of write, flush and read through the QEMU
monitor. All timings are emulated.

Bring-up.

| Check | Result |
|---|---|
| `docker pull --platform linux/amd64` on the host | 2 min 16 s. The image has `librbd1-22.0.0-146.g2fd833e9b5ec.el10.clyso.x86_64` and cryptsetup 2.8.6 |
| `./lab build-ceph-volume-provider` | 4 min 0 s |
| `./lab deploy` | 3 min 17 s. `rbd --version` in the new pod names the second build |

A control with the first build, in the quarter of an hour before the switch.

| Check | Result |
|---|---|
| `luksAddKey` while the VM wrote, three runs with a kill after 45 s | two hung. The VM's write waited 65 s in each, and the header listed a keyslot whose passphrase was refused. The third returned in 7.6 s. `header restore` with the VM idle repaired the header each time |

Then the second build. A cycle is five commands, each one started while the
VM wrote: `luksAddKey` for a second passphrase, `keyslot add` for a third,
`keyslot remove` of the third, `luksKillSlot` of the second, and `header
restore` with the dump from before the cycle. Six cycles were run, so 30
commands, each with a kill after 120 s that was never needed.

| Command | Runs | Returned | Time | Slowest write of the VM |
|---|---|---|---|---|
| `luksAddKey` | 6 | 6 | 7.7 to 9.2 s | 1.12 s |
| `keyslot add` | 6 | 6 | 5.3 to 7.0 s | 1.33 s |
| `keyslot remove` | 6 | 6 | 3.3 to 4.0 s | 0.44 s |
| `luksKillSlot` | 6 | 6 | 5.5 to 6.1 s | 0.45 s |
| `header restore` | 6 | 6 | 4.8 to 5.1 s | 0.68 s |

No command hung. The VM saw no I/O error in 3606 rounds. Write and flush
took 0.11 to 0.13 s on average in 28 of the 30 runs and up to 0.22 s in the
other two, which are the two with a write above one second. One of those
slow writes came before its command had started. In every cycle all three
passphrases unlocked their keyslot after `keyslot add`, and after `header
restore` only the first one did. At the end the two patterns that the VM
had written before the first rotation read back, and QEMU held the lock.

`keyslot add`, `keyslot remove` and `header restore` call librbd without a
lock of their own, so these 18 runs rest on the change in librbd alone.
`luksAddKey` and `luksKillSlot` add the transient lock. The client that had
to wait in those 12 runs was QEMU's librbd 18.2.7, which had not been tried
with that lock before.

Not run with this build: the provider calling librbd itself (TODO 6),
`luksChangeKey`, and a clone with `rbd_clone_copy_on_read`, the case that
the change to the header reads is for.

### macOS

Run 2026-11-22 on a Mac with Apple silicon, from commit `fc42e29` and
without `lab.env`, so with the upstream provider image. The host was macOS
27.2.1 on an M4 Pro with 12 CPUs and 24 GiB memory. Docker Desktop 4.76.0
(engine 29.5.2, containerd image store, VirtioFS) gave its VM 12 CPUs and
15.6 GiB, kernel 6.12.76-linuxkit, and the kind node had no `/dev/kvm`. The
setting "Use Rosetta for x86_64/amd64 emulation" was on. `bash` was 5.3.3
from Homebrew, not the 3.2 that macOS ships. Nothing was installed for the
lab, and no image was on the Mac before the run.

| Check | Result |
|---|---|
| `./lab up` from nothing | failed after 9 min 24 s in `up-storage` with `Error: timed out waiting for ceph mon endpoints`. The toolbox build, the kind cluster, IronCore, networking and libvirt-provider had gone through. 8 s after the timeout the CephCluster was at `Detecting Ceph version`, about 90 s after it the cluster was `Ready` |
| `./lab up-storage` again, unchanged | 59 s, Ceph `HEALTH_OK`, OSD on `/dev/loop0`. 11 min 57 s from the start of `up` to the end of the rerun |
| The example | all 7 objects created. Volume `Available` after 25 s. Machine `Running` with both volumes `Attached` 5 min 53 s after the apply, the OS image was pulled in that time |
| `./lab status` | provider upstream v0.6.0, QEMU in the node librbd 18.2.7, cluster 19.2.3 |
| Pods at the end | all `Running` or `Completed`. Two or three restarts during start-up for ironcore-controller-manager, ironcore-net-controller-manager, apinetlet, metalbond-client and libvirt-provider. The same five pods show one to three restarts on the Linux host |
| Files that the toolbox wrote into the clone | all owned by the user. `git status` clean in the clone and in the submodule |
| `./lab rbd ls -l` without `lab.env` | fails with `exec: "rbd": executable file not found in $PATH`. The upstream provider image has no `rbd` |
| Disk | the free space on the Mac went from 12 to about 10 GiB |

The wait that timed out is 20 tries of 5 s in ironcore-in-a-box
(`ironcore-in-a-box/hack/detect-ceph-mon-enpoints.sh:11`). In that time the
kind node pulls the Rook image and the Ceph image, and Rook finds the Ceph
version and starts the monitor. The node is new with every cluster and
pulls these images every time. The containerd log of the node on the Linux
host shows the pulls in the run that started from nothing, where the same
wait took 55 and 60 s. So the failure follows the speed of the link, and a
second `./lab up` on the same Mac is expected to fail the same way. Decision
10 gives the wait 15 minutes. The second run below tested both.

Two lines in the output of `up` look like errors and are none. Both hosts
print them.

- `Error: Nexthop device is not up.` followed by `Retrying route addition
  in 1s...`. The network setup of the node adds a route in a loop until its
  device is up (`ironcore-in-a-box/hack/setup-network.sh:39`).
- `/bin/sh: 1: /lab/ironcore-in-a-box/bin/kubectl-v1.36.4: not found`, in
  the first run only. ironcore-in-a-box calls kubectl to see whether it is
  there before it downloads it (`ironcore-in-a-box/Makefile:241`).

x86_64 programs, for decision 9. Checked before the cluster existed, with
`docker run --platform linux/amd64` on the upstream 21.2.0 image.

| Check | Result |
|---|---|
| `/usr/bin/true`, `rpm -q librbd1`, `rbd --version` | all three work, the package is `librbd1-21.2.0-0.el10.x86_64`. No registration step was needed |
| Which emulator ran them | Rosetta, `/proc/cpuinfo` names the CPU `VirtualApple`. QEMU 10.0.4 is registered in `binfmt_misc` as well |
| The x86-64-v3 level | offered. The glibc loader lists it as supported, v4 not, and the CPU flags include avx2, bmi2, fma, f16c and movbe |

Second run, 2026-11-23, on the same Mac with the same Docker Desktop and
settings, from a working state that has the longer wait of decision 10.
Every step passed. The images of the first run were still on the Mac.
First `./lab up` from nothing, without `lab.env`.

| Check | Result |
|---|---|
| `./lab down` for the cluster of the first run, up for 10 hours | 12 s |
| `./lab up` from nothing | passed in one go, 5 min 58 s |
| The wait for the monitor address | 20 tries failed and the 21st found the address, 102 s after the first. The 100 s of ironcore-in-a-box would have failed again |
| Image pulls of the node during that run | Rook image 80 s, Ceph image of the cluster 1.3 s, provider image 8.8 s. The Ceph image of the Rook toolbox took 72 s and ended after the wait |
| `/bin/bash ./lab status`, with and without `lab.env` | works under bash 3.2.57, the bash that macOS ships, with the same output as under the bash of Homebrew |
| `./lab down` at the end | 6 s. No node container left, `.kube` empty, no file in the clone owned by another user |

So the node pulled the images again, and the wait was mostly the pull of
the Rook image. The Ceph image of the cluster costs almost nothing after
it, because the Rook image is built on it. The first two of the eight
layers of `rook/ceph:v1.18.9` are the two layers of
`quay.io/ceph/ceph:v19.2.3`, read in the node of the Linux host, where that
pull took 1 s as well. The toolbox of Rook names `quay.io/ceph/ceph:v19`
(`ironcore-in-a-box/base/rook-cluster/kustomization.yaml:8`), another image
that shares no layer with the first, so the node pulls it in full.

Then the first build from Clyso's build system, for x86_64, with
`CEPH_PLATFORM=linux/amd64` (decision 9) and `./lab deploy` onto the
running cluster. The third column is the Linux host, where QEMU ran the
x86_64 provider. Its times for the image build, the deploy, `rbd` and the
Volume are those of the upstream 21.2.0 image ("Emulated provider" above),
the other rows are from the same build ("Build with rotation commands").
The hosts differ, so the columns do not compare the two emulators cleanly.

| Check | Mac, Rosetta | Linux host, QEMU |
|---|---|---|
| `docker pull --platform linux/amd64` of the Ceph image | 3 min 51 s | 2 min 34 s |
| `./lab build-ceph-volume-provider`, first build | 3 min 43 s, of it 133 s the Go compile. The image has `librbd1-22.0.0-143.g9cce574d9dc7.el10.clyso.x86_64` and the provider is linked against its `/lib64/librbd.so.1` | 51 min 18 s, of it 48 min 21 s the Go compile |
| `./lab deploy` | 96 s, of it 82 s loading the image into the node | 2 min 31 s |
| Process of the provider | `/run/rosetta/rosetta /ceph-volume-provider` | `/usr/bin/qemu-x86_64 /ceph-volume-provider` |
| Restarts 5 minutes after the deploy | provider none, volumepoollet once at the start, the provider's socket was not there yet | provider none, volumepoollet twice |
| `./lab rbd --version`, `./lab rbd ls -l` | 2.0 s and 0.9 s, without the line about THP | 5.8 s and 14.5 s |
| Encrypted Volume of the example | `Available` after 15 s | 110 s |
| Machine of the example | `Running` with both volumes `Attached` 5 min 20 s after the apply | not timed with this build |
| Keyslot of that Volume | argon2id with 732 MiB, time cost 4, 4 threads | argon2id with 64 MiB, time cost 4, 4 threads |
| `rbd encryption keyslot list`, `luksDump` on the image that the VM has open | 0.8 s and 1.0 s | 5 s |
| Disk | 16 GiB for the whole run, 4 of it the Ceph image and 6 the image build | not measured |

No command that changes the header was run on the Mac, because this build
can hang in them ("Build with rotation commands").

### Keyslot cost and the CPU limit

Run 2026-11-23 on the Linux host, after the Mac run showed a keyslot with
732 MiB where the Linux host had always seen 64 MiB. TODO 4 of
`design-decisions.md` expected the cost to follow the CPU that the provider
gets. `cryptsetup benchmark --pbkdf argon2id` runs the measurement that
libcryptsetup does when a keyslot is created. It was run natively with
cryptsetup 2.8.1 of the upstream 21.2.0 image, where only the CPU limit of
the container changed, and once through QEMU with cryptsetup 2.8.6 of the
x86_64 build.

| CPU limit | Result |
|---|---|
| 0.2, what ironcore-in-a-box gives the provider | time cost 4, 64 MiB, 4 threads |
| 2, what the lab gives an emulated provider | time cost 4, 557 MiB, 4 threads |
| none, 8 CPUs | time cost 4, 668 MiB, 4 threads |
| 2, x86_64 through QEMU | time cost 4, 74 MiB, 4 threads |

The 64 MiB of the native provider on the Linux host therefore came from its
CPU limit of 200m. Through QEMU the measurement stays near the lowest
result even at a limit of 2, which fits the 64 MiB of the emulated provider
there. Under Rosetta at the same limit the provider was fast enough for 732
MiB. Every later open of such a Volume needs that memory, in QEMU when the
Volume is attached and in the provider for a keyslot command. QEMU's librbd
on the Mac opened the keyslot with 732 MiB. Not measured: the memory of the
provider during a keyslot command on such a Volume.

What the limits do to a format and to an open, with the same cryptsetup
2.8.1 in a container, natively, on a file of 32 MiB (`cryptsetup luksFormat
--type luks2`, then `cryptsetup open --test-passphrase`).

| Check | Limits of the container | Result |
|---|---|---|
| Format | 2 CPUs | 6.7 s, keyslot with 455 MiB, time cost 4, 4 threads |
| Open that file | 2 CPUs | 2.3 s |
| Open that file | 0.2 CPUs | 21.6 s |
| Open that file | 2 CPUs, 256 MiB | cryptsetup killed after 0.2 s (exit code 137) |
| Format | no CPU limit, 256 MiB | cryptsetup killed after 3.8 s (exit code 137) |
| Format | 0.2 CPUs, 256 MiB | 16.9 s, keyslot with 64 MiB |

So the limits of ironcore-in-a-box for the provider, 200m and 256Mi, fit
each other only because the CPU limit keeps the cost at its lowest value.
The kills are read as the memory limit of the container. The kernel log
was not readable from the test. Not run: the same with the provider
process, which needs about 200 MiB by itself.

A cost that the caller names instead of the measurement, with the same
cryptsetup at the limits of ironcore-in-a-box (`--pbkdf argon2id
--pbkdf-memory 65536 --pbkdf-force-iterations 4 --pbkdf-parallel 4`, a key
file of 32 bytes). The times include the start of the container.

| Check | Limits of the container | Result |
|---|---|---|
| Format with that cost | 0.2 CPUs, 256 MiB | 4.6 s, keyslot with 64 MiB, time cost 4, 4 threads |
| Open that file | 0.2 CPUs, 256 MiB | 3.9 s |
| Open that file | 0.2 CPUs, 128 MiB | 4.1 s |
| Open that file | 2 CPUs, 256 MiB | 1.4 s |
| `luksAddKey` with that cost | 0.2 CPUs, 256 MiB | 9.7 s |

So the memory of such a keyslot no longer depends on the host, and
cryptsetup alone stays within 128 MiB. Not run: the same in the provider
process, which needs its own memory on top. How a Volume gets such a cost
at creation is TODO 14 of `design-decisions.md`.

A header with a fixed cost, without a format by librbd. Run in the provider
pod with the first build from Clyso's build system, emulated. `cryptsetup
luksFormat` built a LUKS2 header on a file with `--pbkdf-memory 65536
--pbkdf-force-iterations 4 --pbkdf-parallel 4`, so without a measurement,
and with aes-xts-plain64, a sector size of 4096 and the data offset of 16
MiB that librbd uses. Its first 16 MiB went onto a new image of 64 MiB with
`rbd encryption header restore`.

| Check | Result |
|---|---|
| `luksDump` on the new image before the restore | refused, the image has no header |
| `header restore` | 6 s, no message |
| `keyslot list` | keyslot 0, argon2id with 64 MiB, time cost 4, 4 threads |
| Load through librbd 22 with a wrong passphrase | refused |
| Load with the right one | works, 48 of the 64 MiB are data |
| 4 KiB written and read back, then read after a second open | equal both times. The raw bytes at 16 MiB are neither the text nor zeros |

So the restore call does not need an earlier format. Not run: an attach of
such an image to a VM, where QEMU's librbd 18.2.7 opens it, the same on a
clone, and the exit code of the restore command, which the test script did
not keep.

## Assumed, not run

- A build from Clyso's build system on a host of its own architecture. The
  first one was x86_64 and ran on the arm64 host through emulation.
- On macOS: the x86_64 programs, the image build and the provider with the
  Rosetta setting turned off, so with the QEMU of Docker Desktop. `./lab up`
  with `lab.env` in place from the start, the provider was deployed onto a
  running cluster. bash 3.2 for `./lab kubectl`, `./lab rbd` and
  `./lab shell`, which differ from the tested call in their last line only.
  A command that changes the header. The domain type of the VM, the LUKS
  magic of the image and a login to the VM were not looked at.
- WSL2. The toolbox reaches the cluster over the kind network, which did
  not depend on the host on macOS. The uid handling in `lab` may need a
  change there (TODO 5).
- A host with x86_64 CPUs. An x86_64 build was run on the arm64 host only,
  through emulation (decision 9).
- Replacing the other five images. Same code path as the provider.
- A rotation by the provider. The commands of the build were run as `rbd` in
  the provider pod, and the provider's stored copy of the passphrase was not
  updated.
- I/O from a guest with a mounted filesystem. In both checks it was sent
  through the QEMU monitor.

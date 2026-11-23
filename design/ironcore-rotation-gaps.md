# What IronCore needs for a passphrase rotation

Short answer. Today IronCore cannot rotate the passphrase of an encrypted
Volume. Nothing notices that the Secret changed, the volume runtime
interface has no call for it, and the provider has no code that touches a
keyslot. The one reaction that exists is on the machine side, and it unplugs
the disk from the running VM. Several building blocks are there already, so
the list of changes is short, and most of them are small.

Rotation means the following here. The user puts a new passphrase into the
Secret that the Volume names. Afterwards the new passphrase opens the volume
and the old one does not. The volume key, which encrypts the data, stays the
same.

Checked against the versions the lab runs: ironcore v0.6.1 ([`ee24604`][ic]),
ceph-provider [`4c61421`][cp] and libvirt-provider v0.5.0 ([`56810ec`][lp]).
Each point says whether it was run in the lab (`development.md`, "Header
rewrite check") or read in the code. The changes are proposals to have
something to discuss. None of them is built.

## The steps of a rotation and their order

```
Secret: old -> new
   |
   v
1. new keyslot     the provider adds a keyslot for the new passphrase.
                   The header accepts old and new.
2. machines move   every machine runtime that holds the old passphrase
                   gets the new one.
3. old keyslot     the provider removes the keyslot of the old passphrase.
                   The header accepts the new one only.
```

The order matters, and each wrong order has a victim.

- Step 2 before step 1. A machine runtime holds a passphrase the header
  does not know, so the next attach of the volume fails.
- Step 3 before step 2. A machine runtime still holds a passphrase the
  header no longer knows. Run: after step 3 a fresh open with the old
  passphrase failed with `encryption load fail`.

A running VM needs nothing in any of the steps. Run: its I/O continued while
keyslots were added and removed, because QEMU works with the volume key it
got at attach. That run used a stand-in for the rotation. With the first
build that changes keyslots through librbd, a command and a writing VM
could block each other on the exclusive lock of the image
(`design-decisions.md`, TODO 13).

## What is there already

- The provider keeps the passphrase it formatted with, encrypted under its
  own key ([`image.go:58`][cp-image]). With that copy it can unlock the
  header and add a keyslot without being handed the old passphrase. Read.
- A header with two keyslots, and one rewritten by a newer libcryptsetup, is
  opened by the older librbd on the QEMU side. Run.
- machinepoollet reads the Secret again at every reconcile of a Machine
  ([`machine_controller_volume.go:202`][mp-read]). Read, and seen in the run.
- The machine runtime interface has `UpdateVolume`
  ([`api.proto:20`][iri-machine]), and libvirt-provider stores the encryption
  data it gets through it ([`machine_volume_update.go:35`][lp-update]). Read.

## What is missing

### 1. Nothing starts a rotation

**Today.** volumepoollet reads the Secret once, when it creates the volume
([`volume_controller.go:319`][vp-secret]). It does not watch Secrets
([`:700`][vp-watch]), and for an existing volume it can only expand it
([`:550`][vp-update]).

**Example.** Run: the Secret of an attached volume was changed, and the
header of its image stayed byte for byte what it was.

**Change.** volumepoollet watches the Secrets that its Volumes name and
reconciles the Volume when one changes.

### 2. The volume runtime interface has no call for it

**Today.** The calls are create, expand, delete and the snapshot calls
([`api.proto:12`][iri-volume]). Encryption data travels in the create call
only.

**Change.** A call that carries new encryption data for an existing volume.
It needs two phases, or a second call, because step 3 happens later than
step 1.

### 3. The provider cannot change a keyslot

**Today.** ceph-provider formats the header once
([`image_controller.go:702`][cp-format]) and does not open it again. Its
volume server has no call besides the ones above. librbd has no call for a
keyslot either, which is what the builds under test in this lab add
(`design-decisions.md`, TODO 6).

**Example.** If a keyslot is changed by other means, the stored copy holds a
passphrase the header no longer knows. The copy is handed on when the
provider clones a snapshot ([`:352`][cp-clone]), and a later rotation that
unlocks with it would fail.

**Change.** A rotation in the provider. It unlocks with the stored copy,
adds the keyslot, keeps both passphrases until step 3 and then stores the
new one alone. The memory a keyslot operation needs is TODO 4.

### 4. The machine side learns of the change late and unplugs the disk

**Today.** The Secret watch of machinepoollet covers the ignition Secret
only ([`util.go:68`][mp-names]). At a reconcile it compares the whole data
of the Secret with what the runtime holds ([`:318`][mp-equal]). Only a
change of size is updated in place ([`:358`][mp-should], with a note for
credentials at [`:372`][mp-todo]). Anything else is a detach followed by an
attach ([`:340`][mp-detach], [`:390`][mp-attach]).

**Example.** Run: a change of the Secret was not picked up for 14 minutes.
An earlier one was, by a reconcile that had another cause, and the disk was
gone from the running VM for 52 s.

**Change.** machinepoollet watches the encryption Secrets of the Volumes its
Machines use, and passes changed encryption data on with `UpdateVolume`.

### 5. libvirt-provider gives the passphrase to libvirt at attach only

**Today.** `UpdateVolume` stores the new data. The controller writes the
libvirt secret inside a real attach
([`machine_controller_volumes.go:414`][lp-secret]) and skips a disk that is
in the domain ([`:394`][lp-exists]).

**Example.** Expected, not run: after an update in place the libvirt secret
still holds the old passphrase. Whether a start of an existing domain reads
it from there without a new attach was not read.

**Change.** Write the secret also for a disk that stays attached.

Seen on the way, run: when detach and attach arrive in the same second, the
controller removes the disk first ([`:130`][lp-remove]) and plugs it again
only at its next resync, one minute later. That matters as long as detach
and attach stay the reaction.

### 6. Nothing orders the steps

**Today.** machinepoollet reads the Secret by itself, at its own time. The
volume side and the machine side do not know each other's state. The status
of a Volume has no field for it ([`volume_types.go:73`][vol-status]), and
the runtime reports name, handle and state per volume
([`api.proto:122`][iri-volstatus]).

**Example.** Not run: the user changes the Secret and machinepoollet
reconciles the Machine before the provider has added the keyslot. That is
step 2 before step 1. With today's reaction the volume is detached and the
attach fails, so the VM has lost its disk. In the lab run the header had
both keyslots by then.

**Change.** The Volume status says which content of the Secret the header
accepts, by an identifier that does not reveal the passphrase.
machinepoollet passes on only what the header accepts. The Machine status
says per volume which one the runtime holds, and step 3 waits until every
Machine that uses the Volume has moved. The same fields tell the user that
the old passphrase is retired, which nothing does today.

### 7. Snapshots and volumes made from them

**Today.** The header is part of the image. Run: it is the first 16 MiB. A
snapshot therefore keeps the header of its time, with the old keyslot. A
volume made from a snapshot gets the content the source volume's Secret has
at that moment ([`volume_controller.go:340`][vp-inherit]).

**Example.** Expected, not run: snapshot, then rotation, then a volume from
that snapshot. It is handed the new passphrase for data whose header knows
the old one. How ceph-provider sets up the header of such a volume
([`image_controller.go:746`][cp-fromsnap]) was not read to the end.

**Change.** Open. As a first step a limit that is written down and tested.

### 8. The limits of the provider do not know what a keyslot costs

**Today.** A keyslot locks the volume key with argon2id, and the memory that
this needs is stored in the keyslot. librbd leaves the choice to
libcryptsetup when the volume is created ([`Header.cc:155`][rbd-pbkdf]), and
libcryptsetup measures the CPU it gets at that moment. Run: 64 MiB at a CPU
limit of 0.2, 557 MiB at 2, and 732 MiB in a provider on a Mac
(`development.md`, "Keyslot cost and the CPU limit"). Every later open needs
that memory and that work again. A rotation opens the old keyslot and
creates a new one. The keyslot call of the build under test does not
measure. It gives the new keyslot the cost of the existing one unless the
caller names another. The provider has 200m CPU and 256Mi in
ironcore-in-a-box, and nothing compares its limits with the volumes.

**Example.** Run with cryptsetup alone, in a container. A file formatted at
2 CPUs got a keyslot of 455 MiB. Opening it took 2.3 s at 2 CPUs and 21.6 s
at 0.2 CPUs, and at a memory limit of 256 MiB the open was killed. Expected,
not run: a rotation of such a volume in a provider at 256Mi ends the same
way, in the middle of the rotation. Creating a volume fails likewise once
the provider gets more CPU without more memory. Run: a format without a CPU
limit at 256 MiB was killed, and at 0.2 CPUs it passed with 64 MiB.

**Change.** Three parts.
- A note for operators. Whatever opens a volume needs its own memory plus
  the cost of the keyslot, up to 1 GiB with the defaults of libcryptsetup.
  The CPU limit and the memory limit of the provider are raised together.
- Before a rotation the provider reads the cost of the keyslot it has to
  open. The header lists it without a passphrase. If the memory limit of
  the provider does not cover it, the rotation is refused with an error that
  names both numbers, before the header is touched.
- The rotation decides the cost of the new keyslot. A copy keeps the volume
  as it is. A fixed cost makes all volumes alike after their first rotation,
  and the old keyslot is opened one last time at its old cost. A passphrase
  that is a random key of 32 bytes gains nothing from an expensive
  derivation, and one that a person chose depends on it. Where the Secret
  always holds a random key, the lowest cost is enough, for example the 64
  MiB that volumes made at 200m have today. Not read: whether IronCore
  checks what the Secret holds.

**Deferred.** A fixed cost when the volume is created
(`design-decisions.md`, TODO 14). The format call of librbd takes no cost,
so the measurement decides. Two ways were looked at. Cost fields in the
format options are the small change for a caller and a change of the librbd
API. Or the caller builds the header with libcryptsetup and writes it with
the header restore call of the build under test. Run: that works on an
image that was never formatted (`development.md`, "Keyslot cost and the CPU
limit"). It needs libcryptsetup and the layout rules of librbd in the
provider. Until one of them exists, the first rotation is where a volume
can get a known cost.

## A possible order of work

1. Point 3 and 2, the rotation in the provider and the call for it. This is
   what the lab is for. Point 8 belongs to it, because it decides whether
   the provider survives the rotation.
2. Point 1, so that a changed Secret reaches the provider.
3. Point 6, before the machine side is touched, since it decides whether a
   rotation can break an attach.
4. Point 4 and 5, the update in place on the machine side.
5. Point 7.

One alternative for point 1 and 6 is to let `spec.encryption.secretRef` of a
Volume change, which is refused today
([`volume.go:126`][vol-immutable]). A rotation is then a Volume that points
to a new Secret. Old and new exist side by side and have names, which makes
the ordering easier to express. It is the larger change of the API.

## Not covered

- A new volume key. That means writing all data again.
- Copies of the header outside IronCore, for example in a backup. An old
  passphrase still opens them.
- The key under which the provider stores its copy of the passphrase.

[ic]: https://github.com/ironcore-dev/ironcore/tree/ee24604077faa679d6e22b06c543ca0a578b5db7
[cp]: https://github.com/ironcore-dev/ceph-provider/tree/4c614216a8b33f5a65aa843aef896844f7f6b8e3
[lp]: https://github.com/ironcore-dev/libvirt-provider/tree/56810ec16f4cfb022caab091120678c96ee2a427
[iri-volume]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/iri/apis/volume/v1alpha1/api.proto#L12-L20
[iri-machine]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/iri/apis/machine/v1alpha1/api.proto#L18-L20
[iri-volstatus]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/iri/apis/machine/v1alpha1/api.proto#L122
[vol-status]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/api/storage/v1alpha1/volume_types.go#L73
[vol-immutable]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/internal/apis/storage/validation/volume.go#L126
[vp-secret]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/volumepoollet/controllers/volume_controller.go#L319-L337
[vp-inherit]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/volumepoollet/controllers/volume_controller.go#L340-L368
[vp-update]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/volumepoollet/controllers/volume_controller.go#L550-L555
[vp-watch]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/volumepoollet/controllers/volume_controller.go#L700-L716
[mp-names]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/api/compute/v1alpha1/util.go#L68
[mp-read]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L185-L202
[mp-equal]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L318
[mp-detach]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L340
[mp-should]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L358-L374
[mp-todo]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L372
[mp-attach]: https://github.com/ironcore-dev/ironcore/blob/ee24604077faa679d6e22b06c543ca0a578b5db7/poollet/machinepoollet/controllers/machine_controller_volume.go#L390
[cp-image]: https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/api/image.go#L58-L61
[cp-format]: https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/internal/controllers/image_controller.go#L702-L730
[cp-clone]: https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/internal/controllers/image_controller.go#L343-L353
[cp-fromsnap]: https://github.com/ironcore-dev/ceph-provider/blob/4c614216a8b33f5a65aa843aef896844f7f6b8e3/internal/controllers/image_controller.go#L746
[lp-update]: https://github.com/ironcore-dev/libvirt-provider/blob/56810ec16f4cfb022caab091120678c96ee2a427/internal/server/machine_volume_update.go#L35-L48
[lp-remove]: https://github.com/ironcore-dev/libvirt-provider/blob/56810ec16f4cfb022caab091120678c96ee2a427/internal/controllers/machine_controller_volumes.go#L130
[lp-exists]: https://github.com/ironcore-dev/libvirt-provider/blob/56810ec16f4cfb022caab091120678c96ee2a427/internal/controllers/machine_controller_volumes.go#L394
[lp-secret]: https://github.com/ironcore-dev/libvirt-provider/blob/56810ec16f4cfb022caab091120678c96ee2a427/internal/controllers/machine_controller_volumes.go#L414
[rbd-pbkdf]: https://github.com/ceph/ceph/blob/b060042deb05d33e6cc358970cfb8221240bcf3e/src/librbd/crypto/luks/Header.cc#L155

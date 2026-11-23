# Header rewrite check

Scripts behind the "Header rewrite check" in `design/development.md`. They
stand in for a passphrase rotation. `cryptsetup` changes a copy of the LUKS
header in the provider pod, and the changed blocks are written back to the
image while it is attached to the lab VM.

Use a Volume made for the test. `hdr.py writeback` rewrites its header and
`ioloop.sh` writes to its disk.

| File | Runs in | What it does |
|---|---|---|
| `env.sh` | host, sourced | derives image, domain and Ceph access, defines `pod`, `hdr`, `hmp`, `qio` |
| `hdr.py` | provider pod | copies the first 16 MiB of an image, compares, writes changed blocks back |
| `meas.py` | provider pod | time, peak memory of the child and of the pod for one command |
| `ioloop.sh` | kind node | write, flush and read rounds on the disk through the QEMU monitor |
| `probe.py` | kind node | which passphrase the libvirt secret and the machine store hold |

## A run

The Volume `hdrtest` is encrypted and attached to `lab-vm` under the same
name. `passA.txt` and `passB.txt` hold the old and the new passphrase
without a newline.

```sh
. hack/header-rewrite-check/env.sh
pod_install
hdr dump "$IMG" hdr.orig
pod sh -c 'cat > /tmp/hdrtest/passA.txt' < passA.txt
pod sh -c 'cat > /tmp/hdrtest/passB.txt' < passB.txt

# add a keyslot on the copy, measured
pod sh -c 'cd /tmp/hdrtest && cp hdr.orig hdr.new &&
    python3 meas.py cryptsetup luksAddKey --key-file passA.txt hdr.new passB.txt'

# write it back while the VM does I/O on the disk
docker exec -i "$NODE" sh -c 'cat > /tmp/hdrtest-ioloop.sh' < hack/header-rewrite-check/ioloop.sh
docker exec -d "$NODE" sh /tmp/hdrtest-ioloop.sh "$DOM" "$(qdev)"
hdr writeback "$IMG" hdr.orig hdr.new
docker exec "$NODE" touch /tmp/hdrtest-stop
docker exec "$NODE" cat /tmp/hdrtest-loop.err

# one read through the VM's disk
qio "read -P 0x5a 0 64k"
```

Removing the old keyslot is the same with `cryptsetup luksKillSlot` on the
copy. Afterwards remove `/tmp/hdrtest` in the pod and `/tmp/hdrtest-*` in
the node.

The files were moved here after the check and had their fixed names
replaced by the ones `env.sh` derives. In this form `env.sh`, `pod_install`,
`hdr info`, `dump` and `verify`, `meas.py`, `qio` and one pass of `probe.py`
were run. The write-back, the loop and the probe loop were run before that
change only.

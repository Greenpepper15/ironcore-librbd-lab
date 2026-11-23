#!/usr/bin/env python3
"""Which passphrase each copy on the machine side holds, and how QEMU sees the disk.

  probe.py <domain> <image> <volume name in the Machine> <sha256 of A> <sha256 of B> [once]

Runs in the kind node. Prints a line whenever the state changes, until
/tmp/hdrtest-probe-stop exists. The passphrases are given as hashes only.
"""
import base64, glob, hashlib, json, os, subprocess, sys, time

DOM, IMG, VOLUME = sys.argv[1:4]
LABEL = {sys.argv[4]: "A", sys.argv[5]: "B"}


def label(raw):
    return LABEL.get(hashlib.sha256(raw).hexdigest(), "other")


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def state():
    out = {}
    uuid = [l.split()[0] for l in sh("virsh", "secret-list").splitlines()
            if l.rstrip().endswith("volume." + VOLUME)]
    try:
        out["libvirt_secret"] = label(base64.b64decode(
            open("/etc/libvirt/secrets/%s.base64" % uuid[0]).read())) if uuid else "none"
    except OSError:
        out["libvirt_secret"] = "nofile"
    vols = json.load(open("/var/lib/libvirt-provider/store/machines/" + DOM))["spec"]["volumes"]
    v = [x for x in vols if x["name"] == VOLUME]
    out["store"] = label(base64.b64decode(v[0]["cephDisk"]["encryption_data"]["encryptionKey"])) if v else "none"
    node = [l.split(":")[0] for l in sh("virsh", "qemu-monitor-command", DOM, "--hmp", "info block").splitlines()
            if IMG in l]
    out["qemu_node"] = node[0] if node else "none"
    out["domblk"] = "present" if IMG in sh("virsh", "domblklist", DOM) else "none"
    return out


if sys.argv[6:] == ["once"]:
    print(state())
    sys.exit(0)
last = None
while not os.path.exists("/tmp/hdrtest-probe-stop"):
    try:
        s = state()
    except Exception as e:
        s = {"error": repr(e)}
    if s != last:
        print("%.1f %s" % (time.time(), s), flush=True)
        last = s
    time.sleep(1)

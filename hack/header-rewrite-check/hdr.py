#!/usr/bin/env python3
"""Raw access to the first bytes of an RBD image, for the header rewrite test.

  hdr.py info      <image>
  hdr.py dump      <image> <file>          copy the first LEN bytes into a file
  hdr.py verify    <image> <file>          compare the image against a file
  hdr.py writeback <image> <old> <new>     write the 4 KiB blocks that differ

Runs in the volume provider pod. env.sh passes the provider's own Ceph access
in HDR_MON, HDR_ID, HDR_KEYRING and HDR_POOL. writeback changes the image.
"""
import hashlib
import os
import sys
import time

import rados
import rbd

MON = os.environ["HDR_MON"]
USER = os.environ["HDR_ID"]
KEYRING = os.environ["HDR_KEYRING"]
POOL = os.environ["HDR_POOL"]
LEN = int(os.environ.get("HDR_LEN", 16 * 1024 * 1024))
BLOCK = 4096
CHUNK = 4 * 1024 * 1024


def connect():
    cluster = rados.Rados(rados_id=USER, conf={"mon_host": MON, "keyring": KEYRING})
    cluster.connect()
    return cluster, cluster.open_ioctx(POOL)


def read_range(image, length):
    buf = bytearray()
    while len(buf) < length:
        buf += image.read(len(buf), min(CHUNK, length - len(buf)))
    return bytes(buf)


def sha(data):
    return hashlib.sha256(data).hexdigest()[:16]


def info(image):
    print("size", image.size(), "features", hex(image.features()))
    lockers = image.list_lockers()
    print("lockers", [(c, a) for c, _, a in lockers["lockers"]] if lockers else [])
    print("watchers", [(w["addr"], w["id"]) for w in image.watchers_list()])


def changed_blocks(old, new):
    return [off for off in range(0, len(new), BLOCK)
            if old[off:off + BLOCK] != new[off:off + BLOCK]]


def runs(offsets):
    """Merge neighbouring block offsets into (offset, length) runs."""
    out = []
    for off in offsets:
        if out and out[-1][0] + out[-1][1] == off:
            out[-1][1] += BLOCK
        else:
            out.append([off, BLOCK])
    return out


def main():
    cmd, name = sys.argv[1], sys.argv[2]
    cluster, ioctx = connect()
    try:
        if cmd == "info":
            with rbd.Image(ioctx, name, read_only=True) as image:
                info(image)
        elif cmd == "dump":
            with rbd.Image(ioctx, name, read_only=True) as image:
                data = read_range(image, LEN)
            with open(sys.argv[3], "wb") as f:
                f.write(data)
            print("dumped", len(data), "bytes sha256", sha(data))
        elif cmd == "verify":
            want = open(sys.argv[3], "rb").read()
            with rbd.Image(ioctx, name, read_only=True) as image:
                have = read_range(image, len(want))
            diff = changed_blocks(want, have)
            print("verify", "equal" if not diff else "DIFFERENT in %d blocks" % len(diff),
                  "sha256", sha(have))
            sys.exit(1 if diff else 0)
        elif cmd == "writeback":
            old = open(sys.argv[3], "rb").read()
            new = open(sys.argv[4], "rb").read()
            assert len(old) == len(new)
            todo = runs(changed_blocks(old, new))
            print("changed", sum(l for _, l in todo) // BLOCK, "blocks in", len(todo), "runs:",
                  ", ".join("%#x+%d" % (o, l) for o, l in todo))
            with rbd.Image(ioctx, name) as image:
                # Refuse to write if someone else changed the header meanwhile.
                if read_range(image, len(old)) != old:
                    sys.exit("image differs from <old>, nothing written")
                t0 = time.monotonic()
                print("write start at %.3f" % time.time())
                for off, length in todo:
                    image.write(new[off:off + length], off)
                image.flush()
                t1 = time.monotonic()
                print("write flushed at %.3f" % time.time())
                back = read_range(image, len(new))
                info(image)
            print("image closed at %.3f" % time.time())
            print("wrote in %.3f s, read-back %s" %
                  (t1 - t0, "equal" if back == new else "DIFFERENT"))
            sys.exit(0 if back == new else 1)
        else:
            sys.exit(__doc__)
    finally:
        ioctx.close()
        cluster.shutdown()


if __name__ == "__main__":
    main()

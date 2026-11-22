#!/usr/bin/env bash
# Backing store for the single OSD: a sparse file in the kind node on a loop
# device.
#
#   hack/storage.sh setup|cleanup <kind node>
#
# ironcore-in-a-box always takes /dev/loop0. The node shares /dev with the
# host, and on a host that already uses loop0 (Ubuntu with snaps) that device
# is not ours. This script asks for a free one and records its name in
# .lab/osd-device for the Rook overlay.
set -euo pipefail

cmd=$1
node=$2
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BACKING=/var/tmp/lab-osd-disk0
SIZE=${LAB_OSD_SIZE:-10G}

case "$cmd" in
    setup)
        device=$(docker exec "$node" bash -ec "
            [ -f $BACKING ] || truncate -s $SIZE $BACKING
            dev=\$(losetup -j $BACKING -n -O NAME | head -n1)
            [ -n \"\$dev\" ] || dev=\$(losetup -f --show $BACKING)
            echo \"\$dev\"")
        mkdir -p "$LAB_DIR/.lab"
        echo "$device" > "$LAB_DIR/.lab/osd-device"
        echo "OSD backing store: $BACKING ($SIZE, sparse) on $device"
        ;;
    cleanup)
        docker exec "$node" bash -c "
            for dev in \$(losetup -j $BACKING -n -O NAME); do losetup -d \"\$dev\"; done
            rm -f $BACKING" || true
        rm -f "$LAB_DIR/.lab/osd-device"
        ;;
    *)
        echo "usage: $0 setup|cleanup <kind node>" >&2
        exit 1
        ;;
esac

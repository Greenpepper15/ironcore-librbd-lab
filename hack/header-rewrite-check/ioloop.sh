#!/bin/sh
# I/O loop on a disk of the lab VM through the QEMU monitor. Runs in the kind
# node. It WRITES to the disk, at 256 MiB and the 64 blocks after it.
#
#   ioloop.sh <domain> <qom path of the disk's device>
#
# Stops when /tmp/hdrtest-stop exists. Timings per round go to
# /tmp/hdrtest-loop.log, monitor errors to /tmp/hdrtest-loop.err.
DOM=$1
QDEV=$2
rm -f /tmp/hdrtest-stop /tmp/hdrtest-loop.log /tmp/hdrtest-loop.err
q() {
    r=$(virsh qemu-monitor-command "$DOM" --hmp "qemu-io -d $QDEV \"$1\"" 2>&1 | tr -d "\r\n")
    [ -n "$r" ] && echo "$(date +%s.%N) $1: $r" >> /tmp/hdrtest-loop.err
}
i=0
while [ ! -e /tmp/hdrtest-stop ]; do
    p=$((i % 250 + 1)); off=$((268435456 + (i % 64) * 4096))
    t0=$(date +%s.%N); q "write -P $p $off 4k"; q "flush"
    t1=$(date +%s.%N); q "read -P $p $off 4k"
    t2=$(date +%s.%N)
    echo "$i $t0 $t1 $t2" >> /tmp/hdrtest-loop.log
    i=$((i + 1))
done

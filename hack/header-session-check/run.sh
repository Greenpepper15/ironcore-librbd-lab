#!/usr/bin/env bash
# Helpers for the check of the Go bindings on the test volume while the VM
# writes. Builds on the helpers of the header rewrite check.
#
#   VOLUME=hdrtest MACHINE=lab-vm . hack/header-session-check/run.sh
#   hsc_install
#   chk "add A" -lock transient -key-file passB.txt -new-key-file passA.txt add "$IMG"
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$LAB/logs/build357-2026-11-23/run.sh"
HSC_BIN=$LAB/.cache/header-session-check/out/header-session-check
CHECK="./header-session-check -m $(_flag ceph-monitors) -id $(_flag ceph-user) -keyring $(_flag ceph-keyring-file) -p $(_flag ceph-pool)"

hsc_install() { pod sh -c 'cat > /tmp/hdrtest/header-session-check && chmod +x /tmp/hdrtest/header-session-check' < "$HSC_BIN"; }

# chk <label> <header-session-check args...>: one run under the I/O loop.
# Prints the output of the program, the loop summary, the lock events that
# the program's librbd logged, and what QEMU logged as failed meanwhile.
chk() {
    local label=$1; shift
    local q0; q0=$(docker exec "$NODE" sh -c "wc -l < $QLOG")
    loop_start
    echo "== $label: $*"
    pod sh -c "cd /tmp/hdrtest && python3 meas.py timeout -s KILL 240 $CHECK -ceph-opts debug_rbd=20,log_to_stderr=true $* 2> dbg.log" 2>&1 | grep -v THP
    local i a now
    for i in $(seq 1 14); do
        sleep 4
        a=$(docker exec "$NODE" sh -c 'tail -1 /tmp/hdrtest-loop.log | cut -d" " -f4'); now=$(date +%s)
        [ $((now - ${a%.*})) -lt 3 ] && break
    done
    sleep 2
    loop_stop
    docker exec "$NODE" sh -c 'awk "{w=\$3-\$2; if (w>2) printf \"slow round %d: write+flush %.1f s, started %.3f\n\", \$1, w, \$2}" /tmp/hdrtest-loop.log'
    # lock and header write events of the program's librbd, in order
    pod sh -c "cd /tmp/hdrtest && grep -E 'post_acquire_lock_handler: r=0|Policy .*lock_requested|HeaderSession: .*(write_next|finish)|pre_release_lock_handler|post_release_lock_handler' dbg.log | sed -E 's/^[0-9-]+T([0-9:.]+)[+0-9]* [0-9a-f]+ +[0-9]+ /\\1 /; s/0x[0-9a-f]+ //g; s/librbd::(crypto::luks::)?//' | cut -c1-110" 2>&1 | grep -v THP
    local qe; qe=$(docker exec "$NODE" sh -c "tail -n +$((q0 + 1)) $QLOG | grep -i 'failed\|error' | sed 's/[0-9][0-9]* bytes at offset [0-9]*//' | sort | uniq -c")
    echo "qemu log: ${qe:-no failed line}"
}

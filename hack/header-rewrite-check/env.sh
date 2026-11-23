# Names and helpers for the header rewrite check. Source it from the host.
#
#   VOLUME=hdrtest MACHINE=lab-vm . hack/header-rewrite-check/env.sh
#
# VOLUME is the IronCore Volume under test, attached to MACHINE under the
# same name.
HRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAB=$(cd "$HRC_DIR/../.." && pwd)
VOLUME=${VOLUME:-hdrtest}
MACHINE=${MACHINE:-lab-vm}
NODE=${KIND_CLUSTER_NAME:-ironcore-in-a-box}-control-plane
KC="$LAB/lab kubectl"
PROVIDER=deployment/ceph-volume-provider-controller-manager

# RBD image of the Volume and libvirt domain of the Machine.
IMG=$($KC get volume "$VOLUME" -o jsonpath='{.status.access.volumeAttributes.image}')
IMG=${IMG#*/}
DOM=$($KC get machine "$MACHINE" -o jsonpath='{.status.machineID}')
DOM=${DOM#*://}
QLOG=/var/log/libvirt/qemu/$DOM.log

# The provider's own Ceph access, read from its arguments as hack/rbd.sh does.
_args=$($KC -n rook-ceph get $PROVIDER \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="ceph-volume-provider")].args}')
_flag() { echo "$_args" | tr -d '[]"' | tr ',' '\n' | sed -n "s/^--$1=//p"; }
HDR_ENV="HDR_MON=$(_flag ceph-monitors) HDR_ID=$(_flag ceph-user) HDR_KEYRING=$(_flag ceph-keyring-file) HDR_POOL=$(_flag ceph-pool)"

# Run a command in the provider container.
pod() { $KC -n rook-ceph exec -i $PROVIDER -c ceph-volume-provider -- "$@"; }
# Copy hdr.py and meas.py into the pod.
pod_install() {
    pod mkdir -p /tmp/hdrtest
    for f in hdr.py meas.py; do pod sh -c "cat > /tmp/hdrtest/$f" < "$HRC_DIR/$f"; done
}
# hdr.py in the pod, working directory /tmp/hdrtest.
hdr() { pod sh -c "cd /tmp/hdrtest && $HDR_ENV python3 hdr.py $*"; }
# QEMU monitor command of the VM.
hmp() { docker exec "$NODE" virsh qemu-monitor-command "$DOM" --hmp "$1"; }
# QOM path of the device the image is attached to, empty if it is not attached.
qdev() { hmp 'info block' | grep -A1 "$IMG" | sed -n 's/.*Attached to: *//p' | tr -d '\r'; }
# qemu-io on the disk through its device, which is the path guest I/O takes.
# QEMU prints the result into the domain log, not into the monitor reply.
qio() {
    local before; before=$(docker exec "$NODE" sh -c "wc -l < $QLOG")
    hmp "qemu-io -d $(qdev) \"$1\"" | grep -v '^$'
    docker exec "$NODE" sh -c "tail -n +$((before + 1)) $QLOG"
}

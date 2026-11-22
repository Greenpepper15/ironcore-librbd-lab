#!/usr/bin/env bash
# Shows which librbd runs where and which component images are deployed.
#
#   hack/status.sh <kind node>
set -uo pipefail

node=$1
KUBECTL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ironcore-in-a-box/bin/kubectl"
provider=deployment/ceph-volume-provider-controller-manager

echo "librbd"
printf '  %-34s %s\n' "volume provider (formats, rotates)" \
    "$("$KUBECTL" -n rook-ceph exec "$provider" -c ceph-volume-provider -- rpm -q librbd1 2>/dev/null \
        || echo "upstream image, Debian packages copied in at build time")"
printf '  %-34s %s\n' "QEMU in the kind node (VM I/O)" \
    "$(docker exec "$node" dpkg-query -W -f '${Package} ${Version}' librbd1 2>/dev/null)"
printf '  %-34s %s\n' "Ceph cluster" \
    "$("$KUBECTL" -n rook-ceph exec deployment/rook-ceph-tools -- ceph version 2>/dev/null | cut -d' ' -f1-3)"

echo "images"
for target in ironcore-system/deployment/ironcore-apiserver \
              ironcore-system/deployment/ironcore-controller-manager \
              libvirt-provider/daemonset/libvirt-provider-controller-manager \
              rook-ceph/$provider; do
    ns=${target%%/*}; workload=${target#*/}
    "$KUBECTL" -n "$ns" get "$workload" \
        -o jsonpath='{range .spec.template.spec.containers[*]}{"  "}{.image}{"\n"}{end}' 2>/dev/null
done

#!/usr/bin/env bash
# Runs the rbd tool of the build under test inside the volume provider pod,
# with the provider's own monitors, user and pool.
#
#   hack/rbd.sh ls
#   hack/rbd.sh info <image>
#
# Needs a provider image built by this lab; the upstream image has no rbd.
set -euo pipefail

KUBECTL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ironcore-in-a-box/bin/kubectl"
deploy=deployment/ceph-volume-provider-controller-manager

args=$("$KUBECTL" -n rook-ceph get "$deploy" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="ceph-volume-provider")].args}')
flag() { echo "$args" | tr -d '[]"' | tr ',' '\n' | sed -n "s/^--$1=//p"; }

exec "$KUBECTL" -n rook-ceph exec "$deploy" -c ceph-volume-provider -- \
    rbd --no-config-file -m "$(flag ceph-monitors)" --id "$(flag ceph-user)" \
    --keyring "$(flag ceph-keyring-file)" -p "$(flag ceph-pool)" "$@"

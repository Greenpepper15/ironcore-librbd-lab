#!/usr/bin/env bash
# Builds the ceph-volume-provider from a local checkout against the librbd of
# CEPH_IMAGE. Settings come from lab.env (see lab.env.example).
set -euo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

: "${CEPH_PROVIDER_DIR:?set CEPH_PROVIDER_DIR to a ceph-provider checkout}"
: "${CEPH_IMAGE:?set CEPH_IMAGE to the Ceph container image to build against}"
: "${CEPH_REPO_URL:?set CEPH_REPO_URL to the RPM repository of the same Ceph build}"
image=${CEPH_VOLUME_PROVIDER_IMAGE:?set CEPH_VOLUME_PROVIDER_IMAGE to the tag to build, e.g. lab/ceph-volume-provider:dev}

docker build \
    -f "$LAB_DIR/images/ceph-volume-provider/Dockerfile" \
    --build-arg "CEPH_IMAGE=$CEPH_IMAGE" \
    --build-arg "CEPH_REPO_URL=$CEPH_REPO_URL" \
    --build-arg "CEPH_REPO_GPGKEY=${CEPH_REPO_GPGKEY:-}" \
    --build-arg "GO_BUILD_TAGS=${CEPH_PROVIDER_GO_BUILD_TAGS:-}" \
    -t "$image" \
    "$CEPH_PROVIDER_DIR"

echo
echo "built $image"
docker run --rm --entrypoint sh "$image" -c \
    'echo "librbd in the image: $(rpm -q librbd1)"; echo "linked against:      $(ldd /ceph-volume-provider | grep -E "librbd|librados" | tr -s " \t" " " | tr "\n" ";")"'

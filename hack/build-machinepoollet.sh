#!/usr/bin/env bash
# Builds the machinepoollet image from the ironcore source, with the
# Dockerfile of that source. Settings come from lab.env (see lab.env.example).
set -euo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The source is the pinned submodule unless lab.env names another checkout
# (design decision 17).
IRONCORE_DIR=${IRONCORE_DIR:-$LAB_DIR/ironcore}
if [ ! -f "$IRONCORE_DIR/go.mod" ]; then
    echo "no ironcore source in $IRONCORE_DIR. For the submodule run on the host:" >&2
    echo "  git submodule update --init ironcore" >&2
    exit 1
fi
echo "ironcore source: $IRONCORE_DIR"
image=${MACHINEPOOLLET_IMAGE:?set MACHINEPOOLLET_IMAGE to the tag to build, e.g. lab/machinepoollet:dev}

docker build --target machinepoollet -t "$image" "$IRONCORE_DIR"

echo
echo "built $image"

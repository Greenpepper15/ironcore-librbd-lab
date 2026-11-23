#!/usr/bin/env bash
# Applies ironcore-in-a-box components with the lab's changes on top.
#
#   hack/apply-overrides.sh <component>...
#
# For each component it renders a kustomize overlay under .lab/overlays/ that
# takes the ironcore-in-a-box config as its base and replaces the images named
# in the environment (see lab.env.example). Images that exist in the local
# Docker are loaded into the kind node first.
set -euo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IIAB_CONFIG="$LAB_DIR/ironcore-in-a-box/.tmp/config/cluster/local"
CLUSTER=${KIND_CLUSTER_NAME:-ironcore-in-a-box}
NODE="$CLUSTER-control-plane"
KIND="$LAB_DIR/ironcore-in-a-box/bin/kind"
KUBECTL="$LAB_DIR/ironcore-in-a-box/bin/kubectl"

# component: "ENV_VAR=image name in the ironcore-in-a-box config" ...
images_of() {
    case "$1" in
        ironcore)
            echo "IRONCORE_APISERVER_IMAGE=ghcr.io/ironcore-dev/ironcore-apiserver" \
                 "IRONCORE_CONTROLLER_MANAGER_IMAGE=ghcr.io/ironcore-dev/ironcore-controller-manager" ;;
        libvirt-provider)
            echo "LIBVIRT_PROVIDER_IMAGE=ghcr.io/ironcore-dev/libvirt-provider" \
                 "MACHINEPOOLLET_IMAGE=ghcr.io/ironcore-dev/ironcore-machinepoollet" ;;
        ceph-volume-provider)
            echo "CEPH_VOLUME_PROVIDER_IMAGE=ghcr.io/ironcore-dev/ceph-volume-provider" \
                 "VOLUMEPOOLLET_IMAGE=ghcr.io/ironcore-dev/ironcore-volumepoollet" ;;
    esac
}

# A locally built image gets a tag derived from its image ID and is loaded
# into the node. A rebuild then changes the tag, which triggers a rollout.
# An image for another platform than the host is named with its platform,
# because "kind load docker-image" cannot save it (design decision 9).
resolve_image() {
    local ref=$1 platform=${2:-} id
    if id=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null); then
        local unique="${ref%:*}:${id:7:12}"
        docker tag "$ref" "$unique"
        if ! docker exec "$NODE" crictl inspecti -q "$unique" >/dev/null 2>&1; then
            echo "loading $unique into $NODE" >&2
            if [ -n "$platform" ]; then
                local tar="$LAB_DIR/.lab/load.tar"
                mkdir -p "$LAB_DIR/.lab"
                docker save --platform "$platform" -o "$tar" "$unique"
                "$KIND" load image-archive --name "$CLUSTER" "$tar" >&2
                rm -f "$tar"
            else
                "$KIND" load docker-image --name "$CLUSTER" "$unique" >&2
            fi
        fi
        echo "$unique"
    else
        echo "$ref"
    fi
}

render() {
    local component=$1 out="$LAB_DIR/.lab/overlays/$1" changed=0
    mkdir -p "$out"
    {
        echo "apiVersion: kustomize.config.k8s.io/v1beta1"
        echo "kind: Kustomization"
        echo "resources:"
        echo "  - ../../../ironcore-in-a-box/.tmp/config/cluster/local/$component"
    } > "$out/kustomization.yaml"

    local images="" pair var name ref platform
    for pair in $(images_of "$component"); do
        var=${pair%%=*}; name=${pair#*=}
        ref=${!var:-}
        [ -z "$ref" ] && continue
        # Only the volume provider is built for the platform of the Ceph build.
        platform=""
        [ "$var" = CEPH_VOLUME_PROVIDER_IMAGE ] && platform=${CEPH_PLATFORM:-}
        ref=$(resolve_image "$ref" "$platform")
        images+="  - name: $name"$'\n'"    newName: ${ref%:*}"$'\n'"    newTag: \"${ref##*:}\""$'\n'
        changed=1
    done
    if [ -n "$images" ]; then
        printf 'images:\n%s' "$images" >> "$out/kustomization.yaml"
    fi

    # Component specific patches.
    local patches=""
    case "$component" in
        rook-cluster)
            local device
            device=$(cat "$LAB_DIR/.lab/osd-device")
            patches+="  - target: {kind: CephCluster, name: rook-ceph}"$'\n'
            patches+="    patch: |-"$'\n'
            patches+="      - {op: replace, path: /spec/storage/devices/0/name, value: $device}"$'\n'
            if [ -n "${CEPH_CLUSTER_IMAGE:-}" ]; then
                patches+="      - {op: replace, path: /spec/cephVersion/image, value: \"$CEPH_CLUSTER_IMAGE\"}"$'\n'
            fi
            changed=1 ;;
        ceph-volume-provider)
            # ironcore-in-a-box limits the provider to 256Mi. The provider with
            # librbd 21 uses about 200 MiB, so an rbd command or a keyslot
            # operation in the same container gets it OOM-killed.
            # An emulated provider (CEPH_PLATFORM) is throttled all the time
            # at the 200m CPU of ironcore-in-a-box and restarts in a loop.
            local limits="memory: ${CEPH_VOLUME_PROVIDER_MEMORY:-2Gi}" cpu=${CEPH_VOLUME_PROVIDER_CPU:-}
            [ -z "$cpu" ] && [ -n "${CEPH_PLATFORM:-}" ] && cpu=2
            [ -n "$cpu" ] && limits+=", cpu: \"$cpu\""
            patches+="  - patch: |-"$'\n'
            patches+="      apiVersion: apps/v1"$'\n'
            patches+="      kind: Deployment"$'\n'
            patches+="      metadata: {name: ceph-volume-provider-controller-manager, namespace: rook-ceph}"$'\n'
            patches+="      spec:"$'\n'
            patches+="        template:"$'\n'
            patches+="          spec:"$'\n'
            patches+="            containers:"$'\n'
            patches+="              - name: ceph-volume-provider"$'\n'
            patches+="                resources: {limits: {$limits}}"$'\n'
            changed=1 ;;
    esac
    if [ -n "$patches" ]; then
        printf 'patches:\n%s' "$patches" >> "$out/kustomization.yaml"
    fi
    return $((1 - changed))
}

for component in "$@"; do
    [ -d "$IIAB_CONFIG/$component" ] || { echo "no ironcore-in-a-box config for $component, run 'make -C ironcore-in-a-box prepare-local-config'" >&2; exit 1; }
    if render "$component"; then
        echo "applying $component with lab overrides"
        "$KUBECTL" apply -k "$LAB_DIR/.lab/overlays/$component"
    else
        echo "$component: no overrides set, left as ironcore-in-a-box deployed it"
    fi
done

#!/usr/bin/env bash
# Builds header-session-check against the Ceph build of lab.env, into
# .cache/header-session-check/. Run it in the toolbox:
#
#   echo hack/header-session-check/build.sh | ./lab shell
#
# The recipe is the one of the provider image up to the Go build, plus the
# header package of libcryptsetup.
set -euo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK_DIR=$LAB_DIR/hack/header-session-check
OUT_DIR=$LAB_DIR/.cache/header-session-check
CEPH_PROVIDER_DIR=${CEPH_PROVIDER_DIR:-$LAB_DIR/ceph-provider}
GO_CEPH_DIR=${GO_CEPH_DIR:-$LAB_DIR/go-ceph}
: "${CEPH_IMAGE:?}" "${CEPH_REPO_URL:?}"

mkdir -p "$OUT_DIR"
sed '/^# GO_BUILD_TAGS passes/,$d' "$LAB_DIR/images/ceph-volume-provider/Dockerfile" > "$OUT_DIR/Dockerfile"
cat >> "$OUT_DIR/Dockerfile" <<'RECIPE'
RUN dnf install -y --repo crb --repo baseos --repo appstream cryptsetup-devel && dnf clean all
COPY --from=check main.go hack/header-session-check/main.go
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg \
    CGO_ENABLED=1 go build -tags ceph_luks_header_session -ldflags="-linkmode=external" \
    -o /header-session-check ./hack/header-session-check

FROM scratch
COPY --from=builder /header-session-check /header-session-check
RECIPE

platform=()
[ -n "${CEPH_PLATFORM:-}" ] && platform=(--platform "$CEPH_PLATFORM")
docker build "${platform[@]}" -f "$OUT_DIR/Dockerfile" \
    --build-context "go-ceph=$GO_CEPH_DIR" \
    --build-context "check=$CHECK_DIR" \
    --build-arg "CEPH_IMAGE=$CEPH_IMAGE" \
    --build-arg "CEPH_REPO_URL=$CEPH_REPO_URL" \
    --build-arg "CEPH_REPO_GPGKEY=${CEPH_REPO_GPGKEY:-}" \
    --output "type=local,dest=$OUT_DIR/out" \
    "$CEPH_PROVIDER_DIR"
ls -la "$OUT_DIR/out/header-session-check"

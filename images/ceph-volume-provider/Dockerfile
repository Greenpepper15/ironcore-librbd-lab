# syntax=docker/dockerfile:1
# ceph-volume-provider linked against the librbd of a given Ceph image.
#
# The build context is a ceph-provider checkout, the named build context
# "go-ceph" a go-ceph checkout. CEPH_IMAGE is an RPM based Ceph container
# image (el9 or el10), CEPH_REPO_URL the RPM repository of the same build,
# which supplies the matching -devel packages.
#
# The upstream Dockerfile copies Debian libraries into a distroless image and
# cannot take RPM builds. Here the Ceph image itself is the runtime base, so
# librbd and its dependencies are exactly the ones that were built together,
# and the pod also has the rbd and ceph command line tools of that build.

ARG CEPH_IMAGE=quay.io/ceph/ceph:v21.2.0
ARG GO_IMAGE=golang:1.27.1

FROM ${GO_IMAGE} AS go

FROM ${CEPH_IMAGE} AS builder
ARG CEPH_REPO_URL
ARG CEPH_REPO_GPGKEY=""

# The -devel packages have to be the same build as the librbd1 in the image.
RUN <<EOF
set -e
if [ -n "$CEPH_REPO_GPGKEY" ]; then gpg="gpgcheck=1
gpgkey=$CEPH_REPO_GPGKEY"; else gpg="gpgcheck=0"; fi
cat > /etc/yum.repos.d/lab-ceph-devel.repo <<REPO
[lab-ceph-devel]
name=Ceph packages matching the image
baseurl=$CEPH_REPO_URL/\$basearch
enabled=1
$gpg
REPO
librbd=$(rpm -q --qf '%{VERSION}-%{RELEASE}' librbd1)
librados=$(rpm -q --qf '%{VERSION}-%{RELEASE}' librados2)
# cryptsetup-devel is for the provider's libcryptsetup package, which is built
# only with the tag ceph_luks_header_session. It comes from the CRB repository.
dnf install -y --repo lab-ceph-devel --repo baseos --repo appstream --repo crb \
    gcc "librbd-devel-$librbd" "librados-devel-$librados" cryptsetup-devel
dnf clean all
EOF

COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local

WORKDIR /workspace
COPY go.mod go.sum ./
# go-ceph comes from the checkout, not from the version go.mod names, so that
# bindings for new librbd calls build without a release (design decision 12).
COPY --from=go-ceph . /go-ceph
RUN go mod edit -replace github.com/ceph/go-ceph=/go-ceph
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg \
    go mod download

COPY api/ api/
COPY internal/ internal/
COPY cmd/ cmd/

# GO_BUILD_TAGS passes go-ceph build tags, for example ceph_preview.
ARG GO_BUILD_TAGS=""
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg \
    CGO_ENABLED=1 go build -tags "$GO_BUILD_TAGS" -ldflags="-linkmode=external" \
    -o /ceph-volume-provider ./cmd/volumeprovider/main.go

FROM ${CEPH_IMAGE}
COPY --from=builder /ceph-volume-provider /ceph-volume-provider
USER 65532:65532
ENTRYPOINT ["/ceph-volume-provider"]

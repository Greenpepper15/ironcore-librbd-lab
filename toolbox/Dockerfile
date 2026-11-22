# Tools that ironcore-in-a-box and the lab Makefile need, so that the laptop
# only needs Docker. kind, kubectl and cmctl are installed by the
# ironcore-in-a-box Makefile itself, in the versions its pinned commit names.
FROM docker:29-cli AS docker-cli

FROM golang:1.27.1-bookworm
RUN apt-get update && \
    apt-get install -y --no-install-recommends make git curl ca-certificates jq && \
    rm -rf /var/lib/apt/lists/*
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
# The lab directory is mounted from the host and may belong to another uid.
RUN git config --system --add safe.directory '*'
WORKDIR /lab

# Lab Makefile. Run it through ./lab, which starts the toolbox container.
# ironcore-in-a-box (submodule, pinned) does the bring-up; this file adds what
# the lab needs on top. See design/design-decisions.md for the reasons.

SHELL := /bin/bash
IIAB  := ironcore-in-a-box
KIND_CLUSTER_NAME ?= ironcore-in-a-box
NODE  := $(KIND_CLUSTER_NAME)-control-plane
IIAB_CONFIG := $(IIAB)/.tmp/config/cluster/local

export KIND_CLUSTER_NAME
export PATH := $(CURDIR)/$(IIAB)/bin:$(PATH)

KIND    = $(IIAB)/bin/kind
KUBECTL = $(IIAB)/bin/kubectl
IIAB_MAKE = $(MAKE) -C $(IIAB)

.PHONY: help
help: ## Show the targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Bring-up

.PHONY: cluster
cluster: ## Create the kind cluster and write the kubeconfigs
	$(IIAB_MAKE) kind kubectl
	$(IIAB_MAKE) kind-cluster
	@docker network connect kind "$$(hostname)" 2>/dev/null || true
	@$(KIND) get kubeconfig --internal --name $(KIND_CLUSTER_NAME) > .kube/config
	@$(KIND) get kubeconfig --name $(KIND_CLUSTER_NAME) > .kube/config.host
	@chmod 600 .kube/config .kube/config.host

.PHONY: up-ironcore
up-ironcore: cluster ## IronCore with networking and libvirt-provider (ironcore-in-a-box "make up")
	$(IIAB_MAKE) up
	hack/apply-overrides.sh ironcore libvirt-provider

.PHONY: up-storage
up-storage: cluster ## Rook Ceph and the ceph-volume-provider
	hack/storage.sh setup $(NODE)
	$(IIAB_MAKE) prepare-local-config
	$(KUBECTL) apply -k $(IIAB_CONFIG)/rook-operator
	hack/apply-overrides.sh rook-cluster
	@# 15 minutes instead of 100 s: the node pulls the Rook and Ceph images
	@# first, which takes longer than that on a slow link (decision 10).
	cd $(IIAB) && MAX_RETRIES=180 hack/detect-ceph-mon-enpoints.sh
	hack/apply-overrides.sh ceph-volume-provider
	@# The provider exits while its pool does not exist yet. Wait for the
	@# pool, then restart it instead of waiting out the crash loop back-off.
	$(KUBECTL) -n rook-ceph wait cephblockpool/ceph-volume-provider \
		--for=jsonpath='{.status.phase}'=Ready --timeout=900s
	$(KUBECTL) -n rook-ceph rollout restart deployment/ceph-volume-provider-controller-manager
	$(KUBECTL) -n rook-ceph rollout status deployment/ceph-volume-provider-controller-manager --timeout=300s

.PHONY: up
up: up-ironcore up-storage ## Everything: IronCore, VMs, Ceph, volume provider

.PHONY: down
down: ## Delete the cluster and release the loop device
	-hack/storage.sh cleanup $(NODE)
	-$(KIND) delete cluster --name $(KIND_CLUSTER_NAME)
	rm -f .kube/config .kube/config.host

##@ Changing a component

.PHONY: build-ceph-volume-provider
build-ceph-volume-provider: ## Build the volume provider from the ceph-provider and go-ceph submodules against CEPH_IMAGE
	hack/build-ceph-volume-provider.sh

.PHONY: build-machinepoollet
build-machinepoollet: ## Build machinepoollet from the ironcore submodule
	hack/build-machinepoollet.sh

.PHONY: deploy
deploy: ## Load the images named in lab.env into the cluster and roll them out
	hack/apply-overrides.sh ironcore libvirt-provider ceph-volume-provider

.PHONY: status
status: ## Which librbd and which images run where
	hack/status.sh $(NODE)

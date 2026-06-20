SHELL := /bin/bash

# All targets go through tf.sh which decrypts secrets.sops.yaml using the age key.
# Prefer top-level make targets from the repo root (make init-ovh, make apply-ovh, etc.)
# which handle age key recovery automatically.
#
# From this directory with the age key already recovered:
#   export SOPS_AGE_KEY_FILE=/tmp/k3s-lab-age.agekey
#   make init && make apply

.PHONY: init plan apply destroy kubeconfig

init:
	terraform init

plan:
	./tf.sh plan

apply:
	./tf.sh apply -auto-approve

destroy:
	./tf.sh destroy -auto-approve

kubeconfig:
	@./tf.sh output -raw kubeconfig_path

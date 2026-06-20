SHELL := /bin/bash

# All targets go through tf.sh which decrypts secrets.sops.env before running.
# From a bare clone + age key: make init && make apply

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

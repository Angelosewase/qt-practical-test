# Exam automation entry points. Secrets come from .private/secrets.env (gitignored).
SHELL := /bin/bash
.DEFAULT_GOAL := help

# Load local secrets into the environment for each recipe that needs them.
LOAD_SECRETS = set -a; . $(CURDIR)/.private/secrets.env; set +a
TF_ENV = $(LOAD_SECRETS); \
	export TF_VAR_proxmox_endpoint="$$PROXMOX_ENDPOINT"; \
	export TF_VAR_proxmox_token_id="$$PROXMOX_TOKEN_ID"; \
	export TF_VAR_proxmox_api_token_secret="$$PROXMOX_TOKEN_SECRET"; \
	export TF_VAR_vm_username="$$VM_USERNAME"; \
	export TF_VAR_vm_password="$$VM_PASSWORD"; \
	export TF_VAR_ssh_public_key="$$(cat $(CURDIR)/.private/ssh/id_ed25519.pub)"

# Ansible targets are listed after the Kubernetes ones.
.PHONY: help setup secret-scan tf-fmt tf-validate tf-init tf-plan tf-apply tf-output env hadolint compose-config docker-build docker-push compose-up compose-down compose-logs verify k8s-render k8s-validate k8s-secrets k8s-deploy k8s-status k8s-verify

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

setup: ## Install the pre-commit secret guard into .git/hooks
	@test -d .git || (echo "not a git repo" && exit 1)
	ln -sf ../../scripts/pre-commit .git/hooks/pre-commit
	@echo "pre-commit hook installed"

secret-scan: ## Scan working tree and git history for secret values
	scripts/secret-scan.sh --tree
	scripts/secret-scan.sh --history

tf-fmt: ## terraform fmt (check mode fails on diffs)
	cd iac && terraform fmt -check -recursive

tf-validate: ## terraform init (no backend) and validate
	cd iac && terraform init -backend=false -input=false >/dev/null && terraform validate

tf-init: ## terraform init with providers
	cd iac && $(TF_ENV) && terraform init -input=false

tf-plan: ## terraform plan (saved to iac/tfplan)
	cd iac && $(TF_ENV) && terraform plan -input=false -out=tfplan

tf-apply: ## terraform apply the saved plan (creates the 4 VMs)
	cd iac && $(TF_ENV) && terraform apply -input=false tfplan

tf-output: ## Show VM names and IP addresses
	cd iac && $(TF_ENV) && terraform output

COMPOSE = docker compose -f docker/docker-compose.yml

env: ## Create docker/.env with generated secrets (kept if it exists)
	scripts/gen-env.sh

hadolint: ## Lint the Dockerfiles
	hadolint docker/api.Dockerfile docker/frontend.Dockerfile

compose-config: ## Validate docker-compose.yml and its env file
	$(COMPOSE) config -q && echo "compose config OK"

docker-build: ## Build both app images locally (tags from docker/.env)
	$(COMPOSE) build

docker-push: ## Log in to Docker Hub from .private/secrets.env, build, and push the app images
	set -a; . $(CURDIR)/.private/secrets.env; set +a; \
	test -n "$$DOCKERHUB_USER" && test -n "$$DOCKERHUB_TOKEN" && ! echo "$$DOCKERHUB_USER" | grep -q '<' || { echo "DOCKERHUB_USER/DOCKERHUB_TOKEN not set in .private/secrets.env"; exit 1; }; \
	echo "$$DOCKERHUB_TOKEN" | docker login -u "$$DOCKERHUB_USER" --password-stdin >/dev/null; \
	DOCKERHUB_USER="$$DOCKERHUB_USER" $(COMPOSE) build && DOCKERHUB_USER="$$DOCKERHUB_USER" $(COMPOSE) push api frontend

compose-up: ## Start the full stack (builds if needed); nginx on port 80
	$(COMPOSE) up -d --build

compose-down: ## Stop the stack (keeps the mongo-data volume)
	$(COMPOSE) down

compose-logs: ## Tail logs of every service (add SERVICE=api to narrow)
	$(COMPOSE) logs --tail=100 $(SERVICE)

verify: ## Functional checks against the local stack (BASE_URL overrides)
	scripts/verify.sh $${BASE_URL:-http://localhost}

# Kubernetes uses an explicit kubeconfig, never the default ~/.kube/config (which may point at other clusters).
KUBECONFIG ?= $(CURDIR)/.private/kubeconfig
KUBE = KUBECONFIG=$(KUBECONFIG)

k8s-render: ## Render k8s/ with image names from docker/.env to stdout
	scripts/k8s-render.sh

k8s-validate: ## Render, policy, nginx parity, strict schema, and cluster dry-run (if KUBECONFIG reaches one)
	$(KUBE) scripts/k8s-validate.sh

k8s-secrets: ## Create or update app-secrets from docker/.env (values are never printed)
	$(KUBE) scripts/k8s-secrets.sh

k8s-deploy: ## Apply the manifests to the cluster in KUBECONFIG and wait for rollout
	set -o pipefail; $(KUBE) $(MAKE) -s k8s-secrets
	set -o pipefail; scripts/k8s-render.sh | $(KUBE) kubectl apply -f -
	for d in mongodb valkey api frontend gateway; do \
	  if [ "$$d" = mongodb ]; then $(KUBE) kubectl -n qt-spring-app rollout status statefulset/$$d --timeout=300s; \
	  else $(KUBE) kubectl -n qt-spring-app rollout status deploy/$$d --timeout=300s; fi; \
	done

k8s-status: ## Pods, services and volume claims in the app namespace
	$(KUBE) kubectl -n qt-spring-app get pods,svc,pvc -o wide

k8s-verify: ## Functional checks against the NodePort (K8S_URL overrides; default http://<node>:30080)
	scripts/verify.sh $${K8S_URL:-http://127.0.0.1:30080}

ANSIBLE_DIR = $(CURDIR)/ansible

inventory: ## Generate ansible/inventory.ini from terraform output
	scripts/gen-inventory.sh

ansible-lint: ## Lint the Ansible project (production profile)
	cd ansible && ansible-lint

ansible-syntax: ## Syntax-check the playbook
	cd ansible && ansible-playbook --syntax-check site.yml

ansible-ping: ## Ping every host in the inventory
	cd ansible && ansible all -m ansible.builtin.ping

ansible-deps: ## Install the pinned Ansible collections
	cd ansible && ansible-galaxy collection install -r requirements.yml

ansible-run: ## Run the full playbook. Sources .private/secrets.env so VM_PASSWORD reaches the VMs (no_log)
	cd ansible && set -a && . $(CURDIR)/.private/secrets.env && set +a && ansible-playbook site.yml

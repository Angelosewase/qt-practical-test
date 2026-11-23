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

.PHONY: help setup secret-scan tf-fmt tf-validate tf-init tf-plan tf-apply tf-output env hadolint compose-config docker-build docker-push compose-up compose-down compose-logs verify

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

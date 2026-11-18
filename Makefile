# =============================================================================
# Maminco infra — convenience Makefile
# =============================================================================
# Local/single-host Docker Compose stack + Terraform shortcuts.
# All compose commands run from this directory and read ./.env automatically.
# =============================================================================

SHELL := /bin/bash
COMPOSE ?= docker compose
TF_DIR  := terraform

.DEFAULT_GOAL := help

.PHONY: help env up up-dev down logs ps rebuild seed build restart psql tf-init tf-up tf-destroy deploy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env — edit it before deploying!")

up: env ## Start the full stack (TLS site) in the background
	$(COMPOSE) up -d --build

up-dev: env ## Start the stack in HTTP-only mode (development)
	$(COMPOSE) -f docker-compose.yml -f docker-compose.dev.yml up -d --build

down: ## Stop the stack (keeps the postgres volume)
	$(COMPOSE) down

logs: ## Tail logs (make logs SERVICE=backend)
	$(COMPOSE) logs -f $(SERVICE)

ps: ## Show container status
	$(COMPOSE) ps

build: ## Build all images
	$(COMPOSE) build

rebuild: ## Rebuild images and recreate containers
	$(COMPOSE) up -d --build --force-recreate

restart: ## Restart all services
	$(COMPOSE) restart

seed: ## Run migrations + seed once (test data; never on a real tenant)
	SEED=true $(COMPOSE) run --rm migrate

psql: ## Open a psql shell inside the postgres container
	$(COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

tf-init: ## terraform init in ./terraform
	terraform -chdir=$(TF_DIR) init

tf-up: tf-init ## Provision/refresh the EC2 infra
	terraform -chdir=$(TF_DIR) apply -auto-approve

tf-destroy: ## Tear down all provisioned infra
	terraform -chdir=$(TF_DIR) destroy -auto-approve

deploy: ## Rebuild the stack and wait until every service is healthy
	$(COMPOSE) up -d --build --wait
	$(COMPOSE) ps

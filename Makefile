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

.PHONY: help env up down logs ps rebuild seed build restart psql tf-init tf-up tf-destroy deploy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env — edit it before deploying!")

up: env ## Start the full stack in the background
	$(COMPOSE) up -d

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

seed: ## Run the Prisma seed inside the running backend
	$(COMPOSE) exec backend npx prisma db seed

psql: ## Open a psql shell inside the postgres container
	$(COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

tf-init: ## terraform init in ./terraform
	terraform -chdir=$(TF_DIR) init

tf-up: tf-init ## Provision/refresh the EC2 infra
	terraform -chdir=$(TF_DIR) apply -auto-approve

tf-destroy: ## Tear down all provisioned infra
	terraform -chdir=$(TF_DIR) destroy -auto-approve

deploy: ## Local deploy: rebuild stack, wait for health, seed
	$(COMPOSE) up -d --build
	@echo "Waiting for services to become healthy..."
	@sleep 15
	$(COMPOSE) ps

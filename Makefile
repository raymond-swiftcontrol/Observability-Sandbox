# ─────────────────────────────────────────────────────────────────────────────
#  Helios — developer control surface
# ─────────────────────────────────────────────────────────────────────────────
SHELL := /bin/bash
.DEFAULT_GOAL := help
.ONESHELL:

ENV        ?= local
CHANNEL    ?= preview
COMPOSE    := docker compose -f docker-compose.yml
COMPOSE_O11Y := $(COMPOSE) -f docker-compose.observability.yml
PY         := apps/quant-engine/.venv/bin/python
TF_DIR     := infra/terraform
HELM_CHART := infra/helm/helios
GIT_SHA    := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
REGISTRY   ?= ghcr.io/raymond-swiftcontrol

SERVICES := api-gateway market-data-ingestor quant-engine risk-engine \
            execution-gateway notification-worker web-console

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── bootstrap ────────────────────────────────────────────────────────────────
.PHONY: bootstrap
bootstrap: bootstrap-js bootstrap-py bootstrap-go ## Install every toolchain's deps
	@echo "✓ workspace ready"

bootstrap-js:
	pnpm install --frozen-lockfile || pnpm install
	pnpm turbo run build --filter='./packages/*'

bootstrap-py:
	for svc in quant-engine risk-engine; do \
	  python3 -m venv apps/$$svc/.venv; \
	  apps/$$svc/.venv/bin/pip install -q --upgrade pip; \
	  apps/$$svc/.venv/bin/pip install -q -r apps/$$svc/requirements-dev.txt; \
	done

bootstrap-go:
	cd apps/market-data-ingestor && go mod download
	cd apps/execution-gateway && go mod download

# ── local stack ──────────────────────────────────────────────────────────────
.PHONY: stack-up stack-down stack-logs stack-ps stack-nuke
stack-up: ## Start infra containers (db, kafka, redis, clickhouse, minio, o11y)
	$(COMPOSE_O11Y) up -d --remove-orphans
	./scripts/wait-for-healthy.sh

stack-down: ## Stop infra containers, keep volumes
	$(COMPOSE_O11Y) down

stack-nuke: ## Stop infra containers and destroy volumes
	$(COMPOSE_O11Y) down -v --remove-orphans

stack-logs:
	$(COMPOSE_O11Y) logs -f --tail=120

stack-ps:
	$(COMPOSE_O11Y) ps

# ── database ─────────────────────────────────────────────────────────────────
.PHONY: db-migrate db-rollback db-seed db-reset db-diff db-analytics
db-migrate: ## Apply pending SQL migrations
	./scripts/db-migrate.sh up

db-rollback: ## Roll back the most recent migration
	./scripts/db-migrate.sh down 1

db-seed: ## Load reference + demo data
	./scripts/db-seed.sh

db-reset: stack-nuke stack-up db-migrate db-seed ## Nuke and rebuild from scratch

db-diff: ## Print schema drift between migrations/ and the live database
	./scripts/db-diff.sh

db-analytics: ## Apply ClickHouse DDL
	./scripts/clickhouse-apply.sh

# ── run ──────────────────────────────────────────────────────────────────────
.PHONY: dev dev-gateway dev-quant dev-risk dev-md dev-exec mobile
dev: ## Run every service with hot reload
	./scripts/dev.sh

dev-gateway:
	pnpm --filter @helios/api-gateway dev

dev-quant:
	cd apps/quant-engine && .venv/bin/uvicorn helios_quant.main:app --reload --port 8100

dev-risk:
	cd apps/risk-engine && .venv/bin/uvicorn helios_risk.main:app --reload --port 8200

dev-md:
	cd apps/market-data-ingestor && go run ./cmd/ingestor

dev-exec:
	cd apps/execution-gateway && go run ./cmd/gateway

mobile: ## Start the Expo dev server
	pnpm --filter @helios/mobile start

# ── quality ──────────────────────────────────────────────────────────────────
.PHONY: lint fmt typecheck test test-unit test-contract test-e2e backtest-golden load-test
lint: ## Lint every language
	pnpm turbo run lint
	cd apps/quant-engine && .venv/bin/ruff check src tests
	cd apps/risk-engine && .venv/bin/ruff check src tests
	cd apps/market-data-ingestor && go vet ./... && test -z "$$(gofmt -l .)"
	cd apps/execution-gateway && go vet ./... && test -z "$$(gofmt -l .)"

fmt: ## Format every language
	pnpm format
	cd apps/quant-engine && .venv/bin/ruff format src tests
	cd apps/risk-engine && .venv/bin/ruff format src tests
	cd apps/market-data-ingestor && gofmt -w .
	cd apps/execution-gateway && gofmt -w .

typecheck:
	pnpm turbo run typecheck
	cd apps/quant-engine && .venv/bin/mypy src
	cd apps/risk-engine && .venv/bin/mypy src

test: test-unit ## Alias for unit tests

test-unit:
	pnpm turbo run test
	cd apps/quant-engine && .venv/bin/pytest -q
	cd apps/risk-engine && .venv/bin/pytest -q
	cd apps/market-data-ingestor && go test ./... -race -count=1
	cd apps/execution-gateway && go test ./... -race -count=1

test-contract: ## Gateway ↔ service contract tests
	pnpm --filter @helios/api-gateway test:contract

test-e2e: ## Detox + Playwright against an ephemeral stack
	./scripts/e2e.sh

backtest-golden: ## Golden-file regression on reference strategies
	cd apps/quant-engine && .venv/bin/pytest tests/golden -q --golden

load-test: ## k6 scenarios
	k6 run scripts/load/quote-fanout.js
	k6 run scripts/load/order-burst.js

# ── build / images ───────────────────────────────────────────────────────────
.PHONY: build images push-images
build:
	pnpm turbo run build

images: ## Build every service container image
	for svc in $(SERVICES); do \
	  docker build -t $(REGISTRY)/helios-$$svc:$(GIT_SHA) \
	    -f apps/$$svc/Dockerfile . || exit 1; \
	done

push-images: images
	for svc in $(SERVICES); do docker push $(REGISTRY)/helios-$$svc:$(GIT_SHA); done

# ── infra / deploy ───────────────────────────────────────────────────────────
.PHONY: infra-init infra-plan infra-apply infra-destroy deploy deploy-diff rollback mobile-release
infra-init:
	cd $(TF_DIR) && terraform init -backend-config=envs/$(ENV)/backend.hcl

infra-plan: ## terraform plan for ENV=staging|prod
	cd $(TF_DIR) && terraform workspace select $(ENV) && \
	  terraform plan -var-file=envs/$(ENV)/terraform.tfvars -out=$(ENV).tfplan

infra-apply:
	cd $(TF_DIR) && terraform workspace select $(ENV) && terraform apply $(ENV).tfplan

infra-destroy:
	@echo "refusing to destroy $(ENV) without CONFIRM=yes"; test "$(CONFIRM)" = "yes"
	cd $(TF_DIR) && terraform workspace select $(ENV) && \
	  terraform destroy -var-file=envs/$(ENV)/terraform.tfvars

deploy: ## helm upgrade --install the umbrella chart
	helm upgrade --install helios $(HELM_CHART) \
	  --namespace helios --create-namespace \
	  --values $(HELM_CHART)/values.yaml \
	  --values $(HELM_CHART)/values-$(ENV).yaml \
	  --set global.image.tag=$(GIT_SHA) --atomic --timeout 10m

deploy-diff:
	helm diff upgrade helios $(HELM_CHART) \
	  --values $(HELM_CHART)/values-$(ENV).yaml --set global.image.tag=$(GIT_SHA)

rollback:
	helm rollback helios --namespace helios

mobile-release: ## EAS build + OTA update on CHANNEL
	cd apps/mobile && eas build --profile $(CHANNEL) --platform all --non-interactive
	cd apps/mobile && eas update --branch $(CHANNEL) --message "$(GIT_SHA)"

# ── utilities ────────────────────────────────────────────────────────────────
.PHONY: replay synth graph secrets-scan
replay: ## Replay a recorded market session into Kafka
	./scripts/replay-session.sh $(SESSION)

synth: ## Generate a synthetic market session
	$(PY) scripts/synth_market.py --symbols 250 --days 30 --out data/synthetic

graph: ## Regenerate architecture diagrams
	./scripts/gen-diagrams.sh

secrets-scan:
	gitleaks detect --no-banner --redact

# ── schema validation (no TimescaleDB image required) ────────────────────────
.PHONY: db-validate db-invariants
db-validate: ## Apply every migration to a throwaway vanilla Postgres
	python3 scripts/validate-schema.py

db-invariants: ## Prove the schema's invariants hold (ledger, state machine, RLS…)
	python3 scripts/validate-schema.py --keep
	python3 -m pytest db/testing/test_invariants.py -q

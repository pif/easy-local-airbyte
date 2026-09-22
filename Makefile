SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Pass FILE=... to restore, LABEL=... / KEEP=... to backup, YES=1 to skip prompts.
FILE  ?=
LABEL ?=
KEEP  ?=
YES   ?=

ifeq ($(YES),1)
export ASSUME_YES := 1
endif

.PHONY: help bootstrap preflight up install upgrade status credentials \
        backup restore restore-latest backups scale-down scale-up \
        down down-all uninstall logs shell-db template lint clean

help: ## Show this help
	@printf '\neasy-local-airbyte -- local open-source Airbyte on Kubernetes\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\nCommon flow:  make bootstrap   ->   make status   ->   make credentials\n\n'

bootstrap: ## One command: check tools, start VM, create cluster, install Airbyte
	@scripts/up.sh
	@scripts/install.sh

preflight: ## Check tooling and Docker resources
	@scripts/preflight.sh

up: ## Create the kind cluster + ingress controller
	@scripts/up.sh

install: ## Install or upgrade the Airbyte Helm release
	@scripts/install.sh

upgrade: install ## Alias for install (same idempotent path)

template: ## Render the Helm manifests without applying (dry run)
	@scripts/install.sh --dry-run

status: ## Show pods, health, and effective low-resource settings
	@scripts/status.sh

credentials: ## Print login and API credentials
	@scripts/credentials.sh

backup: ## Back up the internal Postgres (LABEL=text KEEP=n)
	@scripts/backup.sh $(if $(LABEL),--label "$(LABEL)") $(if $(KEEP),--keep "$(KEEP)")

restore: ## Restore a backup (FILE=backups/<name>.sql.gz)
	@if [ -z "$(FILE)" ]; then \
	  printf 'usage: make restore FILE=backups/<name>.sql.gz\n       make restore-latest\n' >&2; exit 1; fi
	@scripts/restore.sh --file "$(FILE)"

restore-latest: ## Restore the most recent backup
	@scripts/restore.sh --latest

backups: ## List available backups
	@scripts/list-backups.sh

scale-down: ## Stop Airbyte, keep Postgres running (frees laptop resources)
	@scripts/scale.sh down

scale-up: ## Start Airbyte back up
	@scripts/scale.sh up

# Selected by label, not by name: the chart's fullname helper drops the release
# prefix when the release is called "airbyte", so the deployment name is not a
# predictable string across RELEASE values. COMPONENT=worker etc. also works.
logs: ## Tail component logs (COMPONENT=server|worker|workload-launcher|cron)
	@kubectl --context kind-$${CLUSTER_NAME:-easy-local-airbyte} -n $${NAMESPACE:-airbyte} \
	  logs -f -l airbyte=$${COMPONENT:-server} --tail=200 --max-log-requests=10

shell-db: ## Open a psql shell on the internal Postgres
	@kubectl --context kind-$${CLUSTER_NAME:-easy-local-airbyte} -n $${NAMESPACE:-airbyte} \
	  exec -it airbyte-db-0 -c airbyte-db-container -- \
	  env PGPASSWORD=airbyte psql -U airbyte -d db-airbyte

uninstall: ## Uninstall the Helm release, keep the cluster and Postgres PVC
	@scripts/down.sh --release-only

down: ## Delete the kind cluster (backups are kept)
	@scripts/down.sh

down-all: ## Delete the cluster and stop the dedicated Docker VM
	@scripts/down.sh --all

lint: ## Shell-check every script (requires shellcheck)
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: brew install shellcheck" >&2; exit 1; }
	@shellcheck -x scripts/*.sh scripts/lib/*.sh && echo "shellcheck clean"

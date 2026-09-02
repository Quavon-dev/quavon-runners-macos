SHELL := /bin/bash
.DEFAULT_GOAL := help

RUNNER_BASE_DIR ?= $(HOME)/actions-runners

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## Full setup on a fresh VM (creates .env, checks, installs)
	./bootstrap.sh $(ARGS)

.PHONY: install
install: ## Install and start the runner(s)
	./bin/install.sh $(ARGS)

.PHONY: uninstall
uninstall: ## Stop, deregister and remove the runner(s)
	./bin/uninstall.sh $(ARGS)

.PHONY: status
status: ## Show local and org-side runner status
	./bin/status.sh $(ARGS)

.PHONY: doctor
doctor: ## Check that this host is ready to run runners
	./bin/doctor.sh

.PHONY: update
update: ## Update the runner binaries in place
	./bin/update.sh $(ARGS)

.PHONY: logs
logs: ## Tail the runner logs
	@tail -n 50 -F $(RUNNER_BASE_DIR)/*/_diag/*.log

.PHONY: test
test: ## Run the unit tests
	./tests/run.sh

.PHONY: lint
lint: ## Shellcheck every script
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: brew install shellcheck"; exit 1; }
	shellcheck -x --source-path=SCRIPTDIR bootstrap.sh bin/*.sh lib/*.sh tests/*.sh

.PHONY: check
check: lint test ## Lint and test

# Entry point for the testbed. "make help" lists all commands.

VARIANT ?= v0
AK ?=
RESULTS ?=
OWNER ?=
EMAIL ?=

.PHONY: help check-tools cluster deploy down protect-repos scenario fork-setup

help:
	@echo "Testbed for securing the software supply chain"
	@echo ""
	@echo "  make check-tools            Check that all tools are installed"
	@echo "  make cluster VARIANT=v0     Set up the local environment for a variant (v0, v1, v2, v3)"
	@echo "  make deploy                 Deploy the last successful build to the cluster"
	@echo "  make down                   Tear down the local environment completely"
	@echo "  make protect-repos          Protect main of example-app and secure-workflows on GitHub"
	@echo "  make scenario AK=13         Run an attack scenario against the running variant"
	@echo "                              (results in .work/scenario-results.csv, other location with RESULTS=...)"
	@echo "  make fork-setup OWNER=.. EMAIL=..  Adapt the clones to your own GitHub account"
	@echo ""
	@echo "After 'make deploy' the application is available at http://localhost:8080."

check-tools:
	@./scripts/check-tools.sh

cluster:
	@./scripts/cluster-up.sh $(VARIANT)

deploy:
	@./scripts/deploy.sh

down:
	@./scripts/cluster-down.sh

protect-repos:
	@./scripts/protect-repos.sh

scenario:
	@test -n "$(AK)" || { echo "Usage: make scenario AK=13"; exit 1; }
	@RESULTS_FILE="$(RESULTS)" ./scenarios/ak$(AK)-*.sh

fork-setup:
	@OWNER="$(OWNER)" EMAIL="$(EMAIL)" ./scripts/fork-setup.sh

# Einstiegspunkt fuer das Testbed. "make help" zeigt alle Befehle.

VARIANT ?= v0

.PHONY: help check-tools cluster deploy down protect-repos

help:
	@echo "Testbed fuer die Absicherung der Software Supply Chain"
	@echo ""
	@echo "  make check-tools            Pruefen, ob alle Werkzeuge installiert sind"
	@echo "  make cluster VARIANT=v0     Lokale Umgebung fuer eine Variante aufbauen (v0, v1, v2, v3)"
	@echo "  make deploy                 Letzten erfolgreichen Build in den Cluster bringen"
	@echo "  make down                   Lokale Umgebung vollstaendig abbauen"
	@echo "  make protect-repos          main in example-app und secure-workflows auf GitHub schuetzen"
	@echo ""
	@echo "Die Anwendung ist nach 'make deploy' unter http://localhost:8080 erreichbar."

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

# ==============================
# CONFIGURACAO DE CONEXAO
# Edite os valores abaixo antes de executar.
# Se usar DBURL, os demais podem ficar em branco.
# ==============================
PSQL ?= psql
PYTHON ?= python3
LAYOUT ?= multi
AUTHORIZED_SCHEMA ?=
RESTRICTIVE ?= NAO
MASTER_ROLE ?=
OUTPUT_SQL ?= installation.rendered.sql
SETUP_OPTIONS = --non-interactive --mode "$(LAYOUT)" --restrictive "$(RESTRICTIVE)" $(if $(AUTHORIZED_SCHEMA),--schema "$(AUTHORIZED_SCHEMA)") $(if $(MASTER_ROLE),--master "$(MASTER_ROLE)") --psql "$(PSQL)"
PSQL_FLAGS ?= -v ON_ERROR_STOP=1
DBURL =
HOST =
PORT =
DBUSER =
DBPASS =
DBNAME =

PSQL_ENV = $(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='$(DBNAME)')
PSQL_CMD = $(PSQL_ENV) $(PSQL) $(PSQL_FLAGS) $(DBURL)

.PHONY: help see assertDiff core all render test test-db manualExamples usecaseExamples dropDbTest


help:
	@printf '%s\n' \
	  'Targets:' \
	  '  all/core     - transactional fresh installation, including basic asserts.' \
	  '  render       - generate reviewable SQL without connecting.' \
	  '  test         - offline installer tests.' \
	  '  test-db      - four-layout matrix in uniquely named disposable databases.' \
	  '  assertDiff   - legacy alias for test-db.' \
	  '  manualExamples - execute the SQL examples from the user manual tutorial.' \
	  '  usecaseExamples - execute approved simple use-case test cases.' \
		'  see          - show variables' \
		'  dropDbTest   - compatibility alias for test-db; no existing database is dropped.' \
	  '' \
	  'Configuring makefile, for database conection:' \
	  '  Please edit the makefile and fill:' \
	  '    DBURL="postgres://usuario@host/banco"' \
	  '  or variables HOST, PORT, DBUSER, DBPASS e DBNAME' \
	  ''

see:
	@echo "layout=$(LAYOUT), schema=$(AUTHORIZED_SCHEMA), restrictive=$(RESTRICTIVE)"


assertDiff: test-db

core:
	$(PSQL_ENV) $(PYTHON) setup.py $(SETUP_OPTIONS) $(if $(DBURL),--dbname "$(DBURL)")

all: core

render:
	$(PYTHON) setup.py $(SETUP_OPTIONS) --render "$(OUTPUT_SQL)"

test:
	$(PYTHON) -m unittest discover -s tests -v

test-db:
	$(PSQL_ENV) GVLT_RUN_DB_TESTS=1 PSQL="$(PSQL)" $(PYTHON) -m unittest discover -s tests -v

manualExamples:
	@echo ">>> Executing user manual tutorial examples:"
ifeq ($(LAYOUT),single)
	$(PSQL_ENV) $(PYTHON) setup.py $(SETUP_OPTIONS) --tutorial $(if $(DBURL),--dbname "$(DBURL)")
else
	$(PSQL_CMD) -f ./assets/data/manual01-public_health_tutorial.sql
endif

usecaseExamples: manualExamples

dropDbTest: test-db

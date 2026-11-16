# ==============================
# CONFIGURACAO DE CONEXAO
# Defaults match the example: psql -U postgres br_grid.
# Override them on the command line, for example:
#   make all DBUSER=my_user DBNAME=my_database
# A full DBURL can be provided instead of separate connection parameters.
# ==============================
PSQL ?= psql
PYTHON ?= python3
PG_CONFIG ?= pg_config
EXTENSION_VERSION = $(shell $(PYTHON) setup.py --extension-version)
EXTENSION_NAME = $(if $(filter single,$(LAYOUT)),pg_govlite_single,pg_govlite)
MULTI_SQL = build/pg_govlite--$(EXTENSION_VERSION).sql
SINGLE_SQL = build/pg_govlite_single--$(EXTENSION_VERSION).sql
PG_SHAREDIR = $(shell "$(PG_CONFIG)" --sharedir)
EXTENSION_DIR = $(DESTDIR)$(PG_SHAREDIR)/extension
EXTENSION_FILES = $(wildcard extension/pg_govlite--*.sql extension/pg_govlite_single--*.sql)
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
DBUSER ?= postgres
DBPASS =
DBNAME =

PSQL_ENV = $(if $(strip $(DBURL)),,$(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='$(DBNAME)'))
PSQL_CMD = $(PSQL_ENV) $(PSQL) $(PSQL_FLAGS) $(DBURL)

.PHONY: help see assertDiff core all render test test-db manualExamples usecaseExamples dropDbTest extension install upgrade


help:
	@printf '%s\n' \
	  'Targets:' \
	  '  extension    - build the native extension SQL for both layouts.' \
	  '  install      - copy the extension files to the PostgreSQL server.' \
	  '  all/core     - activate the extension for the selected layout.' \
	  '  upgrade      - upgrade a native installation to this checkout version.' \
	  '  render       - generate reviewable SQL without connecting.' \
	  '  test         - offline installer tests.' \
	  '  test-db      - four-layout matrix in uniquely named disposable databases.' \
	  '  assertDiff   - legacy alias for test-db.' \
	  '  manualExamples - execute the SQL examples from the user manual tutorial.' \
	  '  usecaseExamples - execute approved simple use-case test cases.' \
		'  see          - show variables' \
		'  dropDbTest   - compatibility alias for test-db; no existing database is dropped.' \
	  '' \
	  'Default connection: DBUSER=postgres DBNAME=br_grid.' \
	  'Override in the make command, for example:' \
	  '  make all DBUSER=usuario DBNAME=banco' \
	  'Or configure DBURL="postgres://usuario@host/banco".' \
	  ''

see:
	@echo "layout=$(LAYOUT), schema=$(AUTHORIZED_SCHEMA), restrictive=$(RESTRICTIVE)"


assertDiff: test-db

core:
	$(PSQL_ENV) $(PYTHON) setup.py $(SETUP_OPTIONS) --extension $(if $(DBURL),--dbname "$(DBURL)")

all: core

extension:
	@test -n "$(EXTENSION_VERSION)"
	mkdir -p build
	$(PYTHON) setup.py --mode multi --extension-sql "$(MULTI_SQL)"
	$(PYTHON) setup.py --mode single --extension-sql "$(SINGLE_SQL)"

install: extension
	@test -n "$(PG_SHAREDIR)"
	install -d "$(EXTENSION_DIR)"
	install -m 644 pg_govlite.control pg_govlite_single.control "$(MULTI_SQL)" "$(SINGLE_SQL)" $(EXTENSION_FILES) "$(EXTENSION_DIR)"

upgrade:
	@test "$(LAYOUT)" = multi || test "$(LAYOUT)" = single
	@test -n "$(EXTENSION_VERSION)"
	$(PSQL_ENV) $(PSQL) -X -v ON_ERROR_STOP=1 $(if $(DBURL),--dbname "$(DBURL)") -c "ALTER EXTENSION $(EXTENSION_NAME) UPDATE TO '$(EXTENSION_VERSION)';"

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

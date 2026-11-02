# ==============================
# CONFIGURACAO DE CONEXAO
# Defaults match the example: psql -U postgres br_grid.
# Override them on the command line, for example:
#   make all DBUSER=my_user DBNAME=my_database
# A full DBURL can be provided instead of separate connection parameters.
# ==============================
PSQL ?= psql
PSQL_FLAGS ?= -v ON_ERROR_STOP=1
DBURL =
HOST =
PORT =
DBUSER ?= postgres
DBPASS =
DBNAME_WAS_OMITTED := $(if $(filter undefined,$(origin DBNAME)),yes,no)
DBNAME ?= br_grid
TRASHDB = dbtest_trash
TRASHDB_VERS = pg16-psql17
PSQL_DIFF_LINE_SED = s|^psql:([^:]+):[0-9]+:|psql:\1:<LINE>:|

PSQL_ENV = $(if $(strip $(DBURL)),,$(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='$(DBNAME)'))
PSQL_CMD = $(PSQL_ENV) $(PSQL) $(PSQL_FLAGS) $(DBURL)

# only for TRASHDB:
DBURL_prefix = postgres://postgres@localhost
PSQL_ENV2 = $(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='$(TRASHDB)')
PSQL_DB2 = $(if $(strip $(PSQL_ENV2)),"","$(DBURL_prefix)/$(TRASHDB)")
PSQL_CMD2 = $(PSQL_ENV2) $(PSQL) $(PSQL_DB2)
PSQL_CMD2_STOP = $(PSQL_ENV2) $(PSQL) $(PSQL_FLAGS) $(PSQL_DB2)

# conly for drop/create TRASHDB, using db=postgres:
PSQL_ENV3 = $(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='postgres')
PSQL_CMD3 = $(PSQL_ENV3) $(PSQL) $(PSQL_FLAGS) $(if $(strip $(PSQL_ENV3)),"","$(DBURL_prefix)/postgres")


CORE_SQL = \
	./src/inst01-fw_lib.sql \
	./src/inst02-fw_core.sql \
	./src/inst03-fw_govRules.sql \
	./src/inst04-documentation_examples.sql \
	./src/assert01-basic.sql

.PHONY: help see assertDiff core all manualExamples usecaseExamples dropDbTest


help:
	@printf '%s\n' \
	  'Targets:' \
	  '  all          - execute all, including asserts.' \
	  '  inst         - installations.' \
	  '  assertDiff   - execute only asserts by diff.' \
	  '  manualExamples - execute the SQL examples from the user manual tutorial.' \
	  '  usecaseExamples - execute approved simple use-case test cases.' \
		'  test_all     - execute all on the default test-database.' \
		'  see          - show variables' \
		'  dropDbTest   - run all on trash-test database' \
	  '' \
	  'Default connection: DBUSER=postgres DBNAME=br_grid.' \
	  'Override in the make command, for example:' \
	  '  make all DBUSER=usuario DBNAME=banco' \
	  'Or configure DBURL="postgres://usuario@host/banco".' \
	  ''

see:
	@echo "psql_env = $(PSQL_ENV)"
	@echo "psql_cmd = $(PSQL_CMD)"
	@echo "psql_env2 = $(PSQL_ENV2)"
	@echo "psql_cmd2 = $(PSQL_CMD2)"
	@echo "psql_env3 = $(PSQL_ENV3)"
	@echo "psql_cmd3 = $(PSQL_CMD3)"


assertDiff:
	@echo ">>> Executing psql-text-diff asserts:"
	$(PSQL_CMD) -f ./src/assert02-psqlDiff.sql > /tmp/pg_govLite-assert02.txt 2>&1
	sed -E '$(PSQL_DIFF_LINE_SED)' /tmp/pg_govLite-assert02.txt > /tmp/pg_govLite-assert02.normalized.txt
	sed -E '$(PSQL_DIFF_LINE_SED)' "./assets/assert02-res-psqlDiff.$(TRASHDB_VERS).txt" > /tmp/pg_govLite-assert02.expected.normalized.txt
	diff -w -b /tmp/pg_govLite-assert02.normalized.txt /tmp/pg_govLite-assert02.expected.normalized.txt

core:
	@if [ -n "$(DBURL)" ]; then \
	  echo "Connection configured by DBURL; the target database is the one in the URL."; \
	elif [ "$(DBNAME_WAS_OMITTED)" = "yes" ]; then \
	  echo "DBNAME not specified; using the default database '$(DBNAME)'."; \
	else \
	  echo "Using DBNAME='$(DBNAME)'."; \
	fi
	@set -e; for f in $(CORE_SQL); do \
	  echo ">>> Executando $$f"; \
	  if $(PSQL_CMD) -f "$$f"; then :; else \
	    status=$$?; \
	    if [ -n "$(DBURL)" ]; then \
	      echo "Failed to execute '$$f' using DBURL. Check the database name in the URL." >&2; \
	      echo "To select a database with DBNAME: make all DBURL= DBNAME=my_database" >&2; \
	    else \
	      echo "Failed to execute '$$f' connected to DBNAME='$(DBNAME)'." >&2; \
	      echo "Check that this database exists; to use another: make all DBNAME=my_database" >&2; \
	    fi; \
	    exit $$status; \
	  fi; \
	done

all: core assertDiff

manualExamples:
	@echo ">>> Executing user manual tutorial examples:"
	$(PSQL_CMD) -f ./assets/data/manual01-public_health_tutorial.sql

usecaseExamples: manualExamples

dropDbTest:
	$(PSQL_CMD3) -c "DROP DATABASE IF EXISTS $(TRASHDB);"
	$(PSQL_CMD3) -c "CREATE DATABASE $(TRASHDB);"
	@set -e; for f in $(CORE_SQL); do \
	  echo ">>> Executando $$f"; \
	  $(PSQL_CMD2_STOP) -f "$$f"; \
	done
	@echo ">>> Executing psql-text-diff asserts on fresh $(TRASHDB):"
	$(PSQL_CMD2) -f ./src/assert02-psqlDiff.sql > /tmp/trash.txt 2>&1
	sed -E '$(PSQL_DIFF_LINE_SED)' /tmp/trash.txt > /tmp/trash.normalized.txt
	sed -E '$(PSQL_DIFF_LINE_SED)' "./assets/assert02-res-psqlDiff.$(TRASHDB_VERS).txt" > /tmp/assert02-res-psqlDiff.normalized.txt
	diff -w -b /tmp/trash.normalized.txt /tmp/assert02-res-psqlDiff.normalized.txt
	@echo " ... if no diff, rm /tmp/trash.txt /tmp/trash.normalized.txt /tmp/assert02-res-psqlDiff.normalized.txt"
	@echo

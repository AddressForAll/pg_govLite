# ==============================
# CONFIGURACAO DE CONEXAO
# Edite os valores abaixo antes de executar.
# Se usar DBURL, os demais podem ficar em branco.
# ==============================
PSQL ?= psql
PSQL_FLAGS ?= -v ON_ERROR_STOP=1
DBURL =
HOST =
PORT =
DBUSER =
DBPASS =
DBNAME =

TRASHDB = dbtest_trash

PSQL_ENV = $(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='$(DBNAME)')
PSQL_CMD = $(PSQL_ENV) $(PSQL) $(PSQL_FLAGS) $(DBURL)

# only for TRASHDB:
DBURL_prefix = postgres://postgres@localhost
PSQL_ENV2 = $(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='$(TRASHDB)')
PSQL_CMD2 = $(PSQL_ENV2) $(PSQL) $(if $(strip $(PSQL_ENV2)),"","$(DBURL_prefix)/$(TRASHDB)")

# conly for drop/create TRASHDB, using db=postgres:
PSQL_ENV3 = $(if $(HOST),PGHOST='$(HOST)') $(if $(PORT),PGPORT='$(PORT)') $(if $(DBUSER),PGUSER='$(DBUSER)') $(if $(DBPASS),PGPASSWORD='$(DBPASS)') $(if $(DBNAME),PGDATABASE='postgres')
PSQL_CMD3 = $(PSQL_ENV3) $(PSQL) $(PSQL_FLAGS) $(if $(strip $(PSQL_ENV3)),"","$(DBURL_prefix)/postgres")


CORE_SQL = \
	./src/inst01-fw_lib.sql \
	./src/inst02-fw_core.sql \
	./src/inst03-fw_govRules.sql \
	./src/assert01-basic.sql


help:
	@printf '%s\n' \
	  'Targets:' \
	  '  all          - execute all, including asserts.' \
	  '  inst         - installations.' \
	  '  assertDiff   - execute only asserts by diff.' \
		'  test_all     - execute all on the default test-database.' \
		'  see          - show variables' \
		'  dropDbTest   - run all on trash-test database' \
	  '' \
	  'Configuring makefile, for database conection:' \
	  '  Please edit the makefile and fill:' \
	  '    DBURL="postgres://usuario@host/banco"' \
	  '  or variables HOST, PORT, DBUSER, DBPASS e DBNAME' \
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
	$(PSQL_CMD) -f "./src/assert02-psqlDiff.sql | diff - ./src/assert02-res-psqlDiff.txt";

core:
	@for f in $(CORE_SQL); do \
	  echo ">>> Executando $$f"; \
	  $(PSQL_CMD) -f "$$f"; \
	done

all: core assertDiff

dropDbTest:
	$(PSQL_CMD3) -c "DROP DATABASE IF EXISTS $(TRASHDB);"
	$(PSQL_CMD3) -c "CREATE DATABASE $(TRASHDB);"
	@for f in $(CORE_SQL); do \
	  echo ">>> Executando $$f"; \
	  $(PSQL_CMD2) -f "$$f"; \
	done
	@echo ">>> Executing psql-text-diff asserts on fresh $(TRASHDB):"
	$(PSQL_CMD2) -f ./src/assert02-psqlDiff.sql > /tmp/trash.txt 2>&1
	diff -w -b /tmp/trash.txt  ./assets/assert02-res-psqlDiff.txt

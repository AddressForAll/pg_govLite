**pg_govLite** is designed to perform basic data governance tasks in metadata management, complementing [System Catalogs](https://www.postgresql.org/docs/current/catalogs.html) and acting as a unified metadata store. It manages the Medallion architecture and *tags* for all data objects (columns, tables, schemas, functions, etc.), with [RDF](https://en.wikipedia.org/wiki/Resource_Description_Framework) semantic tags, and [governed tags](https://docs.databricks.com/aws/en/admin/governed-tags/).

![](assets/layers.png)

## Objectives
Adopt [Convention over Configuration](https://en.wikipedia.org/wiki/Convention_over_configuration) (CoC) principle for the basic metadata definition and maintenance tasks:

* Semantic tags and control tags;
* Medallion control of data objects (datasets and its part-whole hierarchy), like input/output and intermediary datasets;
* Data tier controls the identity-service and activation of data-quality services. See also "relevance driver" (business, regulatory, analytics, or operational)
* To generate human-readable structures System Catalog as standard structured content, for documentation.

All modules are external implementations, for example data quality is DQX, Secure control is external ABAC, etc. The pg_govLite is a central orchestration of modules by tags and triggers.

## Documentation
See and, please, contribute commenting or correcting:
* USER GUIDE - https://docs.google.com/document/d/1G7tC9tuRwqmwxtxUhElkZtnoM5JYWC_f2s2pLXkhXKs/
* TUTORIAL - ...

Below a fast presentation. UML class:

![](assets/pg_govLite-diag1v1.png)

Documentation helper scripts are also included in `src`:

* `src/doc01-UDF-mediawiki.sql` generates MediaWiki documentation for PostgreSQL UDFs, including summary rows, page sections, full pages, and XML dumps. Usage examples are available in `src/doc01-UDF-mediawiki.md`.
* `src/inst04-documentation_examples.sql` installs executable documentation examples as views in `gvlt_doc_examples`, exposes function-example dependencies, and supports secondary example marking. Usage examples are available in `src/inst04-documentation_examples.md`.

### Use cases and test cases

Curated tutorial-derived use cases are documented in `assets/usecases`.

* `assets/usecases/README.md` defines the use-case/test-case pattern.
* `assets/usecases/SpCs01-public-health.md` documents the executable simple tutorial case.
* `assets/usecases/CxCs01-municipal-climate.md` documents the complex municipal climate case and its external dependencies.

Use cases should use the short governance API:

* `gvlt.tag_include(...)` creates or updates governed tags.
* `gvlt.tagobj_include(...)` associates governed tags with schemas, relations, and columns.
* `gvlt.tag_disable(...)` and `gvlt.tagobj_disable(...)` deactivate tags and object/tag associations without deleting catalog history.
* `gvlt.obj_tags(...)`, `gvlt.obj_has_tags(...)`, and `gvlt.usecase_assert_obj_tags(...)` support inspection and executable checks.
* `gvlt.tag_get(...)`, `gvlt.tag_search(...)`, `gvlt.relation_columns(...)`, `gvlt.medallion_objects(...)`, and `gvlt.governance_check(...)` provide catalog discovery and audit helpers.

The lower-level `gvlt.govtags_*` functions remain the internal implementation surface and are still covered by core asserts.

### User manual and executable tutorial

The user manual is available as a Word document:

* `manual/pg_govLite_User_Manual_and_Practical_Governance_Tutorial.docx`

The manual explains the project resources and includes a practical governance tutorial using a public-data scenario inspired by IBGE municipality data and ANS supplementary-health data.

The executable SQL version of the tutorial is:

* `assets/data/manual01-public_health_tutorial.sql`

It creates a deterministic local sample, so it does not download external data. The script creates the tutorial schemas and tables, applies governed tags, publishes a Gold view, registers an executable documentation example, and runs final checks with `RAISE EXCEPTION` if an expected result is missing.

## Install or test

New installations support **multiple schemas** (default) or a **single authorized schema**, with optional restrictive governance for Silver and Gold. See [installation, permissions and policy operations](docs/INSTALLATION.md).

Setup requires Python 3.9+, psql, PostgreSQL 15+ and DBA privileges for event triggers. It installs in one transaction, preserves unrelated objects and refuses framework collisions/reinstallation. The installation SQL files are templates rendered by setup; do not run them directly through psql.

### Terminal quick start

The commands below use a Linux/macOS shell, Git, Python 3 and `psql`; the Makefile option also requires GNU Make. Run them in the terminal, outside the `psql` prompt. On Windows, use `python` instead of `python3` and PowerShell environment assignments such as `$env:PGDATABASE = 'my_database'` instead of `export PGDATABASE=my_database`.

1. Download the project and enter its directory:

   ```sh
   git clone https://github.com/AddressForAll/pg_govLite.git
   cd pg_govLite
   ```

2. Select an existing destination database and a PostgreSQL DBA login. Replace the example values with your connection settings:

   ```sh
   export PGHOST=localhost
   export PGPORT=5432
   export PGUSER=postgres
   export PGDATABASE=my_database
   psql -X -c '\conninfo'
   psql -X -c '\dn'
   ```

   The installer does not create the database. Use `.pgpass` or your existing credential mechanism if authentication requires a password. For a local Unix socket connection, omit `PGHOST` (or run `unset PGHOST` if it is already set).

3. Choose **one** installation method for this database.

   **Interactive setup:**

   ```sh
   python3 setup.py
   ```

   Enter `multi` for multiple schemas or `single` for one existing authorized schema. For example, answer `single`, then `public`, then `NAO` to install in `public` with restrictive governance disabled. With `multi`, there is no schema question. Answering `SIM` to restrictive governance also requires an existing master login; see [requirements and permissions](docs/INSTALLATION.md) first.

   **Makefile:** select one of these equivalent non-interactive commands:

   ```sh
   # Multiple schemas, restrictive governance disabled:
   make core LAYOUT=multi RESTRICTIVE=NAO

   # Single existing schema, restrictive governance disabled:
   make core LAYOUT=single AUTHORIZED_SCHEMA=public RESTRICTIVE=NAO
   ```

   **Direct non-interactive setup**, if you do not use Make:

   ```sh
   python3 setup.py --non-interactive --mode single --schema public --restrictive NAO
   ```

   All methods use the same installer and connection settings. A successful installation reports `BASIC ASSERTS FINISHED` and ends with `COMMIT`. Do not run another installation method against the same installed database: reinstallation, upgrades and layout migration are refused.

4. Verify the installed framework using the same DBA connection. For `single` in `public`:

   ```sh
   psql -X -v ON_ERROR_STOP=1 -c 'SELECT * FROM public.gvlt_governance_check();'
   psql -X -v ON_ERROR_STOP=1 -c 'SELECT * FROM public.gvlt_policy_check();'
   psql -X -c '\dt public.gvlt_*'
   ```

   Replace `public` if you selected another authorized schema. For `multi`:

   ```sh
   psql -X -v ON_ERROR_STOP=1 -c 'SELECT * FROM gvlt.governance_check();'
   psql -X -v ON_ERROR_STOP=1 -c 'SELECT * FROM gvlt.policy_check();'
   psql -X -c '\dt gvlt.*'
   ```

   Both check functions should return zero rows when no issues are found. The last command lists the framework tables.

### Additional Makefile commands

* `make` shows options; `make core` and `make all` install a fresh core and run basic assertions.
* `make core LAYOUT=single AUTHORIZED_SCHEMA=cliente RESTRICTIVE=SIM MASTER_ROLE=carga_master` selects the single layout.
* `make render` generates reviewable SQL without connecting.
* `make manualExamples` runs the multi-schema manual tutorial; add `LAYOUT=single AUTHORIZED_SCHEMA=cliente` for the single-schema tutorial.
* `make usecaseExamples` aliases the selected tutorial.
* `make test` runs offline installer checks; `make test-db` runs the integration matrix against a disposable PostgreSQL instance. The suite creates and removes only its uniquely named databases and roles.
* `make dropDbTest` and `make assertDiff` are compatibility aliases for `make test-db`; they no longer drop a preexisting fixed test database or compare version-specific demonstration output.

Existing databases are not migrated. pgAdmin/PostgREST adjustments are deferred to a separate delivery.

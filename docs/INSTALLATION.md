# Installation layouts and restrictive governance

This delivery changes the pg_govLite core installer only. pgAdmin and PostgREST integration and deployment are a separate stage. No client service is started or reconfigured.

## Requirements

- Python 3.9+ and `psql` on PATH; no Python packages are required.
- PostgreSQL 15+ (integration verified on PostgreSQL 17.2).
- A DBA/superuser connection for installation and policy administration. PostgreSQL event triggers are database-wide administrative objects.
- A new framework installation. Existing business objects may coexist in the destination; existing framework names cause installation to fail. Upgrades and layout migration are not supported.
- For `single`, an existing authorized schema, using a lowercase identifier of at most 63 bytes. The installer does not create auxiliary schemas in this mode.
- For restrictive governance, an existing operational LOGIN for the master, without superuser, CREATEROLE, CREATEDB, REPLICATION or BYPASSRLS attributes. Operational roles must not be able to assume the master or object owners.

Use libpq variables (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`) and `.pgpass` or your existing credential mechanism. No password is stored in framework configuration or generated SQL. `--dbname` also accepts a psql connection string.

## Install

Interactive setup:

```sh
sh setup.sh
# Or, including on Windows:
python setup.py
```

The installer asks for `multi`/`single`, the authorized schema for `single`, restrictive governance, and the master role when enabled. Affirmative answers are SIM/S/Y and negative answers are NÃO/NAO/N, case-insensitive and trimmed. Empty or invalid answers prompt again.

Equivalent automation:

```sh
python setup.py --non-interactive --mode multi --restrictive NAO
python setup.py --non-interactive --mode single --schema cliente --restrictive SIM --master carga_master
```

Generate reviewable SQL without connecting:

```sh
python setup.py --non-interactive --mode single --schema cliente --restrictive SIM --master carga_master --render installation.rendered.sql
psql -X -v ON_ERROR_STOP=1 -f installation.rendered.sql
```

Rendering validates the input and name lengths; database existence, permissions and collisions are checked when SQL is executed. Setup takes a transaction-level installation lock, checks collisions, installs the core, runs basic assertions and commits everything together. Any error rolls back the installation. Re-running setup does not update, overwrite or convert an installed framework. There is no `DROP SCHEMA ... CASCADE` in the installation path.

The `src/inst01` through `inst04` files and `assert01-basic.sql` are now explicit templates; use setup instead of passing those files directly to psql. `make core` and `make all` call the same installer, defaulting to `multi` with restrictive governance disabled:

```sh
make core LAYOUT=single AUTHORIZED_SCHEMA=cliente RESTRICTIVE=SIM MASTER_ROLE=carga_master
make render LAYOUT=single AUTHORIZED_SCHEMA=cliente
```

## Physical names

| Group | Multiple layout | Single layout |
|---|---|---|
| Library | `lib.object_getype` | `cliente.lib_object_getype` |
| Former public helpers | `public.array_distinct` | `cliente.lib_array_distinct` |
| Governance | `gvlt.tag` | `cliente.gvlt_tag` |
| Executable examples | `gvlt_doc_examples.ex1` | `cliente.doc_ex1` |
| API convention, reserved for the next stage | `api.vw01_tag` | `cliente.api_vw01_tag` |
| Bronze | `brz.municipios` | `cliente.brz_municipios` |
| Silver | `slv.municipios` | `cliente.slv_municipios` |
| Gold | `gld.municipios` | `cliente.gld_municipios` |

The installer persists seven dictionary entries (`lib`, `gvlt`, `doc`, `api`, `brz`, `slv`, `gld`). This dictionary is installation metadata, not an invitation to rename an installed framework by editing rows. Schema and object names are quoted; reserved prefixes include `_` and match only at the beginning. Base names keep their underscores.

```sql
SELECT cliente.gvlt_object_name('slv','municipios_historico');
-- cliente.slv_municipios_historico
SELECT * FROM cliente.gvlt_object_name_parse('slv_municipios_historico');
-- slv | slv_ | municipios_historico
```

Multiple layout retains legacy schema conventions such as `geo_silver` in addition to the explicit `brz`/`slv`/`gld` schemas. It does not rename the existing documentation schema to `doc`. Single layout tracks Medallion relations instead of creating schemas through `medallion_upsert`; that legacy operation raises an explanatory error.

## Permissions and ownership

The installer does not create roles or grant new readers access to business data. Existing SELECT privileges, including approved group grants, remain in place. The master receives INSERT, UPDATE, DELETE and TRUNCATE and required schema/sequence USAGE. **Read authorization remains a DBA decision, including SELECT needed by the master's predicates, expressions or RETURNING clauses.** Configure approved SELECT grants/default privileges for the master and readers separately. Existing row-level security policies are preserved.

New framework metadata tables, sequences and functions have non-owner access removed, including privileges inherited from the installer's default ACLs. Administrators can grant access to specific inspection routines and required metadata after review. Do not grant operational accounts access to policy internals, metadata writes, SQL execution helpers, ownership or elevated role membership.

Protected tables must be owned by the installation DBA or another superuser without operational owner-role memberships. The installer refuses to take over operational-owned tables: the DBA must review and transfer their ownership explicitly. Keep the shared schema under administrative ownership as well.

Restriction removes non-master writes at both table and column level, including PUBLIC and group ACLs. Guards also verify the real login/SET ROLE identity, so ordinary users cannot bypass the policy through writable views or SECURITY DEFINER routines that write to protected tables. Guards are enabled ALWAYS and cover direct partition access and TRUNCATE. Administrative authority remains with superusers; denied-attempt logging requires PostgreSQL logging configuration.

Creation and structural changes to protected objects are administrative operations. Bronze remains available under its prior permissions. In the single schema, an operational account with CREATE may create Bronze objects, but creation/renaming into protected prefixes is rejected. No general privileged SQL executor is exposed. If protection cannot be applied, the DDL/classification transaction fails.

## Policy operations

Examples below use `single`/`cliente`; use `gvlt.<function>` and unprefixed metadata names in `multi`.

```sql
-- Activate or atomically change the master:
SELECT cliente.gvlt_policy_set(true,'carga_master');
SELECT cliente.gvlt_policy_set(true,'novo_master');

-- Refresh catalog and reconcile permissions, safe to repeat:
SELECT cliente.gvlt_relation_sync();
SELECT cliente.gvlt_policy_apply();
SELECT * FROM cliente.gvlt_policy_check();
SELECT * FROM cliente.gvlt_governance_check();

-- Administrative relation assignment:
SELECT cliente.gvlt_relation_classify('cliente.slv_municipios'::regclass,'Silver');
```

Event triggers classify existing and future tables, views, materialized views, foreign tables and partitions by schema/prefix and catalog association. Protected parents also protect their partitions. Layer assignment through the tag API is applied in the same transaction; conflicting names/classifications are rejected.

Protection follows relation OIDs, and column tags follow attribute numbers. Renames preserve old associations as inactive history. Renaming a protected relation to an unrelated or Bronze name does not release it. Rename/move to a compatible location, then use `relation_classify` explicitly to approve its departure. Single-layout governed relations cannot be moved outside the authorized schema. Structural privileges are not granted to the master.

Policy changes, classification changes and grants/revokes are recorded in `gvlt_policy_audit`. Original table and column ACLs are retained in `gvlt_permission_history`; policy-added grants are tracked in `gvlt_policy_grants`. Master changes remove the previous master's protected-table writes and revoke schema/sequence privileges added by the policy, preserving preexisting dependencies.

```sql
SELECT cliente.gvlt_policy_set(false);
SELECT * FROM cliente.gvlt_permission_history WHERE reviewed_at IS NULL ORDER BY id;
SELECT * FROM cliente.gvlt_policy_grants;
```

Disabling leaves current ACLs in place; it does not restore old writes automatically. Review history against current objects, role memberships and later grants, apply approved GRANT/REVOKE commands explicitly, then record the decision:

```sql
SELECT cliente.gvlt_permission_review(1,'Reviewed against current ACLs; approved grants applied separately');
```

This records the review; it does not execute grants from historical text. Audits and ACL changes participate in the same transaction as the administrative operation.

## Examples and verification

```sh
# Single-schema tutorial; use an installed core and run once as DBA:
python setup.py --non-interactive --mode single --schema cliente --restrictive NAO --tutorial
make manualExamples LAYOUT=single AUTHORIZED_SCHEMA=cliente

# Offline validation:
python -m unittest discover -s tests -v

# Disposable PostgreSQL instance, DBA credentials supplied with PG* variables:
GVLT_RUN_DB_TESTS=1 python -m unittest discover -s tests -v
make test-db
```

The integration suite creates uniquely named test databases and roles, exercises the four layout/policy combinations, and removes only its own test objects. It includes existing basic asserts, the executable legacy regression assertions, the multi-schema manual tutorial, the single-schema tutorial, default ACL isolation, indirect writes, future tables, partitions, history, master changes, disabling and failed-install rollback. `make assertDiff` and `make dropDbTest` now alias this suite rather than dropping a fixed preexisting database or comparing version-specific demonstration output. The legacy output/demo SQL remains available as a reference.

The API prefix is reserved in metadata; API views and integration configuration are not installed in this stage. Existing optional legacy exporters/monitoring scripts are not executed by setup. No pgAdmin files are changed.

PostgreSQL references: [event trigger behavior](https://www.postgresql.org/docs/17/event-trigger-definition.html), [privileges](https://www.postgresql.org/docs/17/sql-grant.html).

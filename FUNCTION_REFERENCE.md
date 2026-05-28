# Function Reference Guide

This guide documents the SQL/PLpgSQL functions found in the `pg_govLite` project.
It is formatted for GitHub and organized by source file.

Notes:

- The examples assume PostgreSQL after the installation scripts have been executed.
- The `public` schema is omitted for global functions, such as `array_distinct(...)`.
- Trigger functions return `event_trigger` and are normally called by PostgreSQL, not directly with `SELECT`.
- `assert02-psqlDiff.sql` creates functions only in the test/diff flow; they are documented in a separate section.

## Summary

- [`src/inst01-fw_lib.sql`](#srcinst01-fw_libsql)
- [`src/inst02-fw_core.sql`](#srcinst02-fw_coresql)
- [`src/inst03-fw_govRules.sql`](#srcinst03-fw_govrulessql)
- [`src/inst04-documentation_examples.sql`](#srcinst04-documentation_examplessql)
- [`src/doc01-UDF-mediawiki.sql`](#srcdoc01-udf-mediawikipsql)
- [`src/assert02-psqlDiff.sql`](#srcassert02-psqldiffsql)
- [Commented Drafts](#commented-drafts)

## `src/inst01-fw_lib.sql`

Global utility functions and helper functions in the `lib` schema.

### `round(float, int) RETURNS numeric`

Casts the first `float` argument to `numeric` and then uses PostgreSQL's native `round(numeric, int)`. This is useful because PostgreSQL does not provide decimal-place rounding directly for `double precision`.

```sql
SELECT round(pi(), 3);
```

Expected result:

```text
3.142
```

### `array_distinct(anyarray, p_no_null boolean DEFAULT true) RETURNS anyarray`

Removes duplicate items from an array. By default it also removes `NULL` values. The result order depends on `SELECT DISTINCT`, so use `array_distinct_sort(...)` when deterministic ordering matters.

```sql
SELECT array_distinct('{10,1,1,20,10,NULL,10}'::int[]);
```

Expected result:

```text
{10,1,20}
```

Keeping one `NULL`:

```sql
SELECT array_distinct('{10,1,1,20,10,NULL,10}'::int[], false);
```

Expected result:

```text
{NULL,10,1,20}
```

### `array_distinct_sort(anyarray, p_no_null boolean DEFAULT true) RETURNS anyarray`

Removes duplicates and sorts the array values. By default it removes `NULL`; with `false`, it preserves one `NULL`.

```sql
SELECT array_distinct_sort('{10,1,20,2,3,NULL,10,500,5}'::int[]);
```

Expected result:

```text
{1,2,3,5,10,20,500}
```

### `jsonb_object_keys_asarray(jsonb) RETURNS text[]`

Converts the keys of a JSONB object into a text array.

```sql
SELECT jsonb_object_keys_asarray('{"x":1,"Y":2,"z":3}'::jsonb);
```

Expected result:

```text
{Y,x,z}
```

### `jsonb_array_to_text_array(jsonb, apply_sort boolean DEFAULT false) RETURNS text[]`

Converts a JSONB array into `text[]`. When `apply_sort` is `true`, it applies `array_distinct_sort(...)`, removing duplicates, sorting the values, and removing `NULL`.

```sql
SELECT jsonb_array_to_text_array('["b","a","b",null]'::jsonb);
```

Expected result:

```text
{b,a,b,NULL}
```

With sorting and deduplication:

```sql
SELECT jsonb_array_to_text_array('["b","a","b",null]'::jsonb, true);
```

Expected result:

```text
{a,b}
```

### `lib.dynamic_query(text) RETURNS SETOF record`

Dynamically executes a SQL query that returns rows. Because it returns `record`, the caller must declare the expected output structure.

```sql
SELECT *
FROM lib.dynamic_query('SELECT 42::int AS x') AS t(x int);
```

Expected result:

```text
x
--
42
```

### `lib.dynamic_execute(text) RETURNS boolean`

Dynamically executes a SQL command that does not need to return rows, such as `CREATE TABLE`, `DROP`, `COMMENT`, or `INSERT`. It emits a `NOTICE` with the beginning of the command and returns `true` when the command runs successfully.

```sql
SELECT lib.dynamic_execute('CREATE TEMP TABLE demo_dynamic_execute(x int)');
```

Expected result:

```text
t
```

### `lib.rel_disk_usage(text[]) RETURNS TABLE(schema_name text, relname text, size text, size_bytes bigint)`

Lists relation disk usage by schema. If the parameter is `NULL`, it considers all schemas; if it is an array, it filters by the provided schemas.

```sql
SELECT schema_name, relname, size_bytes
FROM lib.rel_disk_usage(ARRAY['pg_catalog'])
LIMIT 1;
```

Expected result:

```text
schema_name | relname       | size_bytes
------------+---------------+-----------
pg_catalog  | ...           | ...
```

### `lib.pgddl_objtype_to_relkind(text) RETURNS "char"`

Converts values from `pg_event_trigger_ddl_commands().object_type` into `pg_class.relkind` codes.

```sql
SELECT lib.pgddl_objtype_to_relkind('materialized view');
```

Expected result:

```text
m
```

### `lib.pgddl_relkind_to_objtype("char") RETURNS text`

Performs the inverse conversion: from `pg_class.relkind` to the object type text used in DDL events.

```sql
SELECT lib.pgddl_relkind_to_objtype('r'::"char");
```

Expected result:

```text
table
```

### `lib.object_getype(text) RETURNS "char"`

Classifies the shape of a governed object name based on the number of dot-separated parts:

- `s`: schema, such as `schema_name`
- `r`: relation, such as `schema_name.table_name`
- `c`: column, such as `schema_name.table_name.column_name`
- `NULL`: unsupported shape

```sql
SELECT lib.object_getype('schema_name.table_name.column_name');
```

Expected result:

```text
c
```

## `src/inst02-fw_core.sql`

Core functions in the `gvlt` schema, used for tag validation, governed naming, and object-tag associations.

### `gvlt.rdf_prefix_valid(text) RETURNS boolean`

Checks whether an RDF identifier uses an accepted prefix. In the current implementation, the accepted regex prefixes are `sh:`, `wd:`, and `dcat:`.

```sql
SELECT gvlt.rdf_prefix_valid('wd:Q42');
```

Expected result:

```text
t
```

Unsupported prefix:

```sql
SELECT gvlt.rdf_prefix_valid('schema:Person');
```

Expected result:

```text
f
```

### `gvlt.govtags_fail(text[]) RETURNS text[]`

Receives a list of tags and returns the tags that do not exist in `gvlt.tag`, after applying `lower(trim(...))`. Returns `NULL` when all tags exist.

```sql
SELECT gvlt.govtags_fail(ARRAY['CPF', ' cnpj ', 'no_such_tag']);
```

Expected result:

```text
{no_such_tag}
```

### `gvlt.govtags_exists(text) RETURNS boolean`

Checks whether a single tag exists as a governed tag.

```sql
SELECT gvlt.govtags_exists('CPF');
```

Expected result:

```text
t
```

### `gvlt.govtags_exists(text[]) RETURNS boolean`

Checks whether all tags in an array exist as governed tags.

```sql
SELECT gvlt.govtags_exists(ARRAY['CPF', 'CNPJ', 'vatID']);
```

Expected result:

```text
t
```

With one missing tag:

```sql
SELECT gvlt.govtags_exists(ARRAY['CPF', 'no_such_tag']);
```

Expected result:

```text
f
```

### `gvlt.govtags_normalize(text[]) RETURNS text[]`

Normalizes a list of tags to the canonical name registered in `gvlt.tag`. It removes duplicates, ignores unknown tags, and sorts by `lower(tag_name)`.

```sql
SELECT gvlt.govtags_normalize(ARRAY['cpF', 'cnpj', 'xpto', 'vatid', 'CPF']);
```

Expected result:

```text
{CNPJ,CPF,vatID}
```

### `gvlt.govtags_normalize(jsonb) RETURNS text[]`

JSONB-array version. It converts the JSONB array to `text[]` and calls `gvlt.govtags_normalize(text[])`.

```sql
SELECT gvlt.govtags_normalize('["cpF","cnpj","xpto","vatid","CPF"]'::jsonb);
```

Expected result:

```text
{CNPJ,CPF,vatID}
```

### `gvlt.govtag_list_include(text[], text) RETURNS text[]`

Adds one tag to an existing list and normalizes the result. Unknown tags are discarded by normalization.

```sql
SELECT gvlt.govtag_list_include(ARRAY['CPF'], 'cnpj');
```

Expected result:

```text
{CNPJ,CPF}
```

### `gvlt.govtag_list_include(text[], text[]) RETURNS text[]`

Adds multiple tags to an existing list and normalizes the result.

```sql
SELECT gvlt.govtag_list_include(ARRAY['CPF'], ARRAY['cnpj', 'vatid']);
```

Expected result:

```text
{CNPJ,CPF,vatID}
```

### `gvlt.govtag_list_exclude(text[], text) RETURNS text[]`

Removes one exact tag from the array using `array_remove`. This overload does not normalize casing or canonical names; the value must exactly match the existing item.

```sql
SELECT gvlt.govtag_list_exclude(ARRAY['CPF', 'CNPJ', 'vatID'], 'CNPJ');
```

Expected result:

```text
{CPF,vatID}
```

### `gvlt.govtag_list_exclude(text[], text[]) RETURNS text[]`

Removes multiple tags from an array and normalizes the result.

```sql
SELECT gvlt.govtag_list_exclude(ARRAY['CPF', 'CNPJ', 'vatID'], ARRAY['CNPJ', 'vatID']);
```

Expected result:

```text
{CPF}
```

### `gvlt.schema_name_validate(text) RETURNS text`

Validates whether a schema name follows the Medallion architecture naming convention. The last name segment must be a Medallion tag (`Bronze`, `Silver`, or `Gold`), and the previous segments must be governed tags or one-letter acronyms.

Return values:

- Valid Medallion name: returns the canonical Medallion tag, such as `Bronze`.
- Name that does not look like a Medallion schema: returns `NULL`.
- Medallion candidate with a missing tag: returns `!`.

```sql
SELECT gvlt.schema_name_validate('geo_gold');
```

Expected result:

```text
Gold
```

```sql
SELECT gvlt.schema_name_validate('schema_comum');
```

Expected result:

```text
NULL
```

```sql
SELECT gvlt.schema_name_validate('semtag_bronze');
```

Expected result:

```text
!
```

### `gvlt.schema_name_nontag(text) RETURNS text[]`

Returns the schema-name segments that do not match governed tags.

```sql
SELECT gvlt.schema_name_nontag('semtag_bronze');
```

Expected result:

```text
{semtag}
```

### `gvlt.rel_getname(text, text DEFAULT NULL) RETURNS text`

Returns a qualified relation name. If `p_relname` already contains a dot, the value is preserved. If no schema is provided and `p_schemaname` is `NULL`, it uses `public`.

```sql
SELECT gvlt.rel_getname('my_table');
```

Expected result:

```text
public.my_table
```

```sql
SELECT gvlt.rel_getname('my_table', 'my_schema');
```

Expected result:

```text
my_schema.my_table
```

### `gvlt.rel_description(text, text DEFAULT NULL) RETURNS text`

Returns the comment of a table, view, or materialized view using `obj_description(..., 'pg_class')`. Internally it calls `gvlt.rel_getname(...)`.

```sql
CREATE TABLE public.assert02_rel_desc(x int);
COMMENT ON TABLE public.assert02_rel_desc IS 'assert02 relation description';

SELECT gvlt.rel_description('assert02_rel_desc');
```

Expected result:

```text
assert02 relation description
```

### `gvlt.govtags_is_include(text, text[]) RETURNS boolean`

Associates governed tags with an object cataloged in `gvlt.tag_obj`. The object must use a shape accepted by `lib.object_getype(...)`: `schema`, `schema.relation`, or `schema.relation.column`. The function normalizes the tags, inserts the associations, and reactivates existing associations.

```sql
SELECT gvlt.govtags_is_include('assert02_obj.relation', ARRAY['cpf', 'cnpj']);
```

Expected result:

```text
t
```

Expected catalog effect:

```sql
SELECT obj_name, tag_name, is_active
FROM gvlt.tag_obj
WHERE obj_name = 'assert02_obj.relation'
ORDER BY tag_name;
```

Expected result:

```text
obj_name              | tag_name | is_active
----------------------+----------+----------
assert02_obj.relation | CNPJ     | t
assert02_obj.relation | CPF      | t
```

## `src/inst03-fw_govRules.sql`

Governance-rule functions and DDL event triggers for Medallion schemas.

### `gvlt.medallion_upsert(text, jsonb DEFAULT NULL) RETURNS text`

Creates or updates the catalog record for a Medallion schema. The function:

- normalizes the name with `lower(trim(...))`;
- validates the name with `gvlt.schema_name_validate(...)`;
- creates the physical schema if it does not exist yet;
- inserts or reactivates the Medallion tag in `gvlt.tag_obj`;
- preserves the existing `ctrl_config` when the new `p_info` is `NULL`.

```sql
SELECT gvlt.medallion_upsert('t_bronze', '{"case":"manual"}'::jsonb);
```

Expected result:

```text
SUCESSO: Schema t_bronze (tipo Bronze) atualizado no catalogo.
```

With a non-Medallion name:

```sql
SELECT gvlt.medallion_upsert('assert02_plain_schema');
```

Expected result:

```text
ERRO: O nome do schema assert02_plain_schema nao segue o padrao medalhao (bronze/silver/gold).
```

### `gvlt.trig_medallion_upsert_event() RETURNS event_trigger`

Event trigger executed on `CREATE SCHEMA` by the `et_medallion_insert` event trigger. It validates newly created schemas and automatically registers the Medallion tag when the name follows the convention.

Indirect usage:

```sql
CREATE SCHEMA q_bronze;
```

Expected result:

```text
NOTICE: pg_govLite: Schema q_bronze registrado como Bronze!
```

Expected effect:

```sql
SELECT tag_name, obj_name, is_active
FROM gvlt.tag_obj
WHERE obj_name = 'q_bronze';
```

Expected result:

```text
tag_name | obj_name | is_active
---------+----------+----------
Bronze   | q_bronze | t
```

### `gvlt.trig_medallion_disable_event() RETURNS event_trigger`

Event trigger executed on `DROP SCHEMA` by the `et_medallion_drop` event trigger. It marks tag associations for a removed schema as inactive.

Indirect usage:

```sql
DROP SCHEMA q_bronze;
```

Expected result:

```text
NOTICE: pg_govLite: medallion schema q_bronze flagged as non-active
```

Expected effect:

```sql
SELECT tag_name, obj_name, is_active
FROM gvlt.tag_obj
WHERE obj_name = 'q_bronze';
```

Expected result:

```text
tag_name | obj_name | is_active
---------+----------+----------
Bronze   | q_bronze | f
```

## `src/inst04-documentation_examples.sql`

Functions for turning documentation examples into executable views in the `gvlt_doc_examples` schema.

### `gvlt.doc_examples_payload(text) RETURNS text`

Normalizes an expression or query into a `SELECT` payload used to create example views.

Main rules:

- empty input becomes `NULL`;
- a simple expression becomes `SELECT <expr> AS x`;
- simple `SELECT <expr>` without an alias becomes `SELECT <expr> AS x`;
- `SELECT <expr> AS alias` preserves the alias;
- full queries with `FROM`, `WHERE`, `ORDER BY`, etc. are preserved as `SELECT` queries.

```sql
SELECT gvlt.doc_examples_payload('round(pi(),3)');
```

Expected result:

```text
SELECT round(pi(),3) AS x
```

```sql
SELECT gvlt.doc_examples_payload('SELECT round(pi(),3)');
```

Expected result:

```text
SELECT round(pi(),3) AS x
```

### `gvlt.doc_examples_add(text) RETURNS text`

Creates a `gvlt_doc_examples.ex<ID>` view for a documentation example. The function normalizes the payload, avoids duplicates through an MD5 hash of normalized SQL, stores metadata in `gvlt.doc_examples`, and returns either the created SQL or an `EXISTS` message.

```sql
SELECT gvlt.doc_examples_add('round(pi(),3)');
```

Expected result:

```text
CREATE VIEW gvlt_doc_examples.ex1 AS SELECT round(pi(),3) AS x
```

Running the generated view:

```sql
SELECT * FROM gvlt_doc_examples.ex1;
```

Expected result:

```text
x
-----
3.142
```

### `gvlt.add_example(text) RETURNS text`

Compatibility alias for `gvlt.doc_examples_add(text)`.

```sql
SELECT gvlt.add_example('SELECT round(pi(),3)');
```

Expected result when the example already exists:

```text
EXISTS gvlt_doc_examples.ex1 AS SELECT round(pi(),3) AS x
```

### `gvlt.doc_example_secondary_set(bigint, oid DEFAULT NULL, boolean DEFAULT true, text DEFAULT NULL) RETURNS text`

Marks a documentation example as secondary or primary. The mark may apply to the whole example (`p_function_oid` is `NULL`) or to a specific example-function pair.

Marking the whole example as secondary:

```sql
SELECT gvlt.doc_example_secondary_set(2, NULL, true, 'too broad for summary');
```

Expected result:

```text
Example 2 secondary=true
```

Marking an example-function pair:

```sql
SELECT gvlt.doc_example_secondary_set(
  2,
  'public.fx(int)'::regprocedure::oid,
  false,
  'use for fx'
);
```

Expected result:

```text
Example 2 / function <oid> secondary=false
```

## `src/doc01-UDF-mediawiki.sql`

Functions for generating MediaWiki documentation for PostgreSQL UDFs. This module depends on external `doc_UDF_show_simple(...)` and related functions mentioned in the file header.

### `doc_mediawiki_nowiki(text, text DEFAULT '') RETURNS text`

Wraps text in `<nowiki>...</nowiki>` and escapes embedded `</nowiki>` closings so the MediaWiki block is not broken.

```sql
SELECT doc_mediawiki_nowiki('x < y');
```

Expected result:

```text
<nowiki>x < y</nowiki>
```

### `doc_mediawiki_table_cell(text, text DEFAULT '') RETURNS text`

Prepares text for a MediaWiki table cell by replacing line breaks with `<br />`.

```sql
SELECT doc_mediawiki_table_cell(E'line 1\nline 2');
```

Expected result:

```text
line 1<br />line 2
```

### `doc_UDF_generate_mediawiki_row(text DEFAULT NULL, text DEFAULT '', text DEFAULT '', oid DEFAULT NULL) RETURNS text`

Generates MediaWiki table rows for a UDF summary table, using metadata returned by `doc_UDF_show_simple(...)`.

```sql
SELECT doc_UDF_generate_mediawiki_row('public', '%geohash%');
```

Expected result:

```mediawiki
|-
|'''b32cep_to_hbig''' || <nowiki>bigint</nowiki> || <nowiki>x text</nowiki> || <nowiki>func</nowiki>
```

When no function is found:

```text
(no functions found)
```

### `doc_UDF_generate_mediawiki_section(text DEFAULT NULL, text DEFAULT '', text DEFAULT '', oid DEFAULT NULL) RETURNS text`

Generates one MediaWiki section per function, with description, return type, and signature.

```sql
SELECT doc_UDF_generate_mediawiki_section('public', '%geohash%');
```

Expected result:

```mediawiki
== '''b32cep_to_hbig''' ==
* Description: Translates a base32cep string into a varbit representation.
* Return: ''int8''
* Signature: <nowiki>x text</nowiki>
```

### `doc_UDF_generate_mediawiki_page(text DEFAULT NULL, text DEFAULT '', text DEFAULT '', oid DEFAULT NULL) RETURNS text`

Generates a complete MediaWiki page per function, with `Name`, `Synopsis`, `Description`, and `Metadata` sections.

```sql
SELECT doc_UDF_generate_mediawiki_page('public', '%geohash%');
```

Expected result:

```mediawiki
= public.b32cep_to_hbig =
<span id="..."></span>

== Name ==
'''b32cep_to_hbig''' -- ...

== Synopsis ==
: <code><nowiki>public.b32cep_to_hbig(x text) RETURNS bigint</nowiki></code>
```

### `doc_UDF_generate_mediawiki_guide(text DEFAULT NULL, text DEFAULT '', text DEFAULT '') RETURNS text`

Generates a guide-style MediaWiki page as a sortable table with ID, schema, function, return type, arguments, and description.

```sql
SELECT doc_UDF_generate_mediawiki_guide('public', '%geohash%');
```

Expected result:

```mediawiki
{| class="wikitable sortable"
! ID
! Schema
! Function
! Return
! Arguments
! Description
|-
| ...
|}
```

### `doc_UDF_generate_mediawiki_xml_dump(text DEFAULT NULL, text DEFAULT '', text DEFAULT '', text DEFAULT 'pg_govLite', text DEFAULT 'https://example.org/wiki/') RETURNS text`

Generates a MediaWiki XML dump with one page per UDF. It uses native PostgreSQL XML functions (`xmlelement`, `xmlattributes`, `xmlagg`, `xmlserialize`) to build the document.

```sql
SELECT doc_UDF_generate_mediawiki_xml_dump(
  'public',
  '%geohash%',
  '',
  'pg_govLite',
  'https://example.org/wiki/'
);
```

Expected result:

```xml
<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/" ...>
  <siteinfo>...</siteinfo>
  <page>...</page>
</mediawiki>
```

Expected validation:

```sql
SELECT XMLPARSE(
  DOCUMENT doc_UDF_generate_mediawiki_xml_dump('public', '%geohash%')
) IS DOCUMENT;
```

Expected result:

```text
t
```

## `src/assert02-psqlDiff.sql`

Functions dynamically created by the `assert02-psqlDiff.sql` test script. They temporarily replace the Medallion triggers with a version that registers all governed tags present in the schema name. They are relevant for development and validation, but they are not part of the main `CORE_SQL` installation list.

### `gvlt.schema_name_tags(text) RETURNS text[]`

Analyzes a schema name and returns the governed tags found in appearance order when the name ends with a Medallion tag. Returns `NULL` when the schema does not end with a Medallion tag. Returns `{!}` when the name looks governed but contains a non-registered segment longer than one letter.

```sql
SELECT gvlt.schema_name_tags('tsttmp_stage_bronze');
```

Expected result:

```text
{TSTTMP,Stage,Bronze}
```

```sql
SELECT gvlt.schema_name_tags('q_bronze_q');
```

Expected result:

```text
NULL
```

```sql
SELECT gvlt.schema_name_tags('semtag_bronze');
```

Expected result:

```text
{!}
```

### `gvlt.trig_schema_tags_upsert_event() RETURNS event_trigger`

Test event trigger for `CREATE SCHEMA`. It registers all governed tags found in the schema name, not only the Medallion tag.

Indirect usage:

```sql
CREATE SCHEMA tsttmp_stage_bronze;
```

Expected result:

```text
NOTICE: pg_govLite: Schema tsttmp_stage_bronze registrado com tags {TSTTMP,Stage,Bronze}!
```

Expected effect:

```sql
SELECT array_agg(tag_name ORDER BY tag_name)
FROM gvlt.tag_obj
WHERE obj_name = 'tsttmp_stage_bronze'
  AND is_active;
```

Expected result:

```text
{Bronze,Stage,TSTTMP}
```

### `gvlt.trig_schema_tags_disable_event() RETURNS event_trigger`

Test event trigger for `DROP SCHEMA`. It marks all tags associated with the removed schema as inactive.

Indirect usage:

```sql
DROP SCHEMA tsttmp_stage_bronze;
```

Expected result:

```text
NOTICE: pg_govLite: Tags do schema tsttmp_stage_bronze marcadas como inativas
```

## Commented Drafts

The file `src/inst03-fw_govRules.sql` contains a `/* Later review ... */` block with commented draft functions that are not installed:

- `gvlt_examples_bronze.list_functions(p_query text) RETURNS text`
- `gvlt.add_example(p_query text) RETURNS text`

These definitions are inside a comment and therefore do not exist in the database after a normal installation. The active `gvlt.add_example(text)` function is in `src/inst04-documentation_examples.sql` and is documented above.

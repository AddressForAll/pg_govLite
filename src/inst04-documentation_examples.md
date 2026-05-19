# Documentation Examples

`inst04-documentation_examples.sql` adds support for storing documentation examples as executable PostgreSQL views.

The main entry point is:

```sql
SELECT gvlt.doc_examples_add('<function call or SELECT query>');
```

There is also a compatibility alias:

```sql
SELECT gvlt.add_example('<function call or SELECT query>');
```

Generated views are stored in the `gvlt_doc_examples` schema with serial names such as `ex1`, `ex2`, and `ex3`.

The generated examples are cataloged in `gvlt.doc_examples`, which stores the view name, normalized SQL payload, payload hash, and creation timestamp. Duplicate normalized payloads are not recreated.

The script also exposes view-function relationships through `gvlt.vw_doc_view_function_dependencies`. This generic view uses PostgreSQL system catalogs to inspect dependencies between views and user-defined functions.

For documentation examples, `gvlt.vw_doc_function_examples` reuses that generic dependency view and restricts the result to generated example views.

Each relationship includes:

```text
example_id
example_view
payload
function_oid
function_schema
function_name
function_signature
function_type
deptype
is_exclusive
is_secondary
secondary_note
```

`is_exclusive` is derived automatically. It is true when the example view depends on exactly one UDF.

Examples can also be marked as secondary through `gvlt.doc_example_secondary_set(...)`. The mark can apply to the whole example or to one specific function-example pair.

## Function Call Example

```sql
SELECT gvlt.doc_examples_add('round(pi(),3)');
```

Expected result:

```text
CREATE VIEW gvlt_doc_examples.ex1 AS SELECT round(pi(),3) AS x
```

The generated view can then be executed:

```sql
SELECT * FROM gvlt_doc_examples.ex1;
```

Expected result:

```text
   x
-------
 3.142
```

## Equivalent SELECT Example

This input is equivalent to the previous one after normalization:

```sql
SELECT gvlt.doc_examples_add('SELECT round(pi(),3)');
```

Expected result:

```text
EXISTS gvlt_doc_examples.ex1 AS SELECT round(pi(),3) AS x
```

No duplicate view is created because the normalized payload is already registered.

The alias behaves the same way:

```sql
SELECT gvlt.add_example('SELECT round(pi(),3)');
```

Expected result:

```text
EXISTS gvlt_doc_examples.ex1 AS SELECT round(pi(),3) AS x
```

## Full Query Example

Full `SELECT` queries are also supported.

```sql
CREATE TABLE public.t(id int, x int);

CREATE FUNCTION public.f(int)
RETURNS int
LANGUAGE SQL IMMUTABLE
AS 'SELECT $1 + 1';

SELECT gvlt.doc_examples_add($$ SELECT id, f(x) AS y FROM t $$);
```

Expected result:

```text
CREATE VIEW gvlt_doc_examples.ex2 AS SELECT id, f(x) AS y FROM t
```

## Function-Example Dependencies

Example views can use one or more UDFs.

```sql
CREATE FUNCTION public.fx(x int)
RETURNS int
LANGUAGE SQL IMMUTABLE
AS 'SELECT x + 1';

CREATE FUNCTION public.gx(x int)
RETURNS int
LANGUAGE SQL IMMUTABLE
AS 'SELECT x * 2';

SELECT gvlt.doc_examples_add('fx(1)');
SELECT gvlt.doc_examples_add('SELECT fx(1), gx(2) AS y');
```

The dependency view shows which functions each example uses:

```sql
SELECT example_id, function_name, is_exclusive, is_secondary
FROM gvlt.vw_doc_function_examples
ORDER BY example_id, function_name;
```

Example result:

```text
 example_id | function_name | is_exclusive | is_secondary
------------+---------------+--------------+--------------
 1          | fx            | true         | false
 2          | fx            | false        | false
 2          | gx            | false        | false
```

## Secondary Examples

An entire example can be marked as secondary:

```sql
SELECT gvlt.doc_example_secondary_set(2, NULL, true, 'too broad for summary');
```

Or only one function-example pair can be marked:

```sql
SELECT gvlt.doc_example_secondary_set(
  2,
  'public.fx(int)'::regprocedure::oid,
  false,
  'use for fx'
);
```

Pair-level marks override example-level marks in `gvlt.vw_doc_function_examples`.

## Generic View-Function Dependencies

The generic dependency view can also be used for project views outside the documentation examples:

```sql
SELECT view_signature, deptype, function_signature
FROM gvlt.vw_doc_view_function_dependencies
WHERE view_schema = 'gvlt'
ORDER BY view_signature, function_signature;
```

Example result:

```text
 view_signature      | deptype | function_signature
---------------------+---------+-------------------------
 gvlt.vw01_medallion | n       | lib.object_getype(text)
 gvlt.vw01_tag_obj   | n       | lib.object_getype(text)
```

## Catalog Inspection

Generated examples can be inspected through the catalog table:

```sql
SELECT view_name, payload
FROM gvlt.doc_examples
ORDER BY id;
```

Example result:

```text
 view_name | payload
-----------+-----------------------------------
 ex1       | SELECT round(pi(),3) AS x
 ex2       | SELECT id, f(x) AS y FROM t
```

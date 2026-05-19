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

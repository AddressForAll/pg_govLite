-- ---------------------------------------------------------
-- State-independent function asserts.
-- Configure PostgreSQL with check_assertions=on to enforce ASSERT.
-- ---------------------------------------------------------

DO $do$
DECLARE
  v_arr int[];
BEGIN

ASSERT {{object:helper.round}}(pi(), 1) = 3.1,
  'Error: public {{object:helper.round}}(float,int) not working';
ASSERT {{object:helper.round}}(pi(), 15)::text = '3.141592653589790',
  'Error: public {{object:helper.round}}(float,int) not working';
ASSERT {{object:helper.round}}(0.2345::float, 2) = 0.23,
  'Error: public {{object:helper.round}}(float,int) did not round to 2 decimal places';
ASSERT {{object:helper.round}}(-1.235::float, 2) = -1.24,
  'Error: public {{object:helper.round}}(float,int) did not round negative values correctly';

ASSERT {{object:helper.array_distinct}}('{10,1,1,20,10,NULL,10}'::int[]) = '{10,1,20}'::int[],
  'Error: public {{object:helper.array_distinct}}() not working';
ASSERT {{object:helper.array_distinct}}('{10,1,1,20,10,NULL,10}'::int[], false) = '{NULL,10,1,20}'::int[],
  'Error2: public {{object:helper.array_distinct}}() not working';

v_arr := {{object:helper.array_distinct}}('{10,1,1,20,10,NULL,10}'::int[]);
ASSERT array_length(v_arr, 1) = 3
       AND 1 = ANY(v_arr)
       AND 10 = ANY(v_arr)
       AND 20 = ANY(v_arr)
       AND NOT EXISTS (
         SELECT 1
         FROM unnest(v_arr) t(x)
         GROUP BY x
         HAVING count(*) > 1
       ),
  'Error: public {{object:helper.array_distinct}}(anyarray) did not remove duplicates and NULLs';

v_arr := {{object:helper.array_distinct}}('{10,1,1,20,10,NULL,10}'::int[], false);
ASSERT array_length(v_arr, 1) = 4
       AND 1 = ANY(v_arr)
       AND 10 = ANY(v_arr)
       AND 20 = ANY(v_arr)
       AND array_position(v_arr, NULL) IS NOT NULL
       AND NOT EXISTS (
         SELECT 1
         FROM unnest(v_arr) t(x)
         GROUP BY x
         HAVING count(*) > 1
       ),
  'Error: public {{object:helper.array_distinct}}(anyarray,false) did not preserve one NULL and remove duplicates';

ASSERT {{object:helper.array_distinct}}(NULL::int[]) IS NULL,
  'Error: public {{object:helper.array_distinct}}(NULL) should return NULL';
ASSERT {{object:helper.array_distinct}}('{NULL}'::int[]) IS NULL,
  'Error: public {{object:helper.array_distinct}}({NULL}) should return NULL by default';
ASSERT {{object:helper.array_distinct}}('{NULL}'::int[], false) = '{NULL}'::int[],
  'Error: public {{object:helper.array_distinct}}({NULL},false) should preserve NULL';

ASSERT {{object:helper.array_distinct_sort}}('{10,1,20,2,3,NULL,10,500,5}'::int[]) = '{1,2,3,5,10,20,500}'::int[],
  'Error: public {{object:helper.array_distinct_sort}}() not working';
ASSERT {{object:helper.array_distinct_sort}}('{NULL}'::int[]) IS NULL,
  'Error2: public {{object:helper.array_distinct_sort}}() not working';
ASSERT {{object:helper.array_distinct_sort}}('{NULL}'::int[], false) = '{NULL}'::int[],
  'Error3: public {{object:helper.array_distinct_sort}}() not working';
ASSERT {{object:helper.array_distinct_sort}}('{10,1,20,2,3,NULL,10,500,5}'::int[], false) = '{1,2,3,5,10,20,500,NULL}'::int[],
  'Error: public {{object:helper.array_distinct_sort}}(anyarray,false) did not sort and preserve one NULL';
ASSERT {{object:helper.array_distinct_sort}}(NULL::int[]) IS NULL,
  'Error: public {{object:helper.array_distinct_sort}}(NULL) should return NULL';

ASSERT {{object:helper.jsonb_object_keys_asarray}}('{"x":1,"Y":2,"z":3}'::jsonb) = '{Y,x,z}'::text[],
  'Error: public {{object:helper.jsonb_object_keys_asarray}}() not working';
ASSERT {{object:helper.array_distinct_sort}}({{object:helper.jsonb_object_keys_asarray}}('{"x":1,"y":2,"z":3}'::jsonb)) = '{x,y,z}'::text[],
  'Error: public {{object:helper.jsonb_object_keys_asarray}}(jsonb) did not return the expected keys';
ASSERT {{object:helper.jsonb_object_keys_asarray}}('{}'::jsonb) IS NULL,
  'Error: public {{object:helper.jsonb_object_keys_asarray}}(empty object) should return NULL';

ASSERT {{object:helper.jsonb_array_to_text_array}}('["b","a","b",null]'::jsonb) = '{b,a,b,NULL}'::text[],
  'Error: public {{object:helper.jsonb_array_to_text_array}}(jsonb) did not preserve order and values';
ASSERT {{object:helper.jsonb_array_to_text_array}}('["b","a","b",null]'::jsonb, true) = '{a,b}'::text[],
  'Error: public {{object:helper.jsonb_array_to_text_array}}(jsonb,true) did not sort and deduplicate non-NULL values';
ASSERT {{object:helper.jsonb_array_to_text_array}}(NULL::jsonb) IS NULL,
  'Error: public {{object:helper.jsonb_array_to_text_array}}(NULL) should return NULL';

ASSERT {{object:lib.pgddl_objtype_to_relkind}}('table') = 'r'::"char",
  'Error: {{object:lib.pgddl_objtype_to_relkind}}(table) should return r';
ASSERT {{object:lib.pgddl_objtype_to_relkind}}('materialized view') = 'm'::"char",
  'Error: {{object:lib.pgddl_objtype_to_relkind}}(materialized view) should return m';
ASSERT {{object:lib.pgddl_objtype_to_relkind}}('unknown') IS NULL,
  'Error: {{object:lib.pgddl_objtype_to_relkind}}(unknown) should return NULL';

ASSERT {{object:lib.pgddl_relkind_to_objtype}}('r'::"char") = 'table',
  'Error: {{object:lib.pgddl_relkind_to_objtype}}(r) should return table';
ASSERT {{object:lib.pgddl_relkind_to_objtype}}('m'::"char") = 'materialized view',
  'Error: {{object:lib.pgddl_relkind_to_objtype}}(m) should return materialized view';
ASSERT {{object:lib.pgddl_relkind_to_objtype}}('x'::"char") IS NULL,
  'Error: {{object:lib.pgddl_relkind_to_objtype}}(x) should return NULL';

ASSERT {{object:lib.object_getype}}('schema_name') = 's'::"char",
  'Error: {{object:lib.object_getype}}(schema) should return s';
ASSERT {{object:lib.object_getype}}('schema_name.table_name') = 'r'::"char",
  'Error: {{object:lib.object_getype}}(relation) should return r';
ASSERT {{object:lib.object_getype}}('schema_name.table_name.column_name') = 'c'::"char",
  'Error: {{object:lib.object_getype}}(column) should return c';
ASSERT {{object:lib.object_getype}}('schema_name.table_name.column_name.extra') IS NULL,
  'Error: {{object:lib.object_getype}}(too many parts) should return NULL';

ASSERT (
  SELECT count(*) = 8 AND bool_and(p.provolatile = 'i')
  FROM pg_proc p
  WHERE p.oid IN (
    '{{object:helper.round}}(double precision,integer)'::regprocedure,
    '{{object:helper.array_distinct}}(anyarray,boolean)'::regprocedure,
    '{{object:helper.array_distinct_sort}}(anyarray,boolean)'::regprocedure,
    '{{object:helper.jsonb_object_keys_asarray}}(jsonb)'::regprocedure,
    '{{object:helper.jsonb_array_to_text_array}}(jsonb,boolean)'::regprocedure,
    '{{object:lib.pgddl_objtype_to_relkind}}(text)'::regprocedure,
    '{{object:lib.pgddl_relkind_to_objtype}}("char")'::regprocedure,
    '{{object:lib.object_getype}}(text)'::regprocedure
  )
),
  'Error: one or more asserted functions are not declared IMMUTABLE';

END $do$;

---------------------
SELECT E'--- No messages = No error ---\n--- BASIC ASSERTS FINISHED ---' final_message;

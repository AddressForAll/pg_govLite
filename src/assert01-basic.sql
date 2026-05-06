-- ---------------------------------------------------------
-- Roteiro de Testes Unitários: Framework AFA
-- Configuração: Certifique-se de que check_assertions está ON
-- SET check_assertions = on;
-- ---------------------------------------------------------

DO $do$
BEGIN

ASSERT round(pi(),3)=3.142,
  'Error: public round(float,int) not working';
ASSERT array_distinct('{10,1,1,20,10,NULL,10}'::int[])='{10,1,20}'::int[],
  'Error: public array_distinct() not working';
ASSERT array_distinct( '{10,1,1,20,10,NULL,10}'::int[], false )='{NULL,10,1,20}'::int[],
  'Error2: public array_distinct() not working';
ASSERT array_distinct_sort('{10,1,20,2,3,NULL,10,500,5}'::int[])='{1,2,3,5,10,20,500}'::int[],
  'Error: public array_distinct_sort() not working';
ASSERT array_distinct_sort('{NULL}'::int[]) IS NULL,
  'Error2: public array_distinct_sort() not working';
ASSERT array_distinct_sort( '{NULL}'::int[], false ) = '{NULL}'::int[],
  'Error3: public array_distinct_sort() not working';
ASSERT jsonb_object_keys_asarray('{"x":1,"Y":2,"z":3}')='{Y,x,z}'::text[],
  'Error: public jsonb_object_keys_asarray() not working';
END $do$;

---------------------
SELECT E'--- No messages = No error ---\n--- BASIC ASSERTS FINESHED ---' final_message;


/* old asserts
DO $$
DECLARE
    v_status text;
    v_exists boolean;
BEGIN
    -- 1. TESTES DE LÓGICA DE NOMENCLATURA (Regex)
    ASSERT fw_cat.schema_name_validate('schema_comum') IS NULL,
           'Erro: schema_comum não deveria ser medalhão';

    ASSERT fw_cat.schema_name_validate('projeto_silver') = 'silver',
           'Erro: projeto_silver deveria ser identificado como silver';

    -- 2. TESTES DE UPSERT MANUAL
    -- nome valido: gold no final (padrao _(bronze|silver|gold)$)
    v_status := fw_cat.medallion_upsert('teste_gold');
    ASSERT v_status LIKE 'SUCESSO%',
           'Erro no upsert de teste_gold: ' || v_status;

    -- nome invalido: gold no meio nao e reconhecido pelo padrao medalhao
    v_status := fw_cat.medallion_upsert('invalido_sem_tag');
    ASSERT v_status LIKE 'ERRO%',
           'Erro: O sistema deveria ter barrado o schema invalido_sem_tag';

    -- 3. TESTES DE AUTOMAÇÃO (EVENT TRIGGERS)
    -- Simula criação física de um schema
    CREATE SCHEMA IF NOT EXISTS auto_bronze;

    SELECT EXISTS (
        SELECT 1 FROM fw_cat.medallion
        WHERE f_table_schema = 'auto_bronze' AND is_active = true
    ) INTO v_exists;

    ASSERT v_exists, 'Erro: Event Trigger falhou ao registrar auto_bronze como ativo';

    -- Simula remoção física do schema
    DROP SCHEMA auto_bronze;

    SELECT EXISTS (
        SELECT 1 FROM fw_cat.medallion
        WHERE f_table_schema = 'auto_bronze' AND is_active = false
    ) INTO v_exists;

    ASSERT v_exists, 'Erro: Event Trigger falhou ao marcar auto_bronze como inativo (is_active=false)';

    -- 4. TESTES DE NORMALIZAÇÃO DE TAGS
    -- (Assumindo que as funções de tags já foram migradas para o core)
    ASSERT fw_cat.govtags_normalize(ARRAY['cpF', 'cnpj:123', 'XpTo']) = ARRAY['CNPJ:123', 'CPF'],
           'Erro na normalização: Resultado inesperado para tags governadas/especializadas';

    RAISE NOTICE '>>>> TODOS OS TESTES PASSARAM COM SUCESSO (ASSERTs OK) <<<<';
END $$;
*/

-- ---------------------------------------------------------
-- Immutable function asserts.
-- Configure PostgreSQL with check_assertions=on to enforce ASSERT.
-- ---------------------------------------------------------

DO $do$
DECLARE
  v_arr int[];
BEGIN

ASSERT round(1.2345::float, 2) = 1.23,
  'Error: public round(float,int) did not round to 2 decimal places';
ASSERT round(-1.235::float, 2) = -1.24,
  'Error: public round(float,int) did not round negative values correctly';

v_arr := array_distinct('{10,1,1,20,10,NULL,10}'::int[]);
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
  'Error: public array_distinct(anyarray) did not remove duplicates and NULLs';

v_arr := array_distinct('{10,1,1,20,10,NULL,10}'::int[], false);
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
  'Error: public array_distinct(anyarray,false) did not preserve one NULL and remove duplicates';

ASSERT array_distinct(NULL::int[]) IS NULL,
  'Error: public array_distinct(NULL) should return NULL';
ASSERT array_distinct('{NULL}'::int[]) IS NULL,
  'Error: public array_distinct({NULL}) should return NULL by default';
ASSERT array_distinct('{NULL}'::int[], false) = '{NULL}'::int[],
  'Error: public array_distinct({NULL},false) should preserve NULL';

ASSERT array_distinct_sort('{10,1,20,2,3,NULL,10,500,5}'::int[]) = '{1,2,3,5,10,20,500}'::int[],
  'Error: public array_distinct_sort(anyarray) did not sort and remove duplicates/NULLs';
ASSERT array_distinct_sort('{10,1,20,2,3,NULL,10,500,5}'::int[], false) = '{1,2,3,5,10,20,500,NULL}'::int[],
  'Error: public array_distinct_sort(anyarray,false) did not sort and preserve one NULL';
ASSERT array_distinct_sort(NULL::int[]) IS NULL,
  'Error: public array_distinct_sort(NULL) should return NULL';
ASSERT array_distinct_sort('{NULL}'::int[]) IS NULL,
  'Error: public array_distinct_sort({NULL}) should return NULL by default';
ASSERT array_distinct_sort('{NULL}'::int[], false) = '{NULL}'::int[],
  'Error: public array_distinct_sort({NULL},false) should preserve NULL';

ASSERT array_distinct_sort(jsonb_object_keys_asarray('{"x":1,"Y":2,"z":3}'::jsonb)) = '{Y,x,z}'::text[],
  'Error: public jsonb_object_keys_asarray(jsonb) did not return the expected keys';
ASSERT jsonb_object_keys_asarray('{}'::jsonb) IS NULL,
  'Error: public jsonb_object_keys_asarray(empty object) should return NULL';

ASSERT jsonb_array_to_text_array('["b","a","b",null]'::jsonb) = '{b,a,b,NULL}'::text[],
  'Error: public jsonb_array_to_text_array(jsonb) did not preserve order and values';
ASSERT jsonb_array_to_text_array('["b","a","b",null]'::jsonb, true) = '{a,b}'::text[],
  'Error: public jsonb_array_to_text_array(jsonb,true) did not sort and deduplicate non-NULL values';
ASSERT jsonb_array_to_text_array(NULL::jsonb) IS NULL,
  'Error: public jsonb_array_to_text_array(NULL) should return NULL';

ASSERT lib.pgddl_objtype_to_relkind('table') = 'r'::"char",
  'Error: lib.pgddl_objtype_to_relkind(table) should return r';
ASSERT lib.pgddl_objtype_to_relkind('materialized view') = 'm'::"char",
  'Error: lib.pgddl_objtype_to_relkind(materialized view) should return m';
ASSERT lib.pgddl_objtype_to_relkind('unknown') IS NULL,
  'Error: lib.pgddl_objtype_to_relkind(unknown) should return NULL';

ASSERT lib.pgddl_relkind_to_objtype('r'::"char") = 'table',
  'Error: lib.pgddl_relkind_to_objtype(r) should return table';
ASSERT lib.pgddl_relkind_to_objtype('m'::"char") = 'materialized view',
  'Error: lib.pgddl_relkind_to_objtype(m) should return materialized view';
ASSERT lib.pgddl_relkind_to_objtype('x'::"char") IS NULL,
  'Error: lib.pgddl_relkind_to_objtype(x) should return NULL';

ASSERT lib.object_getype('schema_name') = 's'::"char",
  'Error: lib.object_getype(schema) should return s';
ASSERT lib.object_getype('schema_name.table_name') = 'r'::"char",
  'Error: lib.object_getype(relation) should return r';
ASSERT lib.object_getype('schema_name.table_name.column_name') = 'c'::"char",
  'Error: lib.object_getype(column) should return c';
ASSERT lib.object_getype('schema_name.table_name.column_name.extra') IS NULL,
  'Error: lib.object_getype(too many parts) should return NULL';

ASSERT gvlt.rdf_prefix_valid('sh:Person'),
  'Error: gvlt.rdf_prefix_valid(sh:Person) should return true';
ASSERT gvlt.rdf_prefix_valid('wd:Q42'),
  'Error: gvlt.rdf_prefix_valid(wd:Q42) should return true';
ASSERT gvlt.rdf_prefix_valid('dcat:Dataset'),
  'Error: gvlt.rdf_prefix_valid(dcat:Dataset) should return true';
ASSERT NOT gvlt.rdf_prefix_valid('schema:Person'),
  'Error: gvlt.rdf_prefix_valid(schema:Person) should return false';
ASSERT gvlt.rdf_prefix_valid(NULL) IS NULL,
  'Error: gvlt.rdf_prefix_valid(NULL) should return NULL';

ASSERT (
  SELECT count(*) = 9 AND bool_and(p.provolatile = 'i')
  FROM pg_proc p
  WHERE p.oid IN (
    'public.round(double precision,integer)'::regprocedure,
    'public.array_distinct(anyarray,boolean)'::regprocedure,
    'public.array_distinct_sort(anyarray,boolean)'::regprocedure,
    'public.jsonb_object_keys_asarray(jsonb)'::regprocedure,
    'public.jsonb_array_to_text_array(jsonb,boolean)'::regprocedure,
    'lib.pgddl_objtype_to_relkind(text)'::regprocedure,
    'lib.pgddl_relkind_to_objtype("char")'::regprocedure,
    'lib.object_getype(text)'::regprocedure,
    'gvlt.rdf_prefix_valid(text)'::regprocedure
  )
),
  'Error: one or more asserted functions are not declared IMMUTABLE';

END $do$;

---------------------
SELECT E'--- No messages = No error ---\n--- IMMUTABLE ASSERTS FINISHED ---' final_message;

-- ---------------------------------------------------------
-- Stateful function asserts.
-- Configure PostgreSQL with check_assertions=on to enforce ASSERT.
-- ---------------------------------------------------------

DO $do$
DECLARE
  v_text text;
BEGIN

-- Cleanup from interrupted previous runs.
DELETE FROM gvlt.tag_obj WHERE obj_name LIKE 'assert04%';
DELETE FROM gvlt.tag_obj WHERE obj_name IN ('t_bronze', 'tsttmp_silver');
EXECUTE 'DROP SCHEMA IF EXISTS t_bronze CASCADE';
EXECUTE 'DROP SCHEMA IF EXISTS tsttmp_silver CASCADE';
EXECUTE 'DROP TABLE IF EXISTS public.assert04_rel_desc';
EXECUTE 'DROP TABLE IF EXISTS pg_temp.assert04_dynamic_execute_test';

ASSERT (
  SELECT x
  FROM lib.dynamic_query('SELECT 42::int AS x') AS t(x int)
) = 42,
  'Error: lib.dynamic_query(text) did not return query result';

ASSERT lib.dynamic_execute('CREATE TEMP TABLE assert04_dynamic_execute_test(x int)'),
  'Error: lib.dynamic_execute(text) did not return true';
ASSERT to_regclass('pg_temp.assert04_dynamic_execute_test') IS NOT NULL,
  'Error: lib.dynamic_execute(text) did not execute CREATE TEMP TABLE';

ASSERT EXISTS (
  SELECT 1
  FROM lib.rel_disk_usage(ARRAY['pg_catalog'])
  WHERE schema_name = 'pg_catalog'
),
  'Error: lib.rel_disk_usage(text[]) did not return pg_catalog relations';
ASSERT NOT EXISTS (
  SELECT 1
  FROM lib.rel_disk_usage(ARRAY['assert04_schema_that_does_not_exist'])
),
  'Error: lib.rel_disk_usage(text[]) should return no rows for an unknown schema';

ASSERT gvlt.govtags_fail(ARRAY['CPF', ' cnpj ', 'no_such_tag']) = '{no_such_tag}'::text[],
  'Error: gvlt.govtags_fail(text[]) did not identify missing tags';
ASSERT gvlt.govtags_fail(ARRAY['CPF', 'cnpj']) IS NULL,
  'Error: gvlt.govtags_fail(text[]) should return NULL when all tags exist';

ASSERT gvlt.govtags_exists('CPF'),
  'Error: gvlt.govtags_exists(text) should return true for CPF';
ASSERT NOT gvlt.govtags_exists('no_such_tag'),
  'Error: gvlt.govtags_exists(text) should return false for missing tag';
ASSERT gvlt.govtags_exists(ARRAY['CPF', 'CNPJ', 'vatID']),
  'Error: gvlt.govtags_exists(text[]) should return true when all tags exist';
ASSERT NOT gvlt.govtags_exists(ARRAY['CPF', 'no_such_tag']),
  'Error: gvlt.govtags_exists(text[]) should return false when one tag is missing';

ASSERT gvlt.govtags_normalize(ARRAY['cpF', 'cnpj', 'xpto', 'vatid', 'CPF']) = '{CNPJ,CPF,vatID}'::text[],
  'Error: gvlt.govtags_normalize(text[]) did not normalize, sort and discard unknown tags';
ASSERT gvlt.govtags_normalize('["cpF","cnpj","xpto","vatid","CPF"]'::jsonb) = '{CNPJ,CPF,vatID}'::text[],
  'Error: gvlt.govtags_normalize(jsonb) did not normalize JSON tags';
ASSERT gvlt.govtags_normalize(ARRAY['xpto']) IS NULL,
  'Error: gvlt.govtags_normalize(text[]) should return NULL for only unknown tags';

ASSERT gvlt.govtag_list_include(ARRAY['CPF'], 'cnpj') = '{CNPJ,CPF}'::text[],
  'Error: gvlt.govtag_list_include(text[],text) did not include one tag';
ASSERT gvlt.govtag_list_include(ARRAY['CPF'], ARRAY['cnpj', 'vatid']) = '{CNPJ,CPF,vatID}'::text[],
  'Error: gvlt.govtag_list_include(text[],text[]) did not include multiple tags';
ASSERT gvlt.govtag_list_include(ARRAY['CPF'], 'no_such_tag') = '{CPF}'::text[],
  'Error: gvlt.govtag_list_include should ignore unknown tags through normalization';

ASSERT gvlt.govtag_list_exclude(ARRAY['CPF', 'CNPJ', 'vatID'], 'CNPJ') = '{CPF,vatID}'::text[],
  'Error: gvlt.govtag_list_exclude(text[],text) did not remove one tag';
ASSERT gvlt.govtag_list_exclude(ARRAY['CPF', 'CNPJ', 'vatID'], ARRAY['CNPJ', 'vatID']) = '{CPF}'::text[],
  'Error: gvlt.govtag_list_exclude(text[],text[]) did not remove multiple tags';

ASSERT gvlt.schema_name_validate('q_bronze') = 'Bronze',
  'Error: gvlt.schema_name_validate(q_bronze) should return Bronze';
ASSERT gvlt.schema_name_validate('geo_gold') = 'Gold',
  'Error: gvlt.schema_name_validate(geo_gold) should return Gold';
ASSERT gvlt.schema_name_validate('schema_comum') IS NULL,
  'Error: gvlt.schema_name_validate(schema_comum) should return NULL';
ASSERT gvlt.schema_name_validate('semtag_bronze') = '!',
  'Error: gvlt.schema_name_validate(semtag_bronze) should return !';
ASSERT gvlt.schema_name_nontag('semtag_bronze') = '{semtag}'::text[],
  'Error: gvlt.schema_name_nontag(semtag_bronze) should return missing semtag';

ASSERT gvlt.rel_getname('my_table') = 'public.my_table',
  'Error: gvlt.rel_getname(text) should default to public schema';
ASSERT gvlt.rel_getname('my_table', 'my_schema') = 'my_schema.my_table',
  'Error: gvlt.rel_getname(text,text) should prepend provided schema';
ASSERT gvlt.rel_getname('my_schema.my_table', 'ignored_schema') = 'my_schema.my_table',
  'Error: gvlt.rel_getname(qualified,text) should preserve qualified relation name';

EXECUTE 'CREATE TABLE public.assert04_rel_desc(x int)';
EXECUTE 'COMMENT ON TABLE public.assert04_rel_desc IS ''assert04 relation description''';
ASSERT gvlt.rel_description('assert04_rel_desc') = 'assert04 relation description',
  'Error: gvlt.rel_description(text) did not return table comment';
EXECUTE 'DROP TABLE public.assert04_rel_desc';

ASSERT gvlt.govtags_is_include('assert04_obj.relation', ARRAY['cpf', 'cnpj']),
  'Error: gvlt.govtags_is_include(text,text[]) should return true for valid object and tags';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert04_obj.relation'
    AND tag_name = 'CPF'
    AND is_active
),
  'Error: gvlt.govtags_is_include did not insert CPF for object';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert04_obj.relation'
    AND tag_name = 'CNPJ'
    AND is_active
),
  'Error: gvlt.govtags_is_include did not insert CNPJ for object';
UPDATE gvlt.tag_obj
SET is_active = false
WHERE obj_name = 'assert04_obj.relation'
  AND tag_name = 'CPF';
ASSERT gvlt.govtags_is_include('assert04_obj.relation', ARRAY['cpf']),
  'Error: gvlt.govtags_is_include should reactivate existing tag';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert04_obj.relation'
    AND tag_name = 'CPF'
    AND is_active
),
  'Error: gvlt.govtags_is_include did not reactivate existing tag';
ASSERT NOT gvlt.govtags_is_include('assert04_obj.relation.column.extra', ARRAY['CPF']),
  'Error: gvlt.govtags_is_include should reject invalid object shape';
ASSERT NOT gvlt.govtags_is_include('assert04_obj.relation', ARRAY['no_such_tag']),
  'Error: gvlt.govtags_is_include should reject unknown tags';

v_text := gvlt.medallion_upsert('t_bronze', '{"case":"manual"}'::jsonb);
ASSERT v_text LIKE 'SUCESSO:%',
  'Error: gvlt.medallion_upsert(valid schema) should return success';
ASSERT EXISTS (
  SELECT 1
  FROM information_schema.schemata
  WHERE schema_name = 't_bronze'
),
  'Error: gvlt.medallion_upsert did not create schema';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 't_bronze'
    AND tag_name = 'Bronze'
    AND is_active
    AND ctrl_config = '{"case":"manual"}'::jsonb
),
  'Error: gvlt.medallion_upsert did not register Bronze tag and config';

v_text := gvlt.medallion_upsert('t_bronze', NULL);
ASSERT v_text LIKE 'SUCESSO:%',
  'Error: gvlt.medallion_upsert(existing schema) should return success';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 't_bronze'
    AND tag_name = 'Bronze'
    AND ctrl_config = '{"case":"manual"}'::jsonb
),
  'Error: gvlt.medallion_upsert(NULL config) should preserve existing config';

v_text := gvlt.medallion_upsert('assert04_plain_schema');
ASSERT v_text LIKE 'ERRO:%',
  'Error: gvlt.medallion_upsert(non-medallion schema) should return error';
ASSERT NOT EXISTS (
  SELECT 1
  FROM information_schema.schemata
  WHERE schema_name = 'assert04_plain_schema'
),
  'Error: gvlt.medallion_upsert(non-medallion schema) should not create schema';

EXECUTE 'CREATE SCHEMA tsttmp_silver';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_silver'
    AND tag_name = 'Silver'
    AND is_active
),
  'Error: medallion CREATE SCHEMA event trigger did not register Silver schema';
EXECUTE 'DROP SCHEMA tsttmp_silver';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_silver'
    AND tag_name = 'Silver'
    AND NOT is_active
),
  'Error: medallion DROP SCHEMA event trigger did not deactivate Silver schema';

-- Cleanup after successful assertions.
EXECUTE 'DROP SCHEMA IF EXISTS t_bronze CASCADE';
EXECUTE 'DROP SCHEMA IF EXISTS tsttmp_silver CASCADE';
DELETE FROM gvlt.tag_obj WHERE obj_name LIKE 'assert04%';
DELETE FROM gvlt.tag_obj WHERE obj_name IN ('t_bronze', 'tsttmp_silver');

END $do$;

---------------------
SELECT E'--- No messages = No error ---\n--- STATEFUL ASSERTS FINISHED ---' final_message;

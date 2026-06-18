--
-- Tests and outputs with make dropDbTest
--

SELECT *, CASE WHEN role='semantic' AND rdf_id IS NULL THEN 'error' ELSE 'ok' END AS error
FROM gvlt.vw01_tag
;


DO $do$
DECLARE
  v_text text;
BEGIN

PERFORM set_config('client_min_messages', 'warning', true);

EXECUTE $sql$
CREATE OR REPLACE FUNCTION gvlt.schema_name_tags(p_schema_name text) RETURNS text[] AS $f$
WITH a AS (
  SELECT t.p, t.i, g.tag_name, g.role
  FROM string_to_table(trim(lower(p_schema_name), '_'), '_') WITH ORDINALITY t(p, i)
  LEFT JOIN gvlt.tag g
    ON lower(g.tag_name) = t.p
), mx AS (
  SELECT max(i) AS max_i FROM a
)
SELECT CASE
  WHEN NOT EXISTS (
    SELECT 1
    FROM a, mx
    WHERE a.i = mx.max_i
      AND a.role = 'medallion'
  ) THEN NULL
  WHEN EXISTS (
    SELECT 1
    FROM a
    WHERE a.tag_name IS NULL
      AND length(a.p) > 1
  ) THEN ARRAY['!']::text[]
  ELSE (
    SELECT array_agg(a.tag_name ORDER BY a.i)
    FROM a
    WHERE a.tag_name IS NOT NULL
  )
END
$f$ LANGUAGE SQL;
$sql$;

EXECUTE $sql$
CREATE OR REPLACE FUNCTION gvlt.trig_schema_tags_upsert_event()
RETURNS event_trigger AS $f$
DECLARE
    obj record;
    v_schema_name text;
    v_tags text[];
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE object_type = 'schema'
    LOOP
        v_schema_name := lower(trim(obj.object_identity));
        v_tags := gvlt.schema_name_tags(v_schema_name);

        IF v_tags IS NULL THEN
            RAISE NOTICE 'pg_govLite: Schema nao-governado ok, % nao possui tags governadas no padrao de nome', v_schema_name;
        ELSIF v_tags = ARRAY['!']::text[] THEN
            RAISE EXCEPTION 'pg_govLite ERROR, schema % candidato a tagging mas com tags ausentes: %',
               v_schema_name,
               array_to_string(gvlt.schema_name_nontag(v_schema_name), ',');
        ELSE
            INSERT INTO gvlt.tag_obj (tag_name, obj_name, is_active)
            SELECT unnest(v_tags), v_schema_name, true
            ON CONFLICT (obj_name, tag_name)
            DO UPDATE SET is_active = true;

            RAISE NOTICE 'pg_govLite: Schema % registrado com tags %!', v_schema_name, v_tags;
        END IF;
    END LOOP;
END;
$f$ LANGUAGE plpgsql;
$sql$;

EXECUTE $sql$
CREATE OR REPLACE FUNCTION gvlt.trig_schema_tags_disable_event()
RETURNS event_trigger AS $f$
DECLARE
    obj record;
    v_schema_name text;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE object_type = 'schema'
    LOOP
        v_schema_name := lower(trim(obj.object_identity));

        UPDATE gvlt.tag_obj
        SET is_active = false
        WHERE obj_name = v_schema_name;

        IF FOUND THEN
            RAISE NOTICE 'pg_govLite: Tags do schema % marcadas como inativas', v_schema_name;
        END IF;
    END LOOP;
END;
$f$ LANGUAGE plpgsql;
$sql$;

EXECUTE 'DROP EVENT TRIGGER IF EXISTS et_medallion_insert';
EXECUTE 'DROP EVENT TRIGGER IF EXISTS et_medallion_drop';
EXECUTE 'CREATE EVENT TRIGGER et_medallion_insert ON ddl_command_end WHEN TAG IN (''CREATE SCHEMA'') EXECUTE FUNCTION gvlt.trig_schema_tags_upsert_event()';
EXECUTE 'CREATE EVENT TRIGGER et_medallion_drop ON sql_drop WHEN TAG IN (''DROP SCHEMA'') EXECUTE FUNCTION gvlt.trig_schema_tags_disable_event()';

-- Cleanup from interrupted previous runs.
DELETE FROM gvlt.tag_obj WHERE obj_name LIKE 'assert02%';
DELETE FROM gvlt.tag_obj WHERE obj_name LIKE 'public.assert02_cols%';
DELETE FROM gvlt.tag_obj WHERE obj_name IN ('t_bronze', 'tsttmp_silver');
EXECUTE 'DROP SCHEMA IF EXISTS t_bronze CASCADE';
EXECUTE 'DROP SCHEMA IF EXISTS tsttmp_silver CASCADE';
EXECUTE 'DROP SCHEMA IF EXISTS tsttmp_stage_bronze CASCADE';
EXECUTE 'DROP TABLE IF EXISTS public.assert02_rel_desc';
EXECUTE 'DROP TABLE IF EXISTS public.assert02_cols';
EXECUTE 'DROP TABLE IF EXISTS pg_temp.assert02_dynamic_execute_test';

ASSERT (
  SELECT x
  FROM lib.dynamic_query('SELECT 42::int AS x') AS t(x int)
) = 42,
  'Error: lib.dynamic_query(text) did not return query result';

ASSERT lib.dynamic_execute('CREATE TEMP TABLE assert02_dynamic_execute_test(x int)'),
  'Error: lib.dynamic_execute(text) did not return true';
ASSERT to_regclass('pg_temp.assert02_dynamic_execute_test') IS NOT NULL,
  'Error: lib.dynamic_execute(text) did not execute CREATE TEMP TABLE';

ASSERT EXISTS (
  SELECT 1
  FROM lib.rel_disk_usage(ARRAY['pg_catalog'])
  WHERE schema_name = 'pg_catalog'
),
  'Error: lib.rel_disk_usage(text[]) did not return pg_catalog relations';
ASSERT NOT EXISTS (
  SELECT 1
  FROM lib.rel_disk_usage(ARRAY['assert02_schema_that_does_not_exist'])
),
  'Error: lib.rel_disk_usage(text[]) should return no rows for an unknown schema';

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
ASSERT gvlt.schema_name_tags('tsttmp_stage_bronze') = '{TSTTMP,Stage,Bronze}'::text[],
  'Error: gvlt.schema_name_tags(tsttmp_stage_bronze) should return all governed tags in name order';
ASSERT gvlt.schema_name_tags('q_bronze_q') IS NULL,
  'Error: gvlt.schema_name_tags(q_bronze_q) should ignore schemas that do not end with medallion tag';
ASSERT gvlt.schema_name_tags('semtag_bronze') = '{!}'::text[],
  'Error: gvlt.schema_name_tags(semtag_bronze) should flag missing tags';

ASSERT gvlt.rel_getname('my_table') = 'public.my_table',
  'Error: gvlt.rel_getname(text) should default to public schema';
ASSERT gvlt.rel_getname('my_table', 'my_schema') = 'my_schema.my_table',
  'Error: gvlt.rel_getname(text,text) should prepend provided schema';
ASSERT gvlt.rel_getname('my_schema.my_table', 'ignored_schema') = 'my_schema.my_table',
  'Error: gvlt.rel_getname(qualified,text) should preserve qualified relation name';

EXECUTE 'CREATE TABLE public.assert02_rel_desc(x int)';
EXECUTE 'COMMENT ON TABLE public.assert02_rel_desc IS ''assert02 relation description''';
ASSERT gvlt.rel_description('assert02_rel_desc') = 'assert02 relation description',
  'Error: gvlt.rel_description(text) did not return table comment';
EXECUTE 'DROP TABLE public.assert02_rel_desc';

ASSERT gvlt.govtags_is_include('assert02_obj.relation', ARRAY['cpf', 'cnpj']),
  'Error: gvlt.govtags_is_include(text,text[]) should return true for valid object and tags';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert02_obj.relation'
    AND tag_name = 'CPF'
    AND is_active
),
  'Error: gvlt.govtags_is_include did not insert CPF for object';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert02_obj.relation'
    AND tag_name = 'CNPJ'
    AND is_active
),
  'Error: gvlt.govtags_is_include did not insert CNPJ for object';
UPDATE gvlt.tag_obj
SET is_active = false
WHERE obj_name = 'assert02_obj.relation'
  AND tag_name = 'CPF';
ASSERT gvlt.govtags_is_include('assert02_obj.relation', ARRAY['cpf']),
  'Error: gvlt.govtags_is_include should reactivate existing tag';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert02_obj.relation'
    AND tag_name = 'CPF'
    AND is_active
),
  'Error: gvlt.govtags_is_include did not reactivate existing tag';
ASSERT NOT gvlt.govtags_is_include('assert02_obj.relation.column.extra', ARRAY['CPF']),
  'Error: gvlt.govtags_is_include should reject invalid object shape';
ASSERT NOT gvlt.govtags_is_include('assert02_obj.relation', ARRAY['no_such_tag']),
  'Error: gvlt.govtags_is_include should reject unknown tags';

ASSERT gvlt.tag_include(
  'assert02Climate',
  'semantic',
  'Assert02 climate semantic tag',
  'wd:Q7937'
),
  'Error: gvlt.tag_include should create a governed tag';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag
  WHERE tag_name = 'assert02Climate'
    AND role = 'semantic'
    AND rdf_id = 'wd:Q7937'
    AND is_active
),
  'Error: gvlt.tag_include did not upsert the expected tag';
ASSERT gvlt.tagobj_include(
  'assert02Climate',
  ARRAY[
    'assert02_obj.alias_relation',
    'assert02_obj.alias_relation.climate_avg'
  ]
),
  'Error: gvlt.tagobj_include(text,text[]) should tag all listed objects';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert02_obj.alias_relation'
    AND tag_name = 'assert02Climate'
    AND is_active
),
  'Error: gvlt.tagobj_include did not tag the relation object';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'assert02_obj.alias_relation.climate_avg'
    AND tag_name = 'assert02Climate'
    AND is_active
),
  'Error: gvlt.tagobj_include did not tag the column object';
ASSERT gvlt.obj_has_tags('assert02_obj.alias_relation', ARRAY['assert02Climate']),
  'Error: gvlt.obj_has_tags should detect active object tags';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.obj_tags('assert02_obj.alias_relation')
  WHERE tag_name = 'assert02Climate'
    AND role = 'semantic'
),
  'Error: gvlt.obj_tags did not list the expected active object tag';
ASSERT gvlt.usecase_assert_obj_tags('SpCsAssert02', 'assert02_obj.alias_relation', ARRAY['assert02Climate']),
  'Error: gvlt.usecase_assert_obj_tags should return true when tags are present';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_get('assert02Climate')
  WHERE role = 'semantic'
    AND is_active
),
  'Error: gvlt.tag_get did not return the expected tag';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_search('climate', 'semantic')
  WHERE tag_name = 'assert02Climate'
),
  'Error: gvlt.tag_search did not find the expected tag';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.governance_check()
  WHERE check_name = 'active_relation_tag_without_relation'
    AND obj_name = 'assert02_obj.alias_relation'
),
  'Error: gvlt.governance_check should flag active tags on missing relations';
ASSERT gvlt.tagobj_disable('assert02_obj.alias_relation', ARRAY['assert02Climate']),
  'Error: gvlt.tagobj_disable should deactivate an active object/tag association';
ASSERT NOT gvlt.obj_has_tags('assert02_obj.alias_relation', ARRAY['assert02Climate']),
  'Error: gvlt.obj_has_tags should ignore inactive object/tag associations';
ASSERT gvlt.tagobj_include('assert02Climate', ARRAY['assert02_obj.alias_relation']),
  'Error: gvlt.tagobj_include should reactivate disabled object/tag associations';
ASSERT gvlt.tag_disable('assert02Climate', 'assert02 lifecycle test'),
  'Error: gvlt.tag_disable should deactivate an existing tag';
ASSERT NOT gvlt.obj_has_tags('assert02_obj.alias_relation', ARRAY['assert02Climate']),
  'Error: gvlt.obj_has_tags should ignore inactive governed tags';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_get('assert02Climate')
  WHERE NOT is_active
),
  'Error: gvlt.tag_disable did not mark the tag inactive';
ASSERT gvlt.tag_include(
  'assert02Climate',
  'semantic',
  'Assert02 climate semantic tag',
  'wd:Q7937'
),
  'Error: gvlt.tag_include should reactivate an inactive tag';
EXECUTE 'CREATE TABLE public.assert02_cols(id int, name text)';
ASSERT gvlt.tagobj_include('ID', ARRAY['public.assert02_cols.id']),
  'Error: gvlt.tagobj_include should tag a physical test column';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.relation_columns('assert02_cols')
  WHERE column_name = 'id'
    AND tags = ARRAY['ID']::text[]
),
  'Error: gvlt.relation_columns did not report active column tags';
EXECUTE 'DROP TABLE public.assert02_cols';

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
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.medallion_objects('t_bronze')
  WHERE obj_name = 't_bronze'
    AND obj_type = 'schema'
    AND medallion_tag = 'Bronze'
),
  'Error: gvlt.medallion_objects did not list the Medallion schema';

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

v_text := gvlt.medallion_upsert('assert02_plain_schema');
ASSERT v_text LIKE 'ERRO:%',
  'Error: gvlt.medallion_upsert(non-medallion schema) should return error';
ASSERT NOT EXISTS (
  SELECT 1
  FROM information_schema.schemata
  WHERE schema_name = 'assert02_plain_schema'
),
  'Error: gvlt.medallion_upsert(non-medallion schema) should not create schema';

EXECUTE 'CREATE SCHEMA tsttmp_silver';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_silver'
    AND tag_name = 'TSTTMP'
    AND is_active
),
  'Error: schema-tags CREATE SCHEMA event trigger did not register TSTTMP tag';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_silver'
    AND tag_name = 'Silver'
    AND is_active
),
  'Error: schema-tags CREATE SCHEMA event trigger did not register Silver tag';
EXECUTE 'DROP SCHEMA tsttmp_silver';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_silver'
    AND tag_name = 'TSTTMP'
    AND NOT is_active
),
  'Error: schema-tags DROP SCHEMA event trigger did not deactivate TSTTMP tag';
ASSERT EXISTS (
  SELECT 1
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_silver'
    AND tag_name = 'Silver'
    AND NOT is_active
),
  'Error: schema-tags DROP SCHEMA event trigger did not deactivate Silver tag';

EXECUTE 'CREATE SCHEMA tsttmp_stage_bronze';
ASSERT (
  SELECT array_agg(tag_name ORDER BY tag_name)
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_stage_bronze'
    AND is_active
) = '{Bronze,Stage,TSTTMP}'::text[],
  'Error: schema-tags CREATE SCHEMA event trigger did not register all governed schema tags';
EXECUTE 'DROP SCHEMA tsttmp_stage_bronze';
ASSERT (
  SELECT count(*) = 3 AND bool_and(NOT is_active)
  FROM gvlt.tag_obj
  WHERE obj_name = 'tsttmp_stage_bronze'
    AND tag_name IN ('TSTTMP', 'Stage', 'Bronze')
),
  'Error: schema-tags DROP SCHEMA event trigger did not deactivate all governed schema tags';

-- Cleanup after successful assertions.
EXECUTE 'DROP SCHEMA IF EXISTS t_bronze CASCADE';
EXECUTE 'DROP SCHEMA IF EXISTS tsttmp_silver CASCADE';
EXECUTE 'DROP SCHEMA IF EXISTS tsttmp_stage_bronze CASCADE';
DELETE FROM gvlt.tag_obj WHERE obj_name LIKE 'assert02%';
DELETE FROM gvlt.tag_obj WHERE obj_name LIKE 'public.assert02_cols%';
DELETE FROM gvlt.tag_obj WHERE obj_name IN ('t_bronze', 'tsttmp_silver', 'tsttmp_stage_bronze');
DELETE FROM gvlt.tag WHERE tag_name = 'assert02Climate';

END $do$;

SELECT * FROM gvlt.vw01_medallion; -- show current tags (expected demo list)

-- create schema com:
CREATE SCHEMA q_bronze;  CREATE SCHEMA q_silver;   CREATE SCHEMA q_gold;
-- create schema sem:
CREATE SCHEMA q_bronze_q; CREATE SCHEMA q_prata; CREATE SCHEMA q_gold_q;

SELECT * FROM gvlt.vw01_medallion; -- listando

-- create table com:
CREATE TABLE q_bronze.t (x int);  CREATE TABLE q_silver.t (x int);   CREATE TABLE q_gold.t (x int);
-- create table sem:
CREATE TABLE q_bronze_q.t (x int); CREATE TABLE q_prata.t (x int);

CREATE SCHEMA semTag_bronze;
SELECT gvlt.medallion_upsert('q_bronze','{"q":0}');
SELECT gvlt.medallion_upsert('TSTDEMO_silver','{"x":1}');
SELECT gvlt.medallion_upsert('geo_gold','{"y":2}');

SELECT * FROM gvlt.vw01_medallion; -- listando

-- drop schema com:
DROP SCHEMA test_bronze;  DROP SCHEMA test_silver;   DROP SCHEMA test_gold;
-- drop schema sem:
DROP SCHEMA test_bronze_test; DROP SCHEMA test_prata; DROP SCHEMA test_gold_test;

SELECT * FROM gvlt.vw01_medallion; -- listando

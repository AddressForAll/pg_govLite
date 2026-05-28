--
-- Executable examples for:
-- pg_govLite User Manual and Practical Governance Tutorial
--
-- Purpose:
--   Run the public-health tutorial flow described in the manual using a
--   small built-in sample modeled after public IBGE/ANS data.
--
-- Requirements:
--   Run the pg_govLite installation first, for example:
--     make core
--
-- Notes:
--   This script intentionally does not download public data. It uses a small
--   deterministic sample so the tutorial can run in CI, local development, or
--   a clean PostgreSQL database without network access.
--

\echo '--- pg_govLite manual examples: public health tutorial ---'

DO $do$
DECLARE
  r record;
BEGIN
  IF to_regclass('gvlt.doc_examples') IS NOT NULL THEN
    FOR r IN
      SELECT view_schema, view_name
      FROM gvlt.doc_examples
      WHERE payload LIKE '%geo_silver.ibge_municipality%'
    LOOP
      EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', r.view_schema, r.view_name);
    END LOOP;

    DELETE FROM gvlt.doc_examples
    WHERE payload LIKE '%geo_silver.ibge_municipality%';
  END IF;
END
$do$;

DROP SCHEMA IF EXISTS hlth_gold CASCADE;
DROP SCHEMA IF EXISTS hlth_silver CASCADE;
DROP SCHEMA IF EXISTS hlth_bronze CASCADE;
DROP SCHEMA IF EXISTS geo_silver CASCADE;
DROP SCHEMA IF EXISTS geo_bronze CASCADE;

DELETE FROM gvlt.tag_obj
WHERE obj_name LIKE 'hlth_%'
   OR obj_name LIKE 'geo_%';

\echo '--- Step 1: define the governed health domain ---'

INSERT INTO gvlt.tag (tag_name, role, tag_desc, rdf_id, ctrl_config)
VALUES (
  'HLTH',
  'macrodomain',
  'Public and supplementary health data domain',
  NULL,
  '{"descr_expand":"Health data domain for public-interest analysis","lang":"en"}'::jsonb
)
ON CONFLICT (tag_name) DO UPDATE
SET tag_desc = EXCLUDED.tag_desc,
    ctrl_config = COALESCE(EXCLUDED.ctrl_config, gvlt.tag.ctrl_config),
    is_active = true;

\echo '--- Step 2: create Medallion schemas ---'

CREATE SCHEMA geo_bronze;
CREATE SCHEMA geo_silver;
CREATE SCHEMA hlth_bronze;
CREATE SCHEMA hlth_silver;
CREATE SCHEMA hlth_gold;

SELECT obj_name, tag_name, is_active
FROM gvlt.tag_obj
WHERE obj_name IN ('geo_bronze','geo_silver','hlth_bronze','hlth_silver','hlth_gold')
ORDER BY obj_name, tag_name;

\echo '--- Step 3: create Bronze landing tables ---'

CREATE TABLE geo_bronze.ibge_municipality_raw (
  source_url text NOT NULL,
  loaded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ibge_municipality_id bigint,
  municipality_name text,
  state_abbrev text,
  raw_payload jsonb
);

CREATE TABLE hlth_bronze.ans_operator_raw (
  source_url text NOT NULL,
  loaded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  operator_registration text,
  operator_name text,
  municipality_id bigint,
  raw_payload jsonb
);

\echo '--- Step 4: load deterministic public-data sample rows ---'

INSERT INTO geo_bronze.ibge_municipality_raw (
  source_url,
  ibge_municipality_id,
  municipality_name,
  state_abbrev,
  raw_payload
) VALUES
  (
    'https://servicodados.ibge.gov.br/api/v1/localidades/municipios',
    3304557,
    'Rio de Janeiro',
    'RJ',
    '{"id":3304557,"nome":"Rio de Janeiro","uf":"RJ"}'::jsonb
  ),
  (
    'https://servicodados.ibge.gov.br/api/v1/localidades/municipios',
    3550308,
    'Sao Paulo',
    'SP',
    '{"id":3550308,"nome":"Sao Paulo","uf":"SP"}'::jsonb
  ),
  (
    'https://servicodados.ibge.gov.br/api/v1/localidades/municipios',
    5300108,
    'Brasilia',
    'DF',
    '{"id":5300108,"nome":"Brasilia","uf":"DF"}'::jsonb
  );

INSERT INTO hlth_bronze.ans_operator_raw (
  source_url,
  operator_registration,
  operator_name,
  municipality_id,
  raw_payload
) VALUES
  (
    'https://www.gov.br/ans/pt-br/acesso-a-informacao/perfil-do-setor/dados-abertos-1',
    'ANS-000001',
    'Example Health Operator RJ',
    3304557,
    '{"operator_registration":"ANS-000001","municipality_id":3304557}'::jsonb
  ),
  (
    'https://www.gov.br/ans/pt-br/acesso-a-informacao/perfil-do-setor/dados-abertos-1',
    'ANS-000002',
    'Example Health Operator SP',
    3550308,
    '{"operator_registration":"ANS-000002","municipality_id":3550308}'::jsonb
  ),
  (
    'https://www.gov.br/ans/pt-br/acesso-a-informacao/perfil-do-setor/dados-abertos-1',
    'ANS-000003',
    'Example Health Operator SP 2',
    3550308,
    '{"operator_registration":"ANS-000003","municipality_id":3550308}'::jsonb
  );

\echo '--- Step 5: tag schemas, tables, and columns ---'

SELECT gvlt.govtags_is_include('geo_bronze.ibge_municipality_raw', ARRAY['GEO', 'Stage', 'Tier:3']);
SELECT gvlt.govtags_is_include('hlth_bronze.ans_operator_raw', ARRAY['HLTH', 'Stage', 'Organization.Medical', 'Tier:3']);
SELECT gvlt.govtags_is_include('geo_bronze.ibge_municipality_raw.ibge_municipality_id', ARRAY['ID', 'GEO']);
SELECT gvlt.govtags_is_include('hlth_bronze.ans_operator_raw.operator_registration', ARRAY['ID', 'Organization.Medical']);

\echo '--- Step 6: build Silver curated tables ---'

CREATE TABLE geo_silver.ibge_municipality AS
SELECT DISTINCT
  ibge_municipality_id,
  municipality_name,
  upper(state_abbrev) AS state_abbrev
FROM geo_bronze.ibge_municipality_raw
WHERE ibge_municipality_id IS NOT NULL;

CREATE TABLE hlth_silver.ans_operator AS
SELECT DISTINCT
  operator_registration,
  operator_name,
  municipality_id AS ibge_municipality_id
FROM hlth_bronze.ans_operator_raw
WHERE operator_registration IS NOT NULL;

SELECT gvlt.govtags_is_include('geo_silver.ibge_municipality', ARRAY['GEO', 'Tier:2']);
SELECT gvlt.govtags_is_include('hlth_silver.ans_operator', ARRAY['HLTH', 'Organization.Medical', 'Tier:2']);

\echo '--- Step 7: publish a Gold data product ---'

CREATE VIEW hlth_gold.vw_municipality_health_access AS
SELECT
  m.ibge_municipality_id,
  m.municipality_name,
  m.state_abbrev,
  count(DISTINCT o.operator_registration) AS active_operator_count
FROM geo_silver.ibge_municipality m
LEFT JOIN hlth_silver.ans_operator o
  ON o.ibge_municipality_id = m.ibge_municipality_id
GROUP BY
  m.ibge_municipality_id,
  m.municipality_name,
  m.state_abbrev;

COMMENT ON VIEW hlth_gold.vw_municipality_health_access
IS 'Gold data product joining IBGE municipality reference data with ANS supplementary-health operator context.';

SELECT gvlt.govtags_is_include(
  'hlth_gold.vw_municipality_health_access',
  ARRAY['HLTH', 'GEO', 'Gold', 'Prod', 'isProduct', 'Tier:1']
);

SELECT *
FROM hlth_gold.vw_municipality_health_access
ORDER BY state_abbrev, municipality_name;

\echo '--- Step 8: inspect governance metadata ---'

SELECT obj_name, tag_name, is_active
FROM gvlt.vw01_medallion
WHERE obj_name IN ('geo_bronze','geo_silver','hlth_bronze','hlth_silver','hlth_gold')
ORDER BY obj_name, tag_name;

SELECT obj_name, role, tags
FROM gvlt.vw03_gtag_obj_active
WHERE obj_name LIKE 'hlth_%'
ORDER BY obj_name, role;

SELECT obj_name, tags
FROM gvlt.vw02_stag_obj_active
WHERE obj_name LIKE '%.operator_registration'
   OR obj_name LIKE '%.ibge_municipality_id'
ORDER BY obj_name;

\echo '--- Step 9: register an executable documentation example ---'

SELECT gvlt.doc_examples_add($$
  SELECT state_abbrev, count(*) AS municipality_count
  FROM geo_silver.ibge_municipality
  GROUP BY state_abbrev
  ORDER BY municipality_count DESC
$$);

SELECT view_name, payload
FROM gvlt.doc_examples
WHERE payload LIKE '%geo_silver.ibge_municipality%'
ORDER BY id;

\echo '--- Final checks ---'

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM gvlt.tag_obj
    WHERE obj_name = 'hlth_gold.vw_municipality_health_access'
      AND tag_name = 'isProduct'
      AND is_active
  ) THEN
    RAISE EXCEPTION 'Manual example failed: Gold data product is not tagged as isProduct';
  END IF;

  IF (
    SELECT active_operator_count
    FROM hlth_gold.vw_municipality_health_access
    WHERE ibge_municipality_id = 3550308
  ) != 2 THEN
    RAISE EXCEPTION 'Manual example failed: Sao Paulo expected active_operator_count = 2';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM gvlt.doc_examples
    WHERE payload LIKE '%geo_silver.ibge_municipality%'
  ) THEN
    RAISE EXCEPTION 'Manual example failed: documentation example was not registered';
  END IF;
END
$do$;

SELECT '--- MANUAL PUBLIC HEALTH TUTORIAL EXAMPLES FINISHED ---' AS final_message;

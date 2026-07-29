-- Framework's Core

DROP SCHEMA IF EXISTS gvlt CASCADE;
CREATE SCHEMA gvlt;  -- GovLite

--------------------------
--------------------------
-- gvlt - the Framework's internal Catalog.

-- All governance and namespace validation registered by tags, so we start with this tag module.
CREATE TABLE gvlt.role_config ( -- Governance Rules configuration
  role_name text NOT NULL PRIMARY KEY CHECK( trim(lower(role_name))=role_name ),
  role_desc text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,  -- need explicit user activation
  external_name text, -- null for Core modules like medallion.
  config jsonb  -- like Apache Ranger policy JSON, all Data Governance Rules and configurations. see https://ranger.apache.org/blogs/policy_model.html  and https://docs.arenadata.io/en/ADPS/current/how-to/ranger/configure_policies.html
);
-- Examples: tier, medallion, purpose, semantic_ABAC, ... some Core other External controll modules.
INSERT INTO gvlt.role_config (role_name,role_desc,config) VALUES -- Exemplos para teste:
   ('macrodomain',  'Name or acronym of a Macro-Domain, sense Domain Data Mesh',
    '{"in_name":true}' -- mandatory on object's name
    ),
   ('dq',           'Data Quality',                 NULL),
   ('medallion',    'Medallion layers',            '{"in_name":true}'),
   ('purpose',      'Prod/Dev/Stage/Backup layers', NULL),
   ('semantic',     'Semantic controll',            NULL),
   ('dsec',         'Data Security',                NULL),
   ('dprod',        'Data Product',                 NULL)
;

-- All rule_tag's:
CREATE MATERIALIZED VIEW gvlt.vw01_role_config_strings AS
  SELECT array_agg(role_name) all_rules FROM gvlt.role_config WHERE is_active
;
-- for check is_active rules, for example CASE WHEN x=ANY((SELECT all_rules FROM gvlt.vw01_rule_configs_string)) ...

-------------------------
CREATE TABLE gvlt.rdf_voc ( -- Governance of REF Vocabularies, for Semantic Controll:
  -- see https://lov.linkeddata.es/dataset/lov/
  voc_prefix text NOT NULL PRIMARY KEY CHECK( trim(lower(voc_prefix))=voc_prefix ),
  voc_name text NOT NULL, -- Title or popular name
  voc_url text NOT NULL, -- canonic URL of the vocabulary
  is_active boolean NOT NULL DEFAULT true,  -- need explicit user activation
  info jsonb  -- like Apache Ranger policy JSON, all Data Governance Rules and configurations. see https://ranger.apache.org/blogs/policy_model.html  and https://docs.arenadata.io/en/ADPS/current/how-to/ranger/configure_policies.html
);
INSERT INTO gvlt.rdf_voc (voc_prefix,voc_name,voc_url) VALUES -- Exemplos para teste:
   ('sc',   'SchemaOrg', 'https://schema.org'),
   ('wd',   'Wikidata',  'https://wikidata.org'),
   ('dcat', 'W3C DCAT',  'https://www.w3.org/TR/vocab-dcat-3')
;

CREATE FUNCTION gvlt.rdf_prefix_valid(text) RETURNS boolean
language SQL IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT $1 ~ '^(sh|wd|dcat):'; -- see and update from gvlt.rdf_voc table
END;

---------------------
CREATE TABLE gvlt.tag ( -- Governed tags
  tag_name text NOT NULL PRIMARY KEY  CHECK( trim(tag_name)=tag_name ),
  role text NOT NULL REFERENCES gvlt.role_config(role_name),
  tag_desc text NOT NULL,
  rdf_id text  CHECK( rdf_id IS NULL OR (rdf_id IS NOT NULL AND gvlt.rdf_prefix_valid(rdf_id) AND trim(rdf_id)=rdf_id) ),
  is_active boolean NOT NULL DEFAULT true,  -- need explicit user activation
  info        JSONb, -- all metadata here!
  ctrl_config JSONb  -- only internal controlls
);
CREATE UNIQUE INDEX lower_case_tag ON gvlt.tag((lower(tag_name)))
;

INSERT INTO gvlt.tag (tag_name,role,tag_desc,rdf_id,ctrl_config) VALUES -- Exemplos para teste:
   ('CPF',   'semantic', 'Código da Pessoa Fisica', 'wd:Q5016244','{"lang":"pt"}'),
   ('CNPJ',  'semantic', 'Cadastro Nacional da Pessoa Juridica', 'wd:Q15816867','{"lang":"pt"}'),
   ('vatID', 'semantic', 'CPF ou CNPJ ou gringo', 'sh:vatID',NULL),
   ('ID',    'semantic', 'Identificador qualquer', 'sh:identifier',NULL),
   ('Organization', 'semantic',  'Identificador qualquer', 'sh:Person','{"is_word":1}'),
   ('Organization.Medical', 'semantic',  'Identificador qualquer', 'sh:MedicalOrganization','{"is_word":1}'),
   ('Person', 'semantic',     'Identificador qualquer', 'sh:Person','{"is_word":1}'),
   ('CLIPJ',  'macrodomain',  'Cliente PJ', NULL,'{"descr_expand":"Domínio de Dados do Cliente Pessoa Jurídica","lang":"pt","BoundedContext":"CRM-operations","semantic":"sh:customer of sh:Organization"}'),
   ('CLIPF',  'macrodomain',  'Clinte PF', NULL,'{"descr_expand":"Domínio de Dados do Cliente Pessoa Física","lang":"pt","BoundedContext":"CRM-operations","semantic":"sh:customer of sh:Person"}'),
   ('GEO',    'macrodomain',  'Geo', NULL,'{"descr_expand":"Domínio de Dados Estritamente Geográficos","lang":"pt","BoundedContext":"SIG-operations","semantic":"sh:geo"}'),
   ('TSTTMP', 'macrodomain',  'TesteTemp', NULL,'{"descr_expand":"Domínio de Dados para Teste Temporário","lang":"pt","BoundedContext":"Test-operations","semantic":"wd:Q188522"}'),
   ('TSTDEMO','macrodomain',  'TesteDemo', NULL,'{"descr_expand":"Domínio de Dados para Teste Demonstrativo (Benckmarks e Tutoriais)","lang":"pt","BoundedContext":"Test-operations","semantic":"wd:Q816747 and wd:Q535741"}'),
   ('isPII', 'dsec',  'Is Personally Identifiable Information', NULL,'{"on_objects":["column","relation"]}'),
   ('isProduct','dprod', 'Is Data Product', NULL,'{"on_objects":["relation"],"on_medallion":["s","g"]}'),
   ('Tier',  'dq', 'Tier', NULL, '{"default_value":4,"on_objects":["relation","schema","database","function"]}'),
     ('Tier:1','dq', 'Tier I', NULL, NULL),
     ('Tier:2','dq', 'Tier II', NULL, NULL),
     ('Tier:3','dq', 'Tier III', NULL, NULL),
     ('Tier:4','dq', 'Tier IV', NULL, NULL),  -- generates cache "tag_values":[1,2,3,4].
   ('Bronze', 'medallion', 'Medallion Bronze', NULL,'{"on_objects":["schema","database"]}'),
   ('Silver', 'medallion', 'Medallion Silver', NULL,'{"on_objects":["schema","database"]}'),
   ('Gold',   'medallion', 'Medallion Gold', NULL,'{"on_objects":["schema","database"]}'),
   ('Prod',   'purpose', 'Data Product, ready for delivery', NULL,'{"on_objects":["schema","database","relation"]}'),
   ('Stage',  'purpose', 'Staging data, temporarily storing raw data', NULL,'{"on_objects":["schema","database","relation"]}'),
   ('Dev',    'purpose', 'Data Under Development or temporarily storing for tests', NULL,'{"on_objects":["schema","database","relation"]}'),
   ('Bkp',    'purpose', 'Backup storing', NULL,'{"on_objects":["schema","database","relation"]}')
;
-- All role are controled terms, with Data Governance Glossary semantic.
--
-- Stage can be Dev or Prod, but always Bronze. Medallion and purpose on databases or schemas must be explicit in the name (for example "xpto_stage_bronze").
-- Bkp Recommendation is to be explicit in the name with version or date, "xpto_bkp2026" or "xpto_bkp_v2".
--- Versioning by name, "_v2" or "_v1_1_2" is a rule that can be actived or not

-- tags com rdf_id IS NULL são necessariamente de controle, com valor obrigatório em info->>'role'.
   -- select tag_name, info->>'role' as role from gvlt.tag WHERE rdf_id IS NULL;
-- tags baseadas em tag_name-valor possuem obrigatoriamente info->'tag_values'
   -- select g.tag_name, array_agg(t.j) as text_array_values from gvlt.tag g, LATERAL jsonb_array_elements_text(g.info->'tag_values') t(j) where g.has_values group by 1;
-- As tags de controle, tais como "macrodomain", requerem presença em tabela principal e relação controlada por trigger.
-- As siglas de macrodomain só podem ter letras maiúsculas e no máximo 8 letras. O conjunto de domínios, no máximo 100 a cada 1000 tabelas.
-- Dados Silver e Gold podem receber isProduct, Bronze não (basta criar view da tabela Bronze na Prata se for equivalente). Ideal apenas Gold.

CREATE VIEW gvlt.vw01_tag AS
  SELECT g.role,
         g.tag_name,
         g.rdf_id,
         g.tag_type,
         g.tag_desc || ' [' || r.role_desc || ']' AS tag_desc
  FROM (
    SELECT role,
           tag_name,
           rdf_id,
           CASE WHEN tag_name ~ '\.' THEN 'hierarchical' ELSE 'simple' END
           || CASE WHEN tag_name ~ ':' THEN ' valued' ELSE '' END AS tag_type,
           tag_desc
    FROM gvlt.tag
  ) g
  INNER JOIN gvlt.role_config r
    ON r.role_name = g.role
  ORDER BY g.role, g.tag_name
;

CREATE VIEW gvlt.vw01_stag AS
  SELECT tag_name,
         rdf_id,
         CASE WHEN tag_name ~ '\.' THEN 'hierarchical' ELSE 'simple' END
         || CASE WHEN tag_name ~ ':' THEN ' valued' ELSE '' END AS tag_type,
         tag_desc
  FROM gvlt.tag
  WHERE role = 'semantic'
;

CREATE VIEW gvlt.vw01_gtag AS
  SELECT role,
         tag_name,
         rdf_id,
         tag_type,
         tag_desc
  FROM gvlt.vw01_tag
  WHERE role != 'semantic'
;

--- tag controll:
CREATE or replace FUNCTION gvlt.govtags_fail(p_tags text[]) RETURNS text[] AS $f$
   SELECT array_agg(tag_name) -- not found tags
   FROM (
     SELECT t.tag_name, g.tag_name as tag
     FROM (
        SELECT lower(trim(UNNEST(p_tags))) AS tag_name
     ) t LEFT JOIN gvlt.tag g
     ON t.tag_name=lower(g.tag_name)
     ORDER BY t.tag_name
  ) tt
  WHERE tag IS NULL
$f$ LANGUAGE SQL;

CREATE FUNCTION gvlt.govtags_exists(p_new_tag text) RETURNS boolean AS $f$
  SELECT gvlt.govtags_fail(array[p_new_tag]) IS NULL
$f$ LANGUAGE SQL;
CREATE FUNCTION gvlt.govtags_exists(p_new_tags text[]) RETURNS boolean AS $f$
  SELECT gvlt.govtags_fail(p_new_tags) IS NULL
$f$ LANGUAGE SQL;

CREATE FUNCTION gvlt.govtags_normalize (p_tags text[]) RETURNS text[] AS $f$
-- !RENOMEAR para govtag_list_normalize()
   -- garante ordem padronizada e consistência com tag vigente.
   SELECT array_agg(tag_name ORDER BY lower(tag_name))
   FROM (
     SELECT DISTINCT g.tag_name
     FROM (
        SELECT lower(trim(UNNEST(p_tags))) AS tag_name
     ) t INNER JOIN gvlt.tag g
     ON t.tag_name=lower(g.tag_name)
  ) tt
$f$ LANGUAGE SQL;
-- SELECT gvlt.govtags_normalize(array['CPf','cnpj','xpto','vatid']);

CREATE FUNCTION gvlt.govtags_normalize (p_jtags jsonb) RETURNS text[] AS $f$
  SELECT gvlt.govtags_normalize( jsonb_array_to_text_array(p_jtags) )
$f$ LANGUAGE SQL;
-- SELECT gvlt.add_example($$ SELECT gvlt.govtags_normalize('["CPf","cnpj","xpto","vatid"]'::jsonb); $$);

-- Gestão das tags de um objeto:
CREATE FUNCTION gvlt.govtag_list_include(p_tags text[], p_new_tag text) RETURNS text[] AS $f$
  SELECT gvlt.govtags_normalize(p_tags || p_new_tag)
$f$ LANGUAGE SQL;
CREATE FUNCTION gvlt.govtag_list_include(p_tags text[], p_new_tags text[]) RETURNS text[] AS $f$
    SELECT gvlt.govtags_normalize(p_tags || p_new_tags)
$f$ LANGUAGE SQL;

CREATE FUNCTION gvlt.govtag_list_exclude(p_tags text[], p_drop_tag text) RETURNS text[] AS $f$
  SELECT array_remove(p_tags,p_drop_tag)
$f$ LANGUAGE SQL;

CREATE FUNCTION gvlt.govtag_list_exclude(p_tags text[], p_drop_tags text[]) RETURNS text[] AS $f$
  SELECT gvlt.govtags_normalize( -- precisa? conferir se perde ordem
       ARRAY(SELECT unnest(p_tags) EXCEPT SELECT unnest(p_drop_tags))
  )
$f$ LANGUAGE SQL;

--------------------------------------

CREATE or replace FUNCTION gvlt.schema_name_validate(p_schema_name text) RETURNS text AS $f$
  -- old gvlt.medallion_schema_getype()
  -- otimizar no futuro
WITH a AS ( -- analysing:
 SELECT t.*, g.*
 FROM string_to_table(trim(p_schema_name,'_'),'_') WITH ORDINALITY t(p,i)
 LEFT JOIN gvlt.vw01_tag g
 ON lower(t.p)=lower(g.tag_name)
), mx AS (SELECT max(i) max_i FROM a)
 , chk1 AS (
 SELECT CASE
          WHEN i=max_i AND role='medallion' THEN a.tag_name
          ELSE '-'
        END               AS medallin_type,
        length(p)=1       AS is_1letter,
        a.tag_name is not null AS is_valid
 FROM a,mx
 )
   SELECT CASE
    WHEN EXISTS(SELECT 1 FROM chk1 WHERE medallin_type != '-') THEN  -- is_medallin
      CASE
        WHEN (SELECT COUNT(*) FROM a) = (SELECT COUNT(*) FROM chk1 WHERE is_1letter OR is_valid)
        THEN (SELECT medallin_type FROM chk1 WHERE medallin_type != '-')
        ELSE '!' -- not valid
      END
    ELSE NULL -- NOT(is_medallion)
    END
$f$ LANGUAGE SQL;
COMMENT ON FUNCTION gvlt.schema_name_validate
  IS 'Check vality of schema name: false=is_medallion not valid; true=is_medallion valid; NULL=NOT(is_medallion).'
;
-- select x, gvlt.schema_name_validate(x) from unnest(array['p_bronze','geo_silver','bronze_p','silver_geo','xpto_silver','zpto_gold']) t(x);

CREATE or replace FUNCTION gvlt.schema_name_nontag(p_schema_name text) RETURNS text[] AS $f$
 SELECT array_agg(t.p)
 FROM string_to_table(trim(p_schema_name,'_'),'_') WITH ORDINALITY t(p,i)
 LEFT JOIN gvlt.vw01_tag g
 ON lower(t.p)=lower(g.tag_name)
 WHERE g.tag_name IS NULL
$f$ LANGUAGE SQL;
-- select gvlt.schema_name_nontag('xpto_silver');


-- Criar funções!
--SELECT gvlt.tag_obj_remove('objeto','tag')
--SELECT gvlt.tag_obj_upsert('objeto','tag')

----------------------------------------

-- depois criar materializada com apenas <obj_name, tags text[]>.

CREATE TABLE gvlt.tag_obj( -- associating object with tag:
   obj_name text NOT NULL CHECK( lower(trim(obj_name))=obj_name AND lib.object_getype(obj_name) IS NOT NULL ),
   obj_id   bigint,  -- internal use, controlling existence and rename actions.
   tag_name text NOT NULL REFERENCES gvlt.tag(tag_name),
   is_active boolean NOT NULL DEFAULT true,
   ctrl_config JSONb,  -- only controlls, no user metadata
   UNIQUE(obj_name,tag_name) -- PK
);

CREATE VIEW gvlt.vw01_tag_obj AS
  SELECT t.is_active,
         lib.object_getype(t.obj_name) otype, -- s,r or c
         t.obj_name,
         g.role,
         array_agg(t.tag_name) as tags
  FROM gvlt.tag_obj t
  LEFT JOIN gvlt.tag g
  ON g.tag_name=t.tag_name
  GROUP BY 1,2,3,4
  ORDER BY 1,2,3,4
;

-- Isolating active Semantic tags (STAGs) and Governed tags (GTAGs):

CREATE VIEW gvlt.vw02_stag_obj_active AS
  SELECT otype, obj_name, tags
  FROM gvlt.vw01_tag_obj
  WHERE is_active AND role='semantic'
;

CREATE VIEW gvlt.vw03_gtag_obj_active AS
  SELECT otype, obj_name, role, tags
  FROM gvlt.vw01_tag_obj
  WHERE is_active AND role!='semantic'
;

--------------------------
-- Other VIEWs and functions.

CREATE VIEW gvlt.vw01_relations AS
  SELECT
      n.nspname AS schema_name,
      c.relname AS relation_name,
      c.relkind
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'v', 'm') -- more?
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  ORDER BY schema_name, relkind, relation_name
;
CREATE FUNCTION gvlt.rel_getname(
     p_relname text,
     p_schemaname text DEFAULT NULL
) RETURNS text AS $f$
    SELECT CASE
       WHEN strpos($1, '.')>0 THEN $1
       WHEN $2 IS NULL THEN 'public.'||$1
       ELSE $2||'.'||$1
    END  -- ::regclass
$f$ LANGUAGE SQL;

CREATE FUNCTION gvlt.rel_description(
     p_relname text,
     p_schemaname text DEFAULT NULL
) RETURNS text AS $f$
    SELECT obj_description(gvlt.rel_getname(p_relname,p_schemaname)::regclass, 'pg_class');
$f$ LANGUAGE SQL;

-- ===============================================================
-- Teste simulando enriquecimento das tags governadas de exemplo: depois ou antes dos triggers??
/*
INSERT INTO gvlt.tag (tag_name, tag_values, tag_desc, rdf_id) VALUES
('Person', NULL, 'Representacao de pessoa', 'sh:Person')
ON CONFLICT (tag_name) DO UPDATE
SET tag_values = COALESCE(EXCLUDED.tag_values, gvlt.tag.tag_values),
    tag_desc = COALESCE(NULLIF(EXCLUDED.tag_desc, ''), gvlt.tag.tag_desc),
    rdf_id = COALESCE(NULLIF(EXCLUDED.rdf_id, ''), gvlt.tag.rdf_id);
*/
-- ===============================================================
-- Normalizacao canonica de tags (com suporte a especializacao e tag:valor).
-- Ex.: CPf -> CPF, cnpj:123 -> CNPJ:123, mdl.bronze (se mdl governada) -> mdl.bronze.

-- ===============================================================
-- Inclusao de tags por nome de objeto catalogado (schema, tabela ou coluna).
-- p_obj_name exemplos: s, s.t, s.t.c

CREATE OR REPLACE FUNCTION gvlt.govtags_is_include(
  -- conferir relação com govtags_include() e casos de uso.
    p_obj_name text,
    p_tags_to_add text[]
) RETURNS boolean AS $$
DECLARE
    v_obj_name text;
    v_normalized_tags text[];
BEGIN
    v_obj_name := lower(trim(p_obj_name));
    v_normalized_tags := gvlt.govtags_normalize(p_tags_to_add);

    IF v_obj_name IS NULL OR v_obj_name = '' OR lib.object_getype(v_obj_name) IS NULL THEN
        RAISE WARNING 'Objeto invalido para tagging: %', p_obj_name;
        RETURN false;
    END IF;

    IF array_length(v_normalized_tags, 1) IS NULL THEN
        RAISE WARNING 'Nenhuma das tags fornecidas e governada valida.';
        RETURN false;
    END IF;

    INSERT INTO gvlt.tag_obj (obj_name, tag_name)
    SELECT v_obj_name, unnest(v_normalized_tags)
    ON CONFLICT (obj_name, tag_name)
    DO UPDATE
       SET is_active = true;

    RETURN true;
END;
$$ LANGUAGE plpgsql;

-- tag-objeto medalhão.

CREATE VIEW gvlt.vw01_medallion AS
  SELECT o.*, t.tag_desc
  FROM gvlt.tag_obj o INNER JOIN gvlt.tag t
    ON o.tag_name=t.tag_name
  WHERE t.is_active AND o.is_active AND t.role='medallion' AND lib.object_getype(o.obj_name)='s'
;

-- ===============================================================
-- View de apoio: glossario de tags aplicadas no catalogo de objetos.

/* revisar questão dos sepaadores e das tags compostas

CREATE OR REPLACE VIEW gvlt.vw_applied_tags_glossary AS
SELECT
    e.obj_name,
    lib.object_getype(e.obj_name) AS obj_type,
    e.tag_name,
    g.tag_name AS gov_tag_base,
    g.rdf_id AS semantic_uri,
    g.tag_desc AS tag_description
FROM gvlt.tag_obj e
LEFT JOIN gvlt.tag g
       ON lower(g.tag_name) = lower((regexp_split_to_array(e.full_tag, '[\.:]'))[1])
ORDER BY e.obj_name, e.full_tag;
*/

SELECT '--- CORE INSTALL FINESHED ---' final_message;

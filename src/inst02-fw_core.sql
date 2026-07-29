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
COMMENT ON FUNCTION gvlt.schema_name_tags(text)
  IS 'Extract all governed tags from a Medallion schema name, returning NULL for non-Medallion names and {!} when required tags are missing.'
;

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

-- Tutorial/use-case friendly API aliases.
-- Keep the internal govtags_* functions as the implementation surface, while
-- exposing short names for issue-curated use cases.
CREATE OR REPLACE FUNCTION gvlt.tag_include(
    p_tag_name text,
    p_role text,
    p_tag_desc text,
    p_rdf_id text DEFAULT NULL,
    p_ctrl_config jsonb DEFAULT NULL,
    p_info jsonb DEFAULT NULL
) RETURNS boolean AS $$
DECLARE
    v_tag_name text;
    v_existing_tag text;
    v_role text;
    v_tag_desc text;
    v_rdf_id text;
BEGIN
    v_tag_name := trim(p_tag_name);
    v_role := lower(trim(p_role));
    v_tag_desc := trim(p_tag_desc);
    v_rdf_id := NULLIF(trim(p_rdf_id), '');

    IF v_tag_name IS NULL OR v_tag_name = '' THEN
        RAISE WARNING 'Tag invalida para inclusao: %', p_tag_name;
        RETURN false;
    END IF;

    IF v_role IS NULL OR v_role = '' OR NOT EXISTS (
        SELECT 1 FROM gvlt.role_config WHERE role_name = v_role AND is_active
    ) THEN
        RAISE WARNING 'Role invalido para tag %: %', v_tag_name, p_role;
        RETURN false;
    END IF;

    IF v_tag_desc IS NULL OR v_tag_desc = '' THEN
        RAISE WARNING 'Descricao invalida para tag %', v_tag_name;
        RETURN false;
    END IF;

    IF v_rdf_id IS NOT NULL AND NOT gvlt.rdf_prefix_valid(v_rdf_id) THEN
        RAISE WARNING 'RDF id invalido para tag %: %', v_tag_name, v_rdf_id;
        RETURN false;
    END IF;

    SELECT tag_name
    INTO v_existing_tag
    FROM gvlt.tag
    WHERE lower(tag_name) = lower(v_tag_name);

    IF v_existing_tag IS NULL THEN
        INSERT INTO gvlt.tag (
            tag_name,
            role,
            tag_desc,
            rdf_id,
            ctrl_config,
            info
        )
        VALUES (
            v_tag_name,
            v_role,
            v_tag_desc,
            v_rdf_id,
            p_ctrl_config,
            p_info
        );
    ELSE
        UPDATE gvlt.tag
        SET role = v_role,
            tag_desc = v_tag_desc,
            rdf_id = v_rdf_id,
            ctrl_config = COALESCE(p_ctrl_config, gvlt.tag.ctrl_config),
            info = COALESCE(p_info, gvlt.tag.info),
            is_active = true
        WHERE tag_name = v_existing_tag;
    END IF;

    RETURN true;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION gvlt.tagobj_include(
    p_tag_to_add text,
    p_obj_names text[]
) RETURNS boolean AS $$
DECLARE
    v_obj_name text;
    v_ok boolean := true;
BEGIN
    IF array_length(p_obj_names, 1) IS NULL THEN
        RAISE WARNING 'Lista de objetos vazia para tagging.';
        RETURN false;
    END IF;

    IF NOT gvlt.govtags_exists(p_tag_to_add) THEN
        RAISE WARNING 'Tag nao governada para associacao: %', p_tag_to_add;
        RETURN false;
    END IF;

    FOREACH v_obj_name IN ARRAY p_obj_names LOOP
        v_ok := gvlt.govtags_is_include(v_obj_name, ARRAY[p_tag_to_add]) AND v_ok;
    END LOOP;

    RETURN v_ok;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION gvlt.tagobj_include(
    p_tags_to_add text[],
    p_obj_names text[]
) RETURNS boolean AS $$
DECLARE
    v_obj_name text;
    v_ok boolean := true;
BEGIN
    IF array_length(p_obj_names, 1) IS NULL THEN
        RAISE WARNING 'Lista de objetos vazia para tagging.';
        RETURN false;
    END IF;

    IF NOT gvlt.govtags_exists(p_tags_to_add) THEN
        RAISE WARNING 'Uma ou mais tags nao sao governadas para associacao.';
        RETURN false;
    END IF;

    FOREACH v_obj_name IN ARRAY p_obj_names LOOP
        v_ok := gvlt.govtags_is_include(v_obj_name, p_tags_to_add) AND v_ok;
    END LOOP;

    RETURN v_ok;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION gvlt.tag_disable(
    p_tag_name text,
    p_reason text DEFAULT NULL
) RETURNS boolean AS $$
DECLARE
    v_existing_tag text;
BEGIN
    SELECT tag_name
    INTO v_existing_tag
    FROM gvlt.tag
    WHERE lower(tag_name) = lower(trim(p_tag_name));

    IF v_existing_tag IS NULL THEN
        RAISE WARNING 'Tag nao encontrada para desativacao: %', p_tag_name;
        RETURN false;
    END IF;

    UPDATE gvlt.tag
    SET is_active = false,
        info = COALESCE(info, '{}'::jsonb)
          || jsonb_build_object(
               'disabled_at', clock_timestamp(),
               'disabled_reason', NULLIF(trim(p_reason), '')
             )
    WHERE tag_name = v_existing_tag;

    RETURN true;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION gvlt.tagobj_disable(
    p_obj_name text,
    p_tags_to_disable text[] DEFAULT NULL
) RETURNS boolean AS $$
DECLARE
    v_obj_name text;
    v_normalized_tags text[];
    v_rows bigint;
BEGIN
    v_obj_name := lower(trim(p_obj_name));

    IF v_obj_name IS NULL OR v_obj_name = '' OR lib.object_getype(v_obj_name) IS NULL THEN
        RAISE WARNING 'Objeto invalido para desativacao de tagging: %', p_obj_name;
        RETURN false;
    END IF;

    IF p_tags_to_disable IS NULL THEN
        UPDATE gvlt.tag_obj
        SET is_active = false
        WHERE obj_name = v_obj_name
          AND is_active;
    ELSE
        IF NOT gvlt.govtags_exists(p_tags_to_disable) THEN
            RAISE WARNING 'Uma ou mais tags nao sao governadas para desativacao.';
            RETURN false;
        END IF;

        v_normalized_tags := gvlt.govtags_normalize(p_tags_to_disable);

        UPDATE gvlt.tag_obj
        SET is_active = false
        WHERE obj_name = v_obj_name
          AND tag_name = ANY(v_normalized_tags)
          AND is_active;
    END IF;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows = 0 THEN
        RAISE WARNING 'Nenhuma associacao ativa encontrada para desativacao em %', v_obj_name;
        RETURN false;
    END IF;

    RETURN true;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION gvlt.obj_tags(
    p_obj_name text,
    p_only_active boolean DEFAULT true
) RETURNS TABLE(
    obj_name text,
    otype "char",
    tag_name text,
    role text,
    tag_desc text,
    rdf_id text,
    is_active boolean,
    ctrl_config jsonb
) AS $$
    SELECT
        o.obj_name,
        lib.object_getype(o.obj_name) AS otype,
        o.tag_name,
        t.role,
        t.tag_desc,
        t.rdf_id,
        o.is_active,
        o.ctrl_config
    FROM gvlt.tag_obj o
    JOIN gvlt.tag t
      ON t.tag_name = o.tag_name
    WHERE o.obj_name = lower(trim(p_obj_name))
      AND (NOT p_only_active OR (o.is_active AND t.is_active))
    ORDER BY t.role, o.tag_name
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION gvlt.obj_has_tags(
    p_obj_name text,
    p_required_tags text[]
) RETURNS boolean AS $$
DECLARE
    v_obj_name text;
    v_required_tags text[];
BEGIN
    v_obj_name := lower(trim(p_obj_name));

    IF v_obj_name IS NULL OR v_obj_name = '' OR lib.object_getype(v_obj_name) IS NULL THEN
        RETURN false;
    END IF;

    IF array_length(p_required_tags, 1) IS NULL THEN
        RETURN false;
    END IF;

    IF NOT gvlt.govtags_exists(p_required_tags) THEN
        RETURN false;
    END IF;

    v_required_tags := gvlt.govtags_normalize(p_required_tags);

    RETURN NOT EXISTS (
        SELECT 1
        FROM unnest(v_required_tags) r(tag_name)
        WHERE NOT EXISTS (
            SELECT 1
            FROM gvlt.tag_obj o
            JOIN gvlt.tag t
              ON t.tag_name = o.tag_name
            WHERE o.obj_name = v_obj_name
              AND o.tag_name = r.tag_name
              AND o.is_active
              AND t.is_active
        )
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION gvlt.usecase_assert_obj_tags(
    p_case_id text,
    p_obj_name text,
    p_required_tags text[]
) RETURNS boolean AS $$
BEGIN
    IF gvlt.obj_has_tags(p_obj_name, p_required_tags) THEN
        RETURN true;
    END IF;

    RAISE EXCEPTION 'Use case % failed: object % does not have required active tags %',
      p_case_id,
      p_obj_name,
      p_required_tags;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION gvlt.tag_get(
    p_tag_name text
) RETURNS TABLE(
    tag_name text,
    role text,
    tag_desc text,
    rdf_id text,
    is_active boolean,
    info jsonb,
    ctrl_config jsonb
) AS $$
    SELECT
        t.tag_name,
        t.role,
        t.tag_desc,
        t.rdf_id,
        t.is_active,
        t.info,
        t.ctrl_config
    FROM gvlt.tag t
    WHERE lower(t.tag_name) = lower(trim(p_tag_name))
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION gvlt.tag_search(
    p_text text DEFAULT NULL,
    p_role text DEFAULT NULL,
    p_only_active boolean DEFAULT true
) RETURNS TABLE(
    tag_name text,
    role text,
    tag_desc text,
    rdf_id text,
    is_active boolean
) AS $$
    SELECT
        t.tag_name,
        t.role,
        t.tag_desc,
        t.rdf_id,
        t.is_active
    FROM gvlt.tag t
    WHERE (p_text IS NULL OR p_text = ''
        OR t.tag_name ILIKE '%' || p_text || '%'
        OR t.tag_desc ILIKE '%' || p_text || '%'
        OR COALESCE(t.rdf_id, '') ILIKE '%' || p_text || '%')
      AND (p_role IS NULL OR p_role = '' OR t.role = lower(trim(p_role)))
      AND (NOT p_only_active OR t.is_active)
    ORDER BY t.role, t.tag_name
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION gvlt.relation_columns(
    p_relname text
) RETURNS TABLE(
    schema_name text,
    relation_name text,
    column_name text,
    ordinal_position int,
    data_type text,
    is_nullable boolean,
    column_default text,
    tags text[]
) AS $$
WITH rel AS (
    SELECT to_regclass(gvlt.rel_getname(p_relname)) AS oid
), cols AS (
    SELECT
        n.nspname::text AS schema_name,
        c.relname::text AS relation_name,
        a.attname::text AS column_name,
        a.attnum::int AS ordinal_position,
        format_type(a.atttypid, a.atttypmod) AS data_type,
        NOT a.attnotnull AS is_nullable,
        pg_get_expr(ad.adbin, ad.adrelid) AS column_default
    FROM rel
    JOIN pg_class c
      ON c.oid = rel.oid
    JOIN pg_namespace n
      ON n.oid = c.relnamespace
    JOIN pg_attribute a
      ON a.attrelid = c.oid
     AND a.attnum > 0
     AND NOT a.attisdropped
    LEFT JOIN pg_attrdef ad
      ON ad.adrelid = c.oid
     AND ad.adnum = a.attnum
)
SELECT
    cols.schema_name,
    cols.relation_name,
    cols.column_name,
    cols.ordinal_position,
    cols.data_type,
    cols.is_nullable,
    cols.column_default,
    (
        SELECT array_agg(o.tag_name ORDER BY o.tag_name)
        FROM gvlt.tag_obj o
        JOIN gvlt.tag t
          ON t.tag_name = o.tag_name
        WHERE o.obj_name = cols.schema_name || '.' || cols.relation_name || '.' || cols.column_name
          AND o.is_active
          AND t.is_active
    ) AS tags
FROM cols
ORDER BY cols.ordinal_position
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION gvlt.governance_check()
RETURNS TABLE(
    check_name text,
    severity text,
    obj_name text,
    message text
) AS $$
WITH active_tag_objects AS (
    SELECT
        o.obj_name,
        o.tag_name,
        lib.object_getype(o.obj_name) AS otype,
        string_to_array(o.obj_name, '.') AS parts
    FROM gvlt.tag_obj o
    WHERE o.is_active
), physical_schemas AS (
    SELECT nspname::text AS schema_name
    FROM pg_namespace
    WHERE nspname NOT LIKE 'pg_%'
      AND nspname <> 'information_schema'
), medallion_candidates AS (
    SELECT
        schema_name,
        gvlt.schema_name_tags(schema_name) AS tags
    FROM physical_schemas
)
SELECT
    'inactive_tag_with_active_object'::text AS check_name,
    'warning'::text AS severity,
    o.obj_name,
    format('Object has active association with inactive tag %s.', o.tag_name) AS message
FROM active_tag_objects o
JOIN gvlt.tag t
  ON t.tag_name = o.tag_name
WHERE NOT t.is_active

UNION ALL

SELECT
    'invalid_medallion_schema_name',
    'error',
    schema_name,
    format('Schema name looks governed but has missing tags: %s.', array_to_string(gvlt.schema_name_nontag(schema_name), ','))
FROM medallion_candidates
WHERE tags = ARRAY['!']::text[]

UNION ALL

SELECT
    'medallion_schema_without_catalog_tag',
    'error',
    schema_name,
    'Physical Medallion schema exists without all expected active catalog tags.'
FROM medallion_candidates mc
WHERE tags IS NOT NULL
  AND tags <> ARRAY['!']::text[]
  AND EXISTS (
      SELECT 1
      FROM unnest(tags) expected(tag_name)
      WHERE NOT EXISTS (
          SELECT 1
          FROM gvlt.tag_obj o
          JOIN gvlt.tag t
            ON t.tag_name = o.tag_name
          WHERE o.obj_name = mc.schema_name
            AND o.tag_name = expected.tag_name
            AND o.is_active
            AND t.is_active
      )
  )

UNION ALL

SELECT
    'active_schema_tag_without_schema',
    'warning',
    o.obj_name,
    'Catalog has active schema tag association, but the physical schema was not found.'
FROM active_tag_objects o
WHERE o.otype = 's'
  AND NOT EXISTS (
      SELECT 1
      FROM physical_schemas s
      WHERE s.schema_name = o.obj_name
  )

UNION ALL

SELECT
    'active_relation_tag_without_relation',
    'warning',
    o.obj_name,
    'Catalog has active relation tag association, but the physical relation was not found.'
FROM active_tag_objects o
WHERE o.otype = 'r'
  AND CASE
        WHEN o.otype = 'r' THEN to_regclass(o.obj_name) IS NULL
        ELSE false
      END

UNION ALL

SELECT
    'active_column_tag_without_column',
    'warning',
    o.obj_name,
    'Catalog has active column tag association, but the physical column was not found.'
FROM active_tag_objects o
WHERE o.otype = 'c'
  AND NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n
        ON n.oid = c.relnamespace
      JOIN pg_attribute a
        ON a.attrelid = c.oid
       AND a.attname = o.parts[3]
       AND a.attnum > 0
       AND NOT a.attisdropped
      WHERE n.nspname = o.parts[1]
        AND c.relname = o.parts[2]
  )
ORDER BY severity, check_name, obj_name
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION gvlt.medallion_objects(
    p_schema_name text DEFAULT NULL
) RETURNS TABLE(
    schema_name text,
    medallion_tag text,
    obj_name text,
    obj_type text,
    relkind text,
    tags text[]
) AS $$
WITH med AS (
    SELECT DISTINCT
        o.obj_name AS schema_name,
        o.tag_name AS medallion_tag
    FROM gvlt.tag_obj o
    JOIN gvlt.tag t
      ON t.tag_name = o.tag_name
    WHERE o.is_active
      AND t.is_active
      AND t.role = 'medallion'
      AND (p_schema_name IS NULL OR o.obj_name = lower(trim(p_schema_name)))
), objs AS (
    SELECT
        m.schema_name,
        m.medallion_tag,
        m.schema_name AS obj_name,
        'schema'::text AS obj_type,
        NULL::text AS relkind
    FROM med m

    UNION ALL

    SELECT
        m.schema_name,
        m.medallion_tag,
        (n.nspname || '.' || c.relname)::text AS obj_name,
        'relation'::text AS obj_type,
        lib.pgddl_relkind_to_objtype(c.relkind) AS relkind
    FROM med m
    JOIN pg_namespace n
      ON n.nspname = m.schema_name
    JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relkind IN ('r','v','m','f','p')
)
SELECT
    objs.schema_name,
    objs.medallion_tag,
    objs.obj_name,
    objs.obj_type,
    objs.relkind,
    (
        SELECT array_agg(o.tag_name ORDER BY o.tag_name)
        FROM gvlt.tag_obj o
        JOIN gvlt.tag t
          ON t.tag_name = o.tag_name
        WHERE o.obj_name = objs.obj_name
          AND o.is_active
          AND t.is_active
    ) AS tags
FROM objs
ORDER BY schema_name, obj_type, obj_name
$$ LANGUAGE SQL;

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

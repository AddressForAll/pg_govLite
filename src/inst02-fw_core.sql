CREATE EXTENSION IF NOT EXISTS postgis;

DROP SCHEMA IF EXISTS fw_cat CASCADE;
CREATE SCHEMA fw_cat;

--------
-- The following mapping aligns the common string values
-- from pg_event_trigger_ddl_commands().object_type
-- with their pg_class.relkind counterparts
-- GENERAL REF:
--  relkind: I, S, c, f, i, m, p, r, t, v.
--  typcategory: A, B, C, D, E, G, I, N, P, R, S, T, U, V, X.

CREATE FUNCTION fw_cat.pgddl_objtype_relkind(p_name text) RETURNS "char" AS $f$
  SELECT ('{"table":"r","index":"i","sequence":"S","toast table":"t","view":"v","materialized view":"m","foreign table":"f","partitioned table":"p","partitioned index":"I"}'::jsonb)->>$1;
$f$ LANGUAGE SQL;

CREATE FUNCTION fw_cat.pgddl_relkind_to_objtype("char") RETURNS text AS $f$
  SELECT ('{"r":"table","i":"index","S":"sequence","t":"toast table","v":"view","m":"materialized view","f":"foreign table","p":"partitioned table","I":"partitioned index"}'::jsonb)->>$1;
$f$ LANGUAGE SQL;

--------
-- The following mapping aligns the common string values from object_type to relkind-like labels,
-- and schema names to medallion labels.

CREATE FUNCTION fw_cat.object_getype(p_obj_name text) RETURNS "char" AS $f$
  -- Otype. Examples: 's'=schema, 's.t'=table, 's.t.c'=column
  SELECT ('{s,r,c}'::"char"[])[1+regexp_count(p_obj_name,'\.')]
  -- '{"s":"schema","r":"relation","c":"column"}'::jsonb
$f$ LANGUAGE SQL;


--------------------------
--------------------------
-- DNGS - the Framework's core definitions.

CREATE TABLE fw_cat.DNGS_face_id (
  iso_3166_1_numeric smallint NOT NULL,
  iso_3166_2         text     NOT NULL,
  dngs_face_id       smallint NOT NULL PRIMARY KEY,
  dngs_definition    jsonb
);
COMMENT ON TABLE fw_cat.DNGS_face_id IS 'DNGS standard - official catalog of face IDs.';
COMMENT ON COLUMN fw_cat.DNGS_face_id.iso_3166_1_numeric IS 'The ISO 3166-1 Numeric code of the country.';
COMMENT ON COLUMN fw_cat.DNGS_face_id.iso_3166_2 IS 'The ISO 3166-1 Alpha-2 code of the country.';
COMMENT ON COLUMN fw_cat.DNGS_face_id.dngs_face_id IS 'The face ID of the country on DNGS standard (or set of countries represented by the largest-area country).';
COMMENT ON COLUMN fw_cat.DNGS_face_id.dngs_definition IS 'Core metada that defines the DNGS grid system of dngs_face_id.';

-- DRAFT before ingestion process:
INSERT INTO fw_cat.DNGS_face_id VALUES
    (76,'BR',20,'{"iso_alpha2":"BR","iso_numeric":76,"srid":10857,"grid_x0y0":"2715000 6727000","grid_cell_side":1048576,"grid_id":"40 41 42 43 30 31 32 33 34 21 22 23 11 12 13 2 44 24","face_id":"14a 14b 14e 14f 148 149 14c 14d 142 143 146 147 141 144 145 140T 140P 140N","territorial_sea_in_l0_coverage":true,"eez_in_l0_coverage":false}'::jsonb),
    (120,'CM',31,NULL),
    (170,'CO',44,NULL)
;

--------------------------
--------------------------
-- fw_cat - the Framework's internal Catalog.

-- All governance and namespace validation registered by tags, so we start with this tag module.

CREATE TABLE fw_cat.govtag ( -- Governed tags
  tag text NOT NULL PRIMARY KEY CHECK( trim(tag)=tag ),
  has_values boolean NOT NULL DEFAULT false CHECK(
     NOT(has_values)
     OR (has_values 
         AND info->'tag_values' IS NOT NULL
         AND jsonb_array_length(info->'tag_values')>1
         AND jsonb_array_to_text_array(info->'tag_values',true) = jsonb_array_to_text_array(info->'tag_values')  
     )
  ),
  tag_desc text NOT NULL,
  tag_rdf text,  -- semântica formal. "wd:" = WIKIDATA.ORG; "sh:" = SCHEMA.ORG
  info jsonb     -- regras e configurações, principalmente para tags de controle
);
CREATE UNIQUE INDEX lower_case_tag ON fw_cat.govtag((lower(tag)));
INSERT INTO fw_cat.govtag VALUES -- Exemplos para teste:
   ('CPF', false, 'Código da Pessoa Fisica', 'wd:Q5016244','{"lang":"pt"}'),
   ('CNPJ', false, 'Cadastro Nacional da Pessoa Juridica', 'wd:Q15816867','{"lang":"pt"}'),
   ('vatID', false, 'CPF ou CNPJ ou gringo', 'sh:vatID',NULL),
   ('ID', false, 'Identificador qualquer', 'sh:identifier',NULL),
   ('Organization', false, 'Identificador qualquer', 'sh:Person','{"is_word":1}'),
   ('Organization.Medical', false, 'Identificador qualquer', 'sh:MedicalOrganization','{"is_word":1}'),
   ('Person', false, 'Identificador qualquer', 'sh:Person','{"is_word":1}'),
   ('CLIPJ', false, 'Cliente PJ', NULL,'{"ctrl":"macrodomain","descr_expand":"Domínio de Dados do Cliente Pessoa Jurídica","lang":"pt","BoundedContext":"CRM-operations","semantic":"sh:customer of sh:Organization"}'),
   ('CLIPF', false, 'Clinte PF', NULL,'{"ctrl":"macrodomain","descr_expand":"Domínio de Dados do Cliente Pessoa Física","lang":"pt","BoundedContext":"CRM-operations","semantic":"sh:customer of sh:Person"}'),
   ('GEO', false, 'Geo', NULL,'{"ctrl":"macrodomain","descr_expand":"Domínio de Dados Estritamente Geográficos","lang":"pt","BoundedContext":"SIG-operations","semantic":"sh:geo"}'),
   ('TSTTMP', false, 'TesteTemp', NULL,'{"ctrl":"macrodomain","descr_expand":"Domínio de Dados para Teste Temporário","lang":"pt","BoundedContext":"Test-operations","semantic":"wd:Q188522"}'),
   ('TSTDEMO', false, 'TesteDemo', NULL,'{"ctrl":"macrodomain","descr_expand":"Domínio de Dados para Teste Demonstrativo (Benckmarks e Tutoriais)","lang":"pt","BoundedContext":"Test-operations","semantic":"wd:Q816747 and wd:Q535741"}'),
   ('isPII', false, 'Is Personally Identifiable Information', NULL,'{"ctrl":"dataSecurity","on_objects":["column","relation"]}'),
   ('isProduct',false,'Is Data Product', NULL,'{"ctrl":"dataProduct","on_objects":["relation"],"on_medallion":["s","g"]}'),
   ('Tier', true, 'Tier', NULL,'{"ctrl":"dataQuality","default_value":4,"tag_values":[1,2,3,4],"on_objects":["relation","schema","database"]}'),
   ('isMedallion',true,'Is Medallion', NULL,'{"ctrl":"medallion","tag_values":["b","g","s"],"on_objects":["relation","schema","database"]}'),
   ('bronze',false,'Medallion Bronze', NULL,'{"ctrl":"medallion","on_objects":["schema","database"]}'),
   ('silver',false,'Medallion Silver', NULL,'{"ctrl":"medallion","on_objects":["schema","database"]}'),
   ('gold',false,'Medallion Gold', NULL,'{"ctrl":"medallion","on_objects":["schema","database"]}')
;
-- tags com tag_rdf IS NULL são necessariamente de controle, com valor obrigatório em info->>'ctrl'.
   -- select tag, info->>'ctrl' as ctrl from fw_cat.govtag WHERE tag_rdf IS NULL;
-- tags baseadas em tag-valor possuem obrigatoriamente info->'tag_values'
   -- select g.tag, array_agg(t.j) as text_array_values from fw_cat.govtag g, LATERAL jsonb_array_elements_text(g.info->'tag_values') t(j) where g.has_values group by 1;
-- As tags de controle, tais como "macrodomain", requerem presença em tabela principal e relação controlada por trigger.
-- As siglas de macrodomain só podem ter letras maiúsculas e no máximo 8 letras. O conjunto de domínios, no máximo 100 a cada 1000 tabelas.
-- Dados Silver e Gold podem receber isProduct, Bronze não (basta criar view da tabela Bronze na Prata se for equivalente). Ideal apenas Gold.

CREATE VIEW fw_cat.vw01_govtag AS 
  SELECT tag,
         COALESCE(info->>'ctrl','RDF') as ctrl,
         jsonb_array_to_text_array(info->'tag_values') as values,
         CASE WHEN tag ~ '\.' THEN 'hierarchical' ELSE 'simple' END || CASE WHEN info->'tag_values' IS NULL THEN '' ELSE ' valued' END as tag_type
  FROM fw_cat.govtag
  ORDER BY 1
;

--- govtag controll:
CREATE or replace FUNCTION fw_cat.govtags_fail(p_tags text[]) RETURNS text[] AS $f$
   SELECT array_agg(tag) -- not found tags
   FROM (
     SELECT t.tag, g.tag as govtag
     FROM (
        SELECT lower(trim(UNNEST(p_tags))) AS tag
     ) t LEFT JOIN fw_cat.govtag g 
     ON t.tag=lower(g.tag)
     ORDER BY t.tag
  ) tt
  WHERE govtag IS NULL
$f$ LANGUAGE SQL;

CREATE FUNCTION fw_cat.govtags_exists(p_new_tag text) RETURNS boolean AS $f$
  SELECT fw_cat.govtags_fail(array[p_new_tag]) IS NULL
$f$ LANGUAGE SQL;
CREATE FUNCTION fw_cat.govtags_exists(p_new_tags text[]) RETURNS boolean AS $f$
  SELECT fw_cat.govtags_fail(p_new_tags) IS NULL
$f$ LANGUAGE SQL;

CREATE FUNCTION fw_cat.govtags_normalize (p_tags text[]) RETURNS text[] AS $f$
-- !RENOMEAR para govtag_list_normalize()
   -- garante ordem padronizada e consistência com govtag vigente.
   SELECT array_agg(tag ORDER BY lower(tag))
   FROM (
     SELECT DISTINCT g.tag
     FROM (
        SELECT lower(trim(UNNEST(p_tags))) AS tag
     ) t INNER JOIN fw_cat.govtag g 
     ON t.tag=lower(g.tag)
  ) tt
$f$ LANGUAGE SQL;
-- SELECT fw_cat.govtags_normalize(array['CPf','cnpj','xpto','vatid']);

/* revisar nessário, pois parece que SQL faz o mesmo, sendo de manutenção mais simples.
CREATE OR REPLACE FUNCTION fw_cat.govtags_normalize2(p_tags text[])
RETURNS text[] AS $$
DECLARE
    v_tag text;
    v_raw text;
    v_prefix text;
    v_suffix text;
    v_canonical text;
    v_result text[] := '{}';
BEGIN
    IF p_tags IS NULL THEN
        RETURN NULL;
    END IF;

    FOREACH v_tag IN ARRAY p_tags LOOP
        v_raw := trim(v_tag);
        IF v_raw IS NULL OR v_raw = '' THEN
            CONTINUE;
        END IF;

        v_prefix := (regexp_split_to_array(v_raw, '[\.:]'))[1];
        v_suffix := substring(v_raw from length(v_prefix) + 1);

        SELECT g.tag
          INTO v_canonical
          FROM fw_cat.govtag g
         WHERE lower(g.tag) = lower(v_prefix)
         LIMIT 1;

        IF v_canonical IS NOT NULL THEN
            v_result := array_append(v_result, v_canonical || COALESCE(v_suffix, ''));
        END IF;
    END LOOP;

    RETURN (
        SELECT CASE
            WHEN count(*) = 0 THEN NULL
            ELSE array_agg(x ORDER BY lower(x))
        END
        FROM (
            SELECT DISTINCT unnest(v_result) AS x
        ) d
    );
END;
$$ LANGUAGE plpgsql STABLE;
*/

-- Gestão das tags de um objeto:
CREATE FUNCTION fw_cat.govtag_list_include(p_tags text[], p_new_tag text) RETURNS text[] AS $f$
  SELECT fw_cat.govtags_normalize(p_tags || p_new_tag)
$f$ LANGUAGE SQL;
CREATE FUNCTION fw_cat.govtag_list_include(p_tags text[], p_new_tags text[]) RETURNS text[] AS $f$
    SELECT fw_cat.govtags_normalize(p_tags || p_new_tags)
$f$ LANGUAGE SQL;

CREATE FUNCTION fw_cat.govtag_list_exclude(p_tags text[], p_drop_tag text) RETURNS text[] AS $f$
  SELECT array_remove(p_tags,p_drop_tag)
$f$ LANGUAGE SQL;

CREATE FUNCTION fw_cat.govtag_list_exclude(p_tags text[], p_drop_tags text[]) RETURNS text[] AS $f$
  SELECT fw_cat.govtags_normalize( -- precisa? conferir se perde ordem
       ARRAY(SELECT unnest(p_tags) EXCEPT SELECT unnest(p_drop_tags))
  )
$f$ LANGUAGE SQL;

--------------------------------------

CREATE or replace FUNCTION fw_cat.schema_name_validate(p_schema_name text) RETURNS text AS $f$
  -- old fw_cat.medallion_schema_getype()
  -- otimizar no futuro
WITH a AS ( -- analysing:
 SELECT t.*, g.*
 FROM string_to_table(trim(p_schema_name,'_'),'_') WITH ORDINALITY t(p,i)
 LEFT JOIN fw_cat.vw01_govtag g 
 ON lower(t.p)=lower(g.tag)
), mx AS (SELECT max(i) max_i FROM a)
 , chk1 AS (
 SELECT CASE 
          WHEN i=max_i AND ctrl='medallion' AND values IS NULL THEN a.tag
          ELSE '-'
        END               AS medallin_type,
        length(p)=1       AS is_1letter,
        a.tag is not null AS is_valid
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
COMMENT ON FUNCTION fw_cat.schema_name_validate
  IS 'Check vality of schema name: false=is_medallion not valid; true=is_medallion valid; NULL=NOT(is_medallion).'
;
-- select x, fw_cat.schema_name_validate(x) from unnest(array['p_bronze','geo_silver','bronze_p','silver_geo','xpto_silver','zpto_gold']) t(x);

CREATE or replace FUNCTION fw_cat.schema_name_nontag(p_schema_name text) RETURNS text[] AS $f$
 SELECT array_agg(t.p)
 FROM string_to_table(trim(p_schema_name,'_'),'_') WITH ORDINALITY t(p,i)
 LEFT JOIN fw_cat.vw01_govtag g 
 ON lower(t.p)=lower(g.tag)
 WHERE g.tag IS NULL
$f$ LANGUAGE SQL;
-- select fw_cat.schema_name_nontag('xpto_silver');

----

CREATE TABLE fw_cat.cat_tab (
   f_table_schema    name     NOT NULL CHECK( lower(trim(f_table_schema))=f_table_schema ),
   f_table_name      name     NOT NULL CHECK( lower(trim(f_table_name))=f_table_name ),
   dngs_face_id      smallint NOT NULL REFERENCES fw_cat.DNGS_face_id (dngs_face_id) DEFAULT 20, -- BR,
   lineage_script text,    -- NULL for VIEW, NOT NUL nos demais casos excepto Bronze.
   -- Notebook json ou AirFlow DAG-task-ID no futuro.
   -- https://airflow.apache.org/docs/apache-airflow/2.9.1/administration-and-deployment/lineage.html
   lineage_type  text NOT NULL, --  'sql view', 'sql script', 'sh script', 'python script'
   lineage_autotype text, -- 
   info              jsonb, -- controle do usuário
   PRIMARY KEY(f_table_schema,f_table_name)
);

CREATE TABLE fw_cat.medallion (
  mdl_key "char" NOT NULL CHECK( mdl_key IN ('b','s','g') ), -- bronze/silver/gold
  f_table_schema    name     NOT NULL CHECK( lower(trim(f_table_schema))=f_table_schema ),
  info jsonb,  -- path to data contracts, planed permissions, project names, etc. except description and tags.
  is_active boolean NOT NULL DEFAULT false,
  UNIQUE (f_table_schema)
);

-- Criar funções! 
--SELECT fw_cat.cat_govtag_remove('objeto','tag') 
--SELECT fw_cat.cat_govtag_upsert('objeto','tag') 

----

CREATE TABLE fw_cat.cat_govtag( -- catalogo de objeto-tag
   obj_name text NOT NULL PRIMARY KEY CHECK( lower(trim(obj_name))=obj_name AND fw_cat.object_getype(obj_name) IS NOT NULL ), 
   tags     text[] CHECK( tags = fw_cat.govtags_normalize(tags) )
   -- tags controlada por fw_cat.govtags_fail(), govtags_exists(), fw_cat.govtags_normalize(), govtags_include() e govtags_exclude().
   -- tags IS NULL? pode ser deletada! usar trigger. Sempre testar fw_cat.govtags_fail() no include
);

CREATE VIEW fw_cat.vw0_cat_govtag AS
  SELECT t.*, g.tag_desc, g.tag_rdf
  FROM (
    SELECT fw_cat.object_getype(obj_name) obj_type, -- '{"s":"schema","r":"relation","c":"column"}'::jsonb
           obj_name,
           UNNEST(tags) as tag
    FROM fw_cat.cat_govtag
  ) t LEFT JOIN fw_cat.govtag g
  ON g.tag=t.tag
  ORDER BY 2, 1, 3
;

--------------------------
-- Other VIEWs and functions.

CREATE VIEW fw_cat.vw0_relations AS
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

CREATE VIEW fw_cat.postgis_geo_columns AS
 -- REF: 'r'='table', 'v'='view', 'm'='materialized view', 'f'='foreign table', 'p'='partitioned table'.
  
 -- \d+ geometry_columns
 SELECT c.relkind, true AS is_geography_col,
    n.nspname AS f_table_schema,
    c.relname AS f_table_name,
    a.attname AS f_geography_column,
    postgis_typmod_dims(a.atttypmod) AS coord_dimension,
    postgis_typmod_srid(a.atttypmod) AS srid,
    postgis_typmod_type(a.atttypmod) AS type
   FROM pg_class c,
    pg_attribute a,
    pg_type t,
    pg_namespace n
  WHERE t.typname = 'geography'::name AND a.attisdropped = false AND a.atttypid = t.oid AND a.attrelid = c.oid AND c.relnamespace = n.oid AND (c.relkind = ANY (ARRAY['r'::"char", 'v'::"char", 'm'::"char", 'f'::"char", 'p'::"char"])) AND NOT pg_is_other_temp_schema(c.relnamespace) AND has_table_privilege(c.oid, 'SELECT'::text)

UNION ALL

 -- \d+ geography_columns
 SELECT c.relkind, false AS is_geography_col,
    n.nspname AS f_table_schema,
    c.relname AS f_table_name,
    a.attname AS f_geometry_column,
    COALESCE(postgis_typmod_dims(a.atttypmod), sn.ndims, 2) AS coord_dimension,
    COALESCE(NULLIF(postgis_typmod_srid(a.atttypmod), 0), sr.srid, 0) AS srid,
    replace(replace(COALESCE(NULLIF(upper(postgis_typmod_type(a.atttypmod)), 'GEOMETRY'::text), st.type, 'GEOMETRY'::text), 'ZM'::text, ''::text), 'Z'::text, ''::text)::character varying(30) AS type
   FROM pg_class c
     JOIN pg_attribute a ON a.attrelid = c.oid AND NOT a.attisdropped
     JOIN pg_namespace n ON c.relnamespace = n.oid
     JOIN pg_type t ON a.atttypid = t.oid
     LEFT JOIN ( SELECT s.connamespace,
            s.conrelid,
            s.conkey,
            (regexp_match(s.consrc, 'geometrytype\(\w+\)\s*=\s*''(\w+)'''::text, 'i'::text))[1] AS type
           FROM ( SELECT pg_constraint.connamespace,
                    pg_constraint.conrelid,
                    pg_constraint.conkey,
                    pg_get_constraintdef(pg_constraint.oid) AS consrc
                   FROM pg_constraint) s
          WHERE s.consrc ~* 'geometrytype\(\w+\)\s*=\s*''\w+'''::text) st ON st.connamespace = n.oid AND st.conrelid = c.oid AND (a.attnum = ANY (st.conkey))
     LEFT JOIN ( SELECT s.connamespace,
            s.conrelid,
            s.conkey,
            (regexp_match(s.consrc, 'ndims\(\w+\)\s*=\s*(\d+)'::text, 'i'::text))[1]::integer AS ndims
           FROM ( SELECT pg_constraint.connamespace,
                    pg_constraint.conrelid,
                    pg_constraint.conkey,
                    pg_get_constraintdef(pg_constraint.oid) AS consrc
                   FROM pg_constraint) s
          WHERE s.consrc ~* 'ndims\(\w+\)\s*=\s*\d+'::text) sn ON sn.connamespace = n.oid AND sn.conrelid = c.oid AND (a.attnum = ANY (sn.conkey))
     LEFT JOIN ( SELECT s.connamespace,
            s.conrelid,
            s.conkey,
            (regexp_match(s.consrc, 'srid\(\w+\)\s*=\s*(\d+)'::text, 'i'::text))[1]::integer AS srid
           FROM ( SELECT pg_constraint.connamespace,
                    pg_constraint.conrelid,
                    pg_constraint.conkey,
                    pg_get_constraintdef(pg_constraint.oid) AS consrc
                   FROM pg_constraint) s
          WHERE s.consrc ~* 'srid\(\w+\)\s*=\s*\d+'::text) sr ON sr.connamespace = n.oid AND sr.conrelid = c.oid AND (a.attnum = ANY (sr.conkey))
  WHERE (c.relkind = ANY (ARRAY['r'::"char", 'v'::"char", 'm'::"char", 'f'::"char", 'p'::"char"])) AND NOT c.relname = 'raster_columns'::name AND t.typname = 'geometry'::name AND NOT pg_is_other_temp_schema(c.relnamespace) AND has_table_privilege(c.oid, 'SELECT'::text)

  -- falta UNION Raster
;

CREATE FUNCTION fw_cat.rel_getname(
     p_relname text,
     p_schemaname text DEFAULT NULL
) RETURNS text AS $f$
    SELECT CASE
       WHEN strpos($1, '.')>0 THEN $1
       WHEN $2 IS NULL THEN 'public.'||$1
       ELSE $2||'.'||$1
    END  -- ::regclass
$f$ LANGUAGE SQL;

CREATE FUNCTION fw_cat.rel_description(
     p_relname text,
     p_schemaname text DEFAULT NULL
) RETURNS text AS $f$
    SELECT obj_description(fw_cat.rel_getname(p_relname,p_schemaname)::regclass, 'pg_class');
$f$ LANGUAGE SQL;

----
CREATE FUNCTION fw_cat.cat_vector_include(
     p_relname text,
     p_schemaname text,
     p_info JSONb
) RETURNS boolean AS $f$
DECLARE
    tname text;
    tdesc text;
    t_relkind "char";
    t_srid int;
    isvalid boolean := true;
BEGIN
  tname := fw_cat.rel_getname(p_relname,p_schemaname);
  tdesc := fw_cat.rel_description(tname);
  IF tdesc is NULL OR not(trim(tdesc)>'') THEN
    RAISE NOTICE 'Tabela % sem COMMENT descritivo', tname;
    isvalid := false;
  END IF;

  SELECT MAX(relkind), max(srid)
  INTO t_relkind, t_srid
  FROM fw_cat.postgis_geo_columns
  WHERE f_table_schema||'.'||f_table_name = tname;

  IF t_relkind IS NULL THEN
    RAISE NOTICE 'Relação % ausente do catálogo das geometrias PostGIS', tname;
    isvalid := false;
  END IF;
  IF NOT(t_relkind = ANY('{r,m,p,f}'::"char"[])) THEN
    RAISE NOTICE 'Relação % precisa ser tabela pura ou materialized view', tname;
    isvalid := false;
  END IF;
  IF t_srid !=10857 THEN
    RAISE NOTICE 'SRID de % diferente de 10857: srid=% é invadido', tname, t_srid;
    isvalid := false;
  END IF;

  IF isvalid THEN
    RAISE NOTICE 'Tabela perfeita para o fw: %!', tname;
    -- INSERT INTO fw_cat.cat_tab
  END IF;
  RETURN isvalid;
END;
$f$ LANGUAGE plpgsql;

CREATE FUNCTION fw_cat.cat_vector_include(
     p_relname text,
     p_info JSONb
) RETURNS boolean AS $f$
    SELECT fw_cat.cat_vector_include(p_relname,NULL,p_info);
$f$ LANGUAGE SQL;
-- ===============================================================
-- Teste simulando enriquecimento das tags governadas de exemplo: depois ou antes dos triggers??
/*
INSERT INTO fw_cat.govtag (tag, tag_values, tag_desc, tag_rdf) VALUES
('Person', NULL, 'Representacao de pessoa', 'sh:Person')
ON CONFLICT (tag) DO UPDATE
SET tag_values = COALESCE(EXCLUDED.tag_values, fw_cat.govtag.tag_values),
    tag_desc = COALESCE(NULLIF(EXCLUDED.tag_desc, ''), fw_cat.govtag.tag_desc),
    tag_rdf = COALESCE(NULLIF(EXCLUDED.tag_rdf, ''), fw_cat.govtag.tag_rdf);
*/
-- ===============================================================
-- Normalizacao canonica de tags (com suporte a especializacao e tag:valor).
-- Ex.: CPf -> CPF, cnpj:123 -> CNPJ:123, mdl.bronze (se mdl governada) -> mdl.bronze.

-- ===============================================================
-- Inclusao de tags por nome de objeto catalogado (schema, tabela ou coluna).
-- p_obj_name exemplos: s, s.t, s.t.c

CREATE OR REPLACE FUNCTION fw_cat.govtags_is_include(
  -- conferir relação com govtags_include() e casos de uso.
    p_obj_name text,
    p_tags_to_add text[]
) RETURNS boolean AS $$
DECLARE
    v_obj_name text;
    v_normalized_tags text[];
BEGIN
    v_obj_name := lower(trim(p_obj_name));
    v_normalized_tags := fw_cat.govtags_normalize(p_tags_to_add);

    IF v_obj_name IS NULL OR v_obj_name = '' OR fw_cat.object_getype(v_obj_name) IS NULL THEN
        RAISE WARNING 'Objeto invalido para tagging: %', p_obj_name;
        RETURN false;
    END IF;

    IF array_length(v_normalized_tags, 1) IS NULL THEN
        RAISE WARNING 'Nenhuma das tags fornecidas e governada valida.';
        RETURN false;
    END IF;

    INSERT INTO fw_cat.cat_govtag (obj_name, tags)
    VALUES (v_obj_name, v_normalized_tags)
    ON CONFLICT (obj_name)
    DO UPDATE
       SET tags = fw_cat.govtags_normalize(
           COALESCE(fw_cat.cat_govtag.tags, '{}'::text[]) || EXCLUDED.tags
       );

    RETURN true;
END;
$$ LANGUAGE plpgsql;

-- ===============================================================
-- View de apoio: glossario de tags aplicadas no catalogo de objetos.

CREATE OR REPLACE VIEW fw_cat.vw_applied_tags_glossary AS
WITH expanded_tags AS (
    SELECT
        c.obj_name,
        fw_cat.object_getype(c.obj_name) AS obj_type,
        unnest(c.tags) AS full_tag
    FROM fw_cat.cat_govtag c
)
SELECT
    e.obj_name,
    e.obj_type,
    e.full_tag,
    g.tag AS gov_tag_base,
    g.tag_rdf AS semantic_uri,
    g.tag_desc AS tag_description
FROM expanded_tags e
LEFT JOIN fw_cat.govtag g
       ON lower(g.tag) = lower((regexp_split_to_array(e.full_tag, '[\.:]'))[1])
ORDER BY e.obj_name, e.full_tag;


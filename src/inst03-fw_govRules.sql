

CREATE OR REPLACE FUNCTION gvlt.medallion_upsert(
    p_schema_name text,
    p_info jsonb DEFAULT NULL
) RETURNS text AS $f$
DECLARE
    v_mtype text;
    v_schema_name text;
    v_tags text[];
BEGIN
    v_schema_name := lower(trim(p_schema_name));
    -- Validação do nome via regex/lógica medalhão já existente
    -- v_mtype := gvlt.medallion_schema_getype(p_schema_name);
    v_mtype := gvlt.schema_name_validate(v_schema_name);  -- null ou '!' erro ou mtype.
    v_tags := gvlt.schema_name_tags(v_schema_name);
    IF v_mtype IS NULL THEN
        RETURN 'ERRO: O nome do schema ' || p_schema_name || ' não segue o padrão medalhão (bronze/silver/gold).';
    ELSIF v_mtype='!' THEN
        RETURN 'ERRO: O nome do schema ' || p_schema_name || ' requer registro da tag '|| array_to_string( gvlt.schema_name_nontag(v_schema_name) , ',' ) ||'.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_schema_name) THEN
            PERFORM lib.dynamic_execute(format('CREATE SCHEMA %I', v_schema_name));
    END IF;

    INSERT INTO gvlt.tag_obj (tag_name, obj_name, is_active, ctrl_config)
    SELECT unnest(v_tags), v_schema_name, true, p_info
    ON CONFLICT (obj_name, tag_name)
    DO UPDATE SET
        is_active = true,
        ctrl_config = COALESCE(EXCLUDED.ctrl_config, gvlt.tag_obj.ctrl_config)
    ;
    -- RAISE NOTICE 'pg_govLite: Schema % registrado como %!', obj.object_identity, m_type;

    RETURN 'SUCESSO: Schema ' || p_schema_name || ' (tipo ' || v_mtype || ') atualizado no catálogo.';
END;
$f$ LANGUAGE plpgsql;

--------------
---------------


CREATE OR REPLACE FUNCTION gvlt.trig_medallion_upsert_event()
RETURNS event_trigger AS $$
DECLARE
    obj record;
    m_type text;
    v_tags text[];
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE object_type = 'schema'
    LOOP
        m_type := gvlt.schema_name_validate(obj.object_identity);
        v_tags := gvlt.schema_name_tags(obj.object_identity);
        -- NULL=NOT(is_medallion) '!'=error.
        IF m_type IS NOT NULL THEN -- is_medallion
          IF m_type!='!' THEN  -- Bronze/Silver/Gold
            INSERT INTO gvlt.tag_obj (tag_name, obj_name, is_active)
            SELECT unnest(v_tags), lower(trim(obj.object_identity)), true
            ON CONFLICT (obj_name, tag_name)
            DO UPDATE SET is_active = true;
            RAISE NOTICE 'pg_govLite: Schema % registrado com tags %!', obj.object_identity, v_tags;
          ELSE
            RAISE EXCEPTION 'pg_govLite ERROR, schema % candidato a medalhão mas com tags ausentes: %',
               obj.object_identity,
               array_to_string( gvlt.schema_name_nontag(obj.object_identity) , ',' )
            ;
          END IF; -- /vality
        ELSE  -- NOT(is_medallion)
            RAISE NOTICE 'pg_govLite: Schema não-governado ok, % não é medalhão', obj.object_identity;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER et_medallion_insert
ON ddl_command_end
WHEN TAG IN ('CREATE SCHEMA')
EXECUTE FUNCTION gvlt.trig_medallion_upsert_event();

---------------
CREATE OR REPLACE FUNCTION gvlt.trig_medallion_disable_event()
RETURNS event_trigger AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE object_type = 'schema'
    LOOP
        UPDATE gvlt.tag_obj
        SET is_active = false
        WHERE obj_name = obj.object_identity; -- tag_name?

        IF FOUND THEN
            RAISE NOTICE 'pg_govLite: medallion schema % flagged as non-active', obj.object_identity;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER et_medallion_drop
ON sql_drop
WHEN TAG IN ('DROP SCHEMA')
EXECUTE FUNCTION gvlt.trig_medallion_disable_event();


---------------
/* Later review

CREATE OR REPLACE FUNCTION gvlt_examples_bronze.list_functions( p_query text) RETURNS  text AS $f$

SELECT
    r.ev_class as view_id,
    d.refobjid as function_id,
    r.ev_class::regclass AS view_name,
    d.refobjid::regprocedure AS function_name
FROM pg_rewrite r
JOIN pg_depend d ON d.objid = r.oid
JOIN gvlt_examples_bronze.* -- ex_tab_names
WHERE d.refclassid = 'pg_proc'::regclass
  AND r.ev_class = ex_tab_names::regclass;
-- names: lixo1     | fw_cat.govtags_normalize(jsonb)



CREATE OR REPLACE FUNCTION gvlt.add_example( p_query text) RETURNS  text AS $f$
BEGIN
  vname = ? SELECT MAX(ID)
  SELECT lib.dynamic_execute('CREATE VIEW gvlt_examples_bronze.'|| vname ||' AS ' p_query);
  ADD_tag('is_example')
  ... add functions used by
  -- pg_depend , pg_rewrite: Specifically used for view dependencies. In PostgreSQL, a view does not depend on a function directly; instead, the view's rewrite rule (usually named _RETURN) depends on the function


CREATE OR REPLACE VIEW gvlt.vw_governance_medallion_check AS
SELECT
    nspname AS schema_fisco,
    m.f_table_schema AS schema_catalogo,
    CASE
        WHEN m.f_table_schema IS NULL AND gvlt.schema_name_validate(n.nspname) IS NOT NULL
            THEN 'NÃO CATALOGADO: Schema medalhão existe no banco mas não no gvlt.medallion'
        WHEN m.is_active = true AND n.nspname IS NULL
            THEN 'ÓRFÃO: Catalogado como ativo, mas o schema físico foi removido sem trigger'
        WHEN m.is_active = false AND n.nspname IS NOT NULL
            THEN 'INATIVO PRESENTE: Schema existe mas está marcado como inativo no catálogo'
        ELSE 'OK'
    END AS status_governance
FROM pg_namespace n
FULL OUTER JOIN gvlt.medallion m ON n.nspname = m.f_table_schema
WHERE n.nspname NOT LIKE 'pg_%'
  AND n.nspname <> 'information_schema'
  AND (gvlt.schema_name_validate(n.nspname) IS NOT NULL OR m.f_table_schema IS NULL);


  */

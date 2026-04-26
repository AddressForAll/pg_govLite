CREATE OR REPLACE FUNCTION fw_cat.trig_medallion_upsert_event()
RETURNS event_trigger AS $$
DECLARE
    obj record;
    m_type text;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE object_type = 'schema'
    LOOP
        m_type := fw_cat.schema_name_validate(obj.object_identity);
        -- NULL=NOT(is_medallion) '!'=error.
        IF m_type IS NOT NULL THEN -- is_medallion
          IF m_type!='!' THEN
            INSERT INTO fw_cat.medallion (mdl_key, f_table_schema, is_active)
            VALUES (substring(m_type, 1, 1), obj.object_identity, true)
            ON CONFLICT (f_table_schema) 
            DO UPDATE SET is_active = true, mdl_key = EXCLUDED.mdl_key;
            RAISE NOTICE 'Framework AFA: Schema % registrado como %!', obj.object_identity, m_type;
          ELSE
            RAISE EXCEPTION 'Framework ERROR, schema % candidato a medalhão mas com tags ausentes: %',
               obj.object_identity,
               array_to_string( fw_cat.schema_name_nontag(obj.object_identity) , ',' )
            ;
          END IF; -- /vality
        ELSE  -- NOT(is_medallion)
            RAISE NOTICE 'Schema não-governado ok, % não é medalhão', obj.object_identity;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER et_medallion_insert 
ON ddl_command_end 
WHEN TAG IN ('CREATE SCHEMA')
EXECUTE FUNCTION fw_cat.trig_medallion_upsert_event();
---------------
CREATE OR REPLACE FUNCTION fw_cat.trig_medallion_disable_event()
RETURNS event_trigger AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE object_type = 'schema'
    LOOP
        UPDATE fw_cat.medallion 
        SET is_active = false 
        WHERE f_table_schema = obj.object_identity;
        
        IF FOUND THEN
            RAISE NOTICE 'Framework AFA: Schema medalhão % marcado como inativo', obj.object_identity;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER et_medallion_drop 
ON sql_drop 
WHEN TAG IN ('DROP SCHEMA')
EXECUTE FUNCTION fw_cat.trig_medallion_disable_event();

---------------

CREATE OR REPLACE FUNCTION fw_cat.medallion_upsert(
    p_schema_name text,
    p_info jsonb DEFAULT NULL
) RETURNS text AS $$
DECLARE
    v_mtype text;
BEGIN
    -- Validação do nome via regex/lógica medalhão já existente
    -- v_mtype := fw_cat.medallion_schema_getype(p_schema_name); 
    v_mtype := fw_cat.schema_name_validate(p_schema_name);  -- null ou '!' erro ou mtype.
    IF v_mtype IS NULL THEN
        RETURN 'ERRO: O nome do schema ' || p_schema_name || ' não segue o padrão medalhão (bronze/silver/gold).';
    ELSEIF v_mtype='!' THEN
        RETURN 'ERRO: O nome do schema ' || p_schema_name || ' requer registro da tag '|| array_to_string( fw_cat.schema_name_nontag(obj.object_identity) , ',' ) ||'.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = p_schema_name) THEN
            PERFORM lib.dynamic_execute('CREATE SCHEMA '|| p_schema_name);
    END IF;

    INSERT INTO fw_cat.medallion (mdl_key, f_table_schema, info, is_active)
    VALUES (substring(v_mtype, 1, 1), lower(trim(p_schema_name)), p_info, true)
    ON CONFLICT (f_table_schema) 
    DO UPDATE SET 
        info = COALESCE(EXCLUDED.info, fw_cat.medallion.info),
        is_active = true,
        mdl_key = EXCLUDED.mdl_key;

    RETURN 'SUCESSO: Schema ' || p_schema_name || ' (tipo ' || v_mtype || ') atualizado no catálogo.';
END;
$$ LANGUAGE plpgsql;
--------------

CREATE OR REPLACE VIEW fw_cat.vw_governance_medallion_check AS
SELECT 
    nspname AS schema_fisco,
    m.f_table_schema AS schema_catalogo,
    CASE 
        WHEN m.f_table_schema IS NULL AND fw_cat.schema_name_validate(n.nspname) IS NOT NULL 
            THEN 'NÃO CATALOGADO: Schema medalhão existe no banco mas não no fw_cat.medallion'
        WHEN m.is_active = true AND n.nspname IS NULL 
            THEN 'ÓRFÃO: Catalogado como ativo, mas o schema físico foi removido sem trigger'
        WHEN m.is_active = false AND n.nspname IS NOT NULL
            THEN 'INATIVO PRESENTE: Schema existe mas está marcado como inativo no catálogo'
        ELSE 'OK'
    END AS status_governance
FROM pg_namespace n
FULL OUTER JOIN fw_cat.medallion m ON n.nspname = m.f_table_schema
WHERE n.nspname NOT LIKE 'pg_%' 
  AND n.nspname <> 'information_schema'
  AND (fw_cat.schema_name_validate(n.nspname) IS NOT NULL OR m.f_table_schema IS NULL);

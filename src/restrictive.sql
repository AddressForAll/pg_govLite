-- Administrative routines deliberately have no PUBLIC EXECUTE (setup revokes it).
-- Fixed search_path prevents temporary/user objects from shadowing trusted helpers.
CREATE FUNCTION {{object:gvlt.policy_actor}}() RETURNS name
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
  SELECT CASE WHEN current_setting('role')='none' THEN session_user::name
              ELSE current_setting('role')::name END
$$;

CREATE FUNCTION {{object:gvlt.policy_is_admin}}() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS(SELECT FROM pg_roles WHERE rolname={{object:gvlt.policy_actor}}() AND rolsuper)
$$;

CREATE FUNCTION {{object:gvlt.relation_layer}}(p_oid oid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT CASE WHEN i.layout='single' THEN
      (SELECT CASE p.reserved_word WHEN 'brz' THEN 'Bronze' WHEN 'slv' THEN 'Silver' WHEN 'gld' THEN 'Gold' END
       FROM {{object:gvlt.object_name_parse}}(c.relname::text) p
       WHERE p.reserved_word IN ('brz','slv','gld') AND n.nspname=i.target_schema)
    ELSE CASE n.nspname WHEN 'brz' THEN 'Bronze' WHEN 'slv' THEN 'Silver' WHEN 'gld' THEN 'Gold'
         ELSE NULLIF({{object:gvlt.schema_name_validate}}(n.nspname::text),'!') END END
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  CROSS JOIN {{object:gvlt.installation}} i
  WHERE c.oid=p_oid AND c.relkind IN ('r','p','v','m','f')
$$;

CREATE FUNCTION {{object:gvlt.relation_is_internal}}(p_oid oid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT CASE WHEN i.layout='single' THEN
    n.nspname<>i.target_schema OR EXISTS(SELECT FROM {{object:gvlt.object_name_parse}}(c.relname::text) p
      WHERE p.reserved_word IN ('lib','gvlt','doc','api'))
    ELSE n.nspname IN ('lib','gvlt','gvlt_doc_examples','api') END
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN {{object:gvlt.installation}} i
  WHERE c.oid=p_oid
$$;

CREATE FUNCTION {{object:gvlt.policy_guard}}() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor name; master oid;
BEGIN
  SELECT master_oid INTO master FROM {{object:gvlt.installation}} WHERE restrictive;
  IF FOUND AND EXISTS(SELECT FROM {{object:gvlt.relation_registry}}
                      WHERE objid=TG_RELID AND is_active AND layer IN ('Silver','Gold')) THEN
    PERFORM {{object:gvlt.policy_validate_roles}}(master);
    actor := {{object:gvlt.policy_actor}}();
    IF NOT {{object:gvlt.policy_is_admin}}() AND (SELECT oid FROM pg_roles WHERE rolname=actor) IS DISTINCT FROM master THEN
      RAISE EXCEPTION 'Restrictive governance: only the designated master may write to %.%',TG_TABLE_SCHEMA,TG_TABLE_NAME
        USING ERRCODE='42501';
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION {{object:gvlt.policy_grant}}(p_kind text,p_oid oid,p_grantee oid,p_privilege text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE identity text; class_id oid; already_granted boolean; role_name name;
BEGIN
  SELECT rolname INTO role_name FROM pg_roles WHERE oid=p_grantee;
  IF p_kind='SCHEMA' AND p_privilege='USAGE' THEN
    SELECT quote_ident(nspname), 'pg_namespace'::regclass INTO identity,class_id FROM pg_namespace WHERE oid=p_oid;
    already_granted := has_schema_privilege(p_grantee,p_oid,p_privilege);
  ELSIF p_kind='SEQUENCE' AND p_privilege='USAGE' THEN
    SELECT format('%I.%I',n.nspname,c.relname),'pg_class'::regclass INTO identity,class_id FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=p_oid;
    already_granted := has_sequence_privilege(p_grantee,p_oid,p_privilege);
  ELSIF p_kind='TABLE' AND p_privilege IN ('INSERT','UPDATE','DELETE','TRUNCATE') THEN
    SELECT format('%I.%I',n.nspname,c.relname),'pg_class'::regclass INTO identity,class_id FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=p_oid;
    already_granted := has_table_privilege(p_grantee,p_oid,p_privilege);
  ELSE RAISE EXCEPTION 'Unsupported policy grant'; END IF;
  IF NOT already_granted THEN
    EXECUTE format('GRANT %s ON %s %s TO %I',p_privilege,p_kind,identity,role_name);
    INSERT INTO {{object:gvlt.policy_grants}} VALUES(class_id,p_oid,p_grantee,p_privilege,identity)
      ON CONFLICT DO NOTHING;
    INSERT INTO {{object:gvlt.policy_audit}} (action,objid,details) VALUES ('grant',p_oid,
      jsonb_build_object('identity',identity,'role',role_name,'privilege',p_privilege,'kind',p_kind));
  END IF;
END $$;

CREATE FUNCTION {{object:gvlt.policy_validate_roles}}(p_master oid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE owner_id oid; unsafe text;
BEGIN
  SELECT owner_oid INTO owner_id FROM {{object:gvlt.installation}};
  IF NOT EXISTS(SELECT FROM pg_roles WHERE oid=p_master AND rolcanlogin
      AND NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'Master must be an existing operational LOGIN without administrative attributes';
  END IF;
  SELECT string_agg(rolname,', ') INTO unsafe FROM pg_roles
  WHERE NOT rolsuper AND oid<>owner_id AND
    (pg_has_role(oid,owner_id,'MEMBER') OR (oid<>p_master AND pg_has_role(oid,p_master,'MEMBER')));
  IF unsafe IS NOT NULL THEN
    RAISE EXCEPTION 'Unsafe owner/master role memberships: %. Review role membership before activation',unsafe;
  END IF;
END $$;

CREATE FUNCTION {{object:gvlt.policy_apply}}() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE cfg record; t record; a record; col record; seq record;
  identity text; before_acl aclitem[]; before_owner oid; before_cols jsonb;
  master_name name; owner_name name; grantee text;
BEGIN
  SELECT * INTO cfg FROM {{object:gvlt.installation}} WHERE restrictive AND NOT policy_busy FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE {{object:gvlt.installation}} SET policy_busy=true;
  PERFORM {{object:gvlt.policy_validate_roles}}(cfg.master_oid);
  SELECT rolname INTO master_name FROM pg_roles WHERE oid=cfg.master_oid;
  SELECT rolname INTO owner_name FROM pg_roles WHERE oid=cfg.owner_oid;
  FOR t IN SELECT c.*, n.nspname FROM {{object:gvlt.relation_registry}} r
    JOIN pg_class c ON c.oid=r.objid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE r.is_active AND r.layer IN ('Silver','Gold') ORDER BY c.oid
  LOOP
    identity := format('%I.%I',t.nspname,t.relname);
    before_acl := t.relacl; before_owner := t.relowner;
    SELECT COALESCE(jsonb_object_agg(attname,attacl::text) FILTER (WHERE attacl IS NOT NULL),'{}')
      INTO before_cols FROM pg_attribute WHERE attrelid=t.oid AND attnum>0 AND NOT attisdropped;
    -- Refuse privilege takeover of operational-owned objects. DBA must transfer ownership explicitly.
    IF t.relowner<>cfg.owner_oid AND NOT EXISTS(SELECT FROM pg_roles WHERE oid=t.relowner AND rolsuper) THEN
      RAISE EXCEPTION 'Transfer ownership of % to the installation DBA before protection',identity;
    END IF;
    IF EXISTS(SELECT FROM pg_roles WHERE NOT rolsuper AND oid<>t.relowner AND pg_has_role(oid,t.relowner,'MEMBER')) THEN
      RAISE EXCEPTION 'Operational role can assume the owner of %',identity;
    END IF;
    FOR a IN SELECT DISTINCT x.grantee FROM aclexplode(t.relacl) x
      WHERE x.grantee<>t.relowner AND x.grantee<>cfg.master_oid
        AND x.privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
    LOOP
      grantee := CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END;
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE %s FROM %s CASCADE',identity,grantee);
      IF current_setting('server_version_num')::int>=170000 THEN
        EXECUTE format('REVOKE MAINTAIN ON TABLE %s FROM %s CASCADE',identity,grantee);
      END IF;
    END LOOP;
    FOR col IN SELECT attname,attacl FROM pg_attribute WHERE attrelid=t.oid AND attnum>0 AND NOT attisdropped AND attacl IS NOT NULL
    LOOP
      FOR a IN SELECT DISTINCT x.grantee FROM aclexplode(col.attacl) x
        WHERE x.grantee<>t.relowner AND x.grantee<>cfg.master_oid AND x.privilege_type IN ('INSERT','UPDATE','REFERENCES')
      LOOP
        grantee := CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END;
        EXECUTE format('REVOKE INSERT (%I), UPDATE (%I), REFERENCES (%I) ON %s FROM %s CASCADE',col.attname,col.attname,col.attname,identity,grantee);
      END LOOP;
    END LOOP;
    PERFORM {{object:gvlt.policy_grant}}('SCHEMA',t.relnamespace,cfg.master_oid,'USAGE');
    PERFORM {{object:gvlt.policy_grant}}('TABLE',t.oid,cfg.master_oid,'INSERT');
    PERFORM {{object:gvlt.policy_grant}}('TABLE',t.oid,cfg.master_oid,'UPDATE');
    PERFORM {{object:gvlt.policy_grant}}('TABLE',t.oid,cfg.master_oid,'DELETE');
    PERFORM {{object:gvlt.policy_grant}}('TABLE',t.oid,cfg.master_oid,'TRUNCATE');
    -- Identity/serial dependencies, including sequences shared via a column default.
    FOR seq IN
      SELECT DISTINCT s.oid,s.relname,n.nspname FROM pg_class s JOIN pg_namespace n ON n.oid=s.relnamespace
      WHERE s.relkind='S' AND (
        EXISTS(SELECT FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=s.oid AND d.refclassid='pg_class'::regclass AND d.refobjid=t.oid)
        OR EXISTS(SELECT FROM pg_depend d JOIN pg_attrdef ad ON ad.oid=d.objid WHERE d.classid='pg_attrdef'::regclass AND d.refclassid='pg_class'::regclass AND d.refobjid=s.oid AND ad.adrelid=t.oid))
    LOOP
      PERFORM {{object:gvlt.policy_grant}}('SEQUENCE',seq.oid,cfg.master_oid,'USAGE');
    END LOOP;
    IF t.relkind IN ('r','p','f') AND NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid=t.oid AND tgname='gvlt_write_guard') THEN
      EXECUTE format('CREATE TRIGGER gvlt_write_guard BEFORE INSERT OR UPDATE OR DELETE ON %s FOR EACH STATEMENT EXECUTE FUNCTION {{object:gvlt.policy_guard}}()',identity);
    END IF;
    IF t.relkind IN ('r','p') AND NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid=t.oid AND tgname='gvlt_truncate_guard') THEN
      EXECUTE format('CREATE TRIGGER gvlt_truncate_guard BEFORE TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION {{object:gvlt.policy_guard}}()',identity);
    END IF;
    IF EXISTS(SELECT FROM pg_trigger WHERE tgrelid=t.oid AND tgname IN ('gvlt_write_guard','gvlt_truncate_guard')
      AND tgfoid<>'{{object:gvlt.policy_guard}}()'::regprocedure) THEN
      RAISE EXCEPTION 'Policy trigger name collision on %',identity;
    END IF;
    FOR a IN SELECT tgname FROM pg_trigger WHERE tgrelid=t.oid AND tgname IN ('gvlt_write_guard','gvlt_truncate_guard') AND tgenabled<>'A' LOOP
      EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I',identity,a.tgname);
    END LOOP;
    IF before_acl IS DISTINCT FROM (SELECT relacl FROM pg_class WHERE oid=t.oid) OR before_cols IS DISTINCT FROM
      (SELECT COALESCE(jsonb_object_agg(attname,attacl::text) FILTER (WHERE attacl IS NOT NULL),'{}') FROM pg_attribute WHERE attrelid=t.oid AND attnum>0 AND NOT attisdropped) THEN
      INSERT INTO {{object:gvlt.permission_history}} (objid,object_identity,original_owner,original_acl,column_acls)
        VALUES (t.oid,identity,before_owner,before_acl,before_cols);
      INSERT INTO {{object:gvlt.policy_audit}} (action,objid,details) VALUES ('permissions',t.oid,
        jsonb_build_object('identity',identity,'before_acl',before_acl::text,'after_acl',(SELECT relacl::text FROM pg_class WHERE oid=t.oid),'before_columns',before_cols));
    END IF;
  END LOOP;
  UPDATE {{object:gvlt.installation}} SET policy_busy=false;
END $$;

CREATE FUNCTION {{object:gvlt.relation_sync}}() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t record; found_layer text; old_layer text; obj text; parent_layer text;
  assoc record; next_name text; column_name name;
BEGIN
  IF (SELECT catalog_busy FROM {{object:gvlt.installation}} FOR UPDATE) THEN RETURN; END IF;
  UPDATE {{object:gvlt.installation}} SET catalog_busy=true;
  FOR t IN SELECT c.oid,c.relname,c.relkind,n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.relkind IN ('r','p','v','m','f') AND n.nspname !~ '^pg_' AND n.nspname<>'information_schema'
    ORDER BY c.relispartition,c.oid
  LOOP
    IF {{object:gvlt.relation_is_internal}}(t.oid) THEN CONTINUE; END IF;
    found_layer := {{object:gvlt.relation_layer}}(t.oid);
    SELECT layer INTO old_layer FROM {{object:gvlt.relation_registry}} WHERE objid=t.oid AND is_active;
    obj := t.nspname||'.'||t.relname;
    IF found_layer IS NULL THEN
      SELECT r.layer INTO found_layer FROM {{object:gvlt.tag_obj}} o
        JOIN (VALUES ('Bronze'),('Silver'),('Gold')) r(layer) ON r.layer=o.tag_name
        WHERE o.is_active AND o.obj_name=lower(obj) ORDER BY r.layer DESC LIMIT 1;
    END IF;
    WITH RECURSIVE ancestors(objid) AS (
      SELECT inhparent FROM pg_inherits WHERE inhrelid=t.oid
      UNION SELECT inh.inhparent FROM pg_inherits inh JOIN ancestors a ON a.objid=inh.inhrelid
    )
    SELECT COALESCE(r.layer,{{object:gvlt.relation_layer}}(a.objid)) INTO parent_layer
      FROM ancestors a LEFT JOIN {{object:gvlt.relation_registry}} r ON r.objid=a.objid AND r.is_active
      WHERE COALESCE(r.layer,{{object:gvlt.relation_layer}}(a.objid)) IN ('Silver','Gold') LIMIT 1;
    -- Sticky protection: leaving a protected layer requires relation_classify().
    found_layer := COALESCE(parent_layer,CASE WHEN old_layer IN ('Silver','Gold') THEN old_layer END,found_layer,old_layer);
    IF found_layer IS NOT NULL THEN
      IF NOT EXISTS(SELECT FROM {{object:gvlt.relation_registry}} WHERE objid=t.oid AND is_active
          AND schema_name=t.nspname AND relation_name=t.relname AND layer=found_layer) THEN
        INSERT INTO {{object:gvlt.policy_audit}} (action,objid,details) VALUES ('relation_sync',t.oid,
          jsonb_build_object('schema',t.nspname,'relation',t.relname,'layer',found_layer));
      END IF;
      INSERT INTO {{object:gvlt.relation_registry}} (objid,schema_name,relation_name,layer)
      VALUES(t.oid,t.nspname,t.relname,found_layer)
      ON CONFLICT(objid) DO UPDATE SET schema_name=EXCLUDED.schema_name, relation_name=EXCLUDED.relation_name,
        layer=EXCLUDED.layer,is_active=true,updated_at=clock_timestamp();
    END IF;
    -- Follow physical OID/attnum, retaining former names as inactive history.
    FOR assoc IN SELECT * FROM {{object:gvlt.tag_obj}} WHERE obj_id=t.oid AND is_active LOOP
      next_name := NULL;
      IF {{object:lib.object_getype}}(assoc.obj_name)='r' THEN next_name := lower(obj);
      ELSIF {{object:lib.object_getype}}(assoc.obj_name)='c' THEN
        SELECT attname INTO column_name FROM pg_attribute WHERE attrelid=t.oid AND NOT attisdropped AND attnum>0
          AND attnum=CASE WHEN assoc.ctrl_config->>'_column_attnum' ~ '^[0-9]+$' THEN (assoc.ctrl_config->>'_column_attnum')::int END;
        IF FOUND THEN next_name := lower(obj||'.'||column_name); END IF;
      ELSE CONTINUE; END IF;
      IF next_name IS DISTINCT FROM assoc.obj_name THEN
        UPDATE {{object:gvlt.tag_obj}} SET is_active=false WHERE obj_name=assoc.obj_name AND tag_name=assoc.tag_name;
        IF next_name IS NOT NULL THEN
          INSERT INTO {{object:gvlt.tag_obj}} (obj_name,obj_id,tag_name,is_active,ctrl_config)
            VALUES(next_name,t.oid,assoc.tag_name,true,assoc.ctrl_config)
            ON CONFLICT(obj_name,tag_name) DO UPDATE SET obj_id=EXCLUDED.obj_id,is_active=true,ctrl_config=EXCLUDED.ctrl_config;
        END IF;
      END IF;
    END LOOP;
    IF found_layer IS NULL THEN CONTINUE; END IF;
    UPDATE {{object:gvlt.tag_obj}} SET is_active=false WHERE obj_id=t.oid AND is_active
      AND tag_name IN ('Bronze','Silver','Gold') AND tag_name<>found_layer;
    INSERT INTO {{object:gvlt.tag_obj}} (obj_name,obj_id,tag_name,is_active)
      VALUES(lower(obj),t.oid,found_layer,true)
      ON CONFLICT(obj_name,tag_name) DO UPDATE SET obj_id=EXCLUDED.obj_id,is_active=true;
  END LOOP;
  UPDATE {{object:gvlt.relation_registry}} r SET is_active=false,updated_at=clock_timestamp()
    WHERE is_active AND NOT EXISTS(SELECT FROM pg_class c WHERE c.oid=r.objid);
  UPDATE {{object:gvlt.installation}} SET catalog_busy=false;
  PERFORM {{object:gvlt.policy_apply}}();
END $$;

CREATE FUNCTION {{object:gvlt.policy_set}}(p_enabled boolean,p_master text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE old_cfg record; master_id oid; t record; old_name name; kind text;
BEGIN
  IF NOT {{object:gvlt.policy_is_admin}}() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501'; END IF;
  SELECT * INTO old_cfg FROM {{object:gvlt.installation}} FOR UPDATE;
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'Explicit enabled/disabled value required'; END IF;
  IF p_enabled THEN
    SELECT oid INTO master_id FROM pg_roles WHERE rolname=p_master;
    PERFORM {{object:gvlt.policy_validate_roles}}(master_id);
  END IF;
  IF p_enabled AND old_cfg.master_oid IS NOT NULL AND old_cfg.master_oid<>master_id THEN
    SELECT rolname INTO old_name FROM pg_roles WHERE oid=old_cfg.master_oid;
    IF old_name IS NOT NULL THEN
      FOR t IN SELECT * FROM {{object:gvlt.policy_grants}} WHERE grantee=old_cfg.master_oid LOOP
        kind := CASE WHEN t.classid='pg_namespace'::regclass THEN 'SCHEMA'
                     WHEN EXISTS(SELECT FROM pg_class WHERE oid=t.objid AND relkind='S') THEN 'SEQUENCE' ELSE 'TABLE' END;
        IF (t.classid='pg_namespace'::regclass AND EXISTS(SELECT FROM pg_namespace WHERE oid=t.objid))
           OR (t.classid='pg_class'::regclass AND EXISTS(SELECT FROM pg_class WHERE oid=t.objid)) THEN
          IF t.classid='pg_namespace'::regclass THEN SELECT quote_ident(nspname) INTO t.object_identity FROM pg_namespace WHERE oid=t.objid;
          ELSE SELECT format('%I.%I',n.nspname,c.relname) INTO t.object_identity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=t.objid; END IF;
          EXECUTE format('REVOKE %s ON %s %s FROM %I CASCADE',t.privilege,kind,t.object_identity,old_name);
          INSERT INTO {{object:gvlt.policy_audit}} (action,objid,details) VALUES ('revoke_previous_master',t.objid,
            jsonb_build_object('identity',t.object_identity,'role',old_name,'privilege',t.privilege,'kind',kind));
        END IF;
      END LOOP;
      DELETE FROM {{object:gvlt.policy_grants}} WHERE grantee=old_cfg.master_oid;
      FOR t IN SELECT c.oid,c.relname,c.relacl,n.nspname FROM {{object:gvlt.relation_registry}} r
        JOIN pg_class c ON c.oid=r.objid JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE r.is_active AND r.layer IN ('Silver','Gold')
      LOOP
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE %I.%I FROM %I CASCADE',t.nspname,t.relname,old_name);
        INSERT INTO {{object:gvlt.policy_audit}} (action,objid,details) VALUES ('revoke_previous_master',t.oid,
          jsonb_build_object('role',old_name,'before_acl',t.relacl::text,'after_acl',(SELECT relacl::text FROM pg_class WHERE oid=t.oid)));
      END LOOP;
    END IF;
  END IF;
  UPDATE {{object:gvlt.installation}} SET restrictive=p_enabled,master_oid=COALESCE(master_id,master_oid);
  IF p_enabled THEN PERFORM {{object:gvlt.relation_sync}}(); END IF;
  INSERT INTO {{object:gvlt.policy_audit}} (action,details) VALUES
    ('policy_set',jsonb_build_object('before',to_jsonb(old_cfg),'enabled',p_enabled,'master_oid',COALESCE(master_id,old_cfg.master_oid),
      'master_role',COALESCE(p_master,(SELECT rolname::text FROM pg_roles WHERE oid=old_cfg.master_oid)),
      'previous_master_role',(SELECT rolname FROM pg_roles WHERE oid=old_cfg.master_oid),
      'restoration',CASE WHEN NOT p_enabled THEN 'Permissions remain restricted. Review permission_history and apply approved grants explicitly.' END));
END $$;

CREATE FUNCTION {{object:gvlt.relation_classify}}(p_relation regclass,p_layer text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE physical text; parent_layer text;
BEGIN
  IF NOT {{object:gvlt.policy_is_admin}}() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501'; END IF;
  IF p_layer NOT IN ('Bronze','Silver','Gold') OR p_layer IS NULL THEN RAISE EXCEPTION 'Use Bronze, Silver or Gold'; END IF;
  IF {{object:gvlt.relation_is_internal}}(p_relation::oid) THEN RAISE EXCEPTION 'Internal or out-of-scope object cannot be classified'; END IF;
  physical := {{object:gvlt.relation_layer}}(p_relation::oid);
  IF physical IS NOT NULL AND physical<>p_layer THEN
    RAISE EXCEPTION 'Rename or move the object to match layer % before reclassification',p_layer;
  END IF;
  SELECT r.layer INTO parent_layer FROM pg_inherits inh JOIN {{object:gvlt.relation_registry}} r ON r.objid=inh.inhparent
    WHERE inh.inhrelid=p_relation::oid AND r.is_active AND r.layer IN ('Silver','Gold') LIMIT 1;
  IF parent_layer IS NOT NULL AND p_layer<>parent_layer THEN RAISE EXCEPTION 'Partition must retain its protected parent layer'; END IF;
  UPDATE {{object:gvlt.relation_registry}} SET layer=p_layer WHERE objid=p_relation::oid;
  UPDATE {{object:gvlt.tag_obj}} SET is_active=false WHERE obj_id=p_relation::oid
    AND tag_name IN ('Bronze','Silver','Gold') AND tag_name<>p_layer;
  INSERT INTO {{object:gvlt.policy_audit}} (action,objid,details) VALUES ('classify',p_relation::oid,jsonb_build_object('layer',p_layer));
  -- For a new unprefixed object, seed the association before synchronization.
  INSERT INTO {{object:gvlt.tag_obj}} (obj_name,obj_id,tag_name)
    SELECT lower(n.nspname||'.'||c.relname),c.oid,p_layer FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=p_relation::oid
    ON CONFLICT(obj_name,tag_name) DO UPDATE SET is_active=true,obj_id=EXCLUDED.obj_id;
  PERFORM {{object:gvlt.relation_sync}}();
END $$;

CREATE FUNCTION {{object:gvlt.relation_ddl_event}}() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE cmd record; actor_admin boolean; active_policy boolean;
BEGIN
  IF (SELECT policy_busy FROM {{object:gvlt.installation}}) THEN RETURN; END IF;
  actor_admin := {{object:gvlt.policy_is_admin}}();
  SELECT restrictive INTO active_policy FROM {{object:gvlt.installation}};
  IF EXISTS(SELECT FROM {{object:gvlt.installation}} i JOIN {{object:gvlt.relation_registry}} r ON r.is_active
      JOIN pg_class c ON c.oid=r.objid JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE i.layout='single' AND n.nspname<>i.target_schema) THEN
    RAISE EXCEPTION 'Single layout: governed relations must stay in the authorized schema';
  END IF;
  FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE classid='pg_class'::regclass
  LOOP
    IF active_policy AND NOT actor_admin AND
      ({{object:gvlt.relation_layer}}(cmd.objid) IN ('Silver','Gold') OR EXISTS
        (SELECT FROM {{object:gvlt.relation_registry}} WHERE objid=cmd.objid AND is_active AND layer IN ('Silver','Gold'))) THEN
      RAISE EXCEPTION 'Only administrators may create or alter protected objects' USING ERRCODE='42501';
    END IF;
  END LOOP;
  IF active_policy AND NOT actor_admin THEN
    IF EXISTS(SELECT FROM pg_event_trigger_ddl_commands() d JOIN pg_class c ON
        (d.classid='pg_namespace'::regclass AND c.relnamespace=d.objid)
        OR (d.classid='pg_class'::regclass AND c.oid=(SELECT indrelid FROM pg_index WHERE indexrelid=d.objid))
        OR (d.classid='pg_trigger'::regclass AND c.oid=(SELECT tgrelid FROM pg_trigger WHERE oid=d.objid))
      JOIN {{object:gvlt.relation_registry}} r ON r.objid=c.oid WHERE r.is_active AND r.layer IN ('Silver','Gold')) THEN
      RAISE EXCEPTION 'Only administrators may alter protected schemas, indexes or triggers' USING ERRCODE='42501';
    END IF;
  END IF;
  PERFORM {{object:gvlt.relation_sync}}();
  -- A partition can acquire protection through a parent despite an unrelated name.
  IF active_policy AND NOT actor_admin THEN
    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE classid='pg_class'::regclass LOOP
      IF EXISTS(SELECT FROM {{object:gvlt.relation_registry}} WHERE objid=cmd.objid AND is_active AND layer IN ('Silver','Gold')) THEN
        RAISE EXCEPTION 'Only administrators may alter protected objects or partitions' USING ERRCODE='42501';
      END IF;
    END LOOP;
  END IF;
END $$;

CREATE FUNCTION {{object:gvlt.relation_drop_event}}() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE obj record;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE objsubid=0
  LOOP
    IF obj.classid='pg_trigger'::regclass AND obj.address_names[3] IN ('gvlt_write_guard','gvlt_truncate_guard')
       AND (SELECT restrictive FROM {{object:gvlt.installation}}) AND NOT {{object:gvlt.policy_is_admin}}() THEN
      RAISE EXCEPTION 'Only administrators may remove policy guards' USING ERRCODE='42501';
    END IF;
    IF obj.classid<>'pg_class'::regclass THEN CONTINUE; END IF;
    IF EXISTS(SELECT FROM {{object:gvlt.relation_registry}} WHERE objid=obj.objid AND is_active AND layer IN ('Silver','Gold'))
       AND (SELECT restrictive FROM {{object:gvlt.installation}}) AND NOT {{object:gvlt.policy_is_admin}}() THEN
      RAISE EXCEPTION 'Only administrators may drop protected objects' USING ERRCODE='42501';
    END IF;
    UPDATE {{object:gvlt.relation_registry}} SET is_active=false,updated_at=clock_timestamp() WHERE objid=obj.objid;
    UPDATE {{object:gvlt.tag_obj}} SET is_active=false WHERE obj_id=obj.objid
      AND {{object:lib.object_getype}}(obj_name) IN ('r','c');
  END LOOP;
END $$;

CREATE FUNCTION {{object:gvlt.tag_layer_event}}() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF (SELECT catalog_busy FROM {{object:gvlt.installation}}) THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND NEW IS NOT DISTINCT FROM OLD THEN RETURN NEW; END IF;
  IF pg_trigger_depth()=1 AND NEW.is_active AND NEW.tag_name IN ('Silver','Gold','Bronze')
     AND {{object:lib.object_getype}}(NEW.obj_name)='r' THEN
    IF {{object:gvlt.relation_is_internal}}(to_regclass(NEW.obj_name)::oid) THEN RAISE EXCEPTION 'Internal or out-of-scope object cannot be assigned a layer'; END IF;
    IF {{object:gvlt.relation_layer}}(to_regclass(NEW.obj_name)::oid) IS NOT NULL
       AND {{object:gvlt.relation_layer}}(to_regclass(NEW.obj_name)::oid)<>NEW.tag_name THEN
      RAISE EXCEPTION 'Name/layer conflict; rename or move the relation before classification';
    END IF;
    PERFORM {{object:gvlt.relation_sync}}();
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION {{object:gvlt.tag_object_identity}}() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE parts text[]; kind "char"; relation_oid oid; colnum smallint;
BEGIN
  parts := string_to_array(NEW.obj_name,'.');
  kind := {{object:lib.object_getype}}(NEW.obj_name);
  IF kind='s' THEN
    SELECT oid INTO relation_oid FROM pg_namespace WHERE nspname=parts[1];
  ELSIF kind IN ('r','c') THEN
    relation_oid := to_regclass(format('%I.%I',parts[1],parts[2]));
    IF kind='c' AND relation_oid IS NOT NULL THEN
      SELECT attnum INTO colnum FROM pg_attribute WHERE attrelid=relation_oid AND attname=parts[3] AND attnum>0 AND NOT attisdropped;
      IF FOUND THEN NEW.ctrl_config := COALESCE(NEW.ctrl_config,'{}') || jsonb_build_object('_column_attnum',colnum); END IF;
    END IF;
  END IF;
  IF relation_oid IS NOT NULL THEN NEW.obj_id := relation_oid; END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER gvlt_tag_identity BEFORE INSERT OR UPDATE ON {{object:gvlt.tag_obj}}
FOR EACH ROW EXECUTE FUNCTION {{object:gvlt.tag_object_identity}}();

CREATE TRIGGER gvlt_tag_layer AFTER INSERT OR UPDATE ON {{object:gvlt.tag_obj}}
FOR EACH ROW EXECUTE FUNCTION {{object:gvlt.tag_layer_event}}();

CREATE EVENT TRIGGER gvlt_relation_ddl ON ddl_command_end
WHEN TAG IN ('CREATE TABLE','CREATE TABLE AS','SELECT INTO','ALTER TABLE','CREATE VIEW','ALTER VIEW',
 'CREATE MATERIALIZED VIEW','ALTER MATERIALIZED VIEW','REFRESH MATERIALIZED VIEW','CREATE FOREIGN TABLE','ALTER FOREIGN TABLE',
 'CREATE SCHEMA','ALTER SCHEMA','CREATE INDEX','ALTER INDEX','CREATE TRIGGER','ALTER TRIGGER')
EXECUTE FUNCTION {{object:gvlt.relation_ddl_event}}();
CREATE EVENT TRIGGER gvlt_relation_drop ON sql_drop
EXECUTE FUNCTION {{object:gvlt.relation_drop_event}}();

CREATE FUNCTION {{object:gvlt.policy_check}}()
RETURNS TABLE(object_identity text,layer text,issue text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT format('%I.%I',n.nspname,c.relname),r.layer,
    CASE WHEN {{object:gvlt.relation_layer}}(c.oid) IS DISTINCT FROM r.layer THEN 'Name/classification differs; retained catalog protection'
         WHEN c.relkind IN ('r','p','f') AND NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid=c.oid AND tgname='gvlt_write_guard' AND tgenabled='A')
           AND i.restrictive THEN 'Missing or disabled write guard'
         ELSE 'OK' END
  FROM {{object:gvlt.relation_registry}} r JOIN pg_class c ON c.oid=r.objid JOIN pg_namespace n ON n.oid=c.relnamespace
  CROSS JOIN {{object:gvlt.installation}} i WHERE r.is_active
  UNION ALL
  SELECT format('%I.%I',n.nspname,c.relname),r.layer,
    format('Unexpected %s privilege for %s',a.privilege_type,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END)
  FROM {{object:gvlt.relation_registry}} r JOIN pg_class c ON c.oid=r.objid JOIN pg_namespace n ON n.oid=c.relnamespace
  CROSS JOIN {{object:gvlt.installation}} i CROSS JOIN LATERAL aclexplode(c.relacl) a
  WHERE i.restrictive AND r.is_active AND r.layer IN ('Silver','Gold') AND a.grantee<>c.relowner AND a.grantee<>i.master_oid
    AND a.privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
  UNION ALL
  SELECT format('%I.%I',n.nspname,c.relname),r.layer,format('Unexpected column %I %s privilege for %s',col.attname,a.privilege_type,
    CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END)
  FROM {{object:gvlt.relation_registry}} r JOIN pg_class c ON c.oid=r.objid JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN pg_attribute col ON col.attrelid=c.oid AND col.attnum>0 AND NOT col.attisdropped
  CROSS JOIN {{object:gvlt.installation}} i CROSS JOIN LATERAL aclexplode(col.attacl) a
  WHERE i.restrictive AND r.is_active AND r.layer IN ('Silver','Gold') AND a.grantee<>c.relowner AND a.grantee<>i.master_oid
    AND a.privilege_type IN ('INSERT','UPDATE','REFERENCES')
$$;

CREATE FUNCTION {{object:gvlt.permission_review}}(p_history_id bigint,p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT {{object:gvlt.policy_is_admin}}() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501'; END IF;
  IF p_note IS NULL OR trim(p_note)='' THEN RAISE EXCEPTION 'Review note required; apply approved grants explicitly'; END IF;
  UPDATE {{object:gvlt.permission_history}} SET reviewed_at=clock_timestamp(),review_note=p_note WHERE id=p_history_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown history entry'; END IF;
  INSERT INTO {{object:gvlt.policy_audit}} (action,details) VALUES ('permission_review',jsonb_build_object('history_id',p_history_id,'note',p_note));
END $$;

CREATE FUNCTION {{object:gvlt.governance_check}}()
RETURNS TABLE(check_name text,severity text,obj_name text,message text)
LANGUAGE sql STABLE AS $$
  SELECT b.* FROM {{object:gvlt.governance_check_base}}() b
  CROSS JOIN {{object:gvlt.installation}} i
  WHERE i.layout='multi' OR (b.check_name NOT IN ('invalid_medallion_schema_name','medallion_schema_without_catalog_tag')
    AND (b.obj_name=i.target_schema OR left(b.obj_name,length(i.target_schema)+1)=i.target_schema||'.'))
  UNION ALL
  SELECT 'relation_name_classification_differs','warning',format('%I.%I',r.schema_name,r.relation_name),
    'Physical name differs from catalog layer; protection is retained until administrative reclassification.'
  FROM {{object:gvlt.relation_registry}} r WHERE r.is_active
    AND {{object:gvlt.relation_layer}}(r.objid) IS DISTINCT FROM r.layer
$$;

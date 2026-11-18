-- Keep aligned and updated with AddressForAll/pg_pubLib-v1 src/pubLib01py-string.sql, revision e023d292b81b112ac9d4379e36825c75cd47615d; curator to be assigned.
-- Curated copies of YAML and Mustache functions. Adaptations use layout tokens,
-- json.loads/safe_dump for JSON input, and volatility appropriate for file access.

CREATE FUNCTION @extschema@."lib_yaml_to_jsonb"(p_yaml text) RETURNS jsonb AS $f$
    import yaml
    import json
    return json.dumps(yaml.safe_load(p_yaml))
$f$ LANGUAGE plpython3u IMMUTABLE STRICT;

CREATE FUNCTION @extschema@."lib_jsonb_to_yaml"(p_jsonb text) RETURNS text AS $f$
    import yaml
    import json
    return yaml.safe_dump(json.loads(p_jsonb), allow_unicode=True)
$f$ LANGUAGE plpython3u IMMUTABLE STRICT;

CREATE FUNCTION @extschema@."lib_jsonb_to_yaml"(p_jsonb text, flow_style boolean) RETURNS text AS $f$
    import yaml
    import json
    return yaml.safe_dump(json.loads(p_jsonb), allow_unicode=True, default_flow_style=flow_style)
$f$ LANGUAGE plpython3u IMMUTABLE STRICT;

CREATE FUNCTION @extschema@."lib_jsonb_mustache_render"(
    tpl text,
    i jsonb,
    partials_path text DEFAULT ''
) RETURNS text AS $f$
    import chevron
    import json
    return chevron.render(tpl, json.loads(i), partials_path=partials_path)
$f$ LANGUAGE plpython3u VOLATILE STRICT;

CREATE FUNCTION @extschema@."lib_yamlfile_to_jsonb"(file text) RETURNS jsonb
LANGUAGE SQL VOLATILE STRICT
BEGIN ATOMIC
    SELECT @extschema@."lib_yaml_to_jsonb"(pg_catalog.pg_read_file(file));
END;

REVOKE ALL ON FUNCTION @extschema@."lib_yaml_to_jsonb"(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION @extschema@."lib_jsonb_to_yaml"(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION @extschema@."lib_jsonb_to_yaml"(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION @extschema@."lib_jsonb_mustache_render"(text, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION @extschema@."lib_yamlfile_to_jsonb"(text) FROM PUBLIC;

-- Apply the same owner-only access as the core installer, including default grants.
DO $acl$
DECLARE routine record; privilege record;
BEGIN
    FOR routine IN
        SELECT p.oid::regprocedure AS signature, p.proacl, p.proowner
        FROM pg_catalog.pg_proc p
        WHERE p.oid IN (
            '@extschema@."lib_yaml_to_jsonb"(text)'::regprocedure,
            '@extschema@."lib_jsonb_to_yaml"(text)'::regprocedure,
            '@extschema@."lib_jsonb_to_yaml"(text,boolean)'::regprocedure,
            '@extschema@."lib_jsonb_mustache_render"(text,jsonb,text)'::regprocedure,
            '@extschema@."lib_yamlfile_to_jsonb"(text)'::regprocedure
        )
    LOOP
        FOR privilege IN SELECT DISTINCT grantee FROM pg_catalog.aclexplode(routine.proacl)
                         WHERE grantee <> 0 AND grantee <> routine.proowner
        LOOP
            EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I CASCADE',
                           routine.signature, pg_catalog.pg_get_userbyid(privilege.grantee));
        END LOOP;
    END LOOP;
END $acl$;

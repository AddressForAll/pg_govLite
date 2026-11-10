-- Installation metadata stays in the authorized namespace in both layouts.
CREATE TABLE {{object:gvlt.installation}} (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  version text NOT NULL DEFAULT 'single-schema-v1',
  layout text NOT NULL CHECK (layout IN ('single','multi')),
  target_schema name NOT NULL,
  owner_oid oid NOT NULL,
  restrictive boolean NOT NULL DEFAULT false,
  policy_busy boolean NOT NULL DEFAULT false,
  catalog_busy boolean NOT NULL DEFAULT false,
  master_oid oid,
  installed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE {{object:gvlt.prefix_dictionary}} (
  reserved_word text PRIMARY KEY,
  prefix text NOT NULL UNIQUE CHECK (right(prefix,1)='_'),
  legacy_schema name NOT NULL
);
CREATE TABLE {{object:gvlt.relation_registry}} (
  objid oid PRIMARY KEY,
  schema_name name NOT NULL,
  relation_name name NOT NULL,
  layer text NOT NULL CHECK (layer IN ('Bronze','Silver','Gold')),
  is_active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE {{object:gvlt.policy_audit}} (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  happened_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  executor name NOT NULL DEFAULT session_user,
  effective_role text NOT NULL DEFAULT current_setting('role'),
  action text NOT NULL,
  objid oid,
  details jsonb NOT NULL DEFAULT '{}'
);
CREATE TABLE {{object:gvlt.permission_history}} (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  objid oid NOT NULL,
  object_identity text NOT NULL,
  original_owner oid NOT NULL,
  original_acl aclitem[],
  column_acls jsonb NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reviewed_at timestamptz,
  review_note text
);
CREATE TABLE {{object:gvlt.policy_grants}} (
  classid oid NOT NULL,
  objid oid NOT NULL,
  grantee oid NOT NULL,
  privilege text NOT NULL,
  object_identity text NOT NULL,
  PRIMARY KEY(classid,objid,grantee,privilege)
);

CREATE FUNCTION {{object:gvlt.object_name}}(p_group text, p_base text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE s name; p text; m text; result text;
BEGIN
  SELECT layout,target_schema INTO m,s FROM {{object:gvlt.installation}};
  SELECT prefix, CASE WHEN m='multi' THEN legacy_schema ELSE s END
    INTO p,s FROM {{object:gvlt.prefix_dictionary}} WHERE reserved_word=p_group;
  IF NOT FOUND OR p_base IS NULL OR p_base='' THEN RAISE EXCEPTION 'Unknown group or empty base name'; END IF;
  result := CASE WHEN m='single' THEN p ELSE '' END || p_base;
  IF octet_length(result)>63 THEN RAISE EXCEPTION 'Object name exceeds 63 bytes'; END IF;
  RETURN format('%I.%I',s,result);
END $$;

CREATE FUNCTION {{object:gvlt.object_name_parse}}(p_name text)
RETURNS TABLE(reserved_word text, prefix text, base_name text)
LANGUAGE sql STABLE AS $$
  SELECT d.reserved_word, d.prefix, substr(p_name,length(d.prefix)+1)
  FROM {{object:gvlt.prefix_dictionary}} d
  WHERE left(p_name,length(d.prefix))=d.prefix AND length(p_name)>length(d.prefix)
$$;

CREATE OR REPLACE FUNCTION {{object:gvlt.medallion_objects}}(p_schema_name text DEFAULT NULL)
RETURNS TABLE(schema_name text,medallion_tag text,obj_name text,obj_type text,relkind text,tags text[])
LANGUAGE sql AS $$
WITH med AS (
  SELECT DISTINCT o.obj_name AS schema_name,o.tag_name AS medallion_tag
  FROM {{object:gvlt.tag_obj}} o JOIN {{object:gvlt.tag}} t ON t.tag_name=o.tag_name
  WHERE o.is_active AND t.is_active AND t.role='medallion'
    AND {{object:lib.object_getype}}(o.obj_name)='s'
    AND (p_schema_name IS NULL OR o.obj_name=p_schema_name)
), objects AS (
  SELECT m.schema_name,m.medallion_tag,m.schema_name AS obj_name,'schema'::text AS obj_type,NULL::text AS relkind FROM med m
  UNION
  SELECT m.schema_name,m.medallion_tag,(n.nspname||'.'||c.relname)::text,'relation',{{object:lib.pgddl_relkind_to_objtype}}(c.relkind)
  FROM med m JOIN pg_namespace n ON n.nspname=m.schema_name JOIN pg_class c ON c.relnamespace=n.oid
  WHERE c.relkind IN ('r','p','v','m','f')
  UNION
  SELECT r.schema_name::text,r.layer,(r.schema_name||'.'||r.relation_name)::text,'relation',{{object:lib.pgddl_relkind_to_objtype}}(c.relkind)
  FROM {{object:gvlt.relation_registry}} r JOIN pg_class c ON c.oid=r.objid
  WHERE r.is_active AND (p_schema_name IS NULL OR r.schema_name=p_schema_name)
)
SELECT o.*,(SELECT array_agg(t.tag_name ORDER BY t.tag_name) FROM {{object:gvlt.tag_obj}} t
  JOIN {{object:gvlt.tag}} g ON g.tag_name=t.tag_name
  WHERE t.obj_name=lower(o.obj_name) AND t.is_active AND g.is_active)
FROM objects o ORDER BY schema_name,obj_type,obj_name
$$;

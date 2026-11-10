-- Single layout exposes relation-level Medallion metadata, preserving return columns.
CREATE OR REPLACE FUNCTION {{object:gvlt.medallion_objects}}(p_schema_name text DEFAULT NULL)
RETURNS TABLE(schema_name text,medallion_tag text,obj_name text,obj_type text,relkind text,tags text[])
LANGUAGE sql AS $$
  SELECT r.schema_name::text,r.layer,(r.schema_name||'.'||r.relation_name)::text,'relation'::text,
    {{object:lib.pgddl_relkind_to_objtype}}(c.relkind),
    (SELECT array_agg(o.tag_name ORDER BY o.tag_name) FROM {{object:gvlt.tag_obj}} o
      JOIN {{object:gvlt.tag}} t ON t.tag_name=o.tag_name WHERE o.is_active AND t.is_active
      AND o.obj_name=lower(r.schema_name||'.'||r.relation_name))
  FROM {{object:gvlt.relation_registry}} r JOIN pg_class c ON c.oid=r.objid
  WHERE r.is_active AND (p_schema_name IS NULL OR r.schema_name=p_schema_name)
  ORDER BY r.schema_name,r.relation_name
$$;
CREATE OR REPLACE VIEW {{object:gvlt.vw01_medallion}} AS
  SELECT o.*,t.tag_desc FROM {{object:gvlt.tag_obj}} o JOIN {{object:gvlt.tag}} t ON t.tag_name=o.tag_name
  WHERE t.is_active AND o.is_active AND t.role='medallion' AND {{object:lib.object_getype}}(o.obj_name)='r';

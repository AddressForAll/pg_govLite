
-- -- -- -- -- -- -- -- -- -- --
--- Public Helper functions:

CREATE or replace FUNCTION ROUND(float,int) RETURNS NUMERIC AS $wrap$
   SELECT ROUND($1::numeric,$2)
$wrap$ language SQL IMMUTABLE PARALLEL SAFE;
COMMENT ON FUNCTION ROUND(float,int)
  IS 'Cast for ROUND(float,x). Useful for SUM, AVG, etc. See also https://stackoverflow.com/a/20934099/287948.'
;

CREATE or replace FUNCTION array_distinct(
  ANYARRAY,
  p_no_null boolean DEFAULT true
) RETURNS ANYARRAY AS $f$
  SELECT CASE WHEN array_length(x,1) IS NULL THEN NULL ELSE x END
  FROM (
    SELECT ARRAY(
        SELECT DISTINCT x
        FROM unnest($1) t(x)
        WHERE CASE
          WHEN p_no_null  THEN  x IS NOT NULL
          ELSE  true
          END
    )
 ) t(x)
$f$ language SQL strict IMMUTABLE;


CREATE or replace FUNCTION array_distinct_sort (
  ANYARRAY,
  p_no_null boolean DEFAULT true
) RETURNS ANYARRAY AS $f$
  SELECT CASE WHEN array_length(x,1) IS NULL THEN NULL ELSE x END -- same as  x='{}'::anyarray
  FROM (
  	SELECT ARRAY(
        SELECT DISTINCT x
        FROM unnest($1) t(x)
        WHERE CASE
          WHEN p_no_null  THEN  x IS NOT NULL
          ELSE  true
          END
        ORDER BY 1
   )
 ) t(x)
$f$ language SQL strict IMMUTABLE;

CREATE or replace FUNCTION jsonb_object_keys_asarray(_js jsonb)
  RETURNS text[]
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT  array_agg(x) FROM jsonb_object_keys($1) t(x);
END;
COMMENT ON FUNCTION jsonb_object_keys_asarray(jsonb)
  IS 'JSONB_keys-to-SQL_text_array optimized convertion.';

CREATE or replace FUNCTION jsonb_array_to_text_array(_js jsonb, apply_sort boolean DEFAULT false)
  RETURNS text[]
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE WHEN $1 IS NULL THEN NULL WHEN apply_sort THEN array_distinct_sort(x) ELSE x END 
  FROM (  SELECT CASE WHEN $1 IS NULL THEN NULL ELSE ARRAY(SELECT jsonb_array_elements_text($1)) END ) t(x);
END;
COMMENT ON FUNCTION jsonb_array_to_text_array(jsonb,boolean)
  IS 'JSONB-to-SQL_text arrays optimized convertion, for pg14+. See https://dba.stackexchange.com/a/54289/90651';

-- -- -- -- -- -- -- -- -- -- --
--- LIB Helper functions:
DROP SCHEMA IF EXISTS lib CASCADE;
CREATE SCHEMA lib;

CREATE or replace FUNCTION lib.dynamic_query(text) RETURNS SETOF RECORD AS
$f$
 BEGIN
    RETURN QUERY EXECUTE $1;
 END
$f$ language  PLpgSQL;
COMMENT ON FUNCTION lib.dynamic_query(text)
  IS 'Executes dynamically the text as a SQL-query (DQL command).'
;

CREATE or replace FUNCTION lib.dynamic_execute(text) RETURNS boolean AS
$f$
 BEGIN
    RAISE NOTICE '-- EXE %',substring(trim($1),1,250)||'...'; -- max 253 columns
    EXECUTE $1 ;
    RETURN true;  -- ideal return execute
 END
$f$ language  PLpgSQL;
COMMENT ON FUNCTION lib.dynamic_execute(text)
  IS 'Executes dynamically the text as a SQL non-DQL COMMAND, like CREATE TABLE.'
;

CREATE or replace FUNCTION lib.rel_disk_usage(p_list text[]) RETURNS TABLE(
     schema_name text, relname text, size text, size_bytes bigint
) AS $f$
SELECT
  schema_name, relname,
  pg_size_pretty(table_size) AS size,
  table_size as size_bytes
FROM (
       SELECT
         pg_catalog.pg_namespace.nspname           AS schema_name,
         relname,
         pg_relation_size(pg_catalog.pg_class.oid) AS table_size
       FROM pg_catalog.pg_class
         JOIN pg_catalog.pg_namespace ON relnamespace = pg_catalog.pg_namespace.oid
     ) t
WHERE CASE WHEN p_list IS NULL THEN true ELSE schema_name = ANY (p_list) END
ORDER BY schema_name, table_size DESC;
$f$ language SQL;

-- SELECT * FROM lib.rel_disk_usage('{dpvd24,fw_bronze}'::text[]);


/**
 * Documentation examples as executable views.
 *
 * Stores each example query as a view in gvlt_doc_examples, using stable
 * ex<ID> names controlled by gvlt.doc_examples_id_seq.
 */

CREATE SCHEMA IF NOT EXISTS gvlt_doc_examples;

CREATE SEQUENCE IF NOT EXISTS gvlt.doc_examples_id_seq;

CREATE TABLE IF NOT EXISTS gvlt.doc_examples (
  id bigint PRIMARY KEY DEFAULT nextval('gvlt.doc_examples_id_seq'::regclass),
  view_schema name NOT NULL DEFAULT 'gvlt_doc_examples',
  view_name name NOT NULL UNIQUE,
  payload text NOT NULL,
  payload_md5 text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS gvlt.doc_example_secondary (
  example_id bigint NOT NULL REFERENCES gvlt.doc_examples(id) ON DELETE CASCADE,
  function_oid oid,
  is_secondary boolean NOT NULL DEFAULT true,
  note text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE UNIQUE INDEX IF NOT EXISTS doc_example_secondary_example_uniq
  ON gvlt.doc_example_secondary (example_id)
  WHERE function_oid IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS doc_example_secondary_pair_uniq
  ON gvlt.doc_example_secondary (example_id, function_oid)
  WHERE function_oid IS NOT NULL;

CREATE OR REPLACE FUNCTION gvlt.doc_examples_payload(
  p_query text
) RETURNS text AS $f$
  SELECT CASE
    WHEN q = '' THEN NULL
    WHEN q ~* '^select[[:space:]]+' THEN
      CASE
        WHEN q !~* '[[:space:]](from|where|group[[:space:]]+by|having|window|union|intersect|except|order[[:space:]]+by|limit|offset|fetch)[[:space:]]'
             AND q ~* '[[:space:]]+as[[:space:]]+[[:alpha:]_][[:alnum:]_]*$' THEN
          regexp_replace(q, '^select[[:space:]]+', 'SELECT ', 'i')
        WHEN q !~* '[[:space:]](from|where|group[[:space:]]+by|having|window|union|intersect|except|order[[:space:]]+by|limit|offset|fetch)[[:space:]]'
          THEN regexp_replace(q, '^select[[:space:]]+(.+)$', 'SELECT \1 AS x', 'i')
        ELSE regexp_replace(q, '^select[[:space:]]+', 'SELECT ', 'i')
      END
    ELSE format('SELECT %s AS x', q)
    END
  FROM (
    SELECT regexp_replace(
             regexp_replace(COALESCE(p_query, ''), E'[;[:space:]]+$', ''),
             E'^[[:space:]]+', ''
           ) AS q
  ) s
$f$ LANGUAGE SQL IMMUTABLE;
COMMENT ON FUNCTION gvlt.doc_examples_payload(text)
  IS 'Normalize a documentation example into a SELECT payload for gvlt.doc_examples_add().'
;

CREATE OR REPLACE FUNCTION gvlt.doc_examples_add(
  p_query text
) RETURNS text AS $f$
DECLARE
  v_payload text;
  v_payload_md5 text;
  v_id bigint;
  v_view_name name;
  v_sql text;
  v_existing name;
BEGIN
  v_payload := gvlt.doc_examples_payload(p_query);

  IF v_payload IS NULL THEN
    RAISE EXCEPTION 'Example query must not be empty';
  END IF;

  v_payload_md5 := md5(regexp_replace(v_payload, E'[[:space:]]+', ' ', 'g'));

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.schemata
    WHERE schema_name = 'gvlt_doc_examples'
  ) THEN
    CREATE SCHEMA gvlt_doc_examples;
  END IF;
  LOCK TABLE gvlt.doc_examples IN EXCLUSIVE MODE;

  SELECT view_name
  INTO v_existing
  FROM gvlt.doc_examples
  WHERE payload_md5 = v_payload_md5;

  IF v_existing IS NOT NULL THEN
    RETURN format(
      'EXISTS %I.%I AS %s',
      'gvlt_doc_examples',
      v_existing,
      v_payload
    );
  END IF;

  v_id := nextval('gvlt.doc_examples_id_seq'::regclass);
  v_view_name := ('ex' || v_id)::name;
  v_sql := format('CREATE VIEW %I.%I AS %s', 'gvlt_doc_examples', v_view_name, v_payload);

  EXECUTE v_sql;

  INSERT INTO gvlt.doc_examples (
    id,
    view_schema,
    view_name,
    payload,
    payload_md5
  ) VALUES (
    v_id,
    'gvlt_doc_examples',
    v_view_name,
    v_payload,
    v_payload_md5
  );

  RETURN v_sql;
END;
$f$ LANGUAGE plpgsql;
COMMENT ON FUNCTION gvlt.doc_examples_add(text)
  IS 'Create a gvlt_doc_examples.ex<ID> view for a documentation example query, avoiding duplicate view payloads.'
;

CREATE OR REPLACE FUNCTION gvlt.add_example(
  p_query text
) RETURNS text AS $f$
  SELECT gvlt.doc_examples_add(p_query)
$f$ LANGUAGE SQL;
COMMENT ON FUNCTION gvlt.add_example(text)
  IS 'Compatibility wrapper for gvlt.doc_examples_add(text).'
;

CREATE OR REPLACE VIEW gvlt.vw_doc_view_function_dependencies AS
SELECT DISTINCT
  vc.oid AS view_oid,
  vn.nspname::text AS view_schema,
  vc.relname::text AS view_name,
  (vc.oid::regclass)::text AS view_signature,
  d.deptype,
  p.oid AS function_oid,
  pn.nspname::text AS function_schema,
  p.proname::text AS function_name,
  p.oid::regprocedure::text AS function_signature,
  CASE p.prokind
    WHEN 'a' THEN 'agg'
    WHEN 'w' THEN 'window'
    WHEN 'p' THEN 'proc'
    ELSE 'func'
  END AS function_type
FROM pg_rewrite r
JOIN pg_class vc
  ON vc.oid = r.ev_class
 AND vc.relkind IN ('v', 'm')
JOIN pg_namespace vn
  ON vn.oid = vc.relnamespace
JOIN pg_depend d
  ON d.objid = r.oid
 AND d.refclassid = 'pg_proc'::regclass
JOIN pg_proc p
  ON p.oid = d.refobjid
JOIN pg_namespace pn
  ON pn.oid = p.pronamespace
WHERE r.rulename = '_RETURN'
  AND vn.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pn.nspname NOT IN ('pg_catalog', 'information_schema');
COMMENT ON VIEW gvlt.vw_doc_view_function_dependencies
  IS 'Lists PostgreSQL view dependencies on user-defined functions, using pg_rewrite and pg_depend.'
;

CREATE OR REPLACE VIEW gvlt.vw_doc_function_examples AS
WITH deps AS (
  SELECT DISTINCT
    e.id AS example_id,
    e.view_schema,
    e.view_name,
    fd.view_signature AS example_view,
    e.payload,
    e.created_at,
    fd.deptype,
    fd.function_oid,
    fd.function_schema,
    fd.function_name,
    fd.function_signature,
    fd.function_type
  FROM gvlt.doc_examples e
  JOIN gvlt.vw_doc_view_function_dependencies fd
    ON fd.view_schema = e.view_schema::text
   AND fd.view_name = e.view_name::text
),
dep_count AS (
  SELECT example_id, count(*) AS function_count
  FROM deps
  GROUP BY example_id
)
SELECT
  d.example_id,
  d.view_schema,
  d.view_name,
  d.example_view,
  d.payload,
  d.created_at,
  d.deptype,
  d.function_oid,
  d.function_schema,
  d.function_name,
  d.function_signature,
  d.function_type,
  (c.function_count = 1) AS is_exclusive,
  COALESCE(pair_sec.is_secondary, all_sec.is_secondary, false) AS is_secondary,
  COALESCE(pair_sec.note, all_sec.note) AS secondary_note
FROM deps d
JOIN dep_count c
  ON c.example_id = d.example_id
LEFT JOIN gvlt.doc_example_secondary all_sec
  ON all_sec.example_id = d.example_id
 AND all_sec.function_oid IS NULL
LEFT JOIN gvlt.doc_example_secondary pair_sec
  ON pair_sec.example_id = d.example_id
 AND pair_sec.function_oid = d.function_oid;
COMMENT ON VIEW gvlt.vw_doc_function_examples
  IS 'Lists UDF dependencies used by documentation example views, including exclusive and secondary flags.'
;

CREATE OR REPLACE FUNCTION gvlt.doc_example_secondary_set(
  p_example_id bigint,
  p_function_oid oid DEFAULT NULL,
  p_is_secondary boolean DEFAULT true,
  p_note text DEFAULT NULL
) RETURNS text AS $f$
BEGIN
  IF p_function_oid IS NULL THEN
    INSERT INTO gvlt.doc_example_secondary (
      example_id,
      function_oid,
      is_secondary,
      note
    ) VALUES (
      p_example_id,
      NULL,
      p_is_secondary,
      p_note
    )
    ON CONFLICT (example_id) WHERE function_oid IS NULL
      DO UPDATE SET
        is_secondary = EXCLUDED.is_secondary,
        note = EXCLUDED.note,
        updated_at = clock_timestamp();
  ELSE
    INSERT INTO gvlt.doc_example_secondary (
      example_id,
      function_oid,
      is_secondary,
      note
    ) VALUES (
      p_example_id,
      p_function_oid,
      p_is_secondary,
      p_note
    )
    ON CONFLICT (example_id, function_oid) WHERE function_oid IS NOT NULL
      DO UPDATE SET
        is_secondary = EXCLUDED.is_secondary,
        note = EXCLUDED.note,
        updated_at = clock_timestamp();
  END IF;

  RETURN CASE
    WHEN p_function_oid IS NULL THEN format('Example %s secondary=%s', p_example_id, p_is_secondary)
    ELSE format('Example %s / function %s secondary=%s', p_example_id, p_function_oid, p_is_secondary)
    END;
END;
$f$ LANGUAGE plpgsql;
COMMENT ON FUNCTION gvlt.doc_example_secondary_set(bigint,oid,boolean,text)
  IS 'Mark an entire documentation example, or one function-example pair, as secondary or primary.'
;

-- SELECT gvlt.doc_examples_add('round(pi(),3)');
-- SELECT gvlt.doc_examples_add('SELECT round(pi(),3)');
-- SELECT gvlt.doc_examples_add($$ SELECT id, f(x) AS y FROM t $$);

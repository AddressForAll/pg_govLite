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

CREATE OR REPLACE FUNCTION gvlt.doc_examples_payload(
  p_query text
) RETURNS text AS $f$
  SELECT CASE
    WHEN q = '' THEN NULL
    WHEN q ~* '^select[[:space:]]+' THEN
      CASE
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

-- SELECT gvlt.doc_examples_add('round(pi(),3)');
-- SELECT gvlt.doc_examples_add('SELECT round(pi(),3)');
-- SELECT gvlt.doc_examples_add($$ SELECT id, f(x) AS y FROM t $$);

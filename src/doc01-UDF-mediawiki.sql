/**
 * MediaWiki documentation generator for PostgreSQL UDFs.
 *
 * Depends on the doc_UDF_* helper functions from pubLib03-admin.sql:
 * - doc_UDF_show()
 * - doc_UDF_show_simplified_signature()
 * - doc_UDF_transparent_id()
 * - doc_UDF_show_simple()
 */

CREATE OR REPLACE FUNCTION doc_mediawiki_nowiki(
  p_text text,
  p_empty text DEFAULT ''
) RETURNS text AS $f$
  SELECT '<nowiki>'
         || replace(COALESCE(p_text, p_empty, ''), '</nowiki>', '</nowiki><nowiki></nowiki><nowiki>')
         || '</nowiki>'
$f$ LANGUAGE SQL IMMUTABLE;
COMMENT ON FUNCTION doc_mediawiki_nowiki(text,text)
  IS 'Wrap text in a MediaWiki nowiki block, escaping embedded nowiki closings.'
;

CREATE OR REPLACE FUNCTION doc_mediawiki_table_cell(
  p_text text,
  p_empty text DEFAULT ''
) RETURNS text AS $f$
  SELECT replace(replace(COALESCE(p_text, p_empty, ''), E'\r\n', E'\n'), E'\n', '<br />')
$f$ LANGUAGE SQL IMMUTABLE;
COMMENT ON FUNCTION doc_mediawiki_table_cell(text,text)
  IS 'Prepare plain text for a MediaWiki table cell by preserving line breaks as HTML breaks.'
;

CREATE OR REPLACE FUNCTION doc_UDF_generate_mediawiki_page(
  p_schema_name text DEFAULT NULL,
  p_name_like text DEFAULT '',
  p_name_notlike text DEFAULT '',
  p_oid oid DEFAULT NULL
) RETURNS text AS $f$
  SELECT COALESCE(
    string_agg(
      format(
        E'= %1$I.%2$I =\n<span id="%3$s"></span>\n\n== Name ==\n\'\'\'%2$s\'\'\' -- %4$s\n\n== Synopsis ==\n: <code>%5$s</code>\n\n== Description ==\n%6$s\n\n== Metadata ==\n{| class="wikitable"\n|-\n! ID\n| %3$s\n|-\n! Schema\n| %7$s\n|-\n! Function kind\n| %8$s\n|-\n! Language\n| %9$s\n|-\n! Return type\n| %10$s\n|-\n! Definition MD5\n| %11$s\n|}\n',
        f.schema_name,
        f.name,
        f.id,
        doc_mediawiki_table_cell(f.comment, '(sem comentário)'),
        doc_mediawiki_nowiki(format('%I.%I(%s) RETURNS %s',
          f.schema_name,
          f.name,
          COALESCE(f.arguments, ''),
          COALESCE(f.return_type, 'void')
        )),
        doc_mediawiki_table_cell(f.comment, '(sem comentário)'),
        doc_mediawiki_nowiki(f.schema_name),
        doc_mediawiki_nowiki(f.prokind),
        doc_mediawiki_nowiki(f.language),
        doc_mediawiki_nowiki(f.return_type),
        doc_mediawiki_nowiki(f.definition_md5)
      ),
      E'\n' ORDER BY f.schema_name, f.name, f.arguments
    ),
    '(no functions found)'
  )
  FROM doc_UDF_show_simple(p_schema_name, p_name_like, p_name_notlike, p_oid) f
$f$ LANGUAGE SQL STABLE;
COMMENT ON FUNCTION doc_UDF_generate_mediawiki_page(text,text,text,oid)
  IS 'Generate one-page-per-function MediaWiki documentation for UDFs, following a PostGIS-like page structure.'
;
-- SELECT doc_UDF_generate_mediawiki_page('public', '%geohash%');
-- SELECT doc_UDF_generate_mediawiki_page(p_oid => '12345'::oid);

CREATE OR REPLACE FUNCTION doc_UDF_generate_mediawiki_guide(
  p_schema_name text DEFAULT NULL,
  p_name_like text DEFAULT '',
  p_name_notlike text DEFAULT ''
) RETURNS text AS $f$
  SELECT COALESCE(
    E'{| class="wikitable sortable"\n! ID\n! Schema\n! Function\n! Return\n! Arguments\n! Description\n'
    || string_agg(
      format(
        E'|-\n| %1$s\n| %2$s\n| [[#%1$s|%3$s]]\n| %4$s\n| %5$s\n| %6$s',
        f.id,
        doc_mediawiki_nowiki(f.schema_name),
        doc_mediawiki_nowiki(f.name),
        doc_mediawiki_nowiki(f.return_type),
        doc_mediawiki_nowiki(f.arguments),
        doc_mediawiki_table_cell(f.comment, '(sem comentário)')
      ),
      E'\n' ORDER BY f.schema_name, f.name, f.arguments
    )
    || E'\n|}',
    '(no functions found)'
  )
  FROM doc_UDF_show_simple(p_schema_name, p_name_like, p_name_notlike) f
$f$ LANGUAGE SQL STABLE;
COMMENT ON FUNCTION doc_UDF_generate_mediawiki_guide(text,text,text)
  IS 'Generate guide-style MediaWiki documentation for UDFs as a sortable table of functions.'
;
-- SELECT doc_UDF_generate_mediawiki_guide('public', '%geohash%');


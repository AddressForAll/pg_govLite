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

CREATE OR REPLACE FUNCTION doc_mediawiki_xml_escape(
  p_text text,
  p_empty text DEFAULT ''
) RETURNS text AS $f$
  SELECT replace(
           replace(
             replace(
               replace(
                 replace(COALESCE(p_text, p_empty, ''), '&', '&amp;'),
                 '<', '&lt;'
               ),
               '>', '&gt;'
             ),
             '"', '&quot;'
           ),
           '''', '&apos;'
         )
$f$ LANGUAGE SQL IMMUTABLE;
COMMENT ON FUNCTION doc_mediawiki_xml_escape(text,text)
  IS 'Escape text for MediaWiki XML dump fields.'
;

CREATE OR REPLACE FUNCTION doc_UDF_generate_mediawiki_row(
  p_schema_name text DEFAULT NULL,
  p_name_like text DEFAULT '',
  p_name_notlike text DEFAULT '',
  p_oid oid DEFAULT NULL
) RETURNS text AS $f$
  SELECT COALESCE(
    string_agg(
      format(
        E'|-\n|\'\'\'%1$s\'\'\' || %2$s || %3$s || %4$s',
        f.name,
        doc_mediawiki_nowiki(f.return_type),
        doc_mediawiki_nowiki(f.arguments),
        doc_mediawiki_nowiki(f.prokind)
      ),
      E'\n' ORDER BY f.schema_name, f.name, f.arguments
    ),
    '(no functions found)'
  )
  FROM doc_UDF_show_simple(p_schema_name, p_name_like, p_name_notlike, p_oid) f
$f$ LANGUAGE SQL STABLE;
COMMENT ON FUNCTION doc_UDF_generate_mediawiki_row(text,text,text,oid)
  IS 'Generate MediaWiki table rows for UDF summary tables.'
;
-- SELECT doc_UDF_generate_mediawiki_row('public', '%geohash%');

CREATE OR REPLACE FUNCTION doc_UDF_generate_mediawiki_section(
  p_schema_name text DEFAULT NULL,
  p_name_like text DEFAULT '',
  p_name_notlike text DEFAULT '',
  p_oid oid DEFAULT NULL
) RETURNS text AS $f$
  SELECT COALESCE(
    string_agg(
      format(
        E'== \'\'\'%1$s\'\'\' ==\n* Descrição: %2$s\n* Retorno: \'\'%3$s\'\'\n* Assinatura: %4$s\n',
        f.name,
        doc_mediawiki_table_cell(f.comment, '(sem comentário)'),
        doc_mediawiki_table_cell(f.return_type),
        doc_mediawiki_nowiki(f.arguments)
      ),
      E'\n' ORDER BY f.schema_name, f.name, f.arguments
    ),
    '(no functions found)'
  )
  FROM doc_UDF_show_simple(p_schema_name, p_name_like, p_name_notlike, p_oid) f
$f$ LANGUAGE SQL STABLE;
COMMENT ON FUNCTION doc_UDF_generate_mediawiki_section(text,text,text,oid)
  IS 'Generate MediaWiki page sections for UDF documentation.'
;
-- SELECT doc_UDF_generate_mediawiki_section('public', '%geohash%');

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

CREATE OR REPLACE FUNCTION doc_UDF_generate_mediawiki_xml_dump(
  p_schema_name text DEFAULT NULL,
  p_name_like text DEFAULT '',
  p_name_notlike text DEFAULT '',
  p_site_name text DEFAULT 'pg_govLite',
  p_base_url text DEFAULT 'https://example.org/wiki/'
) RETURNS text AS $f$
  SELECT COALESCE(
    format(
      E'<?xml version="1.0" encoding="UTF-8"?>\n<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="0.11" xml:lang="en">\n  <siteinfo>\n    <sitename>%1$s</sitename>\n    <base>%2$s</base>\n    <generator>pg_govLite</generator>\n    <case>first-letter</case>\n    <namespaces>\n      <namespace key="0" case="first-letter" />\n    </namespaces>\n  </siteinfo>\n%3$s\n</mediawiki>',
      doc_mediawiki_xml_escape(p_site_name),
      doc_mediawiki_xml_escape(p_base_url),
      string_agg(
        format(
          E'  <page>\n    <title>%1$s</title>\n    <ns>0</ns>\n    <id>%2$s</id>\n    <revision>\n      <id>%2$s</id>\n      <timestamp>%3$s</timestamp>\n      <contributor>\n        <username>pg_govLite</username>\n        <id>0</id>\n      </contributor>\n      <comment>Generated from PostgreSQL UDF metadata</comment>\n      <model>wikitext</model>\n      <format>text/x-wiki</format>\n      <text xml:space="preserve">%4$s</text>\n    </revision>\n  </page>',
          doc_mediawiki_xml_escape(format('Function:%I.%I', f.schema_name, f.name)),
          row_number,
          to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          doc_mediawiki_xml_escape(doc_UDF_generate_mediawiki_page(f.schema_name, f.name, p_name_notlike, f.oid))
        ),
        E'\n' ORDER BY f.schema_name, f.name, f.arguments
      )
    ),
    '(no functions found)'
  )
  FROM (
    SELECT
      f.*,
      row_number() OVER (ORDER BY f.schema_name, f.name, f.arguments) AS row_number
    FROM doc_UDF_show_simple(p_schema_name, p_name_like, p_name_notlike) f
  ) f
$f$ LANGUAGE SQL STABLE;
COMMENT ON FUNCTION doc_UDF_generate_mediawiki_xml_dump(text,text,text,text,text)
  IS 'Generate a MediaWiki XML dump with one full page per UDF.'
;
-- SELECT doc_UDF_generate_mediawiki_xml_dump('public', '%geohash%');

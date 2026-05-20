# UDF MediaWiki Documentation

`doc01-UDF-mediawiki.sql` generates MediaWiki documentation for PostgreSQL user-defined functions.

It depends on the `doc_UDF_*` helper functions from `pubLib03-admin.sql`.

## Summary Table Rows

Use `doc_UDF_generate_mediawiki_row(...)` to generate rows for a MediaWiki summary table.

```sql
SELECT doc_UDF_generate_mediawiki_row('public', '%geohash%');
```

Example output:

```mediawiki
|-
|'''b32cep_to_hbig''' || <nowiki>bigint</nowiki> || <nowiki>x text</nowiki> || <nowiki>func</nowiki>
```

## Page Sections

Use `doc_UDF_generate_mediawiki_section(...)` to generate one section per function.

```sql
SELECT doc_UDF_generate_mediawiki_section('public', '%geohash%');
```

Example output:

```mediawiki
== '''b32cep_to_hbig''' ==
* Descrição: Translates a base32cep string into a varbit representation.
* Retorno: ''int8''
* Assinatura: <nowiki>x text</nowiki>
```

## Full Function Pages

Use `doc_UDF_generate_mediawiki_page(...)` to generate fuller MediaWiki pages with `Name`, `Synopsis`, `Description`, and `Metadata` sections.

```sql
SELECT doc_UDF_generate_mediawiki_page('public', '%geohash%');
```

## MediaWiki XML Dump

Use `doc_UDF_generate_mediawiki_xml_dump(...)` to generate a MediaWiki XML dump with one page per function.

```sql
SELECT doc_UDF_generate_mediawiki_xml_dump(
  'public',
  '%geohash%',
  '',
  'pg_govLite',
  'https://example.org/wiki/'
);
```

The XML dump is generated with PostgreSQL's native XML functions:

```text
xmlelement
xmlattributes
xmlagg
xmlserialize
```

This lets PostgreSQL handle XML escaping for page titles, metadata, and generated wikitext.

The generated output can be checked as XML inside PostgreSQL:

```sql
SELECT XMLPARSE(
  DOCUMENT doc_UDF_generate_mediawiki_xml_dump('public', '%geohash%')
) IS DOCUMENT;
```

Expected result:

```text
t
```


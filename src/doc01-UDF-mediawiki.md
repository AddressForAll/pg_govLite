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

## XHTML Table Rows

Use `doc_UDF_generate_mediawiki_xhtml_rows(...)` to generate only the XHTML rows that go inside a MediaWiki table. The function does not emit the outer `<table>` tag.

```sql
SELECT doc_UDF_generate_mediawiki_xhtml_rows('public', '%round%');
```

Example output:

```html
<tr><td> Function / Description / Example </td></tr>
<tr>
<td>
<b><code>round(</code></b><i>double precision, integer</i><b><code>)</code> &#8594; </b> <i>numeric</i>
<p class="pgdoc_comment">Cast for ROUND(float,x). Useful for SUM, AVG, etc.</p>
</td>
</tr>
```

Set `p_include_header` to `false` when the header row should be omitted:

```sql
SELECT doc_UDF_generate_mediawiki_xhtml_rows('public', '%round%', '', NULL, false);
```

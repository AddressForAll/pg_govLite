#!/usr/bin/env python3
"""Transactional pg_govLite installer. Python standard library + PostgreSQL psql."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
PREFIXES = {group: group + '_' for group in ('lib', 'gvlt', 'doc', 'api', 'brz', 'slv', 'gld')}
SCHEMAS = {'lib': 'lib', 'gvlt': 'gvlt', 'doc': 'gvlt_doc_examples', 'api': 'api',
           'brz': 'brz', 'slv': 'slv', 'gld': 'gld', 'helper': 'public'}
TOKEN = re.compile(r'\{\{(object|name|schema_name|prefix):([a-z][a-z0-9_]*)(?:\.([a-z][a-z0-9_]*))?\}\}')


def declarations(sql):
    """Mask comments, literals and dollar bodies before inspecting top-level DDL."""
    result, i = [], 0
    while i < len(sql):
        start = i
        if sql.startswith('--', i):
            end = sql.find('\n', i)
            i = len(sql) if end < 0 else end
        elif sql.startswith('/*', i):
            depth, i = 1, i + 2
            while depth and i < len(sql):
                if sql.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif sql[i] in ("'", '"'):
            quote, i = sql[i], i + 1
            while i < len(sql):
                if sql[i] == quote:
                    i += 1
                    if i < len(sql) and sql[i] == quote:
                        i += 1
                    else:
                        break
                else:
                    i += 1
            result.append(sql[start:i] if quote == '"' else ' ' * (i-start))
            continue
        elif sql[i] == '$' and (match := re.match(r'\$(?:[a-zA-Z_][a-zA-Z0-9_]*)?\$', sql[i:])):
            tag = match.group()
            end = sql.find(tag, i + len(tag))
            if end < 0:
                raise ValueError('Unterminated SQL dollar body')
            i = end + len(tag)
        else:
            result.append(sql[i])
            i += 1
            continue
        result.append(' ' * (i-start))
    return ''.join(result)


def identifier(value):
    if not value or len(value.encode('utf-8')) > 63 or '\x00' in value:
        raise ValueError('Invalid or overlong PostgreSQL identifier')
    return '"' + value.replace('"', '""') + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def answer(value):
    value = value.strip().upper()
    if value in ('SIM', 'S', 'Y'):
        return True
    if value in ('NÃO', 'NAO', 'N'):
        return False
    raise ValueError('Use SIM/S/Y or NÃO/NAO/N; empty input is not accepted.')


class Layout:
    def __init__(self, mode, schema=None):
        if mode not in ('multi', 'single'):
            raise ValueError('Layout must be multi or single')
        if mode == 'single' and (not schema or not re.fullmatch(r'[a-z_][a-z0-9_]*', schema)
                                 or schema.startswith('pg_') or schema == 'information_schema'):
            raise ValueError('Single layout requires an existing lowercase SQL schema identifier.')
        if schema:
            identifier(schema)
        self.mode, self.schema = mode, schema

    def group_schema(self, group):
        return self.schema if self.mode == 'single' else SCHEMAS[group]

    def name(self, group, base):
        prefix = PREFIXES['lib' if group == 'helper' else group] if self.mode == 'single' else ''
        name = prefix + base
        identifier(name)
        return name

    def render(self, sql):
        def replace(match):
            kind, group, base = match.groups()
            if group not in SCHEMAS:
                raise ValueError('Unknown object group: ' + group)
            if kind == 'schema_name':
                return self.group_schema(group)
            if kind == 'prefix':
                return PREFIXES[group] if self.mode == 'single' else ''
            if base is None:
                raise ValueError('Object token requires a base name')
            name = identifier(self.name(group, base))
            return identifier(self.group_schema(group)) + '.' + name if kind == 'object' else name
        result = TOKEN.sub(replace, sql)
        if '{{' in result or '}}' in result:
            raise ValueError('Unresolved installation placeholder')
        return result


def build_sql(layout, restrictive=False, master=None):
    if restrictive and not master:
        raise ValueError('Restrictive governance requires an existing master login role')
    if master:
        identifier(master)
    pieces = ["\\set ON_ERROR_STOP on\nBEGIN;\nSET LOCAL standard_conforming_strings = on;",
              "SELECT pg_advisory_xact_lock(174938, 1);",
              "DO $preflight$ BEGIN\n"
              "IF current_setting('server_version_num')::int < 150000 THEN RAISE EXCEPTION 'PostgreSQL 15+ required'; END IF;\n"
              "IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname=current_user) THEN "
              "RAISE EXCEPTION 'DBA/superuser required to install database event triggers'; END IF;\n"
              "IF EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname IN "
              "('et_medallion_insert','et_medallion_drop','gvlt_relation_ddl','gvlt_relation_drop')) THEN "
              "RAISE EXCEPTION 'Governance installation already exists; migration is not supported'; END IF;\n"
              "END $preflight$;"]
    if layout.mode == 'single':
        pieces.append("DO $schema$ BEGIN IF NOT EXISTS (SELECT FROM pg_namespace WHERE nspname=" +
                      literal(layout.schema) + ") THEN RAISE EXCEPTION 'Authorized schema must already exist'; END IF; END $schema$;")
    else:
        pieces.extend('CREATE SCHEMA IF NOT EXISTS ' + identifier(SCHEMAS[g]) + ';'
                      for g in ('lib', 'gvlt', 'doc'))
    pieces.append('SET LOCAL search_path = pg_catalog, ' + identifier(layout.group_schema('gvlt')) + ', public;')
    for file in ('inst01-fw_lib.sql', 'inst02-fw_core.sql'):
        pieces.append(layout.render((ROOT / 'src' / file).read_text(encoding='utf-8')))
    pieces.append(layout.render((ROOT / 'src' / 'installation.sql').read_text(encoding='utf-8')))
    pieces.append(layout.render("INSERT INTO {{object:gvlt.installation}} (singleton, layout, target_schema, owner_oid) VALUES (true, " +
                               literal(layout.mode) + ', ' + literal(layout.group_schema('gvlt')) + ", (SELECT oid FROM pg_roles WHERE rolname=current_user));"))
    for group, prefix in PREFIXES.items():
        pieces.append(layout.render('INSERT INTO {{object:gvlt.prefix_dictionary}} VALUES (' +
                                   ','.join(literal(v) for v in (group, prefix, SCHEMAS[group])) + ');'))
    if layout.mode == 'multi':
        pieces.append(layout.render((ROOT / 'src' / 'inst03-fw_govRules.sql').read_text(encoding='utf-8')))
    else:
        pieces.append(layout.render("CREATE FUNCTION {{object:gvlt.medallion_upsert}}(text, jsonb DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'single layout: use relation_classify(regclass,text); schema creation is unavailable'; END $$;"))
    for file in ('inst04-documentation_examples.sql', 'restrictive.sql'):
        pieces.append(layout.render((ROOT / 'src' / file).read_text(encoding='utf-8')))
    if layout.mode == 'single':
        pieces.append(layout.render((ROOT / 'src' / 'single_catalog.sql').read_text(encoding='utf-8')))
    else:
        pieces.append(layout.render((ROOT / 'src' / 'multi_catalog.sql').read_text(encoding='utf-8')))
    # Fresh installations must never replace unrelated functions or silently reuse tables.
    sql = '\n'.join(pieces)
    sql = re.sub(r'CREATE (TABLE|SEQUENCE|UNIQUE INDEX|INDEX) IF NOT EXISTS ', r'CREATE \1 ', sql, flags=re.I)
    # Explicit function tokens are the complete set of framework routines (including public helpers).
    ddl = declarations(sql)
    routine_names = sorted(set(re.findall(r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+("[^"]+"\."[^"]+")', ddl, re.I)))
    relation_names = sorted(set(re.findall(r'CREATE\s+(?:OR\s+REPLACE\s+)?(?:TABLE|(?:MATERIALIZED )?VIEW|SEQUENCE)\s+("[^"]+"\."[^"]+")', ddl, re.I)))
    collisions = []
    for name in routine_names:
        schema, routine = name.split('.')
        collisions.append('(n.nspname=' + literal(schema[1:-1]) + ' AND p.proname=' + literal(routine[1:-1]) + ')')
    check = ("\nDO $collisions$ BEGIN IF EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE " +
             ' OR '.join(collisions) + ") THEN RAISE EXCEPTION 'Framework routine name collision; existing objects were preserved'; END IF; "
             "IF EXISTS(SELECT FROM unnest(ARRAY[" + ','.join(literal(name) for name in relation_names) +
             "]) name WHERE to_regclass(name) IS NOT NULL) THEN RAISE EXCEPTION 'Framework relation name collision; existing objects were preserved'; END IF; END $collisions$;\n")
    sql = sql.replace('SELECT pg_advisory_xact_lock(174938, 1);', 'SELECT pg_advisory_xact_lock(174938, 1);' + check)
    for name in routine_names:
        schema, routine = name.split('.')
        sql += ("\nDO $acl$ DECLARE f record; a record; BEGIN FOR f IN SELECT p.oid::regprocedure AS signature,p.proacl,p.proowner FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=" +
                literal(schema[1:-1]) + ' AND p.proname=' + literal(routine[1:-1]) +
                " LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.signature); "
                "FOR a IN SELECT DISTINCT grantee FROM aclexplode(f.proacl) WHERE grantee<>0 AND grantee<>f.proowner LOOP "
                "EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I CASCADE',f.signature,pg_get_userbyid(a.grantee)); "
                "END LOOP; END LOOP; END $acl$;")
    identities = ','.join(literal(name) + '::regclass::oid' for name in relation_names)
    sql += ("\nDO $relations_acl$ DECLARE r record; a record; kind text; BEGIN "
            "FOR r IN SELECT c.oid,c.oid::regclass AS identity,c.relacl,c.relowner,c.relkind FROM pg_class c WHERE c.oid IN (" + identities + ") "
            "OR (c.relkind='S' AND EXISTS(SELECT FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid "
            "AND d.refclassid='pg_class'::regclass AND d.refobjid IN (" + identities + "))) LOOP "
            "kind := CASE WHEN r.relkind='S' THEN 'SEQUENCE' ELSE 'TABLE' END; "
            "EXECUTE format('REVOKE ALL ON %s %s FROM PUBLIC',kind,r.identity); "
            "FOR a IN SELECT DISTINCT grantee FROM aclexplode(r.relacl) WHERE grantee<>0 AND grantee<>r.relowner LOOP "
            "EXECUTE format('REVOKE ALL ON %s %s FROM %I CASCADE',kind,r.identity,pg_get_userbyid(a.grantee)); "
            "END LOOP; END LOOP; END $relations_acl$;")
    sql += '\n' + layout.render('SELECT {{object:gvlt.relation_sync}}();')
    sql += '\nSET LOCAL plpgsql.check_asserts = on;\n' + layout.render((ROOT / 'src/assert01-basic.sql').read_text(encoding='utf-8'))
    if restrictive:
        sql += '\n' + layout.render('SELECT {{object:gvlt.policy_set}}(true, ' + literal(master) + ');')
    sql += '\n' + layout.render("INSERT INTO {{object:gvlt.policy_audit}} (action, details) VALUES ('install', jsonb_build_object('layout', " + literal(layout.mode) + "));")
    return sql + '\nCOMMIT;\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('multi', 'single'))
    parser.add_argument('--schema', help='Existing authorized schema for single layout')
    parser.add_argument('--restrictive', type=answer, metavar='SIM|NAO')
    parser.add_argument('--master', help='Existing PostgreSQL login role; no password is stored')
    parser.add_argument('--non-interactive', action='store_true')
    parser.add_argument('--render', type=Path, help='Write reviewable SQL without connecting')
    parser.add_argument('--psql', default='psql')
    parser.add_argument('--dbname', help='psql connection string (alternatively use libpq environment variables)')
    parser.add_argument('--tutorial', action='store_true', help='Run the single-schema example against an installed core')
    args = parser.parse_args(argv)
    try:
        if args.non_interactive:
            args.mode = args.mode or 'multi'
            if args.restrictive is None:
                parser.error('--restrictive SIM|NAO is required with --non-interactive')
        else:
            while args.mode is None:
                value = input('Installation layout [multi/single]: ').strip().lower()
                if value in ('multi', 'single'):
                    args.mode = value
            if args.mode == 'single' and not args.schema:
                args.schema = input('Existing authorized schema: ').strip()
            while args.restrictive is None:
                try:
                    args.restrictive = answer(input('Enable restrictive governance? [SIM/S/Y or NÃO/NAO/N]: '))
                except ValueError as error:
                    print(error)
            if args.restrictive and not args.master:
                args.master = input('Existing master/sudo PostgreSQL login role: ').strip()
        layout = Layout(args.mode, args.schema)
        if args.tutorial:
            if args.mode != 'single':
                raise ValueError('--tutorial requires --mode single --schema SCHEMA')
            sql = '\\set ON_ERROR_STOP on\nBEGIN;\n' + layout.render((ROOT / 'assets/data/single_schema_tutorial.sql').read_text(encoding='utf-8')) + '\nCOMMIT;\n'
        else:
            sql = build_sql(layout, args.restrictive, args.master)
        if args.render:
            args.render.write_text(sql, encoding='utf-8')
            print('SQL rendered:', args.render)
        else:
            print('Installing layout=' + args.mode + ', schema=' + layout.group_schema('gvlt'), flush=True)
            # PGHOST/PGPORT/PGUSER/PGDATABASE/.pgpass are honored; credentials never enter generated SQL.
            command = [args.psql, '-X', '-v', 'ON_ERROR_STOP=1']
            if args.dbname:
                command.extend(['--dbname', args.dbname])
            result = subprocess.run(command + ['-f', '-'], input=sql, encoding='utf-8')
            return result.returncode
        return 0
    except (ValueError, OSError, EOFError) as error:
        print('Setup failed: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

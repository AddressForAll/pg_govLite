#!/usr/bin/env python3
"""Transactional pg_govLite installer. Python standard library + PostgreSQL psql."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
EXTENSIONS = {'multi': 'pg_govlite', 'single': 'pg_govlite_single'}
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


def build_sql(layout, restrictive=False, master=None, *, extension=False):
    if extension and (restrictive or master):
        raise ValueError('Configure restrictive policy after creating the extension')
    if restrictive and not master:
        raise ValueError('Restrictive governance requires an existing master login role')
    if master:
        identifier(master)
    pieces = ["SET LOCAL standard_conforming_strings = on;"]
    if extension:
        pieces.append('SET LOCAL search_path = pg_catalog, pg_temp;')
    pieces.extend(["SELECT pg_advisory_xact_lock(174938, 1);",
              "DO $preflight$ BEGIN\n"
              "IF current_setting('server_version_num')::int < 150000 THEN RAISE EXCEPTION 'PostgreSQL 15+ required'; END IF;\n"
              "IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname=current_user) THEN "
              "RAISE EXCEPTION 'DBA/superuser required to install database event triggers'; END IF;\n"
              "IF EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname IN "
              "('et_medallion_insert','et_medallion_drop','gvlt_relation_ddl','gvlt_relation_drop')) THEN "
              "RAISE EXCEPTION 'Governance installation already exists; migration is not supported'; END IF;\n"
              "END $preflight$;"])
    if layout.mode == 'single':
        pieces.append("DO $schema$ BEGIN IF NOT EXISTS (SELECT FROM pg_namespace WHERE nspname=" +
                      literal(layout.schema) + ") THEN RAISE EXCEPTION 'Authorized schema must already exist'; END IF; END $schema$;")
    elif extension:
        # Existing namespaces can contain user objects. Leave their ownership alone.
        pieces.append("""DO $schemas$
        BEGIN
          IF to_regnamespace('lib') IS NULL THEN CREATE SCHEMA lib; END IF;
          IF to_regnamespace('gvlt_doc_examples') IS NULL THEN CREATE SCHEMA gvlt_doc_examples; END IF;
        END $schemas$;""")
    else:
        pieces.extend('CREATE SCHEMA IF NOT EXISTS ' + identifier(SCHEMAS[g]) + ';'
                      for g in ('lib', 'gvlt', 'doc'))
    if not extension:
        pieces.append('SET LOCAL search_path = pg_catalog, ' + identifier(layout.group_schema('gvlt')) + ', public;')
        pieces.append('CREATE EXTENSION IF NOT EXISTS plpython3u;')
    for file in ('inst01-fw_lib.sql', 'publib-yaml-mustache.sql', 'inst02-fw_core.sql'):
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
    if extension:
        return sql + '\n'
    return transaction(sql)


def transaction(sql):
    return '\\set ON_ERROR_STOP on\nBEGIN;\n' + sql + '\nCOMMIT;\n'


def extension_version():
    versions = set()
    for name in EXTENSIONS.values():
        filename = name + '.control'
        control = (ROOT / filename).read_text(encoding='utf-8')
        match = re.search(r"^default_version\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'\s*$", control, re.M)
        if not match:
            raise ValueError('Missing or invalid default_version in ' + filename)
        versions.add(match[1])
    if len(versions) != 1:
        raise ValueError('Both layouts must declare the same release version')
    return versions.pop()


def build_extension_sql(mode):
    if mode == 'multi':
        return build_sql(Layout(mode), extension=True)
    placeholder = 'gvlt_extension_target_schema'
    schema_name = "(pg_catalog.parse_ident('@extschema@'))[1]"
    validate_schema = f"""DO $schema_name$
    DECLARE target text := {schema_name};
    BEGIN
      IF target !~ '^[a-z_][a-z0-9_]*$' OR left(target, 3) = 'pg_' OR target = 'information_schema' THEN
        RAISE EXCEPTION 'Single layout requires an existing lowercase SQL schema identifier';
      END IF;
    END $schema_name$;
    """
    sql = build_sql(Layout(mode, placeholder), extension=True)
    # PostgreSQL substitutes an SQL identifier, which can include double quotes.
    # Recover the raw name for metadata and preserve quoting in object references.
    sql = sql.replace(literal(placeholder), schema_name).replace(identifier(placeholder), '@extschema@')
    lock = 'SELECT pg_advisory_xact_lock(174938, 1);'
    return sql.replace(lock, validate_schema + lock, 1).replace(placeholder, '@extschema@')


def create_extension_sql(layout, restrictive=False, master=None):
    sql = 'CREATE EXTENSION ' + EXTENSIONS[layout.mode] + ' VERSION ' + literal(extension_version())
    if layout.mode == 'single':
        sql += ' SCHEMA ' + identifier(layout.schema)
    sql += ' CASCADE;'
    if restrictive:
        if not master:
            raise ValueError('Restrictive governance requires an existing master login role')
        identifier(master)
        sql += '\n' + layout.render('SELECT {{object:gvlt.policy_set}}(true, ' + literal(master) + ');')
    return transaction('SET LOCAL standard_conforming_strings = on;\n' + sql)


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
    parser.add_argument('--extension', action='store_true', help='Install the native extension for the selected layout')
    parser.add_argument('--extension-sql', type=Path, help='Build the native installation script without connecting')
    parser.add_argument('--extension-version', action='store_true', help='Print the packaged extension version')
    args = parser.parse_args(argv)
    try:
        if args.extension_version:
            print(extension_version())
            return 0
        if args.extension_sql:
            args.extension_sql.write_text(build_extension_sql(args.mode or 'multi'), encoding='utf-8')
            return 0
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
        elif args.extension:
            sql = create_extension_sql(layout, args.restrictive, args.master)
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

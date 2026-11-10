"""Run: python -m unittest discover -s tests -v.

Database integration is opt-in: GVLT_RUN_DB_TESTS=1, PGHOST/PGPORT/PGUSER
pointing at a disposable PostgreSQL superuser connection. Only databases and
roles created with a unique test prefix by this suite are removed.
"""
import os
import re
from pathlib import Path
import subprocess
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from setup import Layout, ROOT, answer, build_sql, identifier


class RenderingTests(unittest.TestCase):
    def test_prompt_contract(self):
        for value in ('SIM', 's', 'y', ' sim '):
            self.assertTrue(answer(value))
        for value in ('NÃO', 'nao', 'n', ' não '):
            self.assertFalse(answer(value))
        for value in ('', ' ', 'yes', 'true', 'invalid'):
            with self.assertRaises(ValueError):
                answer(value)

    def test_layout_validation(self):
        for schema in (None, '', 'pg_catalog', 'pg_private', 'a.b', 'Cliente', 'x' * 64, "x';drop schema public;--"):
            with self.assertRaises(ValueError):
                Layout('single', schema)
        with self.assertRaises(ValueError):
            Layout('invalid')
        with self.assertRaises(ValueError):
            Layout('single', 'cliente').render('{{object:slv.' + 'x' * 60 + '}}')
        with self.assertRaises(ValueError):
            build_sql(Layout('multi'), True)
        self.assertEqual(identifier('a"b'), '"a""b"')

    def test_generated_sql_contract(self):
        for mode in ('single', 'multi'):
            layout = Layout(mode, 'cliente' if mode == 'single' else None)
            sql = build_sql(layout, True, 'master')
            self.assertNotIn('{{', sql)
            self.assertFalse(re.search(r'^DROP SCHEMA', sql, re.M | re.I), 'Installer must not drop schemas')
            self.assertTrue(sql.endswith('COMMIT;\n'))
            self.assertIn('pg_advisory_xact_lock', sql)
            self.assertIn('Framework routine name collision', sql)
            self.assertNotIn('CREATE TABLE IF NOT EXISTS', sql)
            if mode == 'single':
                self.assertFalse(re.search(r'^CREATE SCHEMA', sql, re.M), 'Single layout must not create schemas')
                self.assertIn('"cliente"."lib_array_distinct"', sql)
                self.assertIn("('doc_ex' || v_id)", sql)


@unittest.skipUnless(os.environ.get('GVLT_RUN_DB_TESTS') == '1', 'Disposable database tests are opt-in')
class DatabaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prefix = 'gvlt_it_' + uuid.uuid4().hex[:10]
        cls.dbs = []
        cls.roles = [cls.prefix + suffix for suffix in ('_master', '_reader', '_other', '_next', '_group')]
        cls.master, cls.reader, cls.other, cls.next_master, cls.group = cls.roles
        for role in cls.roles:
            cls.sql('postgres', 'CREATE ROLE ' + identifier(role) + (' NOLOGIN' if role == cls.group else ' LOGIN'))

    @classmethod
    def tearDownClass(cls):
        for db in cls.dbs:
            cls.sql('postgres', 'DROP DATABASE ' + identifier(db) + ' WITH (FORCE)')
        for role in reversed(cls.roles):
            cls.sql('postgres', 'DROP ROLE ' + identifier(role))

    @classmethod
    def sql(cls, db, sql, user=None, ok=True):
        args = [os.environ.get('PSQL', 'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db]
        if user:
            args.extend(['-U', user])
        result = subprocess.run(args, input=sql, text=True, encoding='utf-8', capture_output=True)
        if ok and result.returncode:
            raise AssertionError(result.stderr + '\nSQL: ' + sql[:2000])
        if not ok and not result.returncode:
            raise AssertionError('Unexpected success: ' + sql[:2000])
        return result.stdout.strip() if ok else result.stderr

    @classmethod
    def database(cls, suffix):
        db = cls.prefix + '_' + suffix
        cls.sql('postgres', 'CREATE DATABASE ' + identifier(db))
        cls.dbs.append(db)
        return db

    def test_matrix(self):
        for mode in ('multi', 'single'):
            for restrictive in (False, True):
                with self.subTest(mode=mode, restrictive=restrictive):
                    self.exercise_layout(mode, restrictive)

    def exercise_layout(self, mode, restrictive):
        db = self.database(mode + ('_on' if restrictive else '_off'))
        layout = Layout(mode, 'cliente' if mode == 'single' else None)
        target = 'cliente' if mode == 'single' else 'slv'
        bronze_schema = 'cliente' if mode == 'single' else 'brz'
        silver = identifier(target) + '.' + identifier('slv_sample' if mode == 'single' else 'sample')
        bronze = identifier(bronze_schema) + '.' + identifier('brz_sample' if mode == 'single' else 'sample')
        future = identifier(target) + '.' + identifier('slv_future' if mode == 'single' else 'future')
        partitioned = identifier(target) + '.' + identifier('slv_partitioned' if mode == 'single' else 'partitioned')
        partition = identifier(target) + '.' + identifier('partition_child')
        f = lambda name: layout.render('{{object:gvlt.' + name + '}}')
        self.sql(db, 'CREATE SCHEMA ' + identifier(target) + ';' +
                 ('' if mode == 'single' else 'CREATE SCHEMA brz;') +
                 'CREATE TABLE ' + silver + '(id bigint GENERATED ALWAYS AS IDENTITY, value int);' +
                 'CREATE TABLE ' + bronze + '(value int);' +
                 'CREATE TABLE ' + identifier(target) + '.unrelated(value int);' +
                 'INSERT INTO ' + identifier(target) + '.unrelated VALUES (42);' +
                 'GRANT USAGE ON SCHEMA ' + identifier(target) + ',' + identifier(bronze_schema) + ' TO ' + ','.join(map(identifier, self.roles)) + ';' +
                 'GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ' + silver + ' TO ' + identifier(self.master) + ',' + identifier(self.reader) + ';' +
                 'GRANT SELECT,INSERT ON ' + bronze + ' TO ' + identifier(self.reader) + ';' +
                 'GRANT UPDATE(value) ON ' + silver + ' TO ' + identifier(self.group) + ';' +
                 'GRANT ' + identifier(self.group) + ' TO ' + identifier(self.reader) + ';')
        self.sql(db, 'ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO ' + identifier(self.reader) + ';'
                 'ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO ' + identifier(self.reader) + ';'
                 'ALTER DEFAULT PRIVILEGES GRANT USAGE ON SEQUENCES TO ' + identifier(self.reader) + ';')
        self.sql(db, build_sql(layout, restrictive, self.master if restrictive else None))
        self.assertEqual(self.sql(db, 'SELECT value FROM ' + identifier(target) + '.unrelated;'), '42')
        self.assertEqual(self.sql(db, 'SELECT count(*) FROM ' + f('prefix_dictionary')), '7')
        self.assertEqual(self.sql(db, 'SELECT base_name FROM ' + f('object_name_parse') + "('slv_municipios_historico');"), 'municipios_historico')
        self.assertEqual(self.sql(db, 'SELECT ' + f('object_name') + "('slv','municipios_historico');"),
                         target + '.' + ('slv_' if mode == 'single' else '') + 'municipios_historico')
        self.sql(db, 'SELECT ' + f('doc_examples_add') + "('SELECT 1 AS value');")
        self.assertEqual(self.sql(db, 'SELECT view_schema,view_name FROM ' + f('doc_examples')),
                         ('cliente|doc_ex1' if mode == 'single' else 'gvlt_doc_examples|ex1'))
        self.sql(db, 'INSERT INTO ' + bronze + ' VALUES (1);', user=self.reader)
        self.sql(db, 'SELECT * FROM ' + silver, user=self.reader)
        self.sql(db, 'SELECT * FROM ' + silver, user=self.other, ok=False)
        self.sql(db, 'SELECT * FROM ' + f('installation'), user=self.other, ok=False)
        self.sql(db, 'SELECT ' + f('policy_set') + "(false);", user=self.reader, ok=False)
        self.sql(db, 'SELECT ' + f('policy_grant') + "('TABLE','" + silver + "'::regclass,'" + self.reader + "'::regrole,'INSERT');", user=self.reader, ok=False)
        if mode == 'multi':
            if not restrictive:
                assertions = (ROOT / 'src/assert02-psqlDiff.sql').read_text(encoding='utf-8').split('\nEND $do$;', 1)[0] + '\nEND $do$;'
                self.sql(db, 'BEGIN;\n' + assertions + '\nROLLBACK;')
                self.sql(db, 'BEGIN;\n' + (ROOT / 'assets/data/manual01-public_health_tutorial.sql').read_text(encoding='utf-8') + '\nROLLBACK;')
            self.sql(db, 'SELECT gvlt.medallion_upsert(\'tstdemo_silver\');')
            self.sql(db, 'CREATE TABLE tstdemo_silver.legacy(value int);')
            self.assertEqual(self.sql(db, "SELECT layer FROM gvlt.relation_registry WHERE schema_name='tstdemo_silver';"), 'Silver')
        else:
            self.assertEqual(self.sql(db, "SELECT count(*) FROM pg_namespace WHERE nspname IN ('lib','gvlt','gvlt_doc_examples','api');"), '0')
            self.sql(db, 'SELECT ' + f('medallion_upsert') + "('test_silver');", ok=False)
            self.assertIn('cliente.slv_sample', self.sql(db, 'SELECT obj_name FROM ' + f('medallion_objects') + '();'))
            self.sql(db, 'BEGIN;\n' + layout.render((ROOT / 'assets/data/single_schema_tutorial.sql').read_text(encoding='utf-8')) + '\nROLLBACK;')
        # Failed reinstall cannot modify either the installed core or unrelated objects.
        self.sql(db, build_sql(layout, restrictive, self.master if restrictive else None), ok=False)
        self.assertEqual(self.sql(db, 'SELECT value FROM ' + identifier(target) + '.unrelated;'), '42')
        if not restrictive:
            self.sql(db, 'INSERT INTO ' + silver + '(value) VALUES (5);', user=self.reader)
            self.sql(db, 'INSERT INTO ' + silver + '(id,value) OVERRIDING SYSTEM VALUE VALUES (99,5);', user=self.reader)
            return
        for statement in ('INSERT INTO ' + silver + '(value) VALUES (2)',
                          'UPDATE ' + silver + ' SET value=2', 'DELETE FROM ' + silver,
                          'TRUNCATE ' + silver, 'ALTER TABLE ' + silver + ' ADD COLUMN denied int',
                          'COPY ' + silver + "(value) FROM STDIN;\n2\n\\.\n"):
            self.sql(db, statement + ';', user=self.reader, ok=False)
        self.sql(db, 'INSERT INTO ' + silver + '(value) VALUES (10); UPDATE ' + silver + ' SET value=11 WHERE value=10;', user=self.master)
        self.sql(db, 'DELETE FROM ' + silver + '; TRUNCATE ' + silver + ';', user=self.master)
        self.sql(db, 'ALTER TABLE ' + silver + ' ADD COLUMN denied int;', user=self.master, ok=False)
        # SECURITY DEFINER and updatable-view paths must retain the real operational identity.
        self.sql(db, 'CREATE FUNCTION public.indirect_write() RETURNS void LANGUAGE sql SECURITY DEFINER AS $$ INSERT INTO ' + silver + '(value) VALUES (3) $$;'
                 'GRANT EXECUTE ON FUNCTION public.indirect_write() TO ' + identifier(self.reader) + ';'
                 'CREATE VIEW public.write_view AS SELECT value FROM ' + silver + '; GRANT INSERT ON public.write_view TO ' + identifier(self.reader) + ';')
        self.sql(db, 'SELECT public.indirect_write();', user=self.reader, ok=False)
        self.sql(db, 'INSERT INTO public.write_view VALUES (3);', user=self.reader, ok=False)
        self.sql(db, 'SELECT public.indirect_write();', user=self.master)
        # Catalog assignment applies immediately, without waiting for another DDL command.
        assigned = identifier(target) + '.assigned'
        self.sql(db, 'CREATE TABLE ' + assigned + '(value int); GRANT SELECT,INSERT ON ' + assigned + ' TO ' + identifier(self.reader) + ';'
                 'SELECT ' + f('tagobj_include') + "('Silver', ARRAY['" + target + ".assigned']);")
        self.sql(db, 'INSERT INTO ' + assigned + ' VALUES (1);', user=self.reader, ok=False)
        # New tables, partitions and Bronze operational DDL.
        self.sql(db, 'CREATE TABLE ' + future + '(value int); CREATE TABLE ' + partitioned + '(value int) PARTITION BY RANGE(value);'
                 'CREATE TABLE ' + partition + ' PARTITION OF ' + partitioned + ' FOR VALUES FROM (0) TO (100);')
        self.sql(db, 'SELECT ' + f('tagobj_include') + "('GEO', ARRAY['" + target + '.' + ('slv_sample' if mode == 'single' else 'sample') + "']);"
                 'SELECT ' + f('tagobj_include') + "('ID', ARRAY['" + target + '.' + ('slv_sample' if mode == 'single' else 'sample') + ".value']);")
        self.sql(db, 'INSERT INTO ' + future + ' VALUES (1); INSERT INTO ' + partitioned + ' VALUES (1); INSERT INTO ' + partition + ' VALUES (2);', user=self.master)
        self.sql(db, 'INSERT INTO ' + partition + ' VALUES (3);', user=self.reader, ok=False)
        self.sql(db, 'GRANT CREATE ON SCHEMA ' + identifier(target) + ' TO ' + identifier(self.reader) + ';')
        self.sql(db, 'CREATE TABLE ' + identifier(target) + '.' + identifier('slv_denied' if mode == 'single' else 'denied') + '(value int);', user=self.reader, ok=False)
        if mode == 'single':
            self.sql(db, 'CREATE TABLE cliente.brz_owned(value int);', user=self.reader)
            self.assertEqual(self.sql(db, "SELECT layer FROM cliente.gvlt_relation_registry WHERE relation_name='brz_owned';"), 'Bronze')
            self.sql(db, 'ALTER TABLE cliente.brz_owned RENAME TO slv_owned;', user=self.reader, ok=False)
            self.sql(db, "SELECT cliente.gvlt_tagobj_include('Silver',ARRAY['cliente.brz_owned']);", ok=False)
            # An older leaf attached through a newer intermediate partition must be protected immediately.
            self.sql(db, 'CREATE TABLE cliente.old_leaf(value int); GRANT INSERT ON cliente.old_leaf TO ' + identifier(self.reader) + ';'
                     'CREATE TABLE cliente.new_mid(value int) PARTITION BY RANGE(value);'
                     'ALTER TABLE cliente.new_mid ATTACH PARTITION cliente.old_leaf FOR VALUES FROM (100) TO (150);'
                     'CREATE TABLE cliente.slv_nested(value int) PARTITION BY RANGE(value);'
                     'ALTER TABLE cliente.slv_nested ATTACH PARTITION cliente.new_mid FOR VALUES FROM (100) TO (200);')
            self.sql(db, 'INSERT INTO cliente.old_leaf VALUES (101);', user=self.reader, ok=False)
            self.sql(db, 'INSERT INTO cliente.old_leaf VALUES (102);', user=self.master)
            # A renamed Bronze table enters Silver in the DDL transaction.
            self.sql(db, 'CREATE TABLE cliente.brz_promote(value int); GRANT INSERT ON cliente.brz_promote TO ' + identifier(self.reader) + ';'
                     'ALTER TABLE cliente.brz_promote RENAME TO slv_promote;')
            self.sql(db, 'INSERT INTO cliente.slv_promote VALUES (1);', user=self.reader, ok=False)
            self.sql(db, 'ALTER TABLE cliente.slv_promote RENAME TO brz_promote; SELECT cliente.gvlt_relation_classify(\'cliente.brz_promote\',\'Bronze\');')
            self.assertEqual(self.sql(db, "SELECT layer FROM cliente.gvlt_relation_registry WHERE relation_name='brz_promote';"), 'Bronze')
        # Protection follows OID across rename; admin must explicitly classify departure.
        renamed = identifier(target) + '.renamed'
        self.sql(db, 'ALTER TABLE ' + silver + ' RENAME TO renamed;')
        self.sql(db, 'ALTER TABLE ' + renamed + ' RENAME COLUMN value TO renamed_value;')
        self.sql(db, 'INSERT INTO ' + renamed + '(value) VALUES (1);', user=self.reader, ok=False)
        self.assertEqual(self.sql(db, 'SELECT layer FROM ' + f('relation_registry') + " WHERE relation_name='renamed';"), 'Silver')
        self.assertEqual(self.sql(db, 'SELECT is_active FROM ' + f('tag_obj') + " WHERE obj_name='" + target + ".renamed.renamed_value' AND tag_name='ID';"), 't')
        self.assertEqual(self.sql(db, 'SELECT is_active FROM ' + f('tag_obj') + " WHERE obj_name='" + target + ".renamed' AND tag_name='GEO';"), 't')
        self.sql(db, 'ALTER TABLE ' + renamed + ' DISABLE TRIGGER gvlt_write_guard;')
        # Administrative DDL reapplies the policy atomically and repairs guard drift.
        self.assertEqual(self.sql(db, "SELECT tgenabled FROM pg_trigger WHERE tgrelid='" + renamed + "'::regclass AND tgname='gvlt_write_guard';"), 'A')
        self.sql(db, 'GRANT INSERT ON ' + renamed + ' TO ' + identifier(self.reader) + ';')
        self.assertGreater(int(self.sql(db, 'SELECT count(*) FROM ' + f('policy_check') + "() WHERE issue LIKE 'Unexpected INSERT%';")), 0)
        self.sql(db, 'INSERT INTO ' + renamed + '(renamed_value) VALUES (1);', user=self.reader, ok=False)
        self.sql(db, 'SELECT ' + f('policy_apply') + '(); SELECT ' + f('policy_apply') + '();')
        history_count = self.sql(db, 'SELECT count(*) FROM ' + f('permission_history'))
        self.sql(db, 'SELECT ' + f('policy_apply') + '();')
        self.assertEqual(self.sql(db, 'SELECT count(*) FROM ' + f('permission_history')), history_count)
        self.sql(db, 'SELECT ' + f('policy_set') + "(true,'" + self.next_master + "');")
        self.sql(db, 'INSERT INTO ' + renamed + '(renamed_value) VALUES (1);', user=self.master, ok=False)
        self.sql(db, 'INSERT INTO ' + renamed + '(renamed_value) VALUES (1);', user=self.next_master)
        self.sql(db, 'SELECT ' + f('policy_set') + '(false);')
        self.sql(db, 'INSERT INTO ' + renamed + '(renamed_value) VALUES (1);', user=self.reader, ok=False)
        self.assertGreater(int(self.sql(db, 'SELECT count(*) FROM ' + f('permission_history'))), 0)
        self.sql(db, 'BEGIN; GRANT INSERT ON ' + renamed + ' TO ' + identifier(self.reader) + '; SELECT ' + f('permission_review') +
                 "((SELECT min(id) FROM " + f('permission_history') + "),'Reviewed; INSERT restored explicitly after deactivation'); COMMIT;")
        self.sql(db, 'INSERT INTO ' + renamed + '(renamed_value) VALUES (1);', user=self.reader)

    def test_rollback_and_collisions(self):
        db = self.database('rollback')
        layout = Layout('single', 'cliente')
        self.sql(db, 'CREATE SCHEMA cliente; CREATE TABLE cliente.gvlt_tag(value int); INSERT INTO cliente.gvlt_tag VALUES (42);')
        self.sql(db, build_sql(layout), ok=False)
        self.assertEqual(self.sql(db, 'SELECT value FROM cliente.gvlt_tag;'), '42')
        self.assertEqual(self.sql(db, "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='cliente';"), '0')
        self.sql(db, 'DROP TABLE cliente.gvlt_tag;')
        self.sql(db, build_sql(layout, True, 'missing_master'), ok=False)
        self.assertEqual(self.sql(db, "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='cliente';"), '0')
        self.sql(db, build_sql(layout, True, os.environ.get('PGUSER', 'postgres')), ok=False)
        self.sql(db, 'GRANT ' + identifier(self.master) + ' TO ' + identifier(self.reader) + ';')
        try:
            self.sql(db, build_sql(layout, True, self.master), ok=False)
        finally:
            self.sql(db, 'REVOKE ' + identifier(self.master) + ' FROM ' + identifier(self.reader) + ';')
        self.sql(db, 'CREATE FUNCTION cliente.lib_round(double precision,integer) RETURNS int LANGUAGE sql AS $$ SELECT 42 $$;')
        self.sql(db, build_sql(layout), ok=False)
        self.assertEqual(self.sql(db, 'SELECT cliente.lib_round(1,2);'), '42')
        self.sql(db, 'DROP FUNCTION cliente.lib_round(double precision,integer); CREATE VIEW cliente.gvlt_vw_doc_function_examples AS SELECT 42 AS value;')
        self.sql(db, build_sql(layout), ok=False)
        self.assertEqual(self.sql(db, 'SELECT value FROM cliente.gvlt_vw_doc_function_examples;'), '42')


if __name__ == '__main__':
    unittest.main()

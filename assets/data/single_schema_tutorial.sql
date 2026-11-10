-- Explicit template: setup.py --tutorial --mode single --schema cliente.
-- Run as DBA. All example objects stay inside the authorized schema.
CREATE TABLE {{object:brz.tutorial_municipios}} (id integer PRIMARY KEY, municipio text NOT NULL);
INSERT INTO {{object:brz.tutorial_municipios}} VALUES (1,'Municipio A'),(2,'Municipio B');
CREATE TABLE {{object:slv.tutorial_municipios}} AS SELECT * FROM {{object:brz.tutorial_municipios}};
CREATE VIEW {{object:gld.tutorial_municipios}} AS SELECT count(*) AS total FROM {{object:slv.tutorial_municipios}};
SELECT {{object:gvlt.tagobj_include}}('GEO',ARRAY['{{schema_name:slv}}.{{prefix:slv}}tutorial_municipios']);
SELECT {{object:gvlt.doc_examples_add}}('SELECT * FROM {{object:gld.tutorial_municipios}}');
SELECT * FROM {{object:gvlt.medallion_objects}}('{{schema_name:gvlt}}');
DO $$ BEGIN
  ASSERT (SELECT total FROM {{object:gld.tutorial_municipios}})=2,'Unexpected tutorial result';
  ASSERT EXISTS(SELECT FROM {{object:gvlt.relation_registry}} WHERE relation_name='slv_tutorial_municipios' AND layer='Silver' AND is_active),'Silver object not cataloged';
END $$;

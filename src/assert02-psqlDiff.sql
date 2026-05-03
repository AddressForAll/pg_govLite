-- Tests after install fw in an empty database

SELECT * FROM gvlt.vw01_medallion; -- show current tags (expected demo list)

-- create schema com:
CREATE SCHEMA q_bronze;  CREATE SCHEMA q_silver;   CREATE SCHEMA q_gold;
-- create schema sem:
CREATE SCHEMA q_bronze_q; CREATE SCHEMA q_prata; CREATE SCHEMA q_gold_q;

SELECT * FROM gvlt.medallion; -- listando

-- create table com:
CREATE TABLE q_bronze.t (x int);  CREATE TABLE q_silver.t (x int);   CREATE TABLE q_gold.t (x int);
-- create table sem:
CREATE TABLE q_bronze_q.t (x int); CREATE TABLE q_prata.t (x int);

CREATE SCHEMA semTag_bronze;
SELECT gvlt.medallion_upsert('q_bronze','{"q":0}');
SELECT gvlt.medallion_upsert('TSTDEMO_silver','{"x":1}');
SELECT gvlt.medallion_upsert('geo_gold','{"y":2}');

SELECT * FROM gvlt.vw01_medallion; -- listando

-- drop schema com:
DROP SCHEMA test_bronze;  DROP SCHEMA test_silver;   DROP SCHEMA test_gold;
-- drop schema sem:
DROP SCHEMA test_bronze_test; DROP SCHEMA test_prata; DROP SCHEMA test_gold_test;

SELECT * FROM gvlt.vw01_medallion; -- listando

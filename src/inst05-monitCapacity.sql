DROP FUNCTION IF EXISTS lib.rel_disk_usage_full(text[]);

CREATE FUNCTION lib.rel_disk_usage_full(
    p_schema_list text[] DEFAULT NULL
)
RETURNS TABLE (
    schema_name              text,
    relname                  text,
    reltype                  text,

    -- capacidade
    table_size               text,
    table_size_bytes         bigint,
    indexes_size             text,
    indexes_size_bytes       bigint,
    total_size               text,
    total_size_bytes         bigint,
    index_ratio              numeric,

    -- cardinalidade / densidade
    rows_estimate            bigint,
    live_rows                bigint,
    dead_rows                bigint,
    dead_pct                 numeric,
    avg_row_bytes            numeric,

    -- índices
    index_count              integer,
    largest_index_size       text,
    largest_index_bytes      bigint,

    -- padrão real de leitura
    seq_scan                 bigint,
    seq_tup_read             bigint,
    seq_rows_per_scan        numeric,
    seq_table_equivalents    numeric,

    idx_scan                 bigint,
    idx_tup_fetch            bigint,
    idx_rows_per_scan        numeric,

    -- manutenção / estabilidade
    modified_since_analyze   bigint,
    last_analyze             timestamptz,
    last_autoanalyze         timestamptz,
    last_vacuum              timestamptz,
    last_autovacuum          timestamptz,

    -- particionamento
    is_partitioned           boolean,
    is_partition             boolean,
    parent_table             text,
    partition_count          integer,
    partition_key            text,

    -- interpretação
    access_pattern           text,
    capacity_class           text,
    partition_advice         text,

    -- importante para interpretar os contadores acima
    stats_since              timestamptz
)
LANGUAGE SQL
STABLE
BEGIN ATOMIC

WITH rel AS (
    SELECT
        c.oid,
        n.nspname::text AS schema_name,
        c.relname::text AS relname,
        c.relkind,

        CASE c.relkind
            WHEN 'r' THEN 'table'
            WHEN 'p' THEN 'partitioned table'
            WHEN 'm' THEN 'materialized view'
        END::text AS reltype,

        pg_table_size(c.oid)::bigint          AS table_bytes,
        pg_indexes_size(c.oid)::bigint        AS indexes_bytes,
        pg_total_relation_size(c.oid)::bigint AS total_bytes,

        c.reltuples::bigint AS rows_estimate,

        (c.relkind = 'p') AS is_partitioned,

        EXISTS (
            SELECT 1
            FROM pg_catalog.pg_inherits i
            WHERE i.inhrelid = c.oid
        ) AS is_partition

    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n
      ON n.oid = c.relnamespace

    WHERE c.relkind IN ('r', 'p', 'm')
      AND (
          p_schema_list IS NULL
          OR n.nspname = ANY (p_schema_list)
      )
),

base AS (
    SELECT
        r.*,

        coalesce(s.n_live_tup, r.rows_estimate)::bigint
            AS live_rows,

        coalesce(s.n_dead_tup, 0)::bigint
            AS dead_rows,

        coalesce(s.seq_scan, 0)::bigint
            AS seq_scan,

        coalesce(s.seq_tup_read, 0)::bigint
            AS seq_tup_read,

        coalesce(s.idx_scan, 0)::bigint
            AS idx_scan,

        coalesce(s.idx_tup_fetch, 0)::bigint
            AS idx_tup_fetch,

        coalesce(s.n_mod_since_analyze, 0)::bigint
            AS modified_since_analyze,

        s.last_analyze,
        s.last_autoanalyze,
        s.last_vacuum,
        s.last_autovacuum,

        (
            SELECT count(*)::integer
            FROM pg_catalog.pg_index ix
            WHERE ix.indrelid = r.oid
        ) AS index_count,

        coalesce((
            SELECT max(pg_relation_size(ix.indexrelid))
            FROM pg_catalog.pg_index ix
            WHERE ix.indrelid = r.oid
        ), 0)::bigint AS largest_index_bytes,

        (
            SELECT format('%I.%I', pn.nspname, pc.relname)
            FROM pg_catalog.pg_inherits i
            JOIN pg_catalog.pg_class pc
              ON pc.oid = i.inhparent
            JOIN pg_catalog.pg_namespace pn
              ON pn.oid = pc.relnamespace
            WHERE i.inhrelid = r.oid
            LIMIT 1
        )::text AS parent_table,

        (
            SELECT count(*)::integer
            FROM pg_catalog.pg_inherits i
            WHERE i.inhparent = r.oid
        ) AS partition_count,

        CASE
            WHEN r.relkind = 'p'
            THEN pg_catalog.pg_get_partkeydef(r.oid)
        END::text AS partition_key

    FROM rel r

    LEFT JOIN pg_catalog.pg_stat_all_tables s
      ON s.relid = r.oid
),

calc AS (
    SELECT
        b.*,

        round(
            100.0 * dead_rows
            / NULLIF(live_rows + dead_rows, 0),
            2
        ) AS dead_pct,

        round(
            table_bytes::numeric
            / NULLIF(live_rows, 0),
            1
        ) AS avg_row_bytes,

        round(
            indexes_bytes::numeric
            / NULLIF(table_bytes, 0),
            2
        ) AS index_ratio,

        round(
            seq_tup_read::numeric
            / NULLIF(seq_scan, 0),
            1
        ) AS seq_rows_per_scan,

        /*
         * Quantas "leituras completas da tabela" equivalentes
         * os sequential scans representam desde o reset das stats.
         *
         * Exemplo:
         * 100 milhões de linhas na tabela
         * 500 milhões de seq_tup_read
         * => aproximadamente 5 table-equivalents.
         */
        round(
            seq_tup_read::numeric
            / NULLIF(live_rows, 0),
            2
        ) AS seq_table_equivalents,

        round(
            idx_tup_fetch::numeric
            / NULLIF(idx_scan, 0),
            1
        ) AS idx_rows_per_scan

    FROM base b
),

classified AS (
    SELECT
        c.*,

        CASE
            WHEN seq_scan = 0 AND idx_scan = 0
                THEN 'no observed reads'

            WHEN seq_scan > 0
             AND seq_rows_per_scan >= live_rows * 0.50
             AND idx_scan = 0
                THEN 'broad sequential scans'

            WHEN seq_scan > 0
             AND seq_rows_per_scan >= live_rows * 0.50
                THEN 'mixed, with broad sequential scans'

            WHEN idx_scan > seq_scan * 10
             AND coalesce(idx_rows_per_scan, 0) <= 100
                THEN 'highly selective indexed access'

            WHEN idx_scan > seq_scan * 10
                THEN 'index-oriented access'

            WHEN seq_scan > idx_scan * 10
                THEN 'sequential-oriented access'

            ELSE
                'mixed access'
        END::text AS access_pattern,

        CASE
            WHEN total_bytes < 10::bigint * 1024 * 1024 * 1024
                THEN 'small'

            WHEN total_bytes < 50::bigint * 1024 * 1024 * 1024
                THEN 'medium'

            WHEN total_bytes < 100::bigint * 1024 * 1024 * 1024
                THEN 'large'

            ELSE
                'very large'
        END::text AS capacity_class

    FROM calc c
)

SELECT
    c.schema_name,
    c.relname,
    c.reltype,

    pg_size_pretty(c.table_bytes),
    c.table_bytes,

    pg_size_pretty(c.indexes_bytes),
    c.indexes_bytes,

    pg_size_pretty(c.total_bytes),
    c.total_bytes,

    c.index_ratio,

    c.rows_estimate,
    c.live_rows,
    c.dead_rows,
    c.dead_pct,
    c.avg_row_bytes,

    c.index_count,
    pg_size_pretty(c.largest_index_bytes),
    c.largest_index_bytes,

    c.seq_scan,
    c.seq_tup_read,
    c.seq_rows_per_scan,
    c.seq_table_equivalents,

    c.idx_scan,
    c.idx_tup_fetch,
    c.idx_rows_per_scan,

    c.modified_since_analyze,
    c.last_analyze,
    c.last_autoanalyze,
    c.last_vacuum,
    c.last_autovacuum,

    c.is_partitioned,
    c.is_partition,
    c.parent_table,
    c.partition_count,
    c.partition_key,

    c.access_pattern,
    c.capacity_class,

    CASE
        WHEN c.is_partitioned
            THEN
                'already partitioned'

        /*
         * Até 10 GB, para seu tipo de tabela compacta/read-mostly,
         * o tamanho sozinho é argumento muito fraco.
         */
        WHEN c.total_bytes
             < 10::bigint * 1024 * 1024 * 1024
            THEN
                'keep monolithic; size does not justify partitioning'

        /*
         * Se scans estão lendo grande parte da tabela, particionar
         * somente ajuda se WHERE/JOIN permitir partition pruning.
         */
        WHEN c.seq_rows_per_scan >= c.live_rows * 0.50
            THEN
                'broad scans: partition only if common filters align with partition key'

        /*
         * Lookup muito seletivo por índices:
         * uma tabela monolítica normalmente continua eficiente.
         */
        WHEN c.idx_scan > c.seq_scan * 10
         AND coalesce(c.idx_rows_per_scan, 0) <= 100
            THEN
                'selective indexed workload; partitioning probably unnecessary'

        /*
         * Índices ficando muito maiores que heap + relação grande:
         * aqui começa a surgir um argumento operacional.
         */
        WHEN c.total_bytes
             >= 50::bigint * 1024 * 1024 * 1024
         AND c.index_ratio >= 1.0
            THEN
                'review partitioning: large relation and heavy index footprint'

        WHEN c.total_bytes
             >= 50::bigint * 1024 * 1024 * 1024
            THEN
                'review partitioning if a natural pruning key exists'

        ELSE
            'partition only if workload benefits from pruning or bulk maintenance'
    END::text,

    db.stats_reset

FROM classified c

CROSS JOIN (
    SELECT stats_reset
    FROM pg_catalog.pg_stat_database
    WHERE datname = current_database()
) db

ORDER BY c.total_bytes DESC;

END;

# Postgres

## Best practices

- https://wiki.postgresql.org/wiki/Lock_Monitoring
- https://wiki.postgresql.org/wiki/Don't_Do_This
- [Checks for potentially unsafe migrations](https://github.com/ankane/strong_migrations#checks)
- https://www.crunchydata.com/postgres-tips
- Avoid using nested transactions and `SELECT FOR SHARE`
  - [Notes on some PostgreSQL implementation details](https://buttondown.email/nelhage/archive/notes-on-some-postgresql-implementation-details/)
- [Partitioning](https://brandur.org/fragments/postgres-partitioning-2022)
- [Safely renaming a table](https://brandur.org/fragments/postgres-table-rename)

## Extensions

- https://github.com/reorg/pg_repack
- https://github.com/VADOSWARE/pg_idkit

## Tooling

- [Explore what commands issue which kinds of locks](https://pglocks.org/)
- https://github.com/AdmTal/PostgreSQL-Query-Lock-Explainer

## Tricks

### Bulk update

```sql
UPDATE relation SET foo = bulk_update.foo
        FROM (
          SELECT * FROM
            unnest(
              array[(1)],
              array[("bar")]
            ) AS d(id, foo)
        ) AS bulk_update
        WHERE relation.id = bulk_update.id;
```

### Conditional insert

```sql
INSERT INTO possible_problematic_domains (domain, created_at, updated_at)
SELECT $1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
WHERE EXISTS (
  SELECT 1
  FROM companies
  WHERE discarded_at IS NULL
  AND domain = $1
  HAVING (count(*) >= 5)
  LIMIT 1
) AND NOT (
  EXISTS (
    SELECT 1
    FROM problematic_domains
    WHERE domain = $1
    LIMIT 1
  )
)
ON CONFLICT (domain) DO NOTHING
RETURNING id;
```

## Snippets

### Query execution times

```sql
SELECT round(total_exec_time*1000)/1000 AS total_exec_time,
       round(total_plan_time*1000)/1000 AS total_plan_time,
       query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 2;
```

```sql
SELECT total_exec_time,
       mean_exec_time AS avg_ms,
       calls,
       query
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

### Check long running queries

```sql
SELECT pid,
       now() - pg_stat_activity.query_start AS duration,
       query,
       state,
       wait_event,
       wait_event_type,
       pg_blocking_pids(pid)
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > interval '1 minutes'
  AND state = 'active';
```

### Blockers of queries (ALTER TABLE)

```sql
SELECT blockers.pid,
       blockers.usename,
       blockers.query_start,
       blockers.query
FROM pg_stat_activity blockers
INNER JOIN
  (SELECT pg_blocking_pids(pid) blocking_pids
   FROM pg_stat_activity
   WHERE pid != pg_backend_pid()
     AND query LIKE 'ALTER TABLE%' ) my_query ON blockers.pid = ANY(my_query.blocking_pids);
```

### Blockers of queries (blocked query + blocking query)

```sql
SELECT a1.pid,
       a1.usename,
       (now() - a1.query_start) AS running_time,
       pg_blocking_pids(a1.pid) AS blocked_by,
       a1.query AS blocked_query,
       a2.query AS blocking_query
FROM pg_stat_activity AS a1
INNER JOIN pg_stat_activity AS a2 ON (a2.pid = (pg_blocking_pids(a1.pid)::integer[])[1])
WHERE cardinality(pg_blocking_pids(a1.pid)) > 0;
```

### Kill query

```sql
SELECT pg_cancel_backend(pid);
```

```sql
SELECT pg_terminate_backend(pid);
```

#### Kill all autovacuums

```sql
SELECT pg_terminate_backend(pid),
       query,
       now() - pg_stat_activity.query_start AS duration
FROM pg_stat_activity
WHERE query ilike 'autovacuum:%';
```

### Check ongoing vacuums

```sql
SELECT p.pid,
       now() - a.xact_start AS duration,
       coalesce(wait_event_type ||'.'|| wait_event, 'f') AS waiting,
       CASE
           WHEN a.query ~*'^autovacuum.*to prevent wraparound' THEN 'wraparound'
           WHEN a.query ~*'^vacuum' THEN 'user'
           ELSE 'regular'
       END AS MODE,
       p.datname AS DATABASE,
       p.relid::regclass AS TABLE,
       p.phase,
       pg_size_pretty(p.heap_blks_total * current_setting('block_size')::int) AS table_size,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       pg_size_pretty(p.heap_blks_scanned * current_setting('block_size')::int) AS scanned,
       pg_size_pretty(p.heap_blks_vacuumed * current_setting('block_size')::int) AS vacuumed,
       round(100.0 * p.heap_blks_scanned / p.heap_blks_total, 1) AS scanned_pct,
       round(100.0 * p.heap_blks_vacuumed / p.heap_blks_total, 1) AS vacuumed_pct,
       p.index_vacuum_count,
       round(100.0 * p.num_dead_tuples / p.max_dead_tuples, 1) AS dead_pct
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a USING (pid)
ORDER BY now() - a.xact_start DESC;
```

### Estimate row count

```sql
SELECT reltuples::numeric AS estimate_count
FROM pg_class
WHERE relname = 'table_name';
```

### Estimate query row count

```sql
CREATE FUNCTION row_estimator(query text) RETURNS bigint LANGUAGE PLPGSQL AS $$DECLARE
   plan jsonb;
BEGIN
   EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;

   RETURN (plan->0->'Plan'->>'Plan Rows')::bigint;
END;$$;
```

### Check table sizes

```sql
SELECT nspname || '.' || relname AS "relation",
       pg_size_pretty(pg_total_relation_size(C.oid)) AS "total_size"
FROM pg_class C
LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
WHERE nspname NOT IN ('pg_catalog',
                      'information_schema')
  AND C.relkind <> 'i'
  AND nspname !~ '^pg_toast'
ORDER BY pg_total_relation_size(C.oid) DESC
LIMIT 40;
```

### Check table size

```sql
SELECT pg_size_pretty(pg_relation_size('table_name'));
```

### Check unused indexes

```sql
SELECT schemaname || '.' || relname AS TABLE,
       indexrelname AS INDEX,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS "index size",
       idx_scan AS "index scans"
FROM pg_stat_user_indexes ui
JOIN pg_index i ON ui.indexrelid = i.indexrelid
WHERE NOT indisunique
  AND idx_scan < 50
  AND pg_relation_size(relid) > 5 * 8192
ORDER BY pg_relation_size(i.indexrelid) / nullif(idx_scan, 0) DESC NULLS FIRST,
         pg_relation_size(i.indexrelid) DESC;
```

### Check which tables are aging

```sql
SELECT c.oid::regclass,
       age(c.relfrozenxid),
       pg_size_pretty(pg_total_relation_size(c.oid))
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE relkind IN ('r',
                  't',
                  'm')
  AND n.nspname NOT IN ('pg_toast')
ORDER BY 2 DESC
LIMIT 20;
```

### Connection counts

```sql
SELECT count(*),
       state
FROM pg_stat_activity
GROUP BY state;
```

### Check for index usage

```sql

SELECT
    idstat.relname AS TABLE_NAME,
    indexrelname AS index_name,
    idstat.idx_scan AS index_scans_count,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    tabstat.idx_scan AS table_reads_index_count,
    tabstat.seq_scan AS table_reads_seq_count,
    tabstat.seq_scan + tabstat.idx_scan AS table_reads_count,
    n_tup_upd + n_tup_ins + n_tup_del AS table_writes_count,
    pg_size_pretty(pg_relation_size(idstat.relid)) AS table_size
FROM
    pg_stat_user_indexes AS idstat
JOIN
    pg_indexes
    ON
    indexrelname = indexname
    AND
    idstat.schemaname = pg_indexes.schemaname
JOIN
    pg_stat_user_tables AS tabstat
    ON
    idstat.relid = tabstat.relid
WHERE
    indexdef !~* 'unique'
ORDER BY
    idstat.idx_scan DESC,
    pg_relation_size(indexrelid) DESC;
```

### [Check ongoing usage creation](https://www.postgresql.org/docs/current/progress-reporting.html#CREATE-INDEX-PROGRESS-REPORTING)https://www.postgresql.org/docs/current/progress-reporting.html#CREATE-INDEX-PROGRESS-REPORTING

```sql
select * from pg_stat_progress_create_index;
```

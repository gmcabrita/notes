# Postgres
## Best practices / useful blog posts
* https://pglocks.org/
* https://github.com/AdmTal/PostgreSQL-Query-Lock-Explainer
* https://wiki.postgresql.org/wiki/Lock_Monitoring
* https://wiki.postgresql.org/wiki/Don't_Do_This
* [Checks for potentially unsafe migrations](https://github.com/ankane/strong_migrations#checks)
* https://www.crunchydata.com/postgres-tips
* Avoid using nested transactions and SELECT FOR SHARE
  * [Notes on some PostgreSQL implementation details](https://buttondown.email/nelhage/archive/notes-on-some-postgresql-implementation-details/)
* [Partitioning](https://brandur.org/fragments/postgres-partitioning-2022)
* [Safely renaming a table](https://brandur.org/fragments/postgres-table-rename)
* [Notes on Postgres WAL LSNs](https://github.com/superfly/fly_postgres_elixir/blob/88b1bf843c405e02666450e5d2e2c55f940a28e1/DEV_NOTES.md#postgres-features)
* https://gitlab.com/postgres-ai/postgresql-consulting/postgres-howtos
* https://rachbelaid.com/introduction-to-postgres-physical-storage/
* Set a lower `fillfactor` for tables which receive a lot of `UPDATE` operations
  * See also: https://www.crunchydata.com/blog/postgres-performance-boost-hot-updates-and-fill-factor#fill-factor
    * A fill factor of 70%, 80% or 90% provides a good tradeoff to hit more HOT updates at the cost of some extra storage
    * Stats should probably be reset after fill factors are tweaked to better keep track of the percentage of HOT updates going forward
* Consider using `plan_cache_mode = force_custom_plan` to prevent Postgres from caching bad plans
  * Elixir specific(?): You may also set `prepare: :unnamed` at the connection level so that every prepared statement using that connection will be unnamed
* Configure `random_page_cost` to a better value (e.g. 1.1) if using SSDs
  * https://www.postgresql.org/docs/current/runtime-config-query.html#GUC-RANDOM-PAGE-COST
## Extensions
* https://github.com/reorg/pg_repack
* https://github.com/VADOSWARE/pg_idkit
## Tooling
* [Explore what commands issue which kinds of locks](https://pglocks.org/)
* https://leontrolski.github.io/pglockpy.html
  * https://github.com/leontrolski/pglockpy/tree/eda985ff87dbc8c30197e190aa1d8af777f8d349
  * https://github.com/leontrolski/leontrolski.github.io/blob/2d05dcb52b3b90f70a4a3ef9f2cf178b94440cf8/pglockpy.html
* https://github.com/AdmTal/PostgreSQL-Query-Lock-Explainer
* https://github.com/NikolayS/postgres_dba
## Tricks
### Insert sample data
```sql
DO $$
  BEGIN LOOP
    INSERT INTO http_request (
      site_id, ingest_time, url, request_country,
      ip_address, status_code, response_time_msec
    ) VALUES (
      trunc(random()*32), clock_timestamp(),
      concat('[http://example.com](https://t.co/arRaQ8EOz0)', md5(random()::text)),
      ('{China,India,USA,Indonesia}'::text[])[ceil(random()*4)],
      concat(
        trunc(random()*250 + 2), '.',
        trunc(random()*250 + 2), '.',
        trunc(random()*250 + 2), '.',
        trunc(random()*250 + 2)
      )::inet,
      ('{200,404}'::int[])[ceil(random()*2)],
      5+trunc(random()*150)
    );
    COMMIT;
    PERFORM pg_sleep(random() * 0.05);
  END LOOP;
END $$;
```
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
SELECT pg_terminate_backend(pid);
```
### Kill all autovacuums
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
### Check ongoing usage creation
```sql
SELECT now(),
       query_start AS started_at,
       now() - query_start AS query_duration,
       format('[%s] %s', a.pid, a.query) AS pid_and_query,
       index_relid::regclass AS index_name,
       relid::regclass AS TABLE_NAME,
       (pg_size_pretty(pg_relation_size(relid))) AS table_size,
       nullif(wait_event_type, '') || ': ' || wait_event AS wait_type_and_event,
       phase,
       format('%s (%s of %s)', coalesce((round(100 * blocks_done::numeric / nullif(blocks_total, 0), 2))::text || '%', 'N/A'), coalesce(blocks_done::text, '?'), coalesce(blocks_total::text, '?')) AS blocks_progress,
       format('%s (%s of %s)', coalesce((round(100 * tuples_done::numeric / nullif(tuples_total, 0), 2))::text || '%', 'N/A'), coalesce(tuples_done::text, '?'), coalesce(tuples_total::text, '?')) AS tuples_progress,
       current_locker_pid,

  (SELECT nullif(left(query, 150), '') || '...'
   FROM pg_stat_activity a
   WHERE a.pid = current_locker_pid) AS current_locker_query,
       format('%s (%s of %s)', coalesce((round(100 * lockers_done::numeric / nullif(lockers_total, 0), 2))::text || '%', 'N/A'), coalesce(lockers_done::text, '?'), coalesce(lockers_total::text, '?')) AS lockers_progress,
       format('%s (%s of %s)', coalesce((round(100 * partitions_done::numeric / nullif(partitions_total, 0), 2))::text || '%', 'N/A'), coalesce(partitions_done::text, '?'), coalesce(partitions_total::text, '?')) AS partitions_progress,

  (SELECT format('%s (%s of %s)', coalesce((round(100 * n_dead_tup::numeric / nullif(reltuples::numeric, 0), 2))::text || '%', 'N/A'), coalesce(n_dead_tup::text, '?'), coalesce(reltuples::int8::text, '?'))
   FROM pg_stat_all_tables t,
        pg_class tc
   WHERE t.relid = p.relid
     AND tc.oid = p.relid ) AS table_dead_tuples
FROM pg_stat_progress_create_index p
LEFT JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY p.index_relid;
```
See also: https://www.postgresql.org/docs/current/progress-reporting.html\#CREATE-INDEX-PROGRESS-REPORTING
### Show Analyze / Vacuum Statistics
```sql
WITH raw_data AS (
  SELECT
    pg_namespace.nspname,
    pg_class.relname,
    pg_class.oid AS relid,
    pg_class.reltuples,
    pg_stat_all_tables.n_dead_tup,
    pg_stat_all_tables.n_mod_since_analyze,
    (SELECT split_part(x, '=', 2) FROM unnest(pg_class.reloptions) q (x) WHERE x ~ '^autovacuum_analyze_scale_factor=' ) as c_analyze_factor,
    (SELECT split_part(x, '=', 2) FROM unnest(pg_class.reloptions) q (x) WHERE x ~ '^autovacuum_analyze_threshold=' ) as c_analyze_threshold,
    (SELECT split_part(x, '=', 2) FROM unnest(pg_class.reloptions) q (x) WHERE x ~ '^autovacuum_vacuum_scale_factor=' ) as c_vacuum_factor,
    (SELECT split_part(x, '=', 2) FROM unnest(pg_class.reloptions) q (x) WHERE x ~ '^autovacuum_vacuum_threshold=' ) as c_vacuum_threshold,
    to_char(pg_stat_all_tables.last_vacuum, 'YYYY-MM-DD HH24:MI:SS') as last_vacuum,
    to_char(pg_stat_all_tables.last_autovacuum, 'YYYY-MM-DD HH24:MI:SS') as last_autovacuum,
    to_char(pg_stat_all_tables.last_analyze, 'YYYY-MM-DD HH24:MI:SS') as last_analyze,
    to_char(pg_stat_all_tables.last_autoanalyze, 'YYYY-MM-DD HH24:MI:SS') as last_autoanalyze
  FROM
    pg_class
  JOIN pg_namespace ON pg_class.relnamespace = pg_namespace.oid
    LEFT OUTER JOIN pg_stat_all_tables ON pg_class.oid = pg_stat_all_tables.relid
  WHERE
    n_dead_tup IS NOT NULL
    AND nspname NOT IN ('information_schema', 'pg_catalog')
    AND nspname NOT LIKE 'pg_toast%'
    AND pg_class.relkind = 'r'
), data AS (
  SELECT
    *,
    COALESCE(raw_data.c_analyze_factor, current_setting('autovacuum_analyze_scale_factor'))::float8 AS analyze_factor,
    COALESCE(raw_data.c_analyze_threshold, current_setting('autovacuum_analyze_threshold'))::float8 AS analyze_threshold,
    COALESCE(raw_data.c_vacuum_factor, current_setting('autovacuum_vacuum_scale_factor'))::float8 AS vacuum_factor,
    COALESCE(raw_data.c_vacuum_threshold, current_setting('autovacuum_vacuum_threshold'))::float8 AS vacuum_threshold
  FROM raw_data
)
SELECT
  relname,
  reltuples,
  n_dead_tup,
  n_mod_since_analyze,  
  ROUND(reltuples * vacuum_factor + vacuum_threshold) AS v_threshold,
  ROUND(reltuples * analyze_factor + analyze_threshold) AS a_threshold,
  ROUND(CAST(n_dead_tup/(reltuples * vacuum_factor + vacuum_threshold)*100 AS numeric), 2) AS v_percent,
  ROUND(CAST(n_mod_since_analyze/(reltuples * analyze_factor + analyze_threshold)*100 AS numeric), 2) AS a_percent,
  last_vacuum,
  last_autovacuum,
  last_analyze,
  last_autoanalyze
FROM
  data
ORDER BY a_percent DESC;
```
### Check table statistics
```sql
select * from pg_stats pgs where pgs.tablename = '?';
```
### Prepared statements for psql operations
```SQL
PREPARE add_flag_to_team(text, uuid) AS INSERT INTO flag_team (
    flag_id,
    team_id
) VALUES (
    (SELECT id FROM flag WHERE name = $1),
    $2
) ON CONFLICT DO NOTHING;

EXECUTE add_flag_to_team('<flag_name>', '<team_id>');
```
### Rows Without Overlapping Dates
Preventing e.g. multiple concurrent reservations for a meeting room is a complicated task because of race conditions. Without pessimistic locking by the application or careful planning, simultaneous requests can create room reservations for the exact timeframe or overlapping ones. The work can be offloaded to the database with an exclusion constraint that will prevent any overlapping ranges for the same room number. This safety feature is available for integer, numeric, date and timestamp ranges. 
```sql
CREATE TABLE bookings (
  room_number int,
  reservation tstzrange,
  EXCLUDE USING gist (room_number WITH =, reservation WITH &&)
); 
INSERT INTO meeting_rooms (
    room_number, reservation
) VALUES (
  5, '[2022-08-20 16:00:00+00,2022-08-20 17:30:00+00]',
  5, '[2022-08-20 17:30:00+00,2022-08-20 19:00:00+00]',
); 
```
### Max per partition (50 leads, max 5 per company)
```sql
SELECT "lead_list_entries"."id", "rank"
FROM (
  SELECT *, ROW_NUMBER()
  OVER(
    PARTITION BY lead_list_entries.company_domain
    ORDER BY GREATEST(
      lead_list_entries.contacted_at,
      lead_list_entries.exported_at,
      '-infinity'
    ) DESC
  ) AS rank
  FROM "lead_list_entries"
) lead_list_entries
WHERE "lead_list_entries"."rank" BETWEEN 1 AND 5
LIMIT 50
```

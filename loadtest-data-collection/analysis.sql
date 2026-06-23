-- Run after the load test against the same DB. Each query stands alone.

-- 1) PER-INTERVAL hot queries: how much exec time / how many calls each query
--    accrued between consecutive snapshots. This is the "WHEN did it get slow"
--    view that the end-of-run cumulative ORDER BY total_exec_time can't give.
SELECT snap_ts,
       calls       - lag(calls)       OVER w AS calls_d,
       round((total_exec_time - lag(total_exec_time) OVER w)::numeric, 0) AS exec_ms_d,
       round((total_exec_time - lag(total_exec_time) OVER w)
             / NULLIF(calls - lag(calls) OVER w, 0)::numeric, 1)          AS mean_ms,
       left(query, 90) AS query
FROM perf.statements_snap
WINDOW w AS (PARTITION BY userid, dbid, queryid ORDER BY snap_ts)
ORDER BY exec_ms_d DESC NULLS LAST
LIMIT 40;

-- 2) WAIT-EVENT profile: where backends spent time waiting inside Postgres
--    (proxy for pg_wait_sampling's profile, sampled at your snapshot interval).
SELECT coalesce(wait_event_type, 'Running') AS wait_event_type,
       coalesce(wait_event, '(on CPU)')     AS wait_event,
       count(*)                             AS samples,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM perf.activity_snap
GROUP BY 1, 2
ORDER BY samples DESC
LIMIT 30;

-- 3) BLOCKING: snapshots where a backend was blocked, and by whom.
SELECT snap_ts, pid, blocked_by, wait_event_type, wait_event,
       state, left(query, 80) AS query
FROM perf.activity_snap
WHERE cardinality(blocked_by) > 0
ORDER BY snap_ts;

-- 4) CONCURRENCY over time: active backend count per snapshot (correlate the
--    peaks with the db_diesel "pool exhausted" timestamps in omsupply.log).
SELECT snap_ts,
       count(*)                                         AS backends,
       count(*) FILTER (WHERE state = 'active')         AS active,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
       count(*) FILTER (WHERE wait_event IS NOT NULL)   AS waiting
FROM perf.activity_snap
GROUP BY snap_ts
ORDER BY snap_ts;

-- 5) DATABASE TOTALS over the run: diff first vs last snapshot for the app DB.
--    Surfaces deadlocks, rollbacks, temp-file spilling (the changelog COUNT is a
--    prime suspect), and cache hit ratio.
WITH d AS (
  SELECT *, row_number() OVER (PARTITION BY datname ORDER BY snap_ts)            AS rn_first,
            row_number() OVER (PARTITION BY datname ORDER BY snap_ts DESC)       AS rn_last
  FROM perf.database_snap WHERE datname IS NOT NULL
)
SELECT f.datname,
       l.xact_commit   - f.xact_commit   AS commits,
       l.xact_rollback - f.xact_rollback AS rollbacks,
       l.deadlocks     - f.deadlocks     AS deadlocks,
       l.temp_files    - f.temp_files    AS temp_files,
       pg_size_pretty(l.temp_bytes - f.temp_bytes) AS temp_spilled,
       l.blks_read     - f.blks_read     AS blks_read,
       round(100.0 * (l.blks_hit - f.blks_hit)
             / NULLIF((l.blks_hit - f.blks_hit) + (l.blks_read - f.blks_read), 0), 2) AS cache_hit_pct
FROM (SELECT * FROM d WHERE rn_first = 1) f
JOIN (SELECT * FROM d WHERE rn_last  = 1) l USING (datname)
WHERE l.xact_commit - f.xact_commit > 0
ORDER BY commits DESC;

-- Cleanup when done:  DROP SCHEMA perf CASCADE;
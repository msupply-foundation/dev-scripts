-- Run ONCE against the open-mSupply database before a load test.
-- Creates a `perf` schema with snapshot tables + a take_snapshot() function.
-- The snapshot tables live in the DB under test; the extra write load is a few
-- hundred rows every N seconds, negligible. Drop the schema when finished.

CREATE SCHEMA IF NOT EXISTS perf;

-- Cumulative pg_stat_statements, captured per tick. Diff consecutive snapshots
-- (see analysis.sql) to get per-interval exec time / call counts -> "what was
-- hot, and WHEN", which the end-of-run cumulative view can't tell you.
CREATE TABLE IF NOT EXISTS perf.statements_snap AS
  SELECT now() AS snap_ts, * FROM pg_stat_statements WITH NO DATA;

-- One row per non-idle backend per tick: live concurrency, wait events, and who
-- is blocking whom (pg_blocking_pids). This is the in-Postgres wait picture.
-- NB: the app's DB-pool wait (db_diesel:430 "waited Nms for connection") is
-- CLIENT-side in r2d2 -- those waits happen before a backend exists, so they
-- will NOT appear here. This captures LWLock / IO / Lock / etc. waits inside PG.
CREATE TABLE IF NOT EXISTS perf.activity_snap AS
  SELECT now()                  AS snap_ts,
         pg_blocking_pids(pid)  AS blocked_by,
         *
  FROM pg_stat_activity WITH NO DATA;

-- Cluster aggregate counters per tick: commits/rollbacks, deadlocks, temp file
-- spilling (temp_files/temp_bytes), and cache hit ratio (blks_hit/blks_read).
-- Diff first vs last snapshot for the per-run totals.
CREATE TABLE IF NOT EXISTS perf.database_snap AS
  SELECT now() AS snap_ts, * FROM pg_stat_database WITH NO DATA;

CREATE OR REPLACE FUNCTION perf.take_snapshot() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO perf.statements_snap
    SELECT now(), * FROM pg_stat_statements;

  INSERT INTO perf.activity_snap
    SELECT now(), pg_blocking_pids(pid), *
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'   -- skip PG bg workers (autovacuum, walwriter, io workers, ...)
      AND state IS DISTINCT FROM 'idle'     -- keep 'active' + 'idle in transaction'
      AND pid <> pg_backend_pid();          -- don't record the snapshotter itself

  INSERT INTO perf.database_snap
    SELECT now(), * FROM pg_stat_database;
END $$;

-- Helpful index for the diff window function in analysis.sql
CREATE INDEX IF NOT EXISTS statements_snap_key
  ON perf.statements_snap (userid, dbid, queryid, snap_ts);
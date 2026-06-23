# Load-test data collection

A Windows/PowerShell harness for collecting a complete performance picture while
an Open mSupply server is under load. Start it, run your load test, press
`Ctrl-C`, and it bundles everything from that run into a single time-windowed
zip:

- **Postgres query stats** — `pg_stat_statements`, both the end-of-run
  cumulative view and a per-tick snapshot so you can see *when* a query got hot,
  not just that it did.
- **In-database concurrency & waits** — a snapshot of `pg_stat_activity` every
  N seconds: active backend count, wait events, and who is blocking whom.
- **Cluster counters** — `pg_stat_database` per tick: commits, rollbacks,
  deadlocks, temp-file spilling, cache hit ratio.
- **Windows performance counters** — CPU (per core), memory, disk and network,
  via the built-in `logman` collector.
- **Logs** — the Open mSupply server log, the Postgres log, and the Caddy
  access log, sliced to just the test window.
- **A passive capture of all client traffic** — every request the clients sent,
  recorded with [GoReplay](https://github.com/buger/goreplay) for later replay
  against a restored snapshot.

Nothing is lost if the script dies mid-run: the collectors run independently and
snapshots are written to the DB on every tick, so a crashed run can be resumed
(see [Resuming a crashed run](#resuming-a-crashed-run)).

> **This only *collects* data — it does not generate the load.** Run something
> against the server (the "your load test" step above) separately. For a
> repeatable, realistic workload use the **k6 GraphQL load-testing harness**
> (`scripts/load-testing/` in the Open mSupply repo —
> [PR #12235](https://github.com/msupply-foundation/open-msupply/pull/12235)),
> which drives the GraphQL API with a concurrent-user mix derived from a real
> office capture. Alternatively, replay a captured `.gor` file with GoReplay
> (see [Replaying captured traffic](#replaying-captured-traffic)), or just point
> real clients at the server.

## What's in this folder

| File | Purpose |
|---|---|
| [`run-loadtest.ps1`](./run-loadtest.ps1) | The harness. Run this. |
| [`config.ps1`](./config.ps1) | All paths, DB name, and interval. **Edit this first.** Dot-sourced by the harness; also holds the shared helper functions. |
| [`setup_perf_snapshots.sql`](./setup_perf_snapshots.sql) | Creates the `perf` schema (snapshot tables + `take_snapshot()`). Run automatically by SETUP. |
| [`analysis.sql`](./analysis.sql) | Stand-alone queries to run against the DB after a test. Also copied into each run's bundle. |
| [`counters.txt`](./counters.txt) | The list of Windows perfmon counters to sample. Edit to taste. |

## How it works

A run moves through four phases:

| Phase | What happens |
|---|---|
| **SETUP** | `CREATE EXTENSION pg_stat_statements`, create the `perf` snapshot schema, and (re)create the perfmon collector pointed at this run's folder. Skip with `-SkipSetup`. |
| **START** | Reload conf, rotate the Postgres log, reset `pg_stat_statements`, start the perfmon collector and the GoReplay capture, and save run state to disk. |
| **POLL** | Call `perf.take_snapshot()` every `$Interval` seconds until you press `Ctrl-C`. |
| **GATHER** | Stop the collectors, export the Postgres stats and settings to CSV (windowed to this run), copy the logs and the traffic capture, write a `run-info.txt`, and zip the lot. |

The snapshot tables are **never truncated** — they accumulate across runs and
each export is scoped to its own start time. That is what makes a crashed run
recoverable, and it means you clean up the tables yourself when finished (see
[Cleanup](#cleanup)).

## Requirements

- **Windows** with **PowerShell 5+**. Run it **as Administrator** — `logman`,
  reading logs under `Program Files`, and packet capture all want elevation.
- **PostgreSQL** (the version Open mSupply is using). `psql.exe` must exist at
  the path in `config.ps1`.
  - `pg_stat_statements` must be preloaded. In `postgresql.conf`:
    ```conf
    shared_preload_libraries = 'pg_stat_statements'
    ```
    then **restart Postgres**. (The harness runs `CREATE EXTENSION` for you, but
    the library has to be loaded at server start.)
  - Logging to a file enabled, so GATHER can collect the Postgres log:
    ```conf
    logging_collector = on
    log_directory = 'pg_log'
    log_min_duration_statement = 1000   # optional: log slow queries
    ```
    The harness calls `pg_rotate_logfile()` at START so the run gets a clean log.
- **An Open mSupply server** writing its log to a folder (the default is
  `C:\Program Files\Open mSupply Server\log`).
- **[Caddy]** (optional, if you front the server with it) configured to write an
  access log to the path in `config.ps1`, e.g.:
  ```caddyfile
  :7000 {
      log {
          output file C:\PerfLogs\loadtest\caddy\access.log
          format json
      }
      reverse_proxy localhost:8000
  }
  ```
  This is where per-request latency and status come from.
- **[GoReplay]** (optional, for traffic capture/replay):
  - Download `gor.exe` and place it **beside these scripts** (next to
    `run-loadtest.ps1`). It is not committed here — it's a platform binary.
  - Install **[Npcap]** (with WinPcap-compatible mode) so GoReplay can sniff the
    client-facing port passively. If `gor.exe` is missing the harness simply
    skips capture and warns.

[Caddy]: https://caddyserver.com/
[GoReplay]: https://github.com/buger/goreplay
[Npcap]: https://npcap.com/

### Postgres authentication

`psql` needs to authenticate non-interactively for the snapshot loop. Either:

- set `PGPASSWORD` in the environment for the session, or
- add a line to `%APPDATA%\postgresql\pgpass.conf`:
  ```
  localhost:5432:*:postgres:<password>
  ```

If neither works, the harness prompts for the password at startup (up to 3
tries) and uses it for that session only. The default Open mSupply Postgres
password is `password`.

## Setup

1. **Edit [`config.ps1`](./config.ps1)** — at minimum set `$Db` to your current
   app database (find it with `psql -l`) and check `$PsqlBin`. See the table
   below.
2. **Edit [`counters.txt`](./counters.txt)** if you want different perfmon
   counters (the defaults — per-core CPU, memory, disk, network — are a good
   start). See [Perfmon counters](#perfmon-counters).
3. Make sure the prerequisites above are in place (extension preloaded, logging
   on, `gor.exe` beside the script if you want capture).

### Configuration (`config.ps1`)

| Setting | Description |
|---|---|
| `$PsqlBin` | Path to `psql.exe`. |
| `$PgUser` | Postgres user (default `postgres`). |
| `$Db` | **The app database under test.** Find it with `psql -l`. |
| `$Interval` | Seconds between samples — used for **both** perfmon and the DB snapshots. |
| `$CounterName` | `logman` collector name (no need to change). |
| `$CounterCfg` | Perfmon counter list. Defaults to the bundled `counters.txt`. |
| `$PerfDir` | Where per-run perfmon CSVs are staged. |
| `$OmsLogDir` | Open mSupply server log folder. |
| `$PgLogDir` | Postgres log folder (`log_directory`). |
| `$CaddyLog` | Caddy access-log file. Must match the `log` output in your Caddyfile. |
| `$GorBin` | `gor.exe` path (defaults to beside the script). |
| `$CapturePort` | The client-facing port to capture (e.g. Caddy's listen port). |
| `$GorDir` | Where per-run `.gor` captures are staged. |
| `$GatherRoot` | Where each run's gathered bundle + zip is written. |

## Usage

Run from this folder, as Administrator. If scripts are blocked by execution
policy, launch with `-ExecutionPolicy Bypass`:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loadtest.ps1
```

| Command | What it does |
|---|---|
| `.\run-loadtest.ps1` | Full run: SETUP → START → POLL → (Ctrl-C) → GATHER. |
| `.\run-loadtest.ps1 -SkipSetup` | Skip the extension/schema setup (the perfmon collector is still recreated). Use for the 2nd+ run on the same DB. |
| `.\run-loadtest.ps1 -Resume` | Resume a crashed run — see below. |

Typical flow:

1. `.\run-loadtest.ps1` — wait for `=== Collecting on '<db>'. Run your load test now.`
2. Run your load test (the clients hitting `$CapturePort`).
3. Press **`Ctrl-C` once** and let GATHER finish copying.
4. Find the bundle under `$GatherRoot\<timestamp>\` and the matching `.zip`.

### Resuming a crashed run

The collectors and snapshots survive the harness dying. To pick a run back up
without resetting anything:

```powershell
.\run-loadtest.ps1 -Resume
```

This reads the run state saved at START, skips the destructive reset/rotate, and
resumes polling with the **original** start time, so the export window is
preserved. `Ctrl-C` then gathers everything since that original start.

## Output bundle

Each run produces `$GatherRoot\<timestamp>\` (and a matching `.zip`):

| File / folder | Contents |
|---|---|
| `run-info.txt` | The exact run window (start/end/duration), DB, host, CPU count, Postgres version — so logs with pre-test overlap can be sliced precisely. |
| `pg_stat_statements.csv` | End-of-run cumulative query stats, ordered by total exec time. |
| `statements_snap.csv` | Per-tick `pg_stat_statements` snapshots (diff these for per-interval hot queries). |
| `activity_snap.csv` | Per-tick `pg_stat_activity`: concurrency, waits, blocking. |
| `database_snap.csv` | Per-tick `pg_stat_database` cluster counters. |
| `pg_settings.csv` | The full `pg_settings` at run time, for the record. |
| `perfmon/` | The Windows performance-counter CSV(s) for this run. |
| `oms-log/`, `pg_log/`, `caddy/` | The server, Postgres, and Caddy logs, sliced to the test window. |
| `gor/` | The GoReplay capture (`requests*.gor`) plus `gor.log` / `gor.err` (capture stats / packet-drop counts). |
| `analysis.sql` | Copied in for convenience. |

## Analysing a run

Run the queries in [`analysis.sql`](./analysis.sql) against the same DB after a
test (each query stands alone). They cover:

1. **Per-interval hot queries** — exec time / call counts accrued between
   consecutive snapshots (the "when did it get slow" view).
2. **Wait-event profile** — where backends spent time waiting inside Postgres.
3. **Blocking** — snapshots where a backend was blocked, and by whom.
4. **Concurrency over time** — active backend count per snapshot; correlate the
   peaks with any "pool exhausted" timestamps in the server log.
5. **Database totals** — deadlocks, rollbacks, temp-file spilling and cache hit
   ratio across the run.

> The app's own DB-pool wait (r2d2's `waited Nms for connection`) is **client
> side** — those waits happen before a Postgres backend exists, so they will
> *not* show up in `activity_snap`. That signal lives in the server log; the
> snapshots capture the in-Postgres wait picture (LWLock / IO / Lock / etc.).

## Perfmon counters

[`counters.txt`](./counters.txt) is a plain `logman` counter list (one counter
path per line). The defaults are system-wide and valid on any English-locale
Windows box: per-core and total CPU, processor queue, context switches, memory,
physical disk latency/throughput, and network bytes.

To track specific processes, add lines for them — first find the exact instance
name (the executable base name) with `Get-Process`, then add e.g.:

```
\Process(postgres*)\% Processor Time
\Process(postgres*)\Working Set
\Process(<oms-server-exe-name>)\% Processor Time
\Process(<oms-server-exe-name>)\Working Set
```

The target process must be running when the collector is created (it is, by the
START phase) or `logman` rejects the path. Per-core CPU appears as separate
`\Processor(0..N)` columns; the per-process `% Processor Time` is summed across
cores (so it can exceed 100%).

## Replaying captured traffic

The `.gor` capture in `gor/` is full requests (headers + body, no response
bodies). Replay it against a restored snapshot/VM with GoReplay:

```powershell
gor --input-file "requests_0.gor" --output-http "http://restored-host:7000"
```

Add `--input-file-replay-speed 2` to replay faster, etc. See the
[GoReplay docs](https://github.com/buger/goreplay/wiki).

## Cleanup

The snapshot tables accumulate across runs (that's what makes `-Resume` safe).
When you're done load-testing, clear them in pgAdmin / psql:

```sql
TRUNCATE perf.statements_snap, perf.activity_snap, perf.database_snap;
-- or remove the schema entirely:
DROP SCHEMA perf CASCADE;
```

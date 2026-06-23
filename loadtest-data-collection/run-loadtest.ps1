# One-shot load-test harness for open-mSupply on Windows.
#
#   .\run-loadtest.ps1            # set up, start collectors, poll until Ctrl-C, gather
#   .\run-loadtest.ps1 -SkipSetup # skip the PG extension/schema setup (the
#                                 # perfmon collector is recreated either way)
#   .\run-loadtest.ps1 -Resume    # resume a crashed run (see below)
#
# Nothing is lost if this script dies: the collectors (perfmon, gor, PG logging)
# run independently, and snapshots are INSERTed into the DB on each tick. The
# snapshot tables are NEVER truncated -- they accumulate across runs, and each
# bundle is scoped to its own time window. So to recover a crashed run, just:
#
#   .\run-loadtest.ps1 -Resume
#
# which reads the run state saved at START, skips the destructive reset/rotate,
# and resumes polling with the ORIGINAL start time (so the window is preserved).
# Ctrl-C then gathers everything since that original start.
#
# Cleanup (optional, when done load-testing): in pgAdmin run
#   TRUNCATE perf.statements_snap, perf.activity_snap, perf.database_snap;
#   -- or DROP SCHEMA perf CASCADE;  to remove it entirely.
#
# Edit paths/DB/interval in config.ps1. Auth via PGPASSWORD or pgpass.conf.
#
# Phases (fresh run):
#   SETUP  - CREATE EXTENSION pg_stat_statements, create perf snapshot schema,
#            (re)create the perfmon (logman) collector
#   START  - reload conf, rotate the PG log, reset pg_stat_statements, start the
#            perfmon collector, start GoReplay capture, save run state
#   POLL   - Invoke-PollLoop: perf.take_snapshot() every $Interval s until Ctrl-C
#   GATHER - Invoke-Gather (in finally): stop collectors + capture, export this
#            run's stats (windowed by start time) + pg_settings + run-info, copy
#            OMS/Postgres/perfmon/Caddy logs + the .gor capture, and zip the lot

[CmdletBinding()]
param([switch]$SkipSetup, [switch]$Resume)

. "$PSScriptRoot\config.ps1"

if (-not $Db) { throw "Set `$Db in config.ps1 to the current app DB (find it with: psql -l)." }

Connect-Pg   # verifies the connection, prompting for the password and retrying on failure

# ---- RESUME: pick up a crashed run, no destructive steps ----
if ($Resume) {
  $s = Read-RunState
  Write-Host "Resuming run $($s.Stamp) (started $($s.TestStart.ToString('u'))). Collectors assumed still running." -ForegroundColor Green
  Write-Host "=== Press Ctrl-C ONCE to stop and gather. ===" -ForegroundColor Green
  try     { Invoke-PollLoop }
  finally { Invoke-Gather }
  return
}

# ---- FRESH RUN ----
$stamp     = Get-Date -Format "yyyy-MM-dd_HHmmss"
$testStart = Get-Date                            # window start for logs + snapshot export
$out       = Join-Path $GatherRoot $stamp
$gor       = $null                               # GoReplay capture process (set at START)
$gorOut    = $null                               # its output .gor path
$perfRunDir = Join-Path $PerfDir $stamp          # per-run perfmon folder
$perfOut   = Join-Path $perfRunDir "test"        # logman appends _000001.csv etc.
$perfGlob  = Join-Path $perfRunDir "*.csv"

# ---- SETUP ----
New-Item -ItemType Directory -Force $perfRunDir | Out-Null
if (-not $SkipSetup) {
  Write-Host "Setting up (extension, snapshot schema)..."
  Invoke-Sql "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
  Invoke-SqlFile "$PSScriptRoot\setup_perf_snapshots.sql"
}
# (Re)create the perfmon collector every run so it writes into THIS run's folder
# (the output path is fixed at create time). Recreate is instant.
logman delete $CounterName 2>$null | Out-Null              # ignore "not found"
logman create counter $CounterName -f csv -si $Interval -o $perfOut -cf $CounterCfg | Out-Null

# ---- START: fresh PG log + clean cumulative stats. NB: no TRUNCATE of the snap
#      tables -- they accumulate and are windowed at export, so a -Resume never
#      loses data. pg_stat_statements IS reset here (fresh run only) so the
#      cumulative export reflects just this run; -Resume skips this block. ----
Invoke-Sql @'
SELECT pg_reload_conf();
SELECT pg_rotate_logfile();
SELECT pg_stat_statements_reset();
'@
logman start $CounterName | Out-Null

# ---- start passive traffic capture for replay (no latency to the app) ----
if (Test-Path $GorBin) {
  # Per-run subfolder. GoReplay rewrites the output name (treats a trailing
  # _<number> as its chunk index, e.g. requests.gor -> requests_0.gor), so we
  # give it a fixed name in a per-run dir and just copy the whole dir at gather
  # -- robust to gor's naming, and avoids same-day runs colliding.
  $gorRunDir = Join-Path $GorDir $stamp
  New-Item -ItemType Directory -Force $gorRunDir | Out-Null
  $gorOut = Join-Path $gorRunDir "requests.gor"
  # Requests only -- response tracking (--input-raw-track-response) would also
  # capture full response bodies (big stockLines/report payloads), bloating the
  # capture for data we don't need. Latency/status come from Caddy or the app log.
  # -NoNewWindow + redirected output forces CreateProcess (not ShellExecute),
  # avoiding the Mark-of-the-Web "Security Warning" that makes Start-Process fail
  # with "operation was canceled by the user". Stderr holds gor's capture stats /
  # packet-drop counts -- the capture-completeness signal.
  $gor = Start-Process -FilePath $GorBin `
           -ArgumentList "--input-raw", ":$CapturePort", "--output-file", $gorOut `
           -NoNewWindow -PassThru `
           -RedirectStandardOutput (Join-Path $gorRunDir "gor.log") `
           -RedirectStandardError  (Join-Path $gorRunDir "gor.err")
  Write-Host "Capturing :$CapturePort traffic -> $gorRunDir (pid $($gor.Id))"
} else {
  Write-Warning "gor.exe not found at $GorBin -- skipping traffic capture."
}

# Persist run state BEFORE polling, so -Resume can recover a crash with the
# original window and the collector handles to stop.
Save-RunState @{
  Stamp     = $stamp
  TestStart = $testStart
  Out       = $out
  PerfGlob  = $perfGlob
  GorOut    = $gorOut
  GorPid    = if ($gor) { $gor.Id } else { $null }
}

Write-Host "=== Collecting on '$Db'. Run your load test now." -ForegroundColor Green
Write-Host "=== Press Ctrl-C ONCE to stop and gather (let it finish copying)." -ForegroundColor Green

try     { Invoke-PollLoop }
finally { Invoke-Gather }

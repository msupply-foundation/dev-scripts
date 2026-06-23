# Shared config for the load-test harness. Edit paths here only --
# run-loadtest.ps1 dot-sources this file.
#
# Auth: set PGPASSWORD in the env, or add a line to
#   %APPDATA%\postgresql\pgpass.conf  ->  localhost:5432:*:postgres:<pw>

$PsqlBin     = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
$PgUser      = "postgres"
$Db          = "open-msupply-database"   # set to the current app DB (psql -l)

$Interval    = 2         # seconds, used for BOTH perfmon (-si) and PG snapshots

# Perfmon (logman) collector. run-loadtest.ps1 writes each run's CSVs into a
# per-run subfolder $PerfDir\<stamp>\ (so they don't pile up loose in the root).
# $CounterCfg defaults to the counters.txt shipped beside this script -- edit
# that file to choose which Windows counters to sample (see the README).
$CounterName = "omsupply_loadtest"
$CounterCfg  = Join-Path $PSScriptRoot "counters.txt"
$PerfDir     = "C:\PerfLogs\loadtest\perfmon"

# Source log locations gathered at end-of-test
$OmsLogDir   = "C:\Program Files\Open mSupply Server\log"
$PgLogDir    = "C:\Program Files\PostgreSQL\18\data\pg_log"
$CaddyLog    = "C:\PerfLogs\loadtest\caddy\access.log"   # must match the Caddyfile `log` output

# GoReplay traffic capture for replay. gor.exe sits beside this script. Capture
# is passive (raw pcap via Npcap) on the client-facing port, so it adds no
# latency to the app. The .gor file holds full requests (headers + body) for
# replay against a restored VM snapshot.
$GorBin      = Join-Path $PSScriptRoot "gor.exe"
$CapturePort = 7000                       # the Caddy client-facing port the clients hit
$GorDir      = "C:\PerfLogs\loadtest\gor" # staging for .gor files (per-run subfolder)

# Where each run's gathered bundle is written
$GatherRoot  = "C:\PerfLogs\loadtest\runs"

$ScriptDir   = $PSScriptRoot
$StateFile   = Join-Path $PSScriptRoot ".loadtest-state.xml"

# --- helpers ---------------------------------------------------------------

# Verify psql can connect to $Db as $PgUser, prompting for the password and
# retrying on failure. Works with a pre-set PGPASSWORD or pgpass.conf (no prompt
# if those already authenticate). The entered password is set as PGPASSWORD for
# THIS session only -- not persisted to disk or other processes.
# Throws after $MaxTries failures so the caller can abort before collecting.
function Connect-Pg([int]$MaxTries = 3) {
  for ($i = 1; $i -le $MaxTries; $i++) {
    & $PsqlBin -U $PgUser -d $Db -tAc "SELECT 1" *> $null
    if ($LASTEXITCODE -eq 0) { return }

    Write-Warning "Cannot connect to '$Db' as '$PgUser' (attempt $i/$MaxTries)."
    $sec  = Read-Host "Postgres password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
  throw "Could not authenticate to Postgres after $MaxTries attempts. Check the password in the open-mSupply server config (default is 'password')."
}

# Run a SQL string against the app DB, stopping on error.
function Invoke-Sql([string]$Sql) {
  & $PsqlBin -U $PgUser -d $Db -v ON_ERROR_STOP=1 -q -c $Sql
}

# Run a SQL file against the app DB.
function Invoke-SqlFile([string]$Path) {
  & $PsqlBin -U $PgUser -d $Db -v ON_ERROR_STOP=1 -f $Path
}

# Export a query to CSV.
function Export-Csv-Query([string]$Sql, [string]$OutFile) {
  & $PsqlBin -U $PgUser -d $Db -v ON_ERROR_STOP=1 --csv -c $Sql -o $OutFile
}

# Copy only files in $SrcGlob that were written during the test (mtime >= $Since).
# Keeps pre-test history (esp. huge rotated pg_log files) out of the bundle.
function Copy-Since([string]$SrcGlob, [string]$Dest, [datetime]$Since) {
  Get-ChildItem -Path $SrcGlob -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $Since } |
    Copy-Item -Destination $Dest -ErrorAction SilentlyContinue
}

# --- run state (lets gather.ps1 / poll.ps1 work standalone after a crash) ---

# Persist what gather needs to know about the in-progress run. Written by the
# START phase, before polling, so a crash mid-test leaves a recoverable record.
function Save-RunState([hashtable]$State) {
  $State | Export-Clixml -Path $StateFile
}

# Read it back (DateTime fields round-trip). Throws if no run was started.
function Read-RunState {
  if (-not (Test-Path $StateFile)) {
    throw "No run state at $StateFile -- start a run with run-loadtest.ps1 first."
  }
  Import-Clixml $StateFile
}

# --- the two reusable phases (shared by run-loadtest / poll / gather) -------

# POLL: snapshot the DB every $Interval seconds until Ctrl-C. Resets nothing, so
# it's safe to (re)run standalone via poll.ps1 to resume a crashed run.
function Invoke-PollLoop {
  Write-Host "=== Polling perf.take_snapshot() every $Interval s on '$Db'. Ctrl-C to stop. ===" -ForegroundColor Green
  $n = 0
  while ($true) {
    Invoke-Sql "SELECT perf.take_snapshot();" | Out-Null   # psql errors just warn + continue
    $n++
    if ($n % 30 -eq 0) { Write-Host ("  {0} snapshots taken ({1:HH:mm:ss})" -f $n, (Get-Date)) }
    Start-Sleep -Seconds $Interval
  }
}

# GATHER: stop collectors and bundle everything into the run's folder + zip.
# Driven entirely by the saved run state, so it works whether called from
# run-loadtest's finally or standalone via gather.ps1 after a crash.
function Invoke-Gather {
  $s   = Read-RunState
  $out = $s.Out
  Write-Host "`n=== Stopping collectors, gathering to $out ===" -ForegroundColor Yellow

  logman stop $CounterName 2>$null | Out-Null
  # Stop traffic capture (hard kill -- may lose up to gor's flush interval of
  # trailing requests) and wait for it to release the .gor file.
  if ($s.GorPid) {
    Stop-Process -Id $s.GorPid -ErrorAction SilentlyContinue
    Wait-Process  -Id $s.GorPid -Timeout 5 -ErrorAction SilentlyContinue
  }

  $omsDest   = Join-Path $out "oms-log"
  $pgDest    = Join-Path $out "pg_log"
  $perfDest  = Join-Path $out "perfmon"
  $caddyDest = Join-Path $out "caddy"
  $gorDest   = Join-Path $out "gor"
  New-Item -ItemType Directory -Force -Path $out, $omsDest, $pgDest, $perfDest, $caddyDest, $gorDest | Out-Null

  # Postgres stats -> CSV. The snap tables accumulate across runs and are never
  # truncated, so scope each export to this run's window (snap_ts >= test_start)
  # -- the same mtime filter the logs use. Clean the tables in pgAdmin when done.
  $since = $s.TestStart.ToString('o')
  Export-Csv-Query "SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC;" (Join-Path $out "pg_stat_statements.csv")
  Export-Csv-Query "SELECT * FROM perf.statements_snap WHERE snap_ts >= '$since' ORDER BY snap_ts;" (Join-Path $out "statements_snap.csv")
  Export-Csv-Query "SELECT * FROM perf.activity_snap   WHERE snap_ts >= '$since' ORDER BY snap_ts;" (Join-Path $out "activity_snap.csv")
  Export-Csv-Query "SELECT * FROM perf.database_snap   WHERE snap_ts >= '$since' ORDER BY snap_ts;" (Join-Path $out "database_snap.csv")
  Export-Csv-Query "SELECT name, setting, unit, source FROM pg_settings ORDER BY name;" (Join-Path $out "pg_settings.csv")

  # Run metadata: exact window + environment, so logs with pre-test overlap can
  # be sliced precisely and the bundle is self-describing.
  $testEnd = Get-Date
  $ver = (& $PsqlBin -U $PgUser -d $Db -tAc "SELECT version();") -join " "
  @(
    "run         : $($s.Stamp)"
    "db          : $Db"
    "interval_s  : $Interval"
    "host        : $env:COMPUTERNAME"
    "cpus        : $env:NUMBER_OF_PROCESSORS logical   (per-core % in perfmon; Process %CPU is summed across cores)"
    "test_start  : $($s.TestStart.ToString('o'))"
    "test_end    : $($testEnd.ToString('o'))"
    "duration    : $([int]($testEnd - $s.TestStart).TotalSeconds)s"
    "postgres    : $ver"
  ) | Set-Content -Path (Join-Path $out "run-info.txt")

  # Logs -> subfolders. Only files written during the test (mtime >= test_start),
  # so pre-test history (esp. huge rotated pg_log files) stays out of the bundle.
  Copy-Since "$OmsLogDir\*" $omsDest  $s.TestStart
  Copy-Since "$PgLogDir\*"  $pgDest   $s.TestStart
  Copy-Item  $s.PerfGlob    $perfDest -ErrorAction SilentlyContinue   # already run-scoped
  Copy-Since (Join-Path (Split-Path $CaddyLog) "*") $caddyDest $s.TestStart
  if ($s.GorOut) {
    # $s.GorOut lives in a per-run dir; copy the whole dir (gor may have renamed
    # requests.gor to requests_0.gor etc., plus the gor.log/gor.err).
    Copy-Item (Join-Path (Split-Path $s.GorOut) "*") $gorDest -ErrorAction SilentlyContinue
  }
  Copy-Item "$PSScriptRoot\analysis.sql" $out -ErrorAction SilentlyContinue   # for convenience

  $zip = "$out.zip"
  if (Test-Path $zip) { Remove-Item $zip }
  Compress-Archive -Path "$out\*" -DestinationPath $zip
  Write-Host "=== Done. Folder: $out" -ForegroundColor Green
  Write-Host "===       Zip:    $zip" -ForegroundColor Green
}

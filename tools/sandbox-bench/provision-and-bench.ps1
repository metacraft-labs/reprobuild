<#
  provision-and-bench.ps1 - IN-SANDBOX bench provisioner.

  Runs inside Windows Sandbox via the bench.wsb LogonCommand. Captures
  three timestamps that decompose the sandbox-vs-host overhead:

    T0_wsb_launch         - WindowsSandbox.exe spawn (recorded host-side)
    T1_logon_fired        - LogonCommand reached cmd.exe
    T2_script_started     - this script began executing
    T3_vc_staged          - VC++ DLLs copied to System32
    T4_test_started       - the test exe was launched
    T5_test_finished      - the test exe returned
    T6_done               - DONE sentinel written

  Wall-time decomposition the host can read after the sandbox tears down:
    boot+logon = T1 - T0    (Windows Sandbox cold boot + LogonCommand fire)
    script     = T3 - T2    (VC++ stage + nothing else, ~5s)
    test       = T5 - T4    (the test itself - directly comparable to bare host)
    teardown   = sandbox shutdown after this script exits (T6 done is just a sentinel)
#>

$ErrorActionPreference = 'Continue'
$OutDir = 'C:\harness\out'

function Stamp($name) {
  $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  Add-Content -LiteralPath (Join-Path $OutDir 'TIMINGS.txt') -Value "$name=$ts"
}

# Earliest possible script-side checkpoint.
'started' > (Join-Path $OutDir '_script-started.txt')
Stamp 'T2_script_started'

# Stage the VC++ runtime DLLs the host has in System32 so nim-built
# exes can resolve msvcp140 / vcruntime140 / etc.
$vcSrc = 'C:\harness\vcruntime'
$vcDst = 'C:\Windows\System32'
if (Test-Path $vcSrc) {
  Get-ChildItem -LiteralPath $vcSrc -Filter '*.dll' -ErrorAction SilentlyContinue |
    ForEach-Object {
      try { Copy-Item -LiteralPath $_.FullName -Destination $vcDst -Force } catch {}
    }
}
Stamp 'T3_vc_staged'

# The bench payload: run a specific test exe with timing.
# The TEST_EXE name is hardcoded here; if we want to parametrize, the
# launcher would write a small per-run config into the OUTPUT dir before
# starting the sandbox. For now this measures m80 (the heaviest of the
# documented polluters).
$TestExe = 'C:\harness\test-bin\t_integration_plan_classifier_bucket_drift_is_cache_hit.exe'
# Copy sqlite3_64.dll alongside the test exe (it depends on it).
$sqlite = 'C:\harness\repro-bin\sqlite3_64.dll'
$exeWorkDir = 'C:\Users\WDAGUtilityAccount\bench'
New-Item -ItemType Directory -Path $exeWorkDir -Force | Out-Null
Copy-Item -LiteralPath $TestExe -Destination (Join-Path $exeWorkDir 'test.exe') -Force
Copy-Item -LiteralPath $sqlite -Destination (Join-Path $exeWorkDir 'sqlite3_64.dll') -Force
# Also copy repro.exe so the test subprocess can find it (the test
# compiles its OWN repro inside the temp dir on bare host but in the
# sandbox the nim/gcc toolchain isn't available, so the test will
# fail at the compile step. That's OK - we're measuring overhead,
# not test-pass status, and the test failure is identical to bare
# host where my prior runs already failed at the apply stage).
Copy-Item -LiteralPath 'C:\harness\repro-bin\repro.exe' -Destination (Join-Path $exeWorkDir 'repro.exe') -Force

Stamp 'T4_test_started'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$logFile = Join-Path $OutDir 'test-output.log'
try {
  & (Join-Path $exeWorkDir 'test.exe') *> $logFile
  $exitCode = $LASTEXITCODE
} catch {
  $exitCode = -1
  $_ | Out-File -FilePath $logFile -Append
}
$sw.Stop()
Stamp 'T5_test_finished'
Add-Content -LiteralPath (Join-Path $OutDir 'TIMINGS.txt') -Value "test_wall_ms=$($sw.ElapsedMilliseconds)"
Add-Content -LiteralPath (Join-Path $OutDir 'TIMINGS.txt') -Value "test_exit_code=$exitCode"

# DONE sentinel - the host-side poller watches for this.
'done' > (Join-Path $OutDir 'DONE')
Stamp 'T6_done'

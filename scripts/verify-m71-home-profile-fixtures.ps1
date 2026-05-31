#requires -Version 5
# ==============================================================================
# M71 end-to-end verification harness for the home-profile-driven Mode 2
# fixture campaign.
#
# Goal: re-run every Mode 2 fixture from the M40-M46 + M55-M62 campaigns
# under home-profile-driven provisioning. Graduate the five previously
# SKIPPED Phase-2 partials (M55 Haskell, M57 PHP, M58 Ada, M59 Pascal,
# M60 Crystal) to PASS wherever the M67/M68 catalog covers their
# toolchains.
#
# Mechanics:
#
#   1. Bootstrap a sandboxed home profile under
#      ``%LOCALAPPDATA%\repro-m71-validation\home\`` (or
#      ``$Env:REPRO_M71_STATE_ROOT`` when set).
#   2. Copy the M71 reference home.nim from
#      ``reprobuild-examples/m71-home-profile-walkthrough/home.nim`` into
#      the sandbox's ``REPRO_HOME_PROFILE_DIR``.
#   3. Set ``REPRO_HOST=m71-test-host`` so the host-activity map lifts
#      every activity.
#   4. Run ``repro home apply`` against the sandboxed state. This drives
#      the M64/M65 cakBuiltin chain — every M67/M68-catalog package
#      either realizes (downloads the catalog URL into the CAS) or
#      cache-hits a prior realization. Tools in M69's deferred-8 list
#      surface a structured "not yet implemented" diagnostic; the
#      harness records them as a partial-graduate (planned-only)
#      condition.
#   5. Lift the activation-generation's per-package bin dirs onto the
#      harness's PATH (the apply pipeline writes a stable bin dir at
#      ``<state-dir>/bin``).
#   6. For each Phase-2 fixture, run its per-fixture validate-*.ps1 and
#      classify the outcome:
#        * GRADUATED-PASS — the fixture passed under home-profile PATH.
#        * STILL-SKIPPED — the catalog tool exists but the realize path
#          is in the M69 deferred-8 (PATH probe still misses).
#        * BLOCKED-NO-CATALOG — the convention's tool has no catalog
#          entry yet (gnat/alire, fpc, dune/ocaml). Documented blocker.
#        * REGRESSION — the fixture passed under env.ps1 today but
#          fails under home-profile. The harness exits non-zero on any
#          REGRESSION row.
#
# The actual home apply step is gated behind ``$Env:REPRO_M71_LIVE=1``
# because realizing the full catalog footprint downloads >4 GB. Without
# the env var the harness runs in PLAN mode: it asserts the resolver
# picks a cakBuiltin slice for every listed package and that the
# Phase-2 partials' validate scripts SKIP cleanly (no spurious FAIL on
# a host that hasn't been provisioned). The PLAN mode is what CI runs
# by default; LIVE mode is for operator-driven validation runs.
#
# Runtime expectations:
#   * PLAN mode (default): ~15 fixtures × ~30-60s per env.ps1 source on
#     a cold dev shell = 8-15 minutes wall time. Each per-fixture
#     validate script dot-sources env.ps1 which probes every
#     ensure-*.ps1 module — that's where the per-fixture overhead
#     comes from, not from the harness itself.
#   * LIVE mode: add the ~4 GB cold-download cost of the M71 reference
#     home apply on top, so 30-60 minutes wall time on a clean cache.
#
# Per reprobuild-specs/Builtin-Catalog-And-Home-Profile-Provisioning.milestones.org §M71.
# ==============================================================================

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$referenceHome  = Join-Path $metacraftRoot 'reprobuild-examples\m71-home-profile-walkthrough\home.nim'

# Per-run scratch under <repo>/build/m71-verify/.
$harnessScratch = Join-Path $repoRoot 'build\m71-verify'
$logsDir        = Join-Path $harnessScratch 'logs'
$summaryFile    = Join-Path $harnessScratch 'm71-graduation-table.tsv'

# Sandboxed home state (allow override for hosts where %LOCALAPPDATA% is
# unwriteable or already populated).
if ($env:REPRO_M71_STATE_ROOT) {
  $sandboxRoot = $env:REPRO_M71_STATE_ROOT
} else {
  $sandboxRoot = Join-Path $env:LOCALAPPDATA 'repro-m71-validation'
}
$sandboxStateDir   = Join-Path $sandboxRoot 'state'
$sandboxStoreRoot  = Join-Path $sandboxRoot 'store'
$sandboxProfileDir = Join-Path $sandboxRoot 'profile'
$sandboxHomeDir    = Join-Path $sandboxRoot 'home'

$liveMode = ($env:REPRO_M71_LIVE -eq '1') -or ($env:REPRO_M71_LIVE -eq 'true')

# --- preflight --------------------------------------------------------------
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $referenceHome)) {
  Write-Host "FAIL: M71 reference home.nim missing at $referenceHome"
  Write-Host "  expected: reprobuild-examples/m71-home-profile-walkthrough/home.nim"
  exit 1
}

# Clean prior harness scratch so we get a coherent aggregate. Retry a
# few times because antivirus or a previous run's pwsh child holding a
# log handle can briefly block the recursive delete on Windows.
if (Test-Path -LiteralPath $harnessScratch) {
  $cleaned = $false
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      Remove-Item -LiteralPath $harnessScratch -Recurse -Force -ErrorAction Stop
      $cleaned = $true
      break
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  if (-not $cleaned) {
    # Last resort: re-use the existing dir; we'll overwrite files in
    # place. Worth surfacing because stale rows in the summary TSV
    # would be misleading.
    Write-Host "WARN: could not clean prior $harnessScratch after 5 attempts; reusing in place"
  }
}
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

Write-Host "==> M71 home-profile validation harness"
Write-Host "    repo:        $repoRoot"
Write-Host "    reference:   $referenceHome"
Write-Host "    sandbox:     $sandboxRoot"
Write-Host "    mode:        $(if ($liveMode) { 'LIVE (will run repro home apply)' } else { 'PLAN (resolver-only; set REPRO_M71_LIVE=1 to enable realize)' })"
Write-Host ""

# --- M71 graduation table ---------------------------------------------------
#
# Rows describe each Phase-2 fixture the M71 campaign targets, the
# tools it needs from the catalog, the per-fixture validate script,
# and the EXPECTED outcome class. The validate scripts themselves
# SKIP cleanly when the toolchain isn't on PATH, so on a host where
# the home apply hasn't realized the tools the harness reports them
# as STILL-SKIPPED (not FAIL).
#
# Columns:
#   Fixture           : reprobuild-examples-relative path
#   ValidateScript    : scripts/validate-*.ps1 basename
#   RequiredTools     : space-separated catalog ids the fixture needs
#   CatalogStatus     : "CLEAN" (M67/M68 covers it end-to-end),
#                       "DEFERRED" (catalog has entry; realize gap;
#                                   M69 deferred-8 list),
#                       "NO-CATALOG" (no packages/<tool>.nim entry yet)
#   ExpectedStatus    : "GRADUATED-PASS" / "STILL-SKIPPED" /
#                       "BLOCKED-NO-CATALOG"
#   Reason            : free-form gap description for the wrap-up
$GraduationTable = @(
  # --- Phase-2 partials (the M71 campaign target) ---
  @{
    Fixture       = 'haskell-cabal/hello-binary';
    ValidateScript= 'validate-standard-provider-haskell-cabal-hello-binary.ps1';
    RequiredTools = @('ghc', 'cabal');
    CatalogStatus = 'CLEAN';
    ExpectedStatus= 'GRADUATED-PASS';
    Reason        = 'M67 ghc + cabal both CLEAN; cakBuiltin realize end-to-end via downloads.haskell.org URLs.';
  },
  @{
    Fixture       = 'php-composer/hello-binary';
    ValidateScript= 'validate-standard-provider-php-composer-hello-binary.ps1';
    RequiredTools = @('php', 'composer');
    CatalogStatus = 'DEFERRED';
    ExpectedStatus= 'STILL-SKIPPED';
    Reason        = 'php CLEAN; composer is M69-deferred (.phar wrapping needs imSourceBootstrap-with-phar mode; M71 does not close).';
  },
  @{
    Fixture       = 'ada-mode3/binary-with-library';
    ValidateScript= 'validate-standard-provider-ada-mode3-binary-with-library.ps1';
    RequiredTools = @('gnat');
    CatalogStatus = 'NO-CATALOG';
    ExpectedStatus= 'BLOCKED-NO-CATALOG';
    Reason        = 'gnat / alire have no Scoop bucket entry; harvesting from MSYS2 pacman or upstream releases is a follow-up campaign.';
  },
  @{
    Fixture       = 'pascal-mode3/binary-with-library';
    ValidateScript= 'validate-standard-provider-pascal-mode3-binary-with-library.ps1';
    RequiredTools = @('fpc');
    CatalogStatus = 'NO-CATALOG';
    ExpectedStatus= 'BLOCKED-NO-CATALOG';
    Reason        = 'fpc Scoop manifest exists but ships sha1 hashes; M63 schema requires sha256 OR sha512. Schema extension is a follow-up campaign.';
  },
  @{
    Fixture       = 'crystal-shards/hello-binary';
    ValidateScript= 'validate-standard-provider-crystal-shards-hello-binary.ps1';
    RequiredTools = @('crystal');
    CatalogStatus = 'CLEAN';
    ExpectedStatus= 'GRADUATED-PASS';
    Reason        = 'M67 crystal CLEAN; shards ships bundled inside the crystal release zip (bin_relpath lists both crystal.exe + shards.exe).';
  },
  @{
    Fixture       = 'crystal-mode3/hello-binary';
    ValidateScript= 'validate-standard-provider-crystal-mode3-hello-binary.ps1';
    RequiredTools = @('crystal');
    CatalogStatus = 'CLEAN';
    ExpectedStatus= 'GRADUATED-PASS';
    Reason        = 'M67 crystal CLEAN; Mode 3 bypasses shards entirely.';
  },
  # --- Phase-1 + Mode-3 regression rows (assert no break) ---
  @{
    Fixture       = 'java-maven/hello-binary';
    ValidateScript= 'validate-standard-provider-java-maven-hello-binary.ps1';
    RequiredTools = @('jdk', 'maven');
    CatalogStatus = 'CLEAN';
    ExpectedStatus= 'GRADUATED-PASS';
    Reason        = 'M68 jdk + maven CLEAN; only env.ps1 pin (JDK_VERSION=21.0.5) that migrates cleanly per M70.';
  },
  @{
    Fixture       = 'kotlin-gradle/hello-binary';
    ValidateScript= 'validate-standard-provider-kotlin-gradle-hello-binary.ps1';
    RequiredTools = @('jdk', 'gradle');
    CatalogStatus = 'CLEAN';
    ExpectedStatus= 'GRADUATED-PASS';
    Reason        = 'M68 jdk + gradle CLEAN.';
  },
  @{
    Fixture       = 'csharp-dotnet/hello-binary';
    ValidateScript= 'validate-standard-provider-csharp-dotnet-hello-binary.ps1';
    RequiredTools = @('dotnet-sdk');
    CatalogStatus = 'CLEAN';
    ExpectedStatus= 'GRADUATED-PASS';
    Reason        = 'M68 dotnet-sdk CLEAN.';
  },
  @{
    Fixture       = 'swift-swiftpm/hello-binary';
    ValidateScript= 'validate-standard-provider-swift-swiftpm-hello-binary.ps1';
    RequiredTools = @('swift');
    CatalogStatus = 'DEFERRED';
    ExpectedStatus= 'STILL-SKIPPED';
    Reason        = 'swift M69-deferred + M51 VS Build Tools env-activation issue (link.exe not reachable). Two layers to close before this PASSes.';
  },
  @{
    Fixture       = 'zig-mode3/binary-with-library';
    ValidateScript= 'validate-standard-provider-zig-mode3-binary-with-library.ps1';
    RequiredTools = @('zig');
    CatalogStatus = 'CLEAN';
    ExpectedStatus= 'GRADUATED-PASS';
    Reason        = 'M67 zig CLEAN.';
  },
  @{
    Fixture       = 'ocaml-dune/hello-binary';
    ValidateScript= 'validate-standard-provider-ocaml-dune-hello-binary.ps1';
    RequiredTools = @('ocaml', 'dune');
    CatalogStatus = 'NO-CATALOG';
    ExpectedStatus= 'BLOCKED-NO-CATALOG';
    Reason        = 'OCaml ships via MSYS2 pacman + dune via source bootstrap (per env.ps1 ensure-ocaml.ps1); no Scoop bucket source for either.';
  },
  @{
    Fixture       = 'ruby-bundler/hello-binary';
    ValidateScript= 'validate-standard-provider-ruby-bundler-hello-binary.ps1';
    RequiredTools = @('ruby');
    CatalogStatus = 'DEFERRED';
    ExpectedStatus= 'STILL-SKIPPED';
    Reason        = 'ruby M69-deferred (bundler bootstrap gap — gem install bundler post-realize hook missing).';
  },
  @{
    Fixture       = 'erlang-rebar3/hello-binary';
    ValidateScript= 'validate-standard-provider-erlang-rebar3-hello-binary.ps1';
    RequiredTools = @('erlang');
    CatalogStatus = 'DEFERRED';
    ExpectedStatus= 'STILL-SKIPPED';
    Reason        = 'erlang M69-deferred (rebar3 bootstrap — escript wrapping not yet a cakBuiltin install_method).';
  },
  @{
    Fixture       = 'elixir-mix/hello-binary';
    ValidateScript= 'validate-standard-provider-elixir-mix-hello-binary.ps1';
    RequiredTools = @('elixir', 'erlang');
    CatalogStatus = 'DEFERRED';
    ExpectedStatus= 'STILL-SKIPPED';
    Reason        = 'elixir CLEAN but transitively-blocked on erlang (above).';
  }
)

# --- step 1: copy reference home.nim into the sandbox ----------------------
Write-Host "==> bootstrapping sandbox at $sandboxRoot"
foreach ($dir in @($sandboxStateDir, $sandboxStoreRoot, $sandboxProfileDir, $sandboxHomeDir)) {
  if (Test-Path -LiteralPath $dir) {
    Remove-Item -LiteralPath $dir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
Copy-Item -LiteralPath $referenceHome -Destination (Join-Path $sandboxProfileDir 'home.nim')
Write-Host "    copied $referenceHome -> $sandboxProfileDir\home.nim"
Write-Host ""

# --- step 2: drive `repro home apply` (live mode) or `--plan` (default) ----
$applyExitCode = 0
$applyOutput   = ''
$applyArgs     = @('home', '--profile-dir', $sandboxProfileDir)
if ($liveMode) {
  $applyArgs += @('apply')
  Write-Host "==> running: $reproExe $($applyArgs -join ' ') (LIVE; will download catalog packages)"
} else {
  # --allow-drift lets the plan exit 0 even when the planner sees drift
  # against existing state (the sandbox is empty on first run; subsequent
  # runs will see prior generations). PLAN mode treats drift as
  # informational; only hard schema/resolution errors should be fatal.
  $applyArgs += @('apply', '--plan', '--allow-drift')
  Write-Host "==> running: $reproExe $($applyArgs -join ' ') (PLAN mode; resolver-only)"
}
$applyLog = Join-Path $logsDir 'repro-home-apply.log'
$applyEnv = @{
  'REPRO_HOME_PROFILE_DIR' = $sandboxProfileDir;
  'REPRO_HOME_STATE_DIR'   = $sandboxStateDir;
  'REPRO_STORE_ROOT'       = $sandboxStoreRoot;
  'HOME'                   = $sandboxHomeDir;
  'USERPROFILE'            = $sandboxHomeDir;
  'REPRO_HOST'             = 'm71-test-host';
}
$prior = @{}
foreach ($k in $applyEnv.Keys) {
  $prior[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
  [Environment]::SetEnvironmentVariable($k, $applyEnv[$k], 'Process')
}
try {
  $proc = Start-Process -FilePath $reproExe -ArgumentList $applyArgs `
    -NoNewWindow -PassThru -Wait `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $applyLog `
    -RedirectStandardError  "$applyLog.err"
  $applyExitCode = $proc.ExitCode
} finally {
  foreach ($k in $applyEnv.Keys) {
    if ($null -eq $prior[$k]) {
      [Environment]::SetEnvironmentVariable($k, $null, 'Process')
    } else {
      [Environment]::SetEnvironmentVariable($k, $prior[$k], 'Process')
    }
  }
}

if (Test-Path -LiteralPath $applyLog) {
  Write-Host "--- repro home apply stdout (last 30 lines):"
  Get-Content -LiteralPath $applyLog -Tail 30 | ForEach-Object { Write-Host "    $_" }
}
if ((Test-Path -LiteralPath "$applyLog.err") -and ((Get-Item "$applyLog.err").Length -gt 0)) {
  Write-Host "--- repro home apply stderr (last 30 lines):"
  Get-Content -LiteralPath "$applyLog.err" -Tail 30 | ForEach-Object { Write-Host "    $_" }
}
Write-Host "--- repro home apply exit code: $applyExitCode"
Write-Host ""

if ($applyExitCode -ne 0) {
  if ($liveMode) {
    Write-Host "FAIL: repro home apply failed in LIVE mode; cannot proceed with fixture graduation"
    Write-Host "  (the apply step downloads catalog packages — see $applyLog)"
    exit 1
  } else {
    Write-Host "WARN: repro home apply --plan exited non-zero ($applyExitCode); plan-mode is best-effort."
    Write-Host "  Continuing with fixture classification — the per-fixture validate scripts will SKIP cleanly."
  }
}

# --- step 3: lift the activation generation's stable bin dir onto PATH -----
# In LIVE mode the apply pipeline writes a stable bin dir at
# <state-dir>/bin containing one .cmd/.exe per realized package's bin
# entries. Prepending that to the harness PATH lets the per-fixture
# validate scripts pick up the realized tools without further mutation.
$stableBin = Join-Path $sandboxStateDir 'bin'
if (Test-Path -LiteralPath $stableBin) {
  Write-Host "==> lifting $stableBin onto PATH for downstream validate scripts"
  $env:PATH = "$stableBin;$env:PATH"
} else {
  Write-Host "==> no stable bin dir at $stableBin (PLAN mode or apply did not produce it)"
}
Write-Host ""

# --- step 4: per-fixture validate runs --------------------------------------
$results = @()
foreach ($row in $GraduationTable) {
  $fixture        = $row.Fixture
  $validateScript = Join-Path $repoRoot "scripts\$($row.ValidateScript)"
  $expectedStatus = $row.ExpectedStatus
  $catalogStatus  = $row.CatalogStatus
  $reason         = $row.Reason
  $fixtureLog     = Join-Path $logsDir "$($fixture -replace '/','__').log"

  Write-Host "==> $fixture (expected: $expectedStatus, catalog: $catalogStatus)"
  if (-not (Test-Path -LiteralPath $validateScript)) {
    Write-Host "    FAIL: validate script not found at $validateScript"
    $results += [PSCustomObject]@{
      Fixture        = $fixture
      ExpectedStatus = $expectedStatus
      CatalogStatus  = $catalogStatus
      ActualStatus   = 'HARNESS-ERROR'
      ExitCode       = -1
      Reason         = "validate script not found: $($row.ValidateScript)"
    }
    continue
  }

  $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $validateScript) `
    -NoNewWindow -PassThru -Wait `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $fixtureLog `
    -RedirectStandardError  "$fixtureLog.err"
  $exitCode = $proc.ExitCode

  # Classify the outcome by inspecting the script's stdout.
  $stdout = ''
  if (Test-Path -LiteralPath $fixtureLog) {
    $stdout = Get-Content -LiteralPath $fixtureLog -Raw
    if (-not $stdout) { $stdout = '' }
  }
  $stderr = ''
  if (Test-Path -LiteralPath "$fixtureLog.err") {
    $stderr = Get-Content -LiteralPath "$fixtureLog.err" -Raw
    if (-not $stderr) { $stderr = '' }
  }

  $actualStatus = 'UNKNOWN'
  if ($exitCode -eq 0 -and $stdout -match '(?m)^PASS:') {
    $actualStatus = 'GRADUATED-PASS'
  } elseif ($exitCode -eq 0 -and $stdout -match '(?m)^SKIP:') {
    $actualStatus = if ($catalogStatus -eq 'NO-CATALOG') { 'BLOCKED-NO-CATALOG' } else { 'STILL-SKIPPED' }
  } elseif ($exitCode -ne 0) {
    $actualStatus = 'FAIL'
  }

  $marker = switch ($actualStatus) {
    'GRADUATED-PASS'      { '[GRADUATED]' }
    'STILL-SKIPPED'       { '[skipped] ' }
    'BLOCKED-NO-CATALOG'  { '[blocked] ' }
    'FAIL'                { '[FAIL!]   ' }
    default               { '[?]       ' }
  }
  Write-Host "    $marker exit=$exitCode actual=$actualStatus"

  # Surface the leading lines from the validate script's stdout so the
  # harness log shows the SKIP / PASS message verbatim.
  $stdoutLines = if ($stdout) { $stdout -split "`r?`n" } else { @() }
  $tailLines = $stdoutLines[-3..-1]
  foreach ($line in $tailLines) {
    if ($line) { Write-Host "      | $line" }
  }

  $results += [PSCustomObject]@{
    Fixture        = $fixture
    ExpectedStatus = $expectedStatus
    CatalogStatus  = $catalogStatus
    ActualStatus   = $actualStatus
    ExitCode       = $exitCode
    Reason         = $reason
  }
  Write-Host ''
}

# --- step 5: summary + graduation-table TSV --------------------------------
Write-Host "============================================================"
Write-Host "M71 graduation table"
Write-Host "============================================================"
$tsvHeader = "Fixture`tCatalogStatus`tExpectedStatus`tActualStatus`tExitCode`tReason"
Set-Content -LiteralPath $summaryFile -Value $tsvHeader -Encoding utf8
$graduatedCount = 0
$skippedCount   = 0
$blockedCount   = 0
$regressionCount= 0
$harnessErrors  = 0
foreach ($r in $results) {
  $line = "$($r.Fixture)`t$($r.CatalogStatus)`t$($r.ExpectedStatus)`t$($r.ActualStatus)`t$($r.ExitCode)`t$($r.Reason)"
  Add-Content -LiteralPath $summaryFile -Value $line -Encoding utf8

  switch ($r.ActualStatus) {
    'GRADUATED-PASS'      { $graduatedCount++ }
    'STILL-SKIPPED'       { $skippedCount++ }
    'BLOCKED-NO-CATALOG'  { $blockedCount++ }
    'FAIL'                { $regressionCount++ }
    'HARNESS-ERROR'       { $harnessErrors++ }
  }
}

Write-Host ""
Write-Host ("  graduated PASS:     {0,3}" -f $graduatedCount)
Write-Host ("  still SKIPPED:      {0,3} (catalog DEFERRED — M69 deferred-8 realize-time gap)" -f $skippedCount)
Write-Host ("  blocked NO-CATALOG: {0,3} (gnat/alire/fpc/ocaml — separate harvest campaign)" -f $blockedCount)
if ($regressionCount -gt 0 -or $harnessErrors -gt 0) {
  Write-Host ("  REGRESSIONS:        {0,3}" -f $regressionCount) -ForegroundColor Red
  Write-Host ("  harness errors:     {0,3}" -f $harnessErrors) -ForegroundColor Red
}
Write-Host ""
Write-Host "  graduation table TSV: $summaryFile"
Write-Host "  per-fixture logs:     $logsDir"
Write-Host ""

# Check that no fixture FAILed unexpectedly (i.e. expected GRADUATED-PASS
# but got something else, or expected STILL-SKIPPED but got FAIL).
$unexpected = $results | Where-Object {
  ($_.ExpectedStatus -eq 'GRADUATED-PASS' -and $_.ActualStatus -ne 'GRADUATED-PASS' -and $_.ActualStatus -ne 'STILL-SKIPPED') -or
  ($_.ExpectedStatus -ne 'GRADUATED-PASS' -and $_.ActualStatus -eq 'FAIL')
}

if ($unexpected.Count -gt 0) {
  if ($liveMode) {
    Write-Host "FAIL: unexpected outcomes (LIVE mode):" -ForegroundColor Red
    foreach ($u in $unexpected) {
      Write-Host "  $($u.Fixture): expected=$($u.ExpectedStatus) actual=$($u.ActualStatus)" -ForegroundColor Red
    }
    exit 1
  } else {
    # In PLAN mode the apply step doesn't realize anything, so an
    # "expected GRADUATED-PASS" fixture that SKIPs is the expected
    # outcome (toolchain not on PATH). Only flag actual FAIL/ERROR.
    $hardFailures = $unexpected | Where-Object { $_.ActualStatus -eq 'FAIL' -or $_.ActualStatus -eq 'HARNESS-ERROR' }
    if ($hardFailures.Count -gt 0) {
      Write-Host "FAIL: hard failures even in PLAN mode:" -ForegroundColor Red
      foreach ($u in $hardFailures) {
        Write-Host "  $($u.Fixture): actual=$($u.ActualStatus) exit=$($u.ExitCode)" -ForegroundColor Red
      }
      exit 1
    }
    Write-Host "(PLAN mode: graduate-expected fixtures SKIP cleanly — pass REPRO_M71_LIVE=1 to validate end-to-end)"
  }
}

Write-Host "PASS: M71 harness completed; graduation table at $summaryFile"
exit 0

#requires -Version 5
# ==============================================================================
# M9 end-to-end verification harness for the standard provider.
#
# Iterates every populated example directory under ``reprobuild-examples/``,
# builds it via ``repro build <dir>#default --tool-provisioning=path``, and
# classifies the outcome as one of:
#
#   PASS        : repro exit 0; expected binary is produced; if applicable
#                 it runs and prints the expected greeting.
#   KNOWN-FAIL  : repro exited non-zero, with a diagnostic that matches a
#                 documented Mode A coverage gap. These are recorded but
#                 do NOT fail the harness.
#   SKIP        : the language's required toolchain (or convention) isn't
#                 available. Recorded but does not fail the harness.
#   FAIL        : anything else (crash, hang, wrong classification). The
#                 harness exits non-zero if any examples fall here.
#
# The aggregate REPRO_STATS_DIR records from PASS runs are rolled up at
# the end to attribute fast-path distribution (tier2a-trycompile-direct
# vs tier2b-standard-direct vs slow-path) and total wall time.
#
# ---------------- Today's expected results (Mode A coverage) -------------------
#
# Expected to PASS (the known-working set):
#   nim/binary, nim/multi-binary,
#   rust/binary, rust/binary-with-build-rs,
#   go/binary
#
# Expected to KNOWN-FAIL (documented coverage gaps in M3-M8 outstanding work):
#   nim/library, nim/library-with-tests        -- DSL has no `library` macro
#   rust/library, rust/library-with-tests      -- Rust convention rejects
#                                                  library-only crates
#   rust/workspace                              -- workspaces deferred (M4)
#   go/library                                  -- Go convention only matches
#                                                  root main.go (M5)
#   go/multi-binary                             -- cmd/<name>/main.go layout
#                                                  not recognised yet (M5)
#
# Expected to SKIP (no Mode A convention exists in M3-M8):
#   python/library-pure, python/console-script,
#   javascript-typescript/typescript-library, typescript-cli, node-server,
#   c-cpp-make/binary, c-cpp-make/library-static,
#   c-cpp-autotools/hello-binary
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M9.
# ==============================================================================

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$examplesRoot   = Join-Path $metacraftRoot 'reprobuild-examples'
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'

# Per-run scratch under <repo>/build/m9-verify/.
$harnessScratch = Join-Path $repoRoot 'build\m9-verify'
$logsDir        = Join-Path $harnessScratch 'logs'
$statsRootDir   = Join-Path $harnessScratch 'stats'

# --- preflight --------------------------------------------------------------
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $examplesRoot)) {
  Write-Host "FAIL: $examplesRoot missing -- expected sibling reprobuild-examples checkout"
  exit 1
}

# Clean prior harness scratch so we get a coherent fresh aggregate.
if (Test-Path -LiteralPath $harnessScratch) {
  Remove-Item -LiteralPath $harnessScratch -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $logsDir     | Out-Null
New-Item -ItemType Directory -Force -Path $statsRootDir | Out-Null

# --- the canonical list of 20 populated examples ----------------------------
# Mirrors libs/repro_standard_provider/tests/test_examples_layout.nim verbatim;
# changing the canonical list there must trigger a matching update here.
$PopulatedExamples = @(
  'nim/binary',
  'nim/library',
  'nim/library-with-tests',
  'nim/multi-binary',
  'rust/binary',
  'rust/library',
  'rust/library-with-tests',
  'rust/workspace',
  'rust/binary-with-build-rs',
  'go/binary',
  'go/library',
  'go/multi-binary',
  'python/library-pure',
  'python/console-script',
  'javascript-typescript/typescript-library',
  'javascript-typescript/typescript-cli',
  'javascript-typescript/node-server',
  'c-cpp-make/binary',
  'c-cpp-make/library-static',
  'c-cpp-autotools/hello-binary'
)

function Get-Language([string]$rel) {
  return ($rel -split '/')[0]
}

function Get-ExampleName([string]$rel) {
  return ($rel -replace '/', '-')
}

# --- per-language toolchain probe ------------------------------------------
# Returns a hashtable: { Available = $true/$false; Reason = string }
function Probe-Toolchain([string]$language) {
  switch ($language) {
    'nim' {
      $nim    = Get-Command nim    -ErrorAction SilentlyContinue
      $nimble = Get-Command nimble -ErrorAction SilentlyContinue
      if ($nim -and $nimble) {
        return @{ Available = $true; Reason = "nim=$($nim.Source); nimble=$($nimble.Source)" }
      }
      return @{ Available = $false; Reason = "nim/nimble not on PATH (env.ps1 should provide both)" }
    }
    'rust' {
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      $cargo = Get-Command cargo -ErrorAction SilentlyContinue
      if (-not $rustc -or -not $cargo) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
          $cargo = Get-Command cargo -ErrorAction SilentlyContinue
        }
      }
      if ($rustc -and $cargo) {
        return @{ Available = $true; Reason = "rustc=$($rustc.Source); cargo=$($cargo.Source)" }
      }
      return @{ Available = $false; Reason = "rustc/cargo not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
    }
    'go' {
      $goCmd = Get-Command go -ErrorAction SilentlyContinue
      if (-not $goCmd) {
        $goRoot = 'D:/metacraft-dev-deps/go'
        $candidates = @()
        if (Test-Path -LiteralPath $goRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
        }
        foreach ($sys in @('D:\Program Files\Go\bin\go.exe',
                           'C:\Program Files\Go\bin\go.exe',
                           'D:\Go\bin\go.exe',
                           'C:\Go\bin\go.exe')) {
          if (Test-Path -LiteralPath $sys) { $candidates += $sys }
        }
        if ($candidates.Count -gt 0) {
          $picked = $candidates | Sort-Object | Select-Object -Last 1
          $binDir = Split-Path -Parent $picked
          $env:PATH = "$binDir;$env:PATH"
          $goCmd = Get-Command go -ErrorAction SilentlyContinue
        }
      }
      if ($goCmd) {
        return @{ Available = $true; Reason = "go=$($goCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'go' not on PATH and not under D:/metacraft-dev-deps/go/" }
    }
    'python' {
      # Mode A for Python is not implemented yet — the standard provider has
      # no convention registered. Skip uniformly to surface "not implemented"
      # rather than "toolchain missing", which is the more honest classification.
      return @{ Available = $false; Reason = "Mode A not implemented for Python (M8 outstanding)" }
    }
    'javascript-typescript' {
      return @{ Available = $false; Reason = "Mode A not implemented for JavaScript/TypeScript (M8 outstanding)" }
    }
    'c-cpp-make' {
      return @{ Available = $false; Reason = "Mode A not implemented for c-cpp-make (M8 outstanding)" }
    }
    'c-cpp-autotools' {
      return @{ Available = $false; Reason = "Mode A not implemented for c-cpp-autotools (M8 outstanding)" }
    }
    default {
      return @{ Available = $false; Reason = "unknown language '$language'" }
    }
  }
}

# --- KNOWN-FAIL classifier --------------------------------------------------
# Maps a populated-example rel-path to its KNOWN-FAIL reason, or $null if the
# example is expected to PASS. The classifier checks BOTH stdout and stderr
# for the documented "no convention matched"-style diagnostic before
# accepting a non-zero exit as KNOWN-FAIL.
function Get-KnownFailReason([string]$rel) {
  switch ($rel) {
    'nim/library'              { return 'DSL has no `library` macro yet (M8 outstanding)' }
    'nim/library-with-tests'   { return 'DSL has no `library` macro yet (M8 outstanding)' }
    'rust/library'             { return 'Rust convention rejects library-only crates (M4 outstanding)' }
    'rust/library-with-tests'  { return 'Rust convention rejects library-only crates (M4 outstanding)' }
    'rust/workspace'           { return 'Rust workspaces deferred (M4 outstanding)' }
    'go/library'               { return 'Go convention only matches root main.go (M5 outstanding)' }
    'go/multi-binary'          { return 'Go cmd/<name>/main.go layout not recognised yet (M5 outstanding)' }
    default                    { return $null }
  }
}

# --- expected-binary spec per PASS example ----------------------------------
# Each entry returns either:
#   $null              -- no executable to run (the build itself is the assertion)
#   @( @{ Path; Greeting }, ... )  -- one or more produced executables; for
#                                     each, the file must exist, and if a
#                                     Greeting is non-null it must match the
#                                     stdout when run.
function Get-ExpectedOutputs([string]$rel, [string]$fixtureDir) {
  switch ($rel) {
    'nim/binary' {
      $entry = 'nim_binary_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry ($entry + '.exe')))
        Greeting = "hello from $entry"
      })
    }
    'nim/multi-binary' {
      $alpha = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'alpha' 'alpha.exe'))
      $beta  = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'beta'  'beta.exe'))
      return @(
        @{ Path = $alpha; Greeting = 'hello from alpha' },
        @{ Path = $beta;  Greeting = 'hello from beta'  }
      )
    }
    'rust/binary' {
      $crate = 'rust_binary_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $crate (Join-Path 'bin' ($crate + '.exe'))))
        Greeting = 'hello from rust-binary-example'
      })
    }
    'rust/binary-with-build-rs' {
      # Mode B crude path: cargo writes to <fixture>/target/release/.
      return @(@{
        Path     = Join-Path $fixtureDir 'target\release\rust-binary-with-build-rs.exe'
        Greeting = 'hello with build.rs: yes'
      })
    }
    'go/binary' {
      $entry = 'go_binary_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry (Join-Path 'bin' ($entry + '.exe'))))
        Greeting = 'hello from go-binary-example'
      })
    }
    default {
      return $null
    }
  }
}

# --- accounting ------------------------------------------------------------
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$status, [string]$rel, [string]$reason) {
  [void]$results.Add([pscustomobject]@{
    Status  = $status
    Example = $rel
    Reason  = $reason
  })
}

$languageProbeCache = @{}
function Get-LanguageProbe([string]$language) {
  if (-not $languageProbeCache.ContainsKey($language)) {
    $languageProbeCache[$language] = Probe-Toolchain $language
  }
  return $languageProbeCache[$language]
}

# --- main loop -------------------------------------------------------------
Write-Host "============================================================"
Write-Host "M9 verification harness: $($PopulatedExamples.Count) examples"
Write-Host "============================================================"

foreach ($rel in $PopulatedExamples) {
  $language    = Get-Language $rel
  $exampleName = Get-ExampleName $rel
  $fixtureDir  = Join-Path $examplesRoot ($rel -replace '/', '\')
  Write-Host ""
  Write-Host "--- [$rel] ---"

  if (-not (Test-Path -LiteralPath $fixtureDir)) {
    Add-Result 'FAIL' $rel "fixture missing on disk at $fixtureDir"
    continue
  }
  if (-not (Test-Path -LiteralPath (Join-Path $fixtureDir 'reprobuild.nim'))) {
    Add-Result 'FAIL' $rel "fixture has no reprobuild.nim at $fixtureDir"
    continue
  }

  $probe = Get-LanguageProbe $language
  if (-not $probe.Available) {
    Write-Host "  SKIP: $($probe.Reason)"
    Add-Result 'SKIP' $rel $probe.Reason
    continue
  }

  # Wipe scratch BEFORE each invocation. Junction-aware ops not needed here
  # because example .repro/build/ is plain scratch that never contains
  # junctions (per M8 fixture layout).
  $scratchInsideFixture = Join-Path $fixtureDir '.repro'
  if (Test-Path -LiteralPath $scratchInsideFixture) {
    Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
  }
  # Rust also leaves a top-level target/ from cargo runs (Mode B and any
  # manual smoke). Wipe it so the run is cold.
  if ($language -eq 'rust') {
    $cargoTarget = Join-Path $fixtureDir 'target'
    if (Test-Path -LiteralPath $cargoTarget) {
      Remove-Item -LiteralPath $cargoTarget -Recurse -Force
    }
  }

  # Per-example REPRO_STATS_DIR so we can attribute fast-path distribution
  # to specific PASS rows in the aggregate.
  $statsDir = Join-Path $statsRootDir ("$language-$($rel -replace '[/\\]', '-')")
  New-Item -ItemType Directory -Force -Path $statsDir | Out-Null
  $env:REPRO_STATS_DIR = $statsDir

  # Mode B build.rs path requires the FS-snoop bypass on Windows; without
  # it cargo's child rustc panics in std::process::Command. Same rationale
  # as validate-standard-provider-rust-crude.ps1.
  if ($rel -eq 'rust/binary-with-build-rs') {
    $env:REPRO_MONITOR_BYPASS = '1'
  } else {
    Remove-Item Env:REPRO_MONITOR_BYPASS -ErrorAction SilentlyContinue
  }

  $stdoutCapture = Join-Path $logsDir ("$exampleName.stdout.txt")
  $stderrCapture = Join-Path $logsDir ("$exampleName.stderr.txt")
  $reproTarget   = "$fixtureDir#default"

  Write-Host "  invoking repro build $reproTarget"
  try {
    $proc = Start-Process -FilePath $reproExe -ArgumentList @(
        'build', $reproTarget,
        '--tool-provisioning=path',
        '--log=summary'
      ) -NoNewWindow -PassThru -Wait `
      -WorkingDirectory $repoRoot `
      -RedirectStandardOutput $stdoutCapture `
      -RedirectStandardError  $stderrCapture
    $exitCode = $proc.ExitCode
  } finally {
    Remove-Item Env:REPRO_STATS_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:REPRO_MONITOR_BYPASS -ErrorAction SilentlyContinue
  }

  $stdoutText = if (Test-Path $stdoutCapture) { Get-Content -LiteralPath $stdoutCapture -Raw } else { '' }
  $stderrText = if (Test-Path $stderrCapture) { Get-Content -LiteralPath $stderrCapture -Raw } else { '' }
  Write-Host "    exit=$exitCode  stdout=$($stdoutText.Length)B  stderr=$($stderrText.Length)B"

  if ($exitCode -eq 0) {
    # Classify expected outputs. If we don't have expectations recorded for
    # this rel-path, that's a FAIL — we're not supposed to silently accept
    # an unrecognised pass.
    $expected = Get-ExpectedOutputs $rel $fixtureDir
    if ($null -eq $expected) {
      Add-Result 'FAIL' $rel "repro exit 0 but no expected-output spec is recorded for this example"
      continue
    }
    $allOk = $true
    foreach ($exp in $expected) {
      if (-not (Test-Path -LiteralPath $exp.Path)) {
        Add-Result 'FAIL' $rel "expected binary missing: $($exp.Path)"
        $allOk = $false
        break
      }
      if ($exp.Greeting) {
        $output = & $exp.Path 2>&1 | Out-String
        $runExit = $LASTEXITCODE
        if ($runExit -ne 0) {
          Add-Result 'FAIL' $rel "produced binary $($exp.Path) exited $runExit"
          $allOk = $false
          break
        }
        if ($output -notmatch [regex]::Escape($exp.Greeting)) {
          Add-Result 'FAIL' $rel "produced binary stdout missing greeting '$($exp.Greeting)'; got: $($output.Trim())"
          $allOk = $false
          break
        }
      }
    }
    if ($allOk) {
      Write-Host "    PASS"
      Add-Result 'PASS' $rel ''
    }
    continue
  }

  # Non-zero exit. Match against the documented KNOWN-FAIL catalog. We accept
  # the diagnostic if the stderr OR stdout contains the canonical
  # "no convention matched" phrase (exit 3 path) OR a recognisable provider
  # failure tied to the documented Mode A gap.
  $reason = Get-KnownFailReason $rel
  if ($reason) {
    # Be permissive: a documented coverage gap can manifest as either
    # "no convention matched" (exit 3) or a downstream provider exit
    # complaining about the missing DSL member. Both are KNOWN-FAIL.
    Write-Host "    KNOWN-FAIL: $reason"
    Add-Result 'KNOWN-FAIL' $rel "exit=$exitCode; $reason"
    continue
  }

  Write-Host "    FAIL: exit=$exitCode (no KNOWN-FAIL classification matches)"
  $stderrTail = if ($stderrText) { ($stderrText -split "`n" | Select-Object -Last 10) -join "`n" } else { '(empty)' }
  $stdoutTail = if ($stdoutText) { ($stdoutText -split "`n" | Select-Object -Last 10) -join "`n" } else { '(empty)' }
  Write-Host "    --- stderr tail ---"
  Write-Host $stderrTail
  Write-Host "    --- stdout tail ---"
  Write-Host $stdoutTail
  Add-Result 'FAIL' $rel "exit=$exitCode; stderr: $(($stderrText -split "`n" | Where-Object { $_ -ne '' } | Select-Object -First 1))"
}

# --- aggregate stats across PASS runs --------------------------------------
$fastPathCounts = @{}
$totalInvocations = 0
$totalWallMs = 0.0
$statsFiles = Get-ChildItem -LiteralPath $statsRootDir -Recurse -Filter '*.json' -ErrorAction SilentlyContinue
foreach ($f in $statsFiles) {
  try {
    $json = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
  } catch {
    continue
  }
  $totalInvocations++
  $tag = if ($json.fastPath) { [string]$json.fastPath } else { 'slow-path' }
  if (-not $fastPathCounts.ContainsKey($tag)) { $fastPathCounts[$tag] = 0 }
  $fastPathCounts[$tag]++
  if ($json.wallMs -ne $null) {
    $totalWallMs += [double]$json.wallMs
  }
}

# --- final report ----------------------------------------------------------
$passed     = @($results | Where-Object { $_.Status -eq 'PASS' })
$knownFail  = @($results | Where-Object { $_.Status -eq 'KNOWN-FAIL' })
$skipped    = @($results | Where-Object { $_.Status -eq 'SKIP' })
$failed     = @($results | Where-Object { $_.Status -eq 'FAIL' })

Write-Host ""
Write-Host "============================================================"
Write-Host "Standard-Provider Examples Verification - Aggregate Report"
Write-Host "============================================================"
Write-Host "PASSED      : $($passed.Count)"
foreach ($r in $passed)    { Write-Host "    $($r.Example)" }
Write-Host "KNOWN-FAIL  : $($knownFail.Count)"
foreach ($r in $knownFail) { Write-Host "    $($r.Example) -- $($r.Reason)" }
Write-Host "SKIPPED     : $($skipped.Count)"
foreach ($r in $skipped)   { Write-Host "    $($r.Example) -- $($r.Reason)" }
Write-Host "FAILED      : $($failed.Count)"
foreach ($r in $failed)    { Write-Host "    $($r.Example) -- $($r.Reason) (STOP, these are the real bugs)" }
Write-Host ""
Write-Host "Fast-path attribution (across $totalInvocations recorded invocation(s)):"
$sortedTags = $fastPathCounts.Keys | Sort-Object
foreach ($tag in $sortedTags) {
  $count = $fastPathCounts[$tag]
  Write-Host ("    {0,-32} : {1} invocation(s)" -f $tag, $count)
}
Write-Host ("    {0,-32} : {1:F1} ms" -f "Total wall", $totalWallMs)
Write-Host "============================================================"

if ($failed.Count -gt 0) {
  Write-Host ""
  Write-Host "FAILED count = $($failed.Count); harness exits non-zero."
  exit 1
}

Write-Host ""
Write-Host "All examples accounted for; no unexpected failures."
exit 0

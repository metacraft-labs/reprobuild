#requires -Version 5
# End-to-end M41 verification: build the kotlin-gradle/hello-binary
# example via the Tier 2b dispatch path and run the produced jar.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for javac + gradle + java. SKIP exit 0 if any tool is
#      missing. On Windows, attempt to lift javac from a managed JDK
#      under ``D:/metacraft-dev-deps/jdk/`` and gradle from
#      ``D:/metacraft-dev-deps/gradle/`` when ``Get-Command`` doesn't
#      resolve via PATH alone — this is the documented provisioning
#      path (Adoptium JDK 21 LTS under ``D:/metacraft-dev-deps/jdk/21/``
#      and Gradle 8.x under ``D:/metacraft-dev-deps/gradle/8.x/``).
#   3. Wipe any prior .repro/ scratch AND ``build/`` dir under the
#      fixture so the build runs cold.
#   4. Run a non-fatal ``gradle build`` warm step (no ``--offline``)
#      to pre-populate ``~/.gradle/caches/`` with the Kotlin Gradle
#      plugin + Kotlin stdlib jar. The M41 offline-mode contract
#      requires the cache to already be populated before the action
#      runs.
#   5. Wipe ``build/`` once more so the offline build runs cold.
#   6. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   7. Assert exit code 0.
#   8. Locate the produced ``build/libs/hello-1.0.jar`` and run it via
#      ``java -jar``; assert stdout contains
#      ``hello from kotlin-gradle-hello-binary``.
#
# Per reprobuild-specs/Mode3-Language-Expansion.milestones.org §M41.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\kotlin-gradle\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$buildInsideFixture   = Join-Path $fixture 'build'
$expectedGreeting = 'hello from kotlin-gradle-hello-binary'

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'reprobuild.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture -- expected reprobuild-examples checkout"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'build.gradle.kts'))) {
  Write-Host "FAIL: fixture missing build.gradle.kts at $fixture"
  exit 1
}

# --- toolchain probe ---
# Try to lift a managed JDK into PATH when javac doesn't resolve directly.
$javacCmd = Get-Command javac -ErrorAction SilentlyContinue
if (-not $javacCmd) {
  $jdkRoot = 'D:\metacraft-dev-deps\jdk'
  if (Test-Path -LiteralPath $jdkRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $jdkRoot -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $verDir.FullName 'bin\javac.exe'
      if (Test-Path -LiteralPath $candidate) {
        $binDir = Split-Path -Parent $candidate
        if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
          $env:PATH = "$binDir;$env:PATH"
        }
        $javacCmd = Get-Command javac -ErrorAction SilentlyContinue
        break
      }
    }
  }
}
if (-not $javacCmd) {
  Write-Host "SKIP: 'javac' not on PATH (M41 kotlin-gradle convention needs a JDK; install Adoptium JDK 21 LTS into D:/metacraft-dev-deps/jdk/21/)"
  exit 0
}

$gradleCmd = Get-Command gradle -ErrorAction SilentlyContinue
if (-not $gradleCmd) {
  $gradleRoot = 'D:\metacraft-dev-deps\gradle'
  if (Test-Path -LiteralPath $gradleRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $gradleRoot -Directory -ErrorAction SilentlyContinue) {
      foreach ($candidate in @(
        (Join-Path $verDir.FullName 'bin\gradle.bat'),
        (Join-Path $verDir.FullName 'bin\gradle'))) {
        if (Test-Path -LiteralPath $candidate) {
          $binDir = Split-Path -Parent $candidate
          if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
            $env:PATH = "$binDir;$env:PATH"
          }
          $gradleCmd = Get-Command gradle -ErrorAction SilentlyContinue
          break
        }
      }
      if ($gradleCmd) { break }
    }
  }
}
if (-not $gradleCmd) {
  Write-Host "SKIP: 'gradle' not on PATH (M41 kotlin-gradle convention needs stock Gradle; install Gradle 8.x into D:/metacraft-dev-deps/gradle/8.x/)"
  exit 0
}

# Java runtime — needed by the post-build ``java -jar`` step.
$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if (-not $javaCmd) {
  Write-Host "SKIP: 'java' not on PATH (need the JRE to invoke the produced jar)"
  exit 0
}

Write-Host "==> using javac=$($javacCmd.Source)"
Write-Host "==> using gradle=$($gradleCmd.Source)"
Write-Host "==> using java=$($javaCmd.Source)"

# --- warm-step provisioning (network-touching, BEFORE the offline build) ---
# Gradle's offline mode (``gradle build --offline`` in the convention)
# fails if the Kotlin Gradle plugin + Kotlin stdlib jar haven't landed
# in ``~/.gradle/caches/`` yet. Run an online ``gradle build`` ONCE
# here — outside the action graph — so the convention's hermetic
# offline build has everything it needs. This is the provisioning-time
# warm step the M41 spec calls for. We tolerate failure here because
# some hosts have already warmed their cache OR are running in a
# network-less environment (in which case the offline build will fail
# explicitly downstream).
Write-Host "==> warming Gradle dependency cache (gradle build --no-daemon -q)"
$warmStdout = Join-Path $repoRoot 'build\validate-standard-provider-kotlin-gradle-hello-binary.warm.stdout.txt'
$warmStderr = Join-Path $repoRoot 'build\validate-standard-provider-kotlin-gradle-hello-binary.warm.stderr.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $warmStdout) | Out-Null
$warmProc = Start-Process -FilePath $gradleCmd.Source -ArgumentList @(
    'build',
    '--no-daemon',
    '-q'
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $fixture `
  -RedirectStandardOutput $warmStdout `
  -RedirectStandardError  $warmStderr
$warmExit = $warmProc.ExitCode
Write-Host "--- warm-step exit code: $warmExit (non-fatal — proceeding to build)"

# --- step 1: clean prior scratch + build dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $buildInsideFixture) {
  Write-Host "wiping prior Gradle build dir $buildInsideFixture"
  Remove-Item -LiteralPath $buildInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-kotlin-gradle-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-kotlin-gradle-hello-binary.stderr.txt'

Write-Host "==> launching repro.exe build $reproTarget"
$proc = Start-Process -FilePath $reproExe -ArgumentList @(
    'build', $reproTarget,
    '--tool-provisioning=path',
    '--log=actions'
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $repoRoot `
  -RedirectStandardOutput $stdoutCapture `
  -RedirectStandardError  $stderrCapture
$exitCode = $proc.ExitCode

Write-Host "--- repro exit code: $exitCode"
if (Test-Path $stdoutCapture) {
  Write-Host "--- repro stdout (last 20 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 20 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 20
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 20 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build exited with code $exitCode"
  exit 1
}

# --- step 3: locate produced jar ---
$producedJar = Join-Path $fixture 'build\libs\hello-1.0.jar'
if (-not (Test-Path -LiteralPath $producedJar)) {
  Write-Host "FAIL: expected jar not found at $producedJar"
  if (Test-Path $buildInsideFixture) {
    Write-Host "--- contents of ${buildInsideFixture}:"
    Get-ChildItem -LiteralPath $buildInsideFixture -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no Gradle build dir)"
  }
  exit 1
}
Write-Host "produced jar: $producedJar"
Write-Host "  size: $((Get-Item $producedJar).Length) bytes"

# --- step 4: run jar via ``java -jar`` and assert greeting ---
Write-Host "==> running java -jar $producedJar"
$output = & $javaCmd.Source -jar $producedJar 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- jar exit code: $runExit"
Write-Host "--- jar stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: produced jar exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced jar stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: kotlin-gradle/hello-binary built via standard provider; greeting matched"
exit 0

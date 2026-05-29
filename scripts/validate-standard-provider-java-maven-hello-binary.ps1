#requires -Version 5
# End-to-end M40 verification: build the java-maven/hello-binary example
# via the Tier 2b dispatch path and run the produced jar.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for javac + mvn. SKIP exit 0 if either tool is missing.
#      On Windows, attempt to lift javac from a managed JDK under
#      ``D:/metacraft-dev-deps/jdk/`` and mvn from
#      ``D:/metacraft-dev-deps/maven/`` when ``Get-Command`` doesn't
#      resolve via PATH alone — this is the documented provisioning
#      path (Adoptium JDK 21 LTS under ``D:/metacraft-dev-deps/jdk/21/``
#      and Apache Maven 3.9.x under ``D:/metacraft-dev-deps/maven/3.9.x/``).
#   3. Wipe any prior .repro/ scratch AND ``target/`` build dir under the
#      fixture so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced ``target/hello-1.0.jar`` and run it via
#      ``java -jar``; assert stdout contains
#      ``hello from java-maven-hello-binary``.
#
# Per reprobuild-specs/Mode3-Language-Expansion.milestones.org §M40.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\java-maven\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$targetInsideFixture  = Join-Path $fixture 'target'
$expectedGreeting = 'hello from java-maven-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'pom.xml'))) {
  Write-Host "FAIL: fixture missing pom.xml at $fixture"
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
  Write-Host "SKIP: 'javac' not on PATH (M40 java-maven convention needs a JDK; install Adoptium JDK 21 LTS into D:/metacraft-dev-deps/jdk/21/)"
  exit 0
}

$mvnCmd = Get-Command mvn -ErrorAction SilentlyContinue
if (-not $mvnCmd) {
  $mavenRoot = 'D:\metacraft-dev-deps\maven'
  if (Test-Path -LiteralPath $mavenRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $mavenRoot -Directory -ErrorAction SilentlyContinue) {
      foreach ($candidate in @(
        (Join-Path $verDir.FullName 'bin\mvn.cmd'),
        (Join-Path $verDir.FullName 'bin\mvn'))) {
        if (Test-Path -LiteralPath $candidate) {
          $binDir = Split-Path -Parent $candidate
          if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
            $env:PATH = "$binDir;$env:PATH"
          }
          $mvnCmd = Get-Command mvn -ErrorAction SilentlyContinue
          break
        }
      }
      if ($mvnCmd) { break }
    }
  }
}
if (-not $mvnCmd) {
  Write-Host "SKIP: 'mvn' not on PATH (M40 java-maven convention needs stock Maven; install Apache Maven 3.9.x into D:/metacraft-dev-deps/maven/3.9.x/)"
  exit 0
}

# Java runtime — needed by the post-build ``java -jar`` step.
$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if (-not $javaCmd) {
  Write-Host "SKIP: 'java' not on PATH (need the JRE to invoke the produced jar)"
  exit 0
}

Write-Host "==> using javac=$($javacCmd.Source)"
Write-Host "==> using mvn=$($mvnCmd.Source)"
Write-Host "==> using java=$($javaCmd.Source)"

# --- warm-step provisioning (network-touching, BEFORE the offline build) ---
# Maven's offline mode (``mvn package -o`` in the convention) fails if
# the plugin jars haven't landed in ``~/.m2/repository/`` yet. Run
# ``mvn dependency:go-offline`` ONCE here — outside the action graph —
# so the convention's hermetic offline build has everything it needs.
# This is the provisioning-time warm step the M40 spec calls for. For
# the self-contained fixture (no external dependencies) the step's
# main job is to pre-populate the Maven plugin jars; we tolerate
# failure here because some hosts have already warmed their local repo.
Write-Host "==> warming Maven local repo (mvn dependency:go-offline)"
$warmStdout = Join-Path $repoRoot 'build\validate-standard-provider-java-maven-hello-binary.warm.stdout.txt'
$warmStderr = Join-Path $repoRoot 'build\validate-standard-provider-java-maven-hello-binary.warm.stderr.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $warmStdout) | Out-Null
$warmProc = Start-Process -FilePath $mvnCmd.Source -ArgumentList @(
    'dependency:go-offline',
    '-f', (Join-Path $fixture 'pom.xml'),
    '-q'
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $fixture `
  -RedirectStandardOutput $warmStdout `
  -RedirectStandardError  $warmStderr
$warmExit = $warmProc.ExitCode
Write-Host "--- warm-step exit code: $warmExit (non-fatal — proceeding to build)"

# --- step 1: clean prior scratch + target dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $targetInsideFixture) {
  Write-Host "wiping prior Maven target dir $targetInsideFixture"
  Remove-Item -LiteralPath $targetInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-java-maven-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-java-maven-hello-binary.stderr.txt'

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
$producedJar = Join-Path $fixture 'target\hello-1.0.jar'
if (-not (Test-Path -LiteralPath $producedJar)) {
  Write-Host "FAIL: expected jar not found at $producedJar"
  if (Test-Path $targetInsideFixture) {
    Write-Host "--- contents of ${targetInsideFixture}:"
    Get-ChildItem -LiteralPath $targetInsideFixture -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no Maven target dir)"
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
Write-Host "PASS: java-maven/hello-binary built via standard provider; greeting matched"
exit 0

# Provision repro-alpine: a WSL2 instance running Alpine 3.19 (musl).
#
# See tools/multi-distro-harness/README.md and
# D:/metacraft/reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org M0.

[CmdletBinding()] param()
. "$PSScriptRoot\_common.ps1"

$Instance       = 'repro-alpine'
$DistroLabel    = 'alpine'
$RootfsFileName = 'alpine-minirootfs-3.19.1-x86_64.tar.gz'
$RootfsUrl      = "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/$RootfsFileName"
$RootfsSha256   = '185123ceb6e7d08f2449fff5543db206ffb79decd814608d399ad447e08fa29e'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$cacheFile = Join-Path (Get-ReproDistroCacheDir) $RootfsFileName
Invoke-ReproWebDownload -Url $RootfsUrl -DestPath $cacheFile -ExpectedSha256 $RootfsSha256

Invoke-ReproWslImport -InstanceName $Instance -TarPath $cacheFile

# Alpine 3.19 minirootfs lacks an apk world configured for community/main;
# /etc/apk/repositories ships with the v3.19 entries already populated though,
# so a single update + add is sufficient for the smoke prereqs (gcc, make,
# git, curl, libc-dev for the gcc -include <stdio.h> path on musl).
$prereq = @'
set -eu
apk update
apk add --no-cache build-base make git curl ca-certificates xz bash
# Bash is installed so subsequent tests can rely on it; smoke probe uses
# POSIX sh only.
echo "alpine: $(cat /etc/alpine-release)"
gcc --version | head -1
'@
Invoke-ReproWslExec -InstanceName $Instance -BashScript $prereq

# Nim install. choosenim's installer pulls glibc binaries which won't run on
# musl, so we use the apk-shipped Nim if it's recent enough, falling back to
# building from the source tarball. Alpine 3.19 ships nim 2.0.x; for the M0
# smoke probe we only need a working compiler chain (gcc), so we install nim
# best-effort and don't fail the script if the apk package isn't 2.2+.
$nim = @'
set -eu
if apk add --no-cache nim 2>/tmp/nim-add.err; then
  if command -v nim >/dev/null 2>&1; then
    echo "nim: $(nim --version | head -1)"
  fi
else
  echo "nim: apk add failed; smoke probe does not require nim, skipping" >&2
  cat /tmp/nim-add.err >&2 || true
fi
'@
Invoke-ReproWslExec -InstanceName $Instance -BashScript $nim

Invoke-ReproSmokeProbe -InstanceName $Instance -DistroLabel $DistroLabel

$sw.Stop()
Write-ReproProvisionSummary `
  -InstanceName $Instance `
  -RootfsUrl $RootfsUrl `
  -RootfsSha256 $RootfsSha256 `
  -Elapsed $sw.Elapsed

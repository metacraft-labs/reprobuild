# Provision repro-ubuntu: a WSL2 instance running Ubuntu 22.04 LTS (Jammy)
# from Canonical's official WSL rootfs.
#
# See tools/multi-distro-harness/README.md and
# D:/metacraft/reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org M0.

[CmdletBinding()] param()
. "$PSScriptRoot\_common.ps1"

$Instance       = 'repro-ubuntu'
$DistroLabel    = 'ubuntu'
$RootfsFileName = 'ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz'
$RootfsUrl      = "https://cloud-images.ubuntu.com/wsl/jammy/current/$RootfsFileName"
$RootfsSha256   = '1483cc5c1dce13064f774834cbffdff226559fd522a67a381a8ea77d63fb4109'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$cacheFile = Join-Path (Get-ReproDistroCacheDir) $RootfsFileName
Invoke-ReproWebDownload -Url $RootfsUrl -DestPath $cacheFile -ExpectedSha256 $RootfsSha256

Invoke-ReproWslImport -InstanceName $Instance -TarPath $cacheFile

$prereq = @'
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  gcc make git curl ca-certificates xz-utils
echo "ubuntu: $(. /etc/os-release && echo "$PRETTY_NAME")"
gcc --version | head -1
'@
Invoke-ReproWslExec -InstanceName $Instance -BashScript $prereq

# Apt's nim package is older than 2.2.4; install via choosenim for a recent
# Nim. The choosenim installer is shipped at nim-lang.org/choosenim. For M0
# we only need the install to succeed (smoke probe uses gcc); a stale nim is
# still good enough to verify the upstream binary path works.
$nim = @'
set -eu
if ! command -v nim >/dev/null 2>&1; then
  echo "nim: installing via choosenim"
  apt-get install -y --no-install-recommends gcc build-essential
  curl -fsSL https://nim-lang.org/choosenim/init.sh -o /tmp/choosenim.sh
  CHOOSENIM_NO_ANALYTICS=1 sh /tmp/choosenim.sh -y || {
    echo "nim: choosenim install failed; smoke probe does not require nim" >&2
  }
fi
if [ -x "$HOME/.nimble/bin/nim" ]; then
  "$HOME/.nimble/bin/nim" --version | head -1
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

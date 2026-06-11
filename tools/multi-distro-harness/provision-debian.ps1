# Provision repro-debian: a WSL2 instance running Debian 12 (Bookworm) from
# linuxcontainers.org's official Debian rootfs builder.
#
# The Debian Cloud images at cloud.debian.org/images/cloud/bookworm/ ship as
# disk images (tar of qcow2/raw), not as ready-to-import WSL rootfs tarballs;
# we use linuxcontainers.org which ships a clean rootfs.tar.xz built with
# debootstrap. The snapshot date is pinned for reproducibility.
#
# See tools/multi-distro-harness/README.md and
# D:/metacraft/reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org M0.

[CmdletBinding()] param()
. "$PSScriptRoot\_common.ps1"

$Instance       = 'repro-debian'
$DistroLabel    = 'debian'
$Snapshot       = '20260608_05%3A24'   # pinned for reproducibility
$RootfsFileName = "debian-bookworm-amd64-$($Snapshot -replace '%3A', '_')-rootfs.tar.xz"
$RootfsUrl      = "https://images.linuxcontainers.org/images/debian/bookworm/amd64/default/$Snapshot/rootfs.tar.xz"
$RootfsSha256   = '90c1f6bf38736c84f956a2163abb6ebab6adb73386edee0a7b5f44aed31ffefa'

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
echo "debian: $(. /etc/os-release && echo "$PRETTY_NAME")"
gcc --version | head -1
'@
Invoke-ReproWslExec -InstanceName $Instance -BashScript $prereq

# Debian Bookworm ships nim 1.6; use choosenim for Nim 2.2.4+ from upstream.
$nim = @'
set -eu
if ! command -v nim >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends build-essential
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

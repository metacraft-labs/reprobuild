# Provision repro-opensuse: a WSL2 instance running openSUSE Tumbleweed from
# the official LXC appliance tarball.
#
# See tools/multi-distro-harness/README.md and
# D:/metacraft/reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org M0.

[CmdletBinding()] param()
. "$PSScriptRoot\_common.ps1"

$Instance       = 'repro-opensuse'
$DistroLabel    = 'opensuse'
$RootfsFileName = 'opensuse-tumbleweed-image.x86_64-lxc.tar.xz'
$RootfsUrl      = "https://download.opensuse.org/tumbleweed/appliances/$RootfsFileName"
$RootfsSha256   = '66bbc1578894267162b847ee61c2c34c8503d782ac3e899b43fbf9bc23acfd15'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$cacheFile = Join-Path (Get-ReproDistroCacheDir) $RootfsFileName
Invoke-ReproWebDownload -Url $RootfsUrl -DestPath $cacheFile -ExpectedSha256 $RootfsSha256

Invoke-ReproWslImport -InstanceName $Instance -TarPath $cacheFile

$prereq = @'
set -eu
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive install -y gcc make git curl ca-certificates xz
echo "opensuse: $(. /etc/os-release && echo "$PRETTY_NAME")"
gcc --version | head -1
'@
Invoke-ReproWslExec -InstanceName $Instance -BashScript $prereq

$nim = @'
set -eu
if ! command -v nim >/dev/null 2>&1; then
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

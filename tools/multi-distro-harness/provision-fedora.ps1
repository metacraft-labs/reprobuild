# Provision repro-fedora: a WSL2 instance running Fedora 44 from
# linuxcontainers.org's official Fedora rootfs builder.
#
# The official Fedora Container Base images at kojipkgs.fedoraproject.org and
# its mirrors ship as OCI tarballs (.oci.tar.xz) which require unwrapping the
# inner layer.tar before wsl --import can consume them. linuxcontainers.org
# ships a plain rootfs.tar.xz built from the same dnf packages and is the
# simpler ingestion path; the Fedora-WSL-Base-44 .wsl bundle is a third option
# but tied to the WSL Store install flow rather than wsl --import.
#
# See tools/multi-distro-harness/README.md and
# D:/metacraft/reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org M0.

[CmdletBinding()] param()
. "$PSScriptRoot\_common.ps1"

$Instance       = 'repro-fedora'
$DistroLabel    = 'fedora'
$Snapshot       = '20260602_20%3A33'   # pinned for reproducibility
$RootfsFileName = "fedora-44-amd64-$($Snapshot -replace '%3A', '_')-rootfs.tar.xz"
$RootfsUrl      = "https://images.linuxcontainers.org/images/fedora/44/amd64/default/$Snapshot/rootfs.tar.xz"
$RootfsSha256   = '8bb27c7e9c0d7cb51730da5e53d65dbd7f81dd17ed28351ff18f5690ae5c13d9'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$cacheFile = Join-Path (Get-ReproDistroCacheDir) $RootfsFileName
Invoke-ReproWebDownload -Url $RootfsUrl -DestPath $cacheFile -ExpectedSha256 $RootfsSha256

Invoke-ReproWslImport -InstanceName $Instance -TarPath $cacheFile

$prereq = @'
set -eu
dnf -y -q install gcc make git curl ca-certificates xz glibc-langpack-en
echo "fedora: $(. /etc/os-release && echo "$PRETTY_NAME")"
gcc --version | head -1
'@
Invoke-ReproWslExec -InstanceName $Instance -BashScript $prereq

# Fedora 44 ships a recent Nim in dnf, but we follow the campaign's
# upstream-binary policy and use choosenim for consistency across distros.
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

# Provision repro-arch: a WSL2 instance running Arch Linux from the official
# archlinux-bootstrap tarball.
#
# The official bootstrap tarball wraps its rootfs under a top-level
# "root.x86_64/" directory and is zstd-compressed; wsl --import wants a flat
# rootfs at tar root and accepts gzip but not zstd. We therefore use Alpine
# (the smallest of our distros, 3 MB rootfs) as a transient helper to
# repackage the Arch bootstrap into a flat rootfs.tar.gz cached alongside
# the original.
#
# See tools/multi-distro-harness/README.md and
# D:/metacraft/reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org M0.

[CmdletBinding()] param()
. "$PSScriptRoot\_common.ps1"

$Instance           = 'repro-arch'
$DistroLabel        = 'arch'
$Snapshot           = '2025.12.01'
$BootstrapFileName  = "archlinux-bootstrap-$Snapshot-x86_64.tar.zst"
$BootstrapUrl       = "https://archive.archlinux.org/iso/$Snapshot/$BootstrapFileName"
$BootstrapSha256    = '48277d938a439976564f9e5b795e8668b7f1920c9bbbc30eb28a4a65f8832bdf'

# Alpine helper rootfs (used to repackage zst -> gz; same as provision-alpine.ps1).
$HelperFileName  = 'alpine-minirootfs-3.19.1-x86_64.tar.gz'
$HelperUrl       = "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/$HelperFileName"
$HelperSha256    = '185123ceb6e7d08f2449fff5543db206ffb79decd814608d399ad447e08fa29e'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$bootstrapCache = Join-Path (Get-ReproDistroCacheDir) $BootstrapFileName
Invoke-ReproWebDownload -Url $BootstrapUrl -DestPath $bootstrapCache -ExpectedSha256 $BootstrapSha256

$repackCache = Join-Path (Get-ReproDistroCacheDir) "archlinux-bootstrap-$Snapshot-x86_64.flat-rootfs.tar.gz"

if (-not (Test-Path $repackCache)) {
  Write-Host "[arch] repacking bootstrap tar.zst -> flat rootfs.tar.gz via transient Alpine helper"
  $helperInstance = 'repro-arch-repack'
  $helperCache = Join-Path (Get-ReproDistroCacheDir) $HelperFileName
  Invoke-ReproWebDownload -Url $HelperUrl -DestPath $helperCache -ExpectedSha256 $HelperSha256
  try {
    Invoke-ReproWslImport -InstanceName $helperInstance -TarPath $helperCache
    # Install zstd in the helper. Alpine 3.19 ships zstd in its main repo.
    $installZstd = @'
set -eu
apk update >/dev/null
apk add --no-cache zstd >/dev/null
'@
    Invoke-ReproWslExec -InstanceName $helperInstance -BashScript $installZstd
    # Translate Windows paths to WSL paths.
    $inputWsl  = (& wsl.exe -d $helperInstance -u root --exec /bin/wslpath -a $bootstrapCache).Trim()
    $outputWsl = (& wsl.exe -d $helperInstance -u root --exec /bin/wslpath -a $repackCache).Trim()
    $repack = @"
set -eu
mkdir -p /tmp/arch-stage
cd /tmp/arch-stage
zstd -dc '$inputWsl' | tar xf - --strip-components=1
tar czf '$outputWsl' .
cd /
rm -rf /tmp/arch-stage
"@
    Invoke-ReproWslExec -InstanceName $helperInstance -BashScript $repack
  } finally {
    Assert-ReproInstanceName $helperInstance
    & wsl.exe --terminate $helperInstance 2>$null | Out-Null
    & wsl.exe --unregister $helperInstance 2>$null | Out-Null
    $helperDir = Get-ReproDistroInstanceDir $helperInstance
    if (Test-Path $helperDir) { Remove-Item -Recurse -Force $helperDir }
  }
  Write-Host "[arch] repack done -> $repackCache ($([math]::Round((Get-Item $repackCache).Length/1MB, 1)) MB)"
} else {
  Write-Host "[arch] reusing cached flat rootfs at $repackCache"
}

Invoke-ReproWslImport -InstanceName $Instance -TarPath $repackCache

$prereq = @'
set -eu
# Bootstrap rootfs ships with /etc/pacman.d/mirrorlist commented out.
sed -i 's/^#\(Server = \)/\1/' /etc/pacman.d/mirrorlist 2>/dev/null || true
# Pick a single live mirror if none are uncommented yet.
if ! grep -q '^Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
fi
pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm
# The archlinux-bootstrap rootfs ships gcc-libs pre-installed; the base-devel
# group's gcc/libstdc++/libasan/liblsan/libtsan/libubsan packages need to
# overwrite the pre-staged libs (same physical files, different owning pkg).
# --overwrite='*' is the canonical fix per the Arch bootstrap guide.
pacman -S --noconfirm --needed --overwrite='*' base-devel git curl ca-certificates xz
echo "arch: $(. /etc/os-release && echo "$PRETTY_NAME")"
gcc --version | head -1
'@
Invoke-ReproWslExec -InstanceName $Instance -BashScript $prereq -Shell /bin/bash

# Arch ships Nim in its extra repo and tracks upstream closely, but we use
# choosenim for consistency with the other distros' Nim version policy.
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
Invoke-ReproWslExec -InstanceName $Instance -BashScript $nim -Shell /bin/bash

Invoke-ReproSmokeProbe -InstanceName $Instance -DistroLabel $DistroLabel

$sw.Stop()
Write-ReproProvisionSummary `
  -InstanceName $Instance `
  -RootfsUrl $BootstrapUrl `
  -RootfsSha256 $BootstrapSha256 `
  -Elapsed $sw.Elapsed

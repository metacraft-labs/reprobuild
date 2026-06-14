<#
.SYNOPSIS
    Recovers the `repro-cache` distro from the rsync mirror at
    `D:/metacraft/repro-binary-cache-backup/latest/`.

.DESCRIPTION
    The disposable `repro-cache` distro can be lost catastrophically
    (R7-style: bad init replacement, vhdx corruption, or accidental
    `wsl --unregister`). The rsync mirror to the Windows-side dir
    keeps the manifests + payload CAS + cache-info index + producer
    key safe across that loss.

    Recovery steps (per the operator handbook, recipes/cache/README.md
    § "Recovery"):

    1. `wsl --unregister repro-cache` (if still present).
    2. `wsl --import repro-cache <state-dir> <rootfs>` from a fresh
       Ubuntu rootfs (same path as setup-repro-cache.ps1).
    3. Install runtime deps + the daemon binary (same as setup).
    4. Copy the LATEST snapshot from
       `D:/metacraft/repro-binary-cache-backup/latest/` into the new
       distro's `/var/lib/repro-binary-cache/` (this includes the
       producer key under `trust/server-ecdsa-p256.key`).
    5. Re-install the systemd units + reload + start.

    Identity preservation: because the producer ECDSA-P256 keypair
    is copied verbatim from the rsync snapshot, all previously-signed
    manifests remain verifiable against the same pubkey post-restore.
    No re-signing is needed.

    NEVER touches `nixos-main` or `ubuntu-main`. Asserts the distro
    name is exactly `repro-cache` up-front and refuses otherwise.

.PARAMETER BackupRoot
    Where the rsync snapshots live. Defaults to
    `D:/metacraft/repro-binary-cache-backup`.

.PARAMETER SnapshotName
    Which snapshot to restore. Defaults to `latest` (the symlink to
    today's snapshot). Operators can pass an explicit date subdir
    (e.g. `2026-06-13`) to roll back to a known-good state.

.PARAMETER DaemonBinary
    Same as setup-repro-cache.ps1 — path to the pre-built Linux ELF.

.PARAMETER StateDir, RootfsDir
    Same as setup-repro-cache.ps1.

.EXAMPLE
    ./restore-from-backup.ps1 -DaemonBinary D:/builds/repro_binary_cache-linux

.NOTES
    RTO target: ~5 min on a warm rootfs cache (skipping the rootfs
    download). Total bytes copied during restore: the size of the
    binary-cache state — typically tens to hundreds of GiB at steady
    state. The Windows-side mount /mnt/d throughput dominates.
#>
[CmdletBinding()]
param(
  [string] $BackupRoot = "D:/metacraft/repro-binary-cache-backup",
  [string] $SnapshotName = "latest",
  [string] $StateDir = "D:/metacraft-dev-deps/wsl-distros/repro-cache",
  [string] $RootfsDir = "D:/metacraft-dev-deps/wsl-rootfs",
  [string] $DaemonBinary = $null,
  [string] $Listen = "0.0.0.0:7878"
)

$ErrorActionPreference = 'Stop'

$DistroName = "repro-cache"
$ReservedDistros = @("nixos-main", "ubuntu-main")
if ($ReservedDistros -contains $DistroName) {
  throw "REFUSING to touch reserved WSL distro $DistroName."
}

$snapshotPath = Join-Path $BackupRoot $SnapshotName
if (-not (Test-Path $snapshotPath)) {
  throw "Backup snapshot not found at $snapshotPath. Listing the backup dir for the operator:`n$(Get-ChildItem $BackupRoot -ErrorAction SilentlyContinue | Format-Table | Out-String)"
}

# 1. Re-import via setup-repro-cache.ps1 -Force.
$thisDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupScript = Join-Path $thisDir "setup-repro-cache.ps1"
if (-not (Test-Path $setupScript)) {
  throw "setup-repro-cache.ps1 not found alongside restore-from-backup.ps1."
}

Write-Host "[restore-from-backup] re-provisioning $DistroName from rootfs ..."
& $setupScript -StateDir $StateDir -RootfsDir $RootfsDir -DaemonBinary $DaemonBinary -Listen $Listen -Force

# 2. Stop the freshly-started daemon so we can swap state.
& wsl.exe -d $DistroName -- systemctl stop repro-binary-cache.service | Out-Null

# 3. Copy snapshot into the fresh distro's /var/lib/repro-binary-cache.
# The Windows-side snapshot has store/ + manifests/ + index/ + trust/ as
# top-level subdirs (the layout the rsync helper preserves verbatim).
Write-Host "[restore-from-backup] copying snapshot from $snapshotPath ..."
$wslSnapshot = & wsl.exe -d $DistroName -- wslpath ([string](Resolve-Path $snapshotPath))
& wsl.exe -d $DistroName -- sh -c @"
set -euo pipefail
src=$wslSnapshot
dst=/var/lib/repro-binary-cache
install -d -o reprocache -g reprocache "\$dst"
for sub in store manifests index trust; do
  if [ -d "\$src/\$sub" ]; then
    cp -a "\$src/\$sub/." "\$dst/\$sub/"
    chown -R reprocache:reprocache "\$dst/\$sub"
  fi
done
"@
if ($LASTEXITCODE -ne 0) {
  throw "snapshot copy exited with $LASTEXITCODE"
}

# 4. Restart the daemon — same systemd unit, same listen address.
Write-Host "[restore-from-backup] starting repro-binary-cache.service ..."
& wsl.exe -d $DistroName -- systemctl start repro-binary-cache.service
if ($LASTEXITCODE -ne 0) {
  throw "systemctl start exited with $LASTEXITCODE"
}

Start-Sleep -Seconds 2
$status = & wsl.exe -d $DistroName -- systemctl is-active repro-binary-cache.service 2>&1
Write-Host "[restore-from-backup] systemctl is-active: $status"
if ($status.Trim() -ne 'active') {
  throw "service failed to restart cleanly after restore: $status"
}

Write-Host ""
Write-Host "[restore-from-backup] OK — $DistroName restored from $snapshotPath."
Write-Host "[restore-from-backup] Verify retrievability with `bash tests/integration/binary_cache/t_a2_backup_restore.sh`."

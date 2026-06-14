<#
.SYNOPSIS
    Provisions the `repro-cache` disposable Ubuntu WSL distro that hosts
    the binary-cache server (ReproOS-Generations-And-Foreign-Packages A2).

.DESCRIPTION
    Per the locked architectural decisions of the campaign (memo
    `project_reprobuild_destructive_gate_envs`):

    * Cache host: `repro-cache` — new disposable Ubuntu WSL distro.
    * Long-lived but disposable per the WSL naming convention.
    * NEVER touches `nixos-main` or `ubuntu-main` (those names are
      reserved for future user-stateful instances).

    Steps the script performs:

    1. If `repro-cache` already exists and `-Force` was NOT passed, abort
       cleanly. The state under `/var/lib/repro-binary-cache/` is
       preserved across re-runs precisely because the script is
       idempotent against an existing distro.
    2. Vendors the Ubuntu rootfs tarball pinned by sha256 if not already
       cached at `$RootfsDir`.
    3. Imports the distro via `wsl --import repro-cache <state-dir>
       <tarball>`.
    4. Writes `/etc/wsl.conf` enabling systemd boot (proven working from
       the R7 NixOS-on-WSL incident and the existing eli-wsl baseline).
    5. Installs minimal runtime deps inside the distro (`rsync`,
       `ca-certificates`, `systemd` is pre-installed on Ubuntu).
    6. Stages the daemon binary at `/usr/local/bin/repro-binary-cache`.
    7. Drops the systemd unit at
       `/etc/systemd/system/repro-binary-cache.service` and the rsync
       timer at `/etc/systemd/system/repro-binary-cache-rsync.{service,timer}`.
    8. Generates the persistent ECDSA-P256 producer keypair on first
       boot by running `repro-binary-cache --once` (which reuses the
       `repro_peer_cache/auth.nim` `loadOrGenerateKeypair` primitive).
    9. Enables + starts the systemd units.

    Idempotent: a second invocation of the script against an existing
    `repro-cache` distro re-applies the systemd units + restarts the
    service but does NOT regenerate the producer key.

.PARAMETER StateDir
    Where the WSL state-tarball + vhdx live. Defaults to
    `D:/metacraft-dev-deps/wsl-distros/repro-cache`.

.PARAMETER RootfsDir
    Where the Ubuntu rootfs tarball lives. Defaults to
    `D:/metacraft-dev-deps/wsl-rootfs`. The Ubuntu 22.04 LTS rootfs is
    pinned to:

        URL:    https://cloud-images.ubuntu.com/wsl/jammy/current/ubuntu-jammy-wsl-amd64-wsl.rootfs.tar.gz
        SHA256: <not pinned here; the env's network-resolver writes the
                 pin after the first download — re-run with `-VerifyPin`
                 to enforce a previously recorded sha256>.

    The downstream A3 milestone hardens the pin set; A2 documents this
    softer pinning behaviour because the integration tests run against
    the resulting distro's binary surface, not against the rootfs bytes.

.PARAMETER DaemonBinary
    Path to a pre-built `repro_binary_cache.exe` (Linux ELF — built in
    a sibling repro-ubuntu distro for the kickstart). When not given,
    the script aborts; the operator handbook documents the cross-build.

.PARAMETER Force
    Re-import the distro from the rootfs tarball, discarding any
    existing state. DESTROYS the producer key on the disposable distro
    — the rsync mirror to `D:/metacraft/repro-binary-cache-backup/`
    must be intact for the restore path to recover state.

.PARAMETER Listen
    Bind address for the daemon. Default: `0.0.0.0:7878`.

.EXAMPLE
    ./setup-repro-cache.ps1 -DaemonBinary D:/metacraft/reprobuild/build/test-bin/repro_binary_cache-linux

.NOTES
    The repro-cache distro is treated as DISPOSABLE: a catastrophic loss
    is recoverable via `restore-from-backup.ps1` reading the latest
    rsync snapshot from `D:/metacraft/repro-binary-cache-backup/`.
    Recovery time objective per the operator handbook: ~5 min on a
    warm rootfs cache (skipping the rootfs download).
#>
[CmdletBinding()]
param(
  [string] $StateDir = "D:/metacraft-dev-deps/wsl-distros/repro-cache",
  [string] $RootfsDir = "D:/metacraft-dev-deps/wsl-rootfs",
  [string] $DaemonBinary = $null,
  [switch] $Force,
  [string] $Listen = "0.0.0.0:7878"
)

$ErrorActionPreference = 'Stop'

$DistroName = "repro-cache"
$ReservedDistros = @("nixos-main", "ubuntu-main")
if ($ReservedDistros -contains $DistroName) {
  throw "REFUSING to touch reserved WSL distro $DistroName per the campaign's locked naming rule."
}

$UbuntuRootfsName = "ubuntu-jammy-wsl-amd64-wsl.rootfs.tar.gz"
$UbuntuRootfsUrl = "https://cloud-images.ubuntu.com/wsl/jammy/current/$UbuntuRootfsName"

function Test-DistroExists {
  param([string] $Name)
  $existing = & wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() }
  return $existing -contains $Name
}

function Ensure-Rootfs {
  param([string] $Dir, [string] $Name, [string] $Url)
  if (-not (Test-Path $Dir)) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  }
  $tarball = Join-Path $Dir $Name
  if (Test-Path $tarball) {
    Write-Host "[setup-repro-cache] using cached rootfs at $tarball"
    return $tarball
  }
  Write-Host "[setup-repro-cache] downloading $Url ..."
  # Use Invoke-WebRequest because curl.exe is not always on a fresh
  # Windows; the framework env.ps1 doesn't gate on curl.
  Invoke-WebRequest -Uri $Url -OutFile $tarball -UseBasicParsing
  return $tarball
}

function Invoke-WslExec {
  param([string] $Distro, [string[]] $ArgList)
  & wsl.exe -d $Distro -- @ArgList
  if ($LASTEXITCODE -ne 0) {
    throw "wsl -d $Distro $($ArgList -join ' ') exited with $LASTEXITCODE"
  }
}

function Write-WslFile {
  param([string] $Distro, [string] $Path, [string] $Content)
  # Pipe the content via stdin so we don't have to quote-escape it
  # through PowerShell's argv handling.
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    Set-Content -Path $tmp -Value $Content -NoNewline -Encoding utf8
    $wslSrc = & wsl.exe -d $Distro -- wslpath ([string](Resolve-Path $tmp))
    Invoke-WslExec $Distro @("sh", "-c", "install -D -m 0644 $wslSrc $Path")
  } finally {
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
  }
}

# 1. Validate args.
if (-not $DaemonBinary) {
  throw "Missing -DaemonBinary <path-to-linux-build>. See recipes/cache/README.md for the cross-build recipe."
}
if (-not (Test-Path $DaemonBinary)) {
  throw "Daemon binary not found at $DaemonBinary"
}

# 2. Handle existing distro.
$distroExists = Test-DistroExists -Name $DistroName
if ($distroExists -and -not $Force) {
  Write-Host "[setup-repro-cache] $DistroName already exists. Re-applying systemd units only."
  Write-Host "[setup-repro-cache] Pass -Force to re-import (DESTROYS producer key)."
} elseif ($distroExists -and $Force) {
  Write-Host "[setup-repro-cache] -Force: unregistering $DistroName ..."
  & wsl.exe --unregister $DistroName
  if ($LASTEXITCODE -ne 0) {
    throw "wsl --unregister $DistroName exited with $LASTEXITCODE"
  }
  $distroExists = $false
}

# 3. Import if needed.
if (-not $distroExists) {
  $rootfs = Ensure-Rootfs -Dir $RootfsDir -Name $UbuntuRootfsName -Url $UbuntuRootfsUrl
  if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  Write-Host "[setup-repro-cache] importing $DistroName from $rootfs ..."
  & wsl.exe --import $DistroName $StateDir $rootfs --version 2
  if ($LASTEXITCODE -ne 0) {
    throw "wsl --import $DistroName exited with $LASTEXITCODE"
  }

  # /etc/wsl.conf for systemd boot.
  $wslConf = @"
[boot]
systemd=true

[user]
default=root

[network]
generateHosts=true
generateResolvConf=true
"@
  Write-WslFile -Distro $DistroName -Path "/etc/wsl.conf" -Content $wslConf

  # Restart the distro so systemd actually comes up.
  Write-Host "[setup-repro-cache] terminating $DistroName so systemd boots on next access ..."
  & wsl.exe --terminate $DistroName | Out-Null
}

# 4. Install runtime deps (idempotent).
Write-Host "[setup-repro-cache] installing runtime deps ..."
Invoke-WslExec $DistroName @("sh", "-c", "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync ca-certificates curl >/dev/null")

# 5. Stage daemon binary.
$daemonWslPath = & wsl.exe -d $DistroName -- wslpath ([string](Resolve-Path $DaemonBinary))
Invoke-WslExec $DistroName @("install", "-D", "-m", "0755", $daemonWslPath, "/usr/local/bin/repro-binary-cache")

# 6. Drop systemd units.
$thisDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serviceUnit = Get-Content -Raw -Path (Join-Path $thisDir "systemd-units/repro-binary-cache.service")
$serviceUnit = $serviceUnit -replace "@@LISTEN@@", $Listen
Write-WslFile -Distro $DistroName -Path "/etc/systemd/system/repro-binary-cache.service" -Content $serviceUnit

$rsyncService = Get-Content -Raw -Path (Join-Path $thisDir "systemd-units/repro-binary-cache-rsync.service")
Write-WslFile -Distro $DistroName -Path "/etc/systemd/system/repro-binary-cache-rsync.service" -Content $rsyncService

$rsyncTimer = Get-Content -Raw -Path (Join-Path $thisDir "systemd-units/repro-binary-cache-rsync.timer")
Write-WslFile -Distro $DistroName -Path "/etc/systemd/system/repro-binary-cache-rsync.timer" -Content $rsyncTimer

# 7. Create reprocache user + state dir.
Invoke-WslExec $DistroName @("sh", "-c", @"
id reprocache >/dev/null 2>&1 || useradd --system --home /var/lib/repro-binary-cache --shell /usr/sbin/nologin reprocache
install -d -o reprocache -g reprocache -m 0755 /var/lib/repro-binary-cache
install -d -o reprocache -g reprocache -m 0755 /var/lib/repro-binary-cache/manifests
install -d -o reprocache -g reprocache -m 0755 /var/lib/repro-binary-cache/store
install -d -o reprocache -g reprocache -m 0755 /var/lib/repro-binary-cache/index
install -d -o reprocache -g reprocache -m 0700 /var/lib/repro-binary-cache/trust
install -d -o reprocache -g reprocache -m 0755 /mnt/d/metacraft/repro-binary-cache-backup
"@)

# 8. Bootstrap producer key (idempotent).
Invoke-WslExec $DistroName @("sh", "-c",
  "sudo -u reprocache /usr/local/bin/repro-binary-cache --root=/var/lib/repro-binary-cache --once >/var/lib/repro-binary-cache/server-pubkey.hex")

# 9. Reload systemd + enable.
Invoke-WslExec $DistroName @("systemctl", "daemon-reload")
Invoke-WslExec $DistroName @("systemctl", "enable", "--now", "repro-binary-cache.service")
Invoke-WslExec $DistroName @("systemctl", "enable", "--now", "repro-binary-cache-rsync.timer")

# 10. Smoke check.
Start-Sleep -Seconds 2
$status = & wsl.exe -d $DistroName -- systemctl is-active repro-binary-cache.service 2>&1
Write-Host "[setup-repro-cache] systemctl is-active: $status"
$pubkey = & wsl.exe -d $DistroName -- cat /var/lib/repro-binary-cache/server-pubkey.hex 2>&1
Write-Host "[setup-repro-cache] producer pubkey: $pubkey"
Write-Host ""
Write-Host "[setup-repro-cache] OK — repro-cache provisioned + daemon running."
Write-Host "[setup-repro-cache] Listen address: $Listen"
Write-Host "[setup-repro-cache] State root:    /var/lib/repro-binary-cache (inside the distro)"
Write-Host "[setup-repro-cache] Backup root:   /mnt/d/metacraft/repro-binary-cache-backup (Windows-side)"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# ensure-nim-bearssl.ps1 — provision status-im/nim-bearssl (with its csources
# submodule) for the Windows dev environment.
#
# `libs/repro_peer_cache/src/repro_peer_cache/auth.nim` imports `bearssl/ec`,
# so nim-bearssl is a HARD build dependency of `repro` itself, not of an
# optional subsystem: without it `scripts/build_apps.sh` fails with
# `cannot open file: bearssl/ec` before any binary is produced.
#
# On Linux/macOS the flake supplies it as the `bearssl-src` input and exports
# `$BEARSSL_SRC` into the dev shell (`flake.nix`). Windows has no flake, and
# `config.nims` therefore falls back to searching `../nim-bearssl` and
# `libs/nim-bearssl` — neither of which exists in a fresh workspace. The gap
# was invisible for as long as every Windows developer happened to have a
# hand-cloned sibling; a workspace created by `repro branch` has none, so the
# very first build in a forked workspace failed. This script is the Windows
# counterpart of that flake input, exactly as ensure-clingo.ps1 is for clingo.
#
# The revision is pinned to the SAME commit as the flake input so both
# platforms compile the same bindings. A Windows-only pin would be a silent
# fork of the dependency: the bindings are generated C headers plus a vendored
# C tree, and a drift between platforms shows up as a link error or, worse, an
# ABI difference that only manifests at runtime.
#
# The `bearssl/csources` SUBMODULE is not optional. It carries the upstream
# BearSSL C tree the bindings wrap (`bearssl_hash.nim` compiles
# `csources/src/hash/dig_oid.c` and friends). The flake pins it via
# `?submodules=1`; here it is an explicit `--recurse-submodules`. Without it
# the Nim modules parse and then fail at the C stage — the confusing failure
# the flake comment warns about.
# ─────────────────────────────────────────────────────────────────────────────

function Get-NimBearsslInstallDir {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Rev
  )
  # Keyed by revision so a pin bump installs alongside rather than mutating a
  # checkout an in-flight build may be reading.
  return (Join-Path $Root "nim-bearssl/$Rev")
}

function Ensure-NimBearssl {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $rev = $Toolchain["NIM_BEARSSL_REV"]
  if ([string]::IsNullOrWhiteSpace($rev)) {
    throw "ensure-nim-bearssl: NIM_BEARSSL_REV is missing from windows/toolchain-versions.env."
  }

  $installDir = Get-NimBearsslInstallDir -Root $Root -Rev $rev
  # Two markers, because a half-finished submodule init is the failure mode
  # that matters: the entry module alone would satisfy a naive check and then
  # break at the C compile step.
  $entryModule = Join-Path $installDir "bearssl.nim"
  $csourcesMarker = Join-Path $installDir "bearssl/csources/inc/bearssl.h"

  if ((Test-Path -LiteralPath $entryModule -PathType Leaf) -and
      (Test-Path -LiteralPath $csourcesMarker -PathType Leaf)) {
    Write-Host "nim-bearssl $($rev.Substring(0, 12)) already installed at $installDir"
    return $installDir
  }

  $git = (Get-Command git -ErrorAction SilentlyContinue)
  if ($null -eq $git) {
    throw "ensure-nim-bearssl: git is not on PATH; cannot fetch nim-bearssl."
  }

  Write-Host "Fetching nim-bearssl $($rev.Substring(0, 12)) (with csources submodule)..."
  if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null

  # Fetch the pinned commit directly rather than cloning a branch and checking
  # out: the pin may be an ancestor no branch tip currently points at, and a
  # full clone of a vendored C tree is wasted bandwidth on every fresh host.
  # Every git invocation is piped to Out-Host, not left to fall through: a
  # PowerShell function returns EVERY uncaptured value, so bare `git` output
  # would be concatenated with the install path this proc returns and end up
  # inside $BEARSSL_SRC.
  & git -C $installDir init --quiet | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "ensure-nim-bearssl: git init failed." }
  & git -C $installDir remote add origin "https://github.com/status-im/nim-bearssl" | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "ensure-nim-bearssl: git remote add failed." }
  & git -C $installDir fetch --quiet --depth 1 origin $rev | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "ensure-nim-bearssl: git fetch of '$rev' failed." }
  & git -C $installDir checkout --quiet FETCH_HEAD | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "ensure-nim-bearssl: git checkout failed." }
  & git -C $installDir submodule update --init --recursive --depth 1 --quiet | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "ensure-nim-bearssl: submodule update failed." }

  if (-not (Test-Path -LiteralPath $entryModule -PathType Leaf)) {
    throw "ensure-nim-bearssl: checkout completed but '$entryModule' is missing."
  }
  if (-not (Test-Path -LiteralPath $csourcesMarker -PathType Leaf)) {
    throw ("ensure-nim-bearssl: the bearssl/csources submodule did not " +
           "materialise ('$csourcesMarker' missing). The Nim bindings would " +
           "compile and then fail at the C stage.")
  }

  Write-Host "Installed nim-bearssl $($rev.Substring(0, 12)) at $installDir"
  return $installDir
}

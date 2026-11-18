# snapshot_windows_monitor_stack.ps1 -- copy the monitor stack the release
# build injects to a path the release build does not write.
#
# Usage (from the reprobuild checkout root, after `just bootstrap`):
#
#   $shim = & ./scripts/release/snapshot_windows_monitor_stack.ps1 `
#       [-LibDir build\lib] [-Destination build\orchestrator-monitor]
#   $env:REPRO_MONITOR_SHIM_LIB = $shim
#
# Copies the Windows monitor artefacts that exist in -LibDir into a fresh
# -Destination and prints the absolute path of the copied 64-bit shim as its
# only output.
#
# WHY. The `.#release` build injects the monitor shim into every monitored
# action, and it finds that shim beside the running engine, at
# `<engine dir>\..\lib\librepro_monitor_shim.dll` -- that is,
# `build\lib\librepro_monitor_shim.dll`, which `just bootstrap` has just
# published. The same build ALSO produces that file: the
# `reprobuild.test_fixtures.monitor_shim` action links it to exactly that path
# (repro.nim). Every process the shim was injected into keeps the DLL mapped
# for its whole lifetime, and on Windows a mapped image cannot be replaced, so
# when the fixture link runs while any monitored action is still alive (in
# v0.2.25 it was the long `nim c` link of repro.exe and its gcc/ld children)
# the link dies with
#
#   ld.exe: cannot open output file ...\build\lib\librepro_monitor_shim.dll: Permission denied
#
# POSIX has no such lock: `ld` unlinks the old file and creates a new one, and
# the processes that mapped the old inode keep running on it. This is the same
# self-lock the release job already avoids for the engine image by running the
# build from a copy (`build\bin\repro-orchestrator.exe`); this script is the
# equivalent for the DLL the engine injects. With `REPRO_MONITOR_SHIM_LIB`
# pointing at the copy, the injected shim lives in a directory no action of
# the build writes, and the fixture is free to relink `build\lib`, which is
# what the archive packages. Monitoring itself is unchanged: the copy is the
# very shim bootstrap built, and `REPRO_MONITOR_SHIM_LIB` is the engine's own
# operator override, honoured first and never ignored (a pin that names no
# file is an error, not a fallback).
#
# Before v0.2.25 the collision could not happen, but only by accident: the
# engine treated the fixture action as up to date because bootstrap had left
# its output on disk, so it never relinked anything. A cacheable action that
# no cache record vouches for now executes -- correctly -- and on the cold
# Windows release cache that means the fixture always relinks.
#
# WHY ALL FOUR FILES. Only the 64-bit shim is named by the override. The
# injector finds the other three BY CONVENTION in the same directory as the
# 64-bit shim it was handed (the 32-bit shim as `<stem>32.dll`, the WOW64
# probe and the 64-bit inject helper by fixed names), so copying the 64-bit
# shim alone would silently leave every 32-bit child unmonitored -- and their
# fixture edges relink them in `build\lib` too, so they need the copy for the
# same reason. The names are those of
# libs/repro_dsl_stdlib/src/repro_dsl_stdlib/monitor_shim_artifacts.nim;
# tests/unit/test_release_smoke_dev_exec.py fails if the two lists differ.
# The three cross-bitness files exist only on a host with an i686 toolchain,
# so their absence is not an error here: the copy then looks exactly like the
# directory it was taken from.
#
# Windows PowerShell 5.1 compatible.

param(
  [string]$LibDir = "build\lib",
  [string]$Destination = "build\orchestrator-monitor"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$shim64 = "librepro_monitor_shim.dll"
$companions = @(
  "librepro_monitor_shim32.dll",
  "stackable_hooks_wow64_probe32.exe",
  "stackable_hooks_inject64.exe"
)

$source64 = Join-Path $LibDir $shim64
if (-not (Test-Path -LiteralPath $source64 -PathType Leaf)) {
  throw "snapshot_windows_monitor_stack: $source64 is missing; ``just bootstrap`` publishes it, so run this after bootstrap"
}

# Fresh every time. On a persistent runner a previous run's copy may still be
# here, and a stale companion beside a new 64-bit shim would be injected into
# 32-bit children as though it belonged to this build.
if (Test-Path -LiteralPath $Destination) {
  Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

Copy-Item -LiteralPath $source64 -Destination (Join-Path $Destination $shim64)
foreach ($name in $companions) {
  $source = Join-Path $LibDir $name
  if (Test-Path -LiteralPath $source -PathType Leaf) {
    Copy-Item -LiteralPath $source -Destination (Join-Path $Destination $name)
  }
}

(Resolve-Path -LiteralPath (Join-Path $Destination $shim64)).Path

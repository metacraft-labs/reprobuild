## Age-based sweep of `CARGO_HOME`'s extracted registry sources.
##
## Cargo's own garbage collection of `~/.cargo` is off whenever cargo runs
## offline (`cargo --offline` skips its automatic clean), and the explicit
## `cargo clean gc` is still unstable, so offline fleets never shrink the
## cache. This sweeps the one part that is always safe to drop: a crate's
## extracted tree in `registry/src/<index>/<name>-<version>/`, and only when
## the downloaded `.crate` it came from is still in
## `registry/cache/<index>/`, so cargo can re-extract it without the network.
## Downloads (`registry/cache`) and git checkouts are left alone.

import std/[os, times]
import repro_core/file_lock
import ./[types, layout]

type
  CargoHomeReport* = object
    cargoHome*: string
    dryRun*: bool
    removed*: seq[tuple[path: string, bytes: int64]]
    bytesFreed*: int64
    errors*: seq[string]

proc resolveCargoHome*(env: proc (name: string): string {.closure.}): string =
  ## `$CARGO_HOME`, else `$HOME/.cargo`, else "".
  let explicit = env("CARGO_HOME")
  if explicit.len > 0: return explicit
  let home = env("HOME")
  if home.len > 0: return home / ".cargo"
  let profile = env("USERPROFILE")
  if profile.len > 0: profile / ".cargo" else: ""

proc sweepCargoHome*(cargoHome: string; minAgeSeconds: int64;
                     dryRun: bool; now: int64 = getTime().toUnix):
    CargoHomeReport =
  ## Raises `GcBusyError` when cargo holds the package-cache lock
  ## (`$CARGO_HOME/.package-cache`, taken while it downloads or extracts).
  result.cargoHome = cargoHome
  result.dryRun = dryRun
  let src = cargoHome / "registry" / "src"
  if not dirExists(src): return
  var lock: ReproFileLock
  if not dryRun:
    if not tryAcquireExclusiveFileLock(cargoHome / ".package-cache", lock):
      var err = newException(GcBusyError,
        "'" & (cargoHome / ".package-cache") & "' is locked: cargo is " &
        "using CARGO_HOME; try again when it has finished")
      err.lockPath = cargoHome / ".package-cache"
      raise err
  try:
    for kind, indexDir in walkDir(src):
      if kind != pcDir: continue
      let cache = cargoHome / "registry" / "cache" / indexDir.extractFilename
      for kind2, crateDir in walkDir(indexDir):
        if kind2 != pcDir: continue
        # Only what can be re-extracted offline.
        if not fileExists(cache / (crateDir.extractFilename & ".crate")):
          continue
        if now - treeNewestMtime(crateDir) < minAgeSeconds: continue
        let bytes = treeBytes(crateDir)
        result.removed.add (crateDir, bytes)
        result.bytesFreed += bytes
        if not dryRun:
          try: removeDir(crateDir)
          except OSError as err: result.errors.add crateDir & ": " & err.msg
  finally:
    releaseExclusiveFileLock(lock)

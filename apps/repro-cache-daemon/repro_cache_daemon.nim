## Action-Cache-Per-Edge-Store AC-2c — repro-cache-daemon.
##
## The tiny, long-lived single-writer action-cache daemon for ONE
## `--action-cache-root` (Action-Cache-Per-Edge-Store.md §4.5). A build engine
## AUTO-SPAWNS this binary (detached) the first time it opens a cache root whose
## shm control region has no live owner; the control-region pid/heartbeat
## election (AC-2b `tryClaimOwnership`) makes a redundant spawn harmless — only
## one process ever owns the table.
##
## Lifecycle:
##   * Attaches the shm index + Tier-1 store for the root (create-if-absent).
##   * Runs the AC-2b drain → dedup → apply → grow → persist loop as the SOLE
##     writer, publishing a heartbeat every turn.
##   * Reaps itself so an isolated / hermetic-test root's daemon does not
##     linger: it exits once the table + ring have been idle (no drains, no
##     dirty records) for `--idle-exit-ms` (default 30 s). A fresh submission
##     re-spawns a daemon on demand, so idle-exit never loses records — the
##     Tier-1 disk store is the durable backstop.
##   * The shm tier is OPTIONAL: if the index is unavailable (non-POSIX, no
##     atomics, permission) the daemon exits 0 immediately and the engine runs
##     pure Tier-1 disk-only.

import std/[parseopt, strutils, times]

import repro_shm_index
import repro_shm_index/daemon

const
  Usage = """
repro-cache-daemon — AC-2c single-writer action-cache daemon.

Usage:
  repro-cache-daemon --action-cache-root=PATH [--idle-exit-ms=N] [--poll-ms=N]

Options:
  --action-cache-root=PATH  The cache root to own (its `action-index.*` +
                            `hot-records/`). REQUIRED.
  --idle-exit-ms=N          Exit after N ms with no drained records and no
                            dirty state (self-reaping). Default 30000. 0 = run
                            until killed.
  --poll-ms=N               Drain/heartbeat poll interval. Default 5.
"""

proc main() =
  var cacheRoot = ""
  var idleExitMs = 30_000
  var pollMs = 5
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "action-cache-root": cacheRoot = val
      of "idle-exit-ms": idleExitMs = parseInt(val)
      of "poll-ms": pollMs = parseInt(val)
      of "help", "h":
        echo Usage
        quit(0)
      else: discard
    of cmdArgument:
      if cacheRoot.len == 0: cacheRoot = key
    of cmdEnd: discard
  if cacheRoot.len == 0:
    stderr.writeLine("repro-cache-daemon: --action-cache-root is required")
    quit(2)

  var d = openCacheDaemon(cacheRoot)
  when shmIndexSupported:
    if not d.idx.available:
      # No shm tier here (permission / disabled): nothing to own. The engine
      # falls back to Tier-1 disk-only.
      d.close()
      quit(0)
    # Self-reaping idle-exit: stop once no records have been applied and no
    # dirty state remains for `idleExitMs`. `applied` monotonically counts every
    # drained record, so a fresh submission (which a co-running engine makes)
    # resets the idle window and keeps the daemon alive; a genuinely idle
    # isolated root's daemon exits and stops lingering.
    var lastActive = epochTime()
    var lastApplied = d.applied
    let stop = proc (): bool {.closure, gcsafe.} =
      if idleExitMs <= 0:
        return false
      if d.applied != lastApplied:
        lastApplied = d.applied
        lastActive = epochTime()
        return false
      (epochTime() - lastActive) * 1000.0 >= float(idleExitMs)
    d.runDaemonLoop(stop, pollMs = pollMs, persistEveryMs = 50)
    d.close()
    quit(0)
  else:
    d.close()
    quit(0)

when isMainModule:
  main()

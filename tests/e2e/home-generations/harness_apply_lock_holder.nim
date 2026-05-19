## Test-harness binary for M62 gate 3. Acquires the apply lock at
## `<state-dir>` with a configurable timeout, sleeps for the requested
## hold duration, then releases. Used by the integration gate to spawn
## two concurrent processes and verify the second fails closed with
## `EApplyBusy`.
##
## Usage:
##   harness_apply_lock_holder <state-dir> <hold-seconds> [acquire-timeout-seconds]
##
## Exit codes:
##   0   = lock acquired, held, released cleanly
##   3   = EApplyBusy (the contention path)
##   2   = bad CLI usage
##   1   = any other failure

import std/[os, strutils]

import repro_home_generations

proc usage(): int =
  stderr.writeLine("usage: harness_apply_lock_holder " &
    "<state-dir> <hold-seconds> [acquire-timeout-seconds]")
  2

when isMainModule:
  let args = commandLineParams()
  if args.len < 2:
    quit usage()
  let stateDir = args[0]
  var holdSeconds = 0
  var timeoutSeconds = DefaultLockTimeoutSeconds
  try:
    holdSeconds = parseInt(args[1])
  except ValueError:
    quit usage()
  if args.len >= 3:
    try:
      timeoutSeconds = parseInt(args[2])
    except ValueError:
      quit usage()
  try:
    var lock = acquireApplyLock(stateDir, timeoutSeconds)
    # Signal that we hold the lock by emitting a marker line; the
    # parent gate scrapes stdout to know when to spawn the second
    # contender. This avoids the parent racing the child for the
    # first acquire.
    echo "HARNESS_LOCK_HELD"
    stdout.flushFile()
    if holdSeconds > 0:
      sleep(holdSeconds * 1000)
    releaseApplyLock(lock)
    quit 0
  except EApplyBusy:
    echo "HARNESS_LOCK_BUSY"
    stdout.flushFile()
    quit 3
  except CatchableError as e:
    stderr.writeLine("harness_apply_lock_holder: " & e.msg)
    quit 1

## `repro nimble verify`: the store entries a lock's `nimble:` packages name,
## re-hashed and compared with the lock, with no network
## (`repro_nimble_fetch/verify`).

import std/os

import repro_lock
import repro_nimble_fetch

proc verifyLock(lockFlag, storeFlag: string): int =
  let lockPath = absolutePath(if lockFlag.len > 0: lockFlag
                              else: getCurrentDir() / "repro.lock")
  if not fileExists(lockPath):
    raise newException(ValueError, "no lock at " & lockPath)
  let store = if storeFlag.len > 0: absolutePath(storeFlag)
              else: defaultStoreRoot()
  let rows = nimbleRowsOf(parseLockedDependencies(readFile(lockPath)))
  if rows.len == 0:
    echo "no nimble: packages in " & lockPath
    return 0
  var bad = 0
  for f in verifyStore(rows, store):
    case f.verdict
    of vvOk:
      echo "ok nimble:" & f.row.name & " blake3:" & f.row.tree
    else:
      inc bad
      echo $f.verdict & " nimble:" & f.row.name & " blake3:" & f.row.tree &
        ": " & f.detail
  if bad == 0:
    echo "verified: " & $rows.len & " package(s) against " & lockPath
    0
  else:
    echo "not verified: " & $bad & " of " & $rows.len & " package(s) do " &
      "not match " & lockPath
    1

proc runNimbleVerifyCommand*(lockFlag, storeFlag: string): int =
  ## The verb: 0 when every store entry re-hashes to the lock's digest, 1
  ## when any is missing or differs, 2 when the lock cannot be read or holds
  ## a `nimble:` row that cannot be verified.
  try:
    verifyLock(lockFlag, storeFlag)
  except CatchableError as err:
    stderr.writeLine("repro nimble verify: error: " & err.msg)
    2

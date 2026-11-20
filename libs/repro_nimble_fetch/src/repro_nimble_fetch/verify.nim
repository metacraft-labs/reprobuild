## `repro nimble verify`: the store entries a lock names, re-hashed, with no
## network (Nimble-Package-Catalog § 10, "Offline verification").
##
## For each `nimble:` row of a lock the store entry of the row's tree is
## walked (`tree_walk`, links never followed) and its typed canonical tree
## digest recomputed from the bytes on disk, then compared with the lock's
## integrity. Nothing recorded about an entry is trusted: not its name, not
## its receipt. Nothing here opens a socket or starts a process.

import ./lock_rows
import ./store
import ./tree_walk

type
  VerifyVerdict* = enum
    vvOk = "ok"
    vvMissing = "missing"      ## no store entry for the row's tree
    vvMismatch = "mismatch"    ## the entry re-hashes to another digest
    vvUnreadable = "unreadable" ## the entry holds what no tree can

  VerifyFinding* = object
    row*: NimbleLockRow
    verdict*: VerifyVerdict
    observed*: string  ## the recomputed digest, for `vvMismatch`
    detail*: string
    path*: string

proc verifyStore*(rows: seq[NimbleLockRow]; storeRoot: string):
    seq[VerifyFinding] =
  ## One finding per row, in the rows' order.
  for r in rows:
    var f = VerifyFinding(row: r, path: entryPath(storeRoot, r.tree))
    if not hasEntry(storeRoot, r.tree):
      f.verdict = vvMissing
      f.detail = "no store entry " & f.path
    else:
      try:
        let observed = treeDigestOf(f.path)
        if observed == r.tree:
          f.verdict = vvOk
        else:
          f.verdict = vvMismatch
          f.observed = observed
          f.detail = "the entry re-hashes to " & observed & ", the lock " &
            "records " & r.tree
      except CatchableError as e:
        f.verdict = vvUnreadable
        f.detail = e.msg
    result.add f

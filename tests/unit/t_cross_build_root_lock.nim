## The cross build holds its build root exclusively
## (``scripts/cross/build_root_lock.sh``): a second build of the same root is
## refused, naming the holder, while the first holds it, and may proceed
## once the first has finished. Before the lock, the second build re-exported
## ``<root>/source`` under the first one, which then linked another commit's
## tree.
##
## *Mocking.* None: the real helper under bash, with real ``flock``s on a
## temporary root.

import std/[os, osproc, strutils, tempfiles, unittest]

const Helper = currentSourcePath().parentDir.parentDir.parentDir /
  "scripts" / "cross" / "build_root_lock.sh"

proc bashRun(script: string): tuple[output: string; code: int] =
  let r = execCmdEx("bash -c " & quoteShell(script))
  (r.output, r.exitCode)

suite "the cross build's hold on its build root":
  test "a second build of a held root is refused; a released root is not":
    let tmp = createTempDir("cross-lock-", "")
    defer: removeDir(tmp)
    let root = tmp / "root"
    # The first build: holds the lock until its marker file is removed.
    let holder = startProcess("bash", args = ["-c",
      "source " & quoteShell(Helper) & " && acquire_build_root_lock " &
      quoteShell(root) & " && touch " & quoteShell(tmp / "held") &
      " && while [ -e " & quoteShell(tmp / "held") & " ]; do sleep 0.1; done"],
      options = {poUsePath})
    var waited = 0
    while not fileExists(tmp / "held") and waited < 200:
      sleep(50)
      inc waited
    check fileExists(tmp / "held")
    let second = bashRun("source " & quoteShell(Helper) &
      " && acquire_build_root_lock " & quoteShell(root))
    check second.code != 0
    check "another cross build holds" in second.output
    check "pid" in second.output
    removeFile(tmp / "held")
    discard holder.waitForExit()
    holder.close()
    let third = bashRun("source " & quoteShell(Helper) &
      " && acquire_build_root_lock " & quoteShell(root))
    check third.code == 0

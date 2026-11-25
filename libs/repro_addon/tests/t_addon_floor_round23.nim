## The add-on after the A9 review's round 23 (ReproOS Add-On Mode spec
## §10.1, §13 decision 133; A9 review round 14): the revert hold's staging
## directory is durable before the record says ``staged``.
##
## ``placeRevertHold`` makes ``<root>/.repro-addon-revert-hold.<nonce>``,
## syncs ``<root>`` and only then records the step as ``staged``: a record
## that says ``staged`` over a staging directory a power loss took back
## would read as renamed, and an operator's ``<unit>.d`` made before the
## replay would be claimed. What a power loss keeps cannot be tested
## without one, so the test observes what makes it durable: the
## ``fsync(2)`` of ``<root>`` between the ``mkdir(2)`` of the staging
## directory and the rename that writes the ``staged`` record. It runs
## ``placeRevertHold`` in a child (this binary, ``--place-hold``) under
## ``strace -f -y``, which names the directory each descriptor is open on.
##
## Falsifying build, red here: ``revert-hold-staging-not-synced``.
##
## *Mocking.* None: the real file system, the real system calls, as the
## kernel reports them. ``strace`` is the dev shell's (flake.nix), resolved
## from PATH; a missing one is a failure, never a skip.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_addon/addon_apply

if paramCount() == 3 and paramStr(1) == "--place-hold":
  discard placeRevertHold(paramStr(2), "a9r23.service", paramStr(3))
  quit(0)

proc tracedPlacement(state, root: string): seq[string] =
  ## The traced calls of one ``placeRevertHold`` in a child, in order.
  let strace = findExe("strace")
  doAssert strace.len > 0, "strace is not on PATH: run in the dev shell"
  let outFile = state & ".trace"
  let (o, c) = execCmdEx(quoteShellCommand([strace, "-f", "-y", "-qq",
    "-e", "trace=mkdir,mkdirat,fsync,rename,renameat,renameat2",
    "-o", outFile, getAppFilename(), "--place-hold", state, root]))
  doAssert c == 0, "the traced placement failed: " & o
  readFile(outFile).splitLines()

suite "A9 review round 23: the staging directory is durable before it is recorded staged":
  test "the root is synced between the staging mkdir and the staged record":
    let tmp = createTempDir("a9r23-", "-hold")
    defer: removeDir(tmp)
    let state = tmp / "state"
    let root = tmp / "units"
    createDir(state)
    createDir(root)
    let lines = tracedPlacement(state, root)
    var made, staged = -1
    var syncs: seq[int]
    for i, l in lines:
      if ("mkdir" in l) and RevertHoldStagingPrefix in l and made < 0: made = i
      if l.contains("fsync(") and l.contains("<" & root & ">"): syncs.add(i)
      if made >= 0 and staged < 0 and i > made and "rename" in l and
          "revert-hold-dirs" in l:
        staged = i
    checkpoint lines.join("\n")
    check made >= 0
    check staged > made
    var between = false
    for i in syncs:
      if i > made and i < staged: between = true
    check between

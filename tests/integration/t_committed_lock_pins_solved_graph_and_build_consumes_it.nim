## Workspace-Manifest-Optional MO-1 — the committed solved-graph lock
## pins the concrete solved graph, and ``repro build`` consumes it.
##
## Drives a built ``./build/bin/repro`` against a fixture project that
## carries a ``repro.solver`` sidecar (a solvable variant+package graph).
## Asserts:
##
##   1. ``repro lock refresh`` writes the canonical ``repro.lock`` pinning
##      the concrete solved graph — the chosen package version, the
##      variant (option) assignment, the per-package source identity, and
##      (NLF-M9) the per-instance SELECTION STATUS.
##   2. ``repro build --print-solved-graph`` (the no-build inspection
##      surface that runs the exact lock-consumption loader the real build
##      uses) reproduces the pinned graph from the committed lock.
##   3. Round-trip: the graph the build resolves equals the graph written
##      to the lock.
##   4. CONSUMPTION, proven against a graph the SOLVE produced — see below.
##   5. ``--lock <file>`` selects an alternate committed lock.
##
## ## Why assertion 4 was rewritten (NLF-M9, folded-in criterion)
##
## The previous shape of the consumption proof tampered a version in the
## committed lock and checked that ``--print-solved-graph`` echoed the
## tampered value. Every assertion in it was over a **printer driven by the
## lock loader**: no solve ran anywhere in the test, so the whole case would
## have passed identically against an implementation whose only solve-shaped
## behaviour was reading the file it was about to print. That is exactly how
## the §1.2 pin-vs-bias defect survived a green suite until NLF-M3.
##
## NLF-M9 gives the solved graph a field a printer cannot fake. ``selection``
## is declared NOWHERE in ``repro.solver``: it is DERIVED by the solver from
## the variant assignment and the conditional-dependency gate, and its value
## for ``openssl`` here is the opposite of the naive answer. So the proof is
## now a matched pair over the same fixture:
##
##   * **SOLVE ARM** — with no committed lock, the printed graph must mark
##     ``openssl`` *unselected*. Nothing but a real solve can produce that: a
##     stub that echoed the declared inputs would report it selected (or not
##     at all), and there is no lock file to copy the answer from.
##   * **CONSUMPTION ARM** — with a committed lock whose recorded status is
##     the OPPOSITE of what a fresh solve produces, the build must report the
##     LOCKED status. A re-solve would report the other one.
##
## The first arm establishes that the command really solves; the second that
## when a lock is present the solve's answer is not what comes out. Neither
## arm alone is a consumption proof, and the pair cannot be passed by a
## printer.
##
## Falsifiability: if the build-path loader ignored the committed lock and
## re-solved the inputs, the consumption arm would observe ``unselected``
## after tampering and FAIL. If the printer never solved, the solve arm would
## observe no ``unselected`` entry at all and FAIL.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const solverInputs = """
variant enableTLS
kind: bool
set: false

package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0
depends: openssl >=3.0 when enableTLS=true

package nim
versions: 2.2.0

package openssl
versions: 3.0.0
"""

# The three inline-table entries the solved graph renders, spelled exactly as
# the canonical writer emits them. Matching the WHOLE entry rather than a
# fragment is deliberate: `selection = "selected"` appears three times in a
# fully-selected graph, so a fragment match cannot tell which package it came
# from.
const
  AppSelected =
    "{ name = \"app\", version = \"0.1.0\", source = \"app\"" &
    ", selection = \"selected\" }"
  NimSelected =
    "{ name = \"nim\", version = \"2.2.0\", source = \"nim\"" &
    ", selection = \"selected\" }"
  OpensslUnselected =
    "{ name = \"openssl\", version = \"3.0.0\", source = \"openssl\"" &
    ", selection = \"unselected\" }"
  OpensslSelected =
    "{ name = \"openssl\", version = \"3.0.0\", source = \"openssl\"" &
    ", selection = \"selected\" }"

proc writeProject(dir: string) =
  createDir(dir)
  writeFile(dir / "repro.solver", solverInputs)

suite "MO-1: committed lock pins solved graph and build consumes it":

  test "refresh writes the lock and build consumes the pinned graph":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-pin-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      let lockPath = projectDir / "repro.lock"

      # ------------------------------------------------------------------
      # SOLVE ARM (NLF-M9). Run FIRST, with no lock on disk, so there is
      # nothing for a printer to copy from. `openssl` is reachable only
      # through a variant-conditioned arm whose gate is off, so a real solve
      # puts it in the graph and records that NOTHING selected it. The
      # `enableTLS = false` assignment is the same solve's output and is what
      # makes the gate dormant.
      # ------------------------------------------------------------------
      let (solveOut, solveRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) & " --print-solved-graph")
      check solveRc == 0
      check "# source: solve" in solveOut
      check "{ name = \"enableTLS\", value = \"false\" }" in solveOut
      check AppSelected in solveOut
      check NimSelected in solveOut
      check OpensslUnselected in solveOut
      checkpoint("solve arm printed:\n" & solveOut)

      # 1. refresh writes the canonical lock pinning the solved graph.
      let (refreshOut, refreshRc) = execCmdEx(reproBinary &
        " lock refresh " & quoteShell(projectDir))
      check refreshRc == 0
      check fileExists(lockPath)
      let lockBody = readFile(lockPath)
      # The lock pins the concrete version, the package source identity, the
      # per-instance selection status, and uses the v2 schema (MO-8: the
      # self-describing committed lock that also carries per-dependency
      # coordinates + integrity; the v1 solved-graph payload is preserved as a
      # sub-part).
      check "reprobuild.solved-graph-lock.v2" in lockBody
      check NimSelected in lockBody
      check AppSelected in lockBody
      # NLF-M9 — the unselected instance is RECORDED, and it is still HERE.
      # Whether it belongs in the lock at all is one of §5.6's open policy
      # questions; this milestone answers none of them.
      check OpensslUnselected in lockBody
      check refreshOut.len > 0

      # 2 + 3. build consumes the lock and reproduces the pinned graph.
      let (graphOut, graphRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) & " --print-solved-graph")
      check graphRc == 0
      check NimSelected in graphOut
      check OpensslUnselected in graphOut
      check "# source: lock" in graphOut

      # ------------------------------------------------------------------
      # CONSUMPTION ARM (NLF-M9). Tamper the committed lock in BOTH the
      # version dimension and the selection dimension, and flip selection to
      # the value a fresh solve would NOT produce. A re-solve of these inputs
      # still yields nim 2.2.0 and openssl unselected; the build must instead
      # report the tampered 9.9.9 and openssl SELECTED.
      #
      # The selection half is what the old version of this assertion lacked.
      # A version is a value the lock states outright, so echoing the file
      # satisfies it. `selection` is a value the SOLVER computes from the gate,
      # and the solve arm above already established that this command computes
      # it — so seeing the lock's value here can only mean the lock replaced
      # the solve rather than decorating it.
      # ------------------------------------------------------------------
      writeFile(lockPath, lockBody
        .replace("2.2.0", "9.9.9")
        .replace(OpensslUnselected, OpensslSelected))
      let (tamperOut, tamperRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) & " --print-solved-graph")
      check tamperRc == 0
      check "version = \"9.9.9\"" in tamperOut
      check "version = \"2.2.0\"" notin tamperOut
      check OpensslSelected in tamperOut
      check OpensslUnselected notin tamperOut
      check "# source: lock" in tamperOut
      checkpoint("consumption arm printed:\n" & tamperOut)

  test "no committed lock — build solves the inputs implicitly":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-implicit-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      # No repro.lock present — the build solves the sidecar inputs.
      let (graphOut, graphRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) & " --print-solved-graph")
      check graphRc == 0
      check NimSelected in graphOut
      check OpensslUnselected in graphOut
      check "# source: solve" in graphOut

  test "`repro why` answers the package question from the solved graph":
    # NLF-M9's third deliverable. "Nothing selected it" is a first-class
    # ANSWER — the command reports what the solve recorded and stops. Before
    # this milestone the same invocation could only say "package-level why is
    # not implemented for this project context yet".
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-why-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      let (unselOut, unselRc) = execCmdEx(reproBinary &
        " why openssl " & quoteShell(projectDir))
      check unselRc == 0
      check "package: openssl" in unselOut
      check "selection: unselected" in unselOut
      check "nothing selected it" in unselOut
      # Information, not a warning: the command does not tell the user the
      # package is a problem, because whether it is one is policy §5.6
      # deliberately leaves open.
      check "warning" notin unselOut.toLowerAscii()
      checkpoint("repro why openssl printed:\n" & unselOut)

      let (selOut, selRc) = execCmdEx(reproBinary &
        " why nim " & quoteShell(projectDir))
      check selRc == 0
      check "package: nim" in selOut
      check "selection: selected" in selOut

      # The control: a package that is not in the graph at all is not
      # answered as "unselected". Three states, not two.
      let (absentOut, absentRc) = execCmdEx(reproBinary &
        " why no-such-package " & quoteShell(projectDir))
      check absentRc != 0
      check "selection:" notin absentOut

  test "--lock selects an alternate committed lock":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-altlock-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      let altLock = projectDir / "ci-min.lock"
      let (_, refreshRc) = execCmdEx(reproBinary &
        " lock refresh " & quoteShell(projectDir) &
        " --lock " & quoteShell(altLock))
      check refreshRc == 0
      check fileExists(altLock)
      # The canonical repro.lock was NOT written (alternate selected).
      check not fileExists(projectDir / "repro.lock")

      # Tamper the alternate lock and confirm --lock <file> consumes it.
      let altBody = readFile(altLock)
      writeFile(altLock, altBody.replace("2.2.0", "7.7.7"))
      let (graphOut, graphRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) &
        " --lock " & quoteShell(altLock) & " --print-solved-graph")
      check graphRc == 0
      check "version = \"7.7.7\"" in graphOut
      check "# source: lock" in graphOut

## M5 SELF-HOST — the resolving launcher, end to end, in the ordinary suite.
##
## WHY THIS EXISTS AT ALL. Every other part of the milestone has in-suite
## coverage: `libs/repro_selfhost/tests/` pins the resolution arithmetic, the
## pin-root re-derivation and the gc interaction, all against a real store.
## What none of that touches is the BINARY — whether the thing installed on
## `PATH` as `repro` actually walks up to a lock, picks a prefix, and hands
## the caller's argv to the image there. That behaviour lived only in a gate
## transcript run by hand, and a gate transcript nobody re-runs is how a
## working feature quietly stops working.
##
## WHAT IS REAL HERE. The launcher binary (`build/test-bin/repro_trampoline`,
## compiled from the same source the packaging layer ships as `repro`), the
## store (`repro_local_store` on a real temp directory), the locks (written
## by `repro_lock`'s real writer through the real MO-11 lift), and the
## pin-root attachment. The only stand-in is the IMAGE the launcher execs —
## see `tests/fixtures/selfhost/m5_stub_repro_image.nim` for why four real
## reprobuilds would measure the Nim compiler rather than the launcher.
##
## THE PROPERTIES, EACH WITH ITS FAILURE MODE NAMED:
##
##   1. Two projects pinning two versions get two different answers from ONE
##      launcher binary. The failure this catches is a launcher that answers
##      a constant — which every "it ran and printed a version" check passes.
##   2. An unpinned directory gets the bootstrap, so PATH order is not what
##      decided (1).
##   3. A pin the store cannot satisfy REFUSES (exit 70). It must not fall
##      back to the bootstrap: a silent fallback is indistinguishable from
##      success at the call site and is the failure mode the whole milestone
##      is about.
##   4. There is no side channel. Planting `.reprobuild-version` and
##      `.tool-versions` with a different version changes nothing; editing
##      the LOCK changes everything.
##
## Test-double policy: no mocks. See above for the one stub and its reason.

import std/[algorithm, os, osproc, streams, strtabs, strutils, tables,
            tempfiles, unittest]

import repro_lock
import repro_selfhost
import repro_selfhost/install as selfinstall

# Ambient-execution hatch. This test EXISTS to run a binary that the
# committed lock — not a typed execution profile — decided on, so the
# profile system is the thing under test rather than something available to
# it. `git grep uncontrolled` is the audit surface.
import repro_core/ambient_execution

const RepoMarker = "repro.nim"

const
  ExitResolutionFailed = 70
    ## The launcher's own "the pin is unusable" code. Restated here rather
    ## than imported from the binary under test: importing it would make the
    ## assertion agree with whatever that binary currently says.
  ExitNoBootstrap = 71
  BootstrapLabel = "0.1.3-bootstrap"
  VersionA = "0.1.4"
  VersionB = "0.1.5"
  AbsentVersion = "0.1.9"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc requireHelper(name: string): string =
  ## The helper binaries are graph-owned: `reprobuild.test_helpers.*` edges
  ## in `repro.nim` build both, and `.#test-helpers` runs before the suite.
  ## So a missing one is a BUILD defect, not an environment limitation, and
  ## it raises rather than skipping — the same rule the M20 second-runner
  ## test applies to its spawned binary, for the same reason: a skip here
  ## would make every assertion below disappear on exactly the tree where
  ## the launcher stopped being built.
  let path = findRepoRoot() / "build" / "test-bin" / addFileExt(name, ExeExt)
  if not fileExists(path):
    raise newException(IOError, path & " is missing. It is built by the " &
      "`reprobuild.test_helpers." & name & "` edge in repro.nim; run " &
      "`repro build .#test-helpers`.")
  path

proc lockPinning(version, platform: string): string =
  ## A committed lock pinning `reprobuild <version>` with a store
  ## coordinate, produced by the real writer plus the real MO-11 lift —
  ## the same two calls `repro lock refresh` makes.
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  sol.packages["reprobuild"] = version
  var ld = lockedDepsFromSolved(solutionToLock(sol, platform, ""))
  for i in 0 ..< ld.packages.len:
    if ld.packages[i].name == "reprobuild":
      ld.packages[i].source = "store"
  ld.deps = lockedDepsFromPackages(ld.packages, platform)
  serializeLockedDependencies(ld)

proc lockPinningNothing(platform: string): string =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  sol.packages["nim"] = "2.2.0"
  serializeLockedDependencies(lockedDepsFromSolved(
    solutionToLock(sol, platform, "")))

proc makeImageTree(dir, label, stub: string): string =
  ## An image tree laid out the way a pin expects: `bin/repro[.exe]` plus
  ## the `VERSION` file the stub reads to say which image it is.
  createDir(dir / "bin")
  copyFile(stub, dir / "bin" / selfExecutableName())
  when not defined(windows):
    setFilePermissions(dir / "bin" / selfExecutableName(),
      {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
       fpOthersRead, fpOthersExec})
  writeFile(dir / "VERSION", label & "\n")
  dir

proc drain(s: Stream): string =
  ## Read a stream to EOF in bounded chunks. See the note in `launch`.
  var chunk = newString(4096)
  while true:
    let n = s.readData(addr chunk[0], chunk.len)
    if n <= 0:
      break
    result.add(chunk[0 ..< n])

type LaunchResult = object
  code: int
  stdoutText: string
  stderrText: string

proc launch(launcher, cwd, storeRoot, bootstrap: string;
            args: seq[string]): LaunchResult =
  ## Run the launcher with its streams CAPTURED SEPARATELY.
  ##
  ## Separately, because one of the properties under test is that the
  ## launcher's stdout belongs to the command the user typed: the pin-root
  ## bookkeeping child it runs for itself must not land there. A merged
  ## capture cannot tell the two apart and would pass while the output was
  ## corrupted.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["REPRO_STORE_ROOT"] = storeRoot
  env["REPRO_BOOTSTRAP_CLI"] = bootstrap
  # A resolved exec sets this; inheriting one from an outer run would make
  # every launch below trip the recursion guard.
  env.del("REPRO_SELFHOST_RESOLVED")

  var p = uncontrolledStartProcess(launcher, workingDir = cwd, args = args,
    env = env, options = {})
  try:
    # Drained before the wait, and stdout first: the outputs here are a few
    # hundred bytes, but reading after `waitForExit` is the shape that
    # deadlocks the moment one of them is not.
    #
    # `drain` rather than `readAll`, for the reason the launcher itself
    # carries the same loop: `Stream.readAll()` over an `osproc` pipe was
    # measured on this host returning ONE BYTE of a four-line diagnostic. A
    # test that read its evidence that way would assert about a prefix of
    # the output and call the rest absent.
    result.stdoutText = drain(p.outputStream)
    result.stderrText = drain(p.errorStream)
    result.code = p.waitForExit()
  finally:
    p.close()

proc line(s: string): string =
  ## The single line a well-behaved answer is, with the CR a Windows child
  ## contributes removed.
  s.replace("\r", "").strip()

proc hasLine(s, want: string): bool =
  ## Does any LINE of ``s`` equal ``want``?
  ##
  ## ``contains`` is the wrong test for the two no-fallback guards below,
  ## and the full-suite run caught it firing on a refusal that had done
  ## exactly the right thing. The launcher FORWARDS a failed
  ## ``self provision`` child's diagnostic -- deliberately, because that
  ## message is what names the missing version and the command that would
  ## install it -- and the child names ITSELF first:
  ##
  ##   stub-repro 0.1.3-bootstrap: self provision: the requested version ...
  ##
  ## which contains "repro 0.1.3-bootstrap" as a substring. So the guard
  ## reported a silent fallback to the bootstrap on the one path that had
  ## loudly refused to fall back.
  ##
  ## What a fallback actually looks like is the bootstrap image's version
  ## ANSWER, and an answer is a whole line (``repro <label>``, the stub's
  ## default arm). Matching on lines keeps the guard ABLE TO FAIL -- it
  ## still fires the moment such an answer appears on either stream -- while
  ## letting the refusal say what the user needs to read.
  for ln in s.splitLines:
    if ln.line == want:
      return true
  false

type Scenario = object
  root: string
  store: string
  projA: string
  projB: string
  nopin: string
  launcher: string
  bootstrap: string
  platform: string

proc newScenario(): Scenario =
  let stub = requireHelper("m5_stub_repro_image")
  result.launcher = requireHelper("repro_trampoline")
  result.root = createTempDir("repro-m5-launcher-", "")
  result.store = result.root / "store"
  result.projA = result.root / "projA"
  result.projB = result.root / "projB"
  result.nopin = result.root / "nopin"
  result.platform = currentPlatformId()
  for d in [result.store, result.projA, result.projB, result.nopin]:
    createDir(d)
  writeFile(result.projA / "repro.lock",
    lockPinning(VersionA, result.platform))
  writeFile(result.projB / "repro.lock",
    lockPinning(VersionB, result.platform))

  discard selfinstall.installSelfImage(result.store, VersionA,
    result.platform, makeImageTree(result.root / "img-a", VersionA, stub))
  discard selfinstall.installSelfImage(result.store, VersionB,
    result.platform, makeImageTree(result.root / "img-b", VersionB, stub))

  result.bootstrap = makeImageTree(result.root / "boot", BootstrapLabel,
    stub) / "bin" / selfExecutableName()

proc run(s: Scenario; cwd: string; args = @["--version"]): LaunchResult =
  launch(s.launcher, cwd, s.store, s.bootstrap, args)

suite "the resolving launcher execs the version the lock pins":

  test "one launcher, two projects, two versions":
    let s = newScenario()
    defer: removeDir(s.root)

    let a = s.run(s.projA)
    let b = s.run(s.projB)
    checkpoint("projA: rc=" & $a.code & " out=" & a.stdoutText.line &
      " err=" & a.stderrText.line)
    checkpoint("projB: rc=" & $b.code & " out=" & b.stdoutText.line &
      " err=" & b.stderrText.line)

    check a.code == 0
    check b.code == 0
    check a.stdoutText.line == "repro " & VersionA
    check b.stdoutText.line == "repro " & VersionB
    # The discriminating assertion: a launcher that answered a constant
    # would satisfy one of the two lines above and fail this one.
    check a.stdoutText.line != b.stdoutText.line

  test "both versions are resident in the one store the launcher read":
    let s = newScenario()
    defer: removeDir(s.root)
    var resident: seq[string] = @[]
    for row in selfinstall.listSelfPrefixes(s.store):
      resident.add(row.version)
    resident.sort()
    check resident == @[VersionA, VersionB]

  test "an unpinned directory gets the bootstrap, so PATH order did not decide":
    let s = newScenario()
    defer: removeDir(s.root)
    let r = s.run(s.nopin)
    checkpoint("nopin: rc=" & $r.code & " out=" & r.stdoutText.line)
    check r.code == 0
    check r.stdoutText.line == "repro " & BootstrapLabel
    # ... and it is not one of the pinned answers, so the three directories
    # really do produce three results from one binary.
    check r.stdoutText.line != "repro " & VersionA
    check r.stdoutText.line != "repro " & VersionB

  test "the launcher forwards argv unchanged and owns no flag of its own":
    let s = newScenario()
    defer: removeDir(s.root)
    # `self hold` is the one argv the stub answers differently. Passing it
    # through proves the launcher did not interpret it: if the launcher
    # parsed arguments, this would not reach the image.
    let r = s.run(s.projA, @["self", "hold"])
    check r.code == 0
    check r.stdoutText.line.endsWith("self hold: ok")
    check r.stdoutText.line.contains(VersionA)

  test "the launcher's bookkeeping child does not write to the caller's stdout":
    ## The launcher runs `self hold` FOR ITSELF on every resolved launch. If
    ## that child is given the real stdout, every caller that reads the
    ## output of a `repro` command gets the bookkeeping line mixed into it.
    let s = newScenario()
    defer: removeDir(s.root)
    let r = s.run(s.projA)
    check r.code == 0
    let lines = r.stdoutText.replace("\r", "").strip().splitLines()
    checkpoint("stdout lines: " & $lines)
    check lines.len == 1
    check not r.stdoutText.contains("self hold")

suite "the launcher reads the lock and no other file":

  test "planting version files next to the lock changes nothing":
    let s = newScenario()
    defer: removeDir(s.root)
    let before = s.run(s.projA).stdoutText.line
    check before == "repro " & VersionA

    writeFile(s.projA / ".reprobuild-version", "9.9.9\n")
    writeFile(s.projA / ".tool-versions", "reprobuild 9.9.9\n")
    let planted = s.run(s.projA)
    checkpoint("with decoys: " & planted.stdoutText.line)
    check planted.code == 0
    check planted.stdoutText.line == before

    removeFile(s.projA / ".reprobuild-version")
    removeFile(s.projA / ".tool-versions")
    check s.run(s.projA).stdoutText.line == before

  test "editing the LOCK does move the answer":
    ## The control for the case above: a launcher that ignored every file
    ## would pass "the decoys changed nothing" perfectly.
    let s = newScenario()
    defer: removeDir(s.root)
    check s.run(s.projA).stdoutText.line == "repro " & VersionA
    writeFile(s.projA / "repro.lock", lockPinning(VersionB, s.platform))
    check s.run(s.projA).stdoutText.line == "repro " & VersionB

  test "a project whose lock stops pinning falls back to the bootstrap":
    let s = newScenario()
    defer: removeDir(s.root)
    writeFile(s.projA / "repro.lock", lockPinningNothing(s.platform))
    let r = s.run(s.projA)
    check r.code == 0
    check r.stdoutText.line == "repro " & BootstrapLabel

suite "a pin the store cannot satisfy refuses instead of falling back":

  test "an honest pin on an absent version exits 70 and names it":
    let s = newScenario()
    defer: removeDir(s.root)
    writeFile(s.projA / "repro.lock",
      lockPinning(AbsentVersion, s.platform))
    let r = s.run(s.projA)
    checkpoint("rc=" & $r.code & " err=" & r.stderrText.line)
    check r.code == ExitResolutionFailed
    check r.stderrText.contains(AbsentVersion)
    # THE CLAUSE THAT MATTERS: no fallback. A bootstrap answer here would
    # look like success to every caller.
    check not r.stdoutText.contains(BootstrapLabel)
    check not r.stderrText.hasLine("repro " & BootstrapLabel)

  test "a hand-edited lock is refused as tampered, not as a missing prefix":
    ## The integrity check, through the binary. The edit is the one a user
    ## makes: change the version number in `repro.lock` and expect the pin
    ## to move. The coordinate beside it still addresses the old identity,
    ## so the document contradicts itself.
    let s = newScenario()
    defer: removeDir(s.root)
    let honest = readFile(s.projA / "repro.lock")
    writeFile(s.projA / "repro.lock", honest.replace(
      "version = " & '"' & VersionA & '"',
      "version = " & '"' & AbsentVersion & '"'))
    let r = s.run(s.projA)
    checkpoint("rc=" & $r.code & " err=" & r.stderrText.line)
    check r.code == ExitResolutionFailed
    check r.stderrText.contains("was not written by `repro lock refresh`")
    # Distinct from the absent-version sentence above, which is the whole
    # point of separating the two states.
    check not r.stderrText.contains("could not be provisioned")
    check not r.stdoutText.contains(BootstrapLabel)
    check not r.stderrText.hasLine("repro " & BootstrapLabel)

  test "restoring the lock restores the launch":
    ## So the refusals above are about the edit rather than about a launcher
    ## that broke for the rest of the scenario.
    let s = newScenario()
    defer: removeDir(s.root)
    let honest = readFile(s.projA / "repro.lock")
    writeFile(s.projA / "repro.lock", honest.replace(
      "version = " & '"' & VersionA & '"',
      "version = " & '"' & AbsentVersion & '"'))
    check s.run(s.projA).code == ExitResolutionFailed
    writeFile(s.projA / "repro.lock", honest)
    let r = s.run(s.projA)
    check r.code == 0
    check r.stdoutText.line == "repro " & VersionA

  test "with no bootstrap nameable, an unpinned directory says so and exits 71":
    ## The launcher's other exit code, so 70 above is a value it chose
    ## rather than the only thing it can return.
    let s = newScenario()
    defer: removeDir(s.root)
    let r = launch(s.launcher, s.nopin, s.store,
      s.root / "no-such-bootstrap" / selfExecutableName(), @["--version"])
    checkpoint("rc=" & $r.code & " err=" & r.stderrText.line)
    check r.code == ExitNoBootstrap

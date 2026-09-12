## Windows-Build-Correctness M6, continued — an entropy record is graded
## against THE TOOL THAT EMITTED IT, not against the tool the action invoked.
##
## # The defect this closes
##
## `BuildAction.nonDeterminism` is action-scoped; io-mon's evidence is
## process-tree-scoped. For `nim` the two coincide (the tree is nim, gcc and
## ld, all of it "what nim does"), which is why `packages/nim.nim` can bless
## once and be sound. For a shell they come apart: `bash` emits ZERO entropy
## records of its own and every record in a gate capture belongs to a child
## the SCRIPT chose to run. `84b3a087` refused to bless the shell for that
## reason. This is the mechanism that makes the refusal cost nothing:
## `mrNonDeterministic.osPid` is resolved against the capture's own
## `mrProcessExec` records, and the resolved image is looked up in
## `repro_core/entropy_blessings.EntropyBlessedTools`.
##
## # The case that proves it is sound, and not just convenient
##
## `mktemp` and `uuidgen` produce records that differ IN NO FIELD BUT THE
## EMITTING PID: one `getrandom` each, one process each, no `caller=` token on
## Linux. One names scratch space the caller throws away; the other's bytes
## ARE the caller's product. A mechanism that cannot separate those two has
## the same defect as the shell waiver and must not ship, so the middle test
## below puts BOTH in one capture and requires the action to stay unpublished
## — in the same run in which the `mktemp` record is excused.
##
## # What the assertions are on
##
## The published action-cache record, as in `test_m6_entropy_blessing.nim`,
## and for the same reason: asserting on a diagnostic would pass against an
## implementation that complained and cached anyway. The diagnostic is checked
## once, on its own, because a permanent cache miss that says nothing gets
## "fixed" by disabling the check.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

const
  BlessedImage = "mktemp"
    ## In `EntropyBlessedTools`. Named once so a test that stopped exercising
    ## a blessed image could not do so by quietly renaming a string.
  UnblessedImage = "uuidgen"
    ## Deliberately NOT in `EntropyBlessedTools`, and the reason is in this
    ## file's header.

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 909, threadId: 909, path: path, detail: "")

proc execRecord(pid: uint64; imagePath: string; failed = false):
    MonitorRecord =
  ## The shape io-mon's `repro_hook_execve` writes. It emits from the process
  ## that is ABOUT TO BE REPLACED, so `osPid` is already the pid that will run
  ## `path` — which is what makes the pid a usable key.
  result = MonitorRecord(kind: mrProcessExec, observationKind: moExecute,
    osPid: pid, threadId: pid, path: imagePath, detail: "")
  if failed:
    # M9.R.68.3's follow-up marker: control returns to the hook only when the
    # syscall FAILED, so these bytes never ran.
    result.detail = "execstatus=failed errno=2"
    result.result = -2

proc entropyReadFrom(pid: uint64; source = "getrandom"): MonitorRecord =
  ## The Linux shape: that shim filters at the hook and emits a record only
  ## for the program's own use, so the detail carries no `caller=` token.
  MonitorRecord(kind: mrNonDeterministic, observationKind: moNonDeterministic,
    osPid: pid, threadId: pid, path: source,
    detail: "non-deterministic entropy source")

proc observingProfileRecords(): seq[MonitorRecord] =
  profileRecords(defaultHooksMonitorProfile())

proc writeRmdf(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type Scenario = object
  root: string
  cacheRoot: string
  workRoot: string
  binRoot: string
  sourcePath: string
  outputPath: string
  rmdfPath: string

proc setupScenario(name: string): Scenario =
  result.root = createTempDir("repro-m6img-" & name, "")
  result.cacheRoot = result.root / "cache"
  result.workRoot = result.root / "work"
  result.binRoot = result.root / "bin"
  result.sourcePath = result.workRoot / "src" / "input.txt"
  result.outputPath = result.workRoot / "out" / "product.txt"
  result.rmdfPath = result.root / "action.rdep"
  createDir(result.workRoot / "src")
  createDir(result.workRoot / "out")
  createDir(result.binRoot)
  writeFile(result.sourcePath, "payload\n")
  # Real files, because an `mrProcessExec` record is ALSO folded into the
  # action's read set and the cache key fingerprints what it reads. A
  # made-up path would make these cases fail for a reason that has nothing
  # to do with the blessing.
  for image in [BlessedImage, UnblessedImage, "git"]:
    writeFile(result.binRoot / image, "#!/bin/sh\n")

proc image(scenario: Scenario; name: string): string =
  scenario.binRoot / name

proc scenarioAction(scenario: Scenario;
                    blessing = ndpUnblessed;
                    justification = ""): BuildAction =
  result = builtinAction(bakCopyFile, "produce",
    cwd = scenario.workRoot,
    inputs = ["src/input.txt"],
    outputs = ["out/product.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.monitorDepfile = scenario.rmdfPath
  result.nonDeterminism = blessing
  result.nonDeterminismJustification = justification

proc published(scenario: Scenario; act: BuildAction): bool =
  fileExists(dependencyEvidencePath(scenario.cacheRoot, act.id))

suite "M6 an entropy record is graded against the image that emitted it":

  test "a record from a blessed image publishes, though the action's tool is not":
    ## The gate shape, reduced: the action invokes an unblessed tool (a shell
    ## edge is `ndpUnblessed` and stays so), a CHILD draws the randomness, and
    ## the child's own CLI spec vouches for it. Before per-image attribution
    ## this capture cost the action its cache entry and there was nowhere to
    ## put the statement that would have saved it except on the shell, where
    ## it would have covered every other program the script ran.
    let scenario = setupScenario("blessed-child")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, scenario.image(BlessedImage)),
      entropyReadFrom(1001)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    check scenario.published(act)

  test "ONE unblessed emitter in the same capture withholds the entry":
    ## THE ACCEPTANCE CASE. Both records are `getrandom`, both unattributed by
    ## caller origin, both in a process of their own; the ONLY difference is
    ## which image the pid resolves to. The blessed one is excused in this
    ## very run — the test above proves that is not vacuous — and the action
    ## still does not publish, because a cache entry is a promise about the
    ## whole action's output and `uuidgen`'s bytes are somebody's product.
    let scenario = setupScenario("mixed")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, scenario.image(BlessedImage)),
      entropyReadFrom(1001),
      execRecord(1002, scenario.image(UnblessedImage)),
      entropyReadFrom(1002)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    check not scenario.published(act)

  test "an unblessed emitter alone withholds it too":
    ## The same capture without the blessed record, so the case above cannot
    ## be passing because the blessed one was simply ignored.
    let scenario = setupScenario("unblessed-child")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1002, scenario.image(UnblessedImage)),
      entropyReadFrom(1002)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check not scenario.published(act)

  test "a record no exec record accounts for withholds it":
    ## FAIL CLOSED ON AN UNKNOWN EMITTER. This is not a corner case: the
    ## action's own root process has no `mrProcessExec` record at all, because
    ## io-mon's `execve` hook runs in the process being replaced and the
    ## launcher's exec of the root image precedes the shim constructor. An
    ## unattributable read must keep its full consequence, or the mechanism
    ## would hand out blessings by default to exactly the process most likely
    ## to be the tool itself.
    let scenario = setupScenario("unattributed")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      entropyReadFrom(1001)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check not scenario.published(act)

  test "a FAILED exec does not lend its image to the pid":
    ## io-mon emits a follow-up `mrProcessExec` with `execstatus=failed` when
    ## the syscall returned — bash's platform probes alone fire a dozen per
    ## `configure`. Those bytes never ran, so the pid is still running
    ## whatever it was running, and treating the attempt as an attribution
    ## would let any process borrow a blessed name by trying to exec it.
    let scenario = setupScenario("failed-exec")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, scenario.image(BlessedImage), failed = true),
      entropyReadFrom(1001)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check not scenario.published(act)

  test "a RELATIVE exec path does not lend its image to the pid":
    ## `execvp`/`execlp` record the unresolved name the caller passed, because
    ## glibc does the PATH walk internally where no interposer can see it. The
    ## fold refuses to manufacture a path from it for the read set; it must
    ## refuse to attribute from it too, or `PATH=. exec mktemp` would be a way
    ## to claim a blessing.
    let scenario = setupScenario("relative-exec")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, BlessedImage),
      entropyReadFrom(1001)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check not scenario.published(act)

  test "the LAST exec before the read is the one that counts":
    ## A pid can exec more than once (the Nix gcc/rustc bash-wrapper shape
    ## re-execs the same pid). The image that matters is the one the process
    ## was running WHEN IT DREW, so a pid that was `mktemp` and is now
    ## `uuidgen` must be graded as `uuidgen`. An implementation that kept the
    ## first exec, or that resolved in a pass over the whole capture without
    ## regard to order, would grade this backwards and publish.
    let scenario = setupScenario("re-exec")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, scenario.image(BlessedImage)),
      execRecord(1001, scenario.image(UnblessedImage)),
      entropyReadFrom(1001)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check not scenario.published(act)

  test "two records alike but for the emitter are BOTH kept":
    ## `addEntropyObservation` dedupes, and the dedup key has to include the
    ## image. `mktemp`'s record and `uuidgen`'s are identical in `source` and
    ## in `origin`, so a two-component key collapses them into one and the
    ## action is graded by whichever process happened to run first — which is
    ## a coin toss, and half the time a false publish.
    let scenario = setupScenario("dedup")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, scenario.image(BlessedImage)),
      entropyReadFrom(1001),
      execRecord(1002, scenario.image(UnblessedImage)),
      entropyReadFrom(1002)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    var images: seq[string] = @[]
    for observation in run.results[0].evidence.entropyObservations:
      check observation.source == "getrandom"
      images.add observation.image
    check images.len == 2
    check scenario.image(BlessedImage) in images
    check scenario.image(UnblessedImage) in images

  test "the action-level blessing still covers the whole tree":
    ## `nim`'s shape, unchanged. A blessed tool's blessing is a claim about
    ## everything under it — gcc and ld included — so a record from a child
    ## image nobody listed must NOT start blocking a `nim c` edge. Reading the
    ## per-image table first would have done exactly that.
    let scenario = setupScenario("action-blessed")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1002, scenario.image(UnblessedImage)),
      entropyReadFrom(1002)])

    let act = scenarioAction(scenario, ndpEntropyBlessed,
      "the tool's randomness names scratch files it throws away")
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    check scenario.published(act)

  test "the reason names the blocking emitter and the excused one":
    ## A permanent cache miss that says nothing reads as a caching bug. This
    ## one has to say more than the pre-attribution diagnostic did: WHICH tool
    ## is unaccounted for, so the reader knows whose spec to go and read, and
    ## that another record in the same capture WAS excused, so "entropy blocks
    ## caching" is not the lesson taken away.
    let scenario = setupScenario("diag")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, scenario.image(BlessedImage)),
      entropyReadFrom(1001),
      execRecord(1002, scenario.image(UnblessedImage)),
      entropyReadFrom(1002)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    var reported = false
    for diagnostic in run.results[0].evidence.diagnostics:
      if "publish skipped" in diagnostic and UnblessedImage in diagnostic and
          BlessedImage in diagnostic and "excused" in diagnostic:
        reported = true
    check reported

  test "an all-blessed capture says so, and says the waiver is per-image":
    ## The other half of the diagnostic. An action that publishes DESPITE
    ## entropy having been observed is the surprising outcome, and the record
    ## of why has to survive in the evidence — otherwise the next person to
    ## read a gate's diagnostics sees a blessed-looking result with no
    ## statement of who blessed it.
    let scenario = setupScenario("diag-ok")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      execRecord(1001, scenario.image(BlessedImage)),
      entropyReadFrom(1001)])

    let act = scenarioAction(scenario)
    let run = runBuild(graph([act]),
      defaultBuildEngineConfig(scenario.cacheRoot))
    var reported = false
    for diagnostic in run.results[0].evidence.diagnostics:
      if "attributed by its own pid" in diagnostic and
          BlessedImage in diagnostic and "per-image" in diagnostic:
        reported = true
    check reported

## An output the engine removes before the action runs -- an optional output
## candidate, or a ``removeBeforeRun`` entry -- may not be the action's
## working directory or contain it, and may not contain a declared input.
## On a filesystem that folds case those are refused whatever letter case the
## output is spelled in.
##
## A scratch directory, which the engine empties before the action runs, is
## held to the same rule by `scratchDirProblem`, and may not overlap a
## declared output either.
##
## Build-Engine-And-Scheduler.md §"A declared output is an obligation"
## (optional paths), §"Opaque output directories" (bullet "Exclusive") and
## §"Scratch directories".
##
## The defect this pins: validation compared the removal's location with the
## cwd and the inputs by spelling (`==`, `startsWith`). The location's parent
## is resolved through the filesystem, which answers in the on-disk case, but
## its last component is kept as spelled, so under a cwd `<D>/work` on a
## case-insensitive volume the optional output `../WORK` named `<D>/WORK`,
## equal to nothing the cwd is spelled as, and was accepted. Removing it
## removes the working directory. The same held for an output `SRC` and an
## input `src/in.txt`. macOS's default APFS volume folds case, so this was
## the ordinary configuration there. `scratchDirProblem` compared its
## scratch directories with the cwd, inputs and outputs by spelling in the
## same way, so `../WORK` (and `<D>/WORK`) under that cwd was emptied; the
## same-case parent walks it also accepted are pinned in `t_scratch_dirs`.
##
## The second suite pins the same rule for entries that do not exist when
## the graph is validated, which on a fresh build is every output and every
## input another action produces (issue
## `2026-11-21-output-removal-checks-compare-spellings-for-entries-that-do-not-exist-yet`).
## An absent entry has no identity to compare, and the fix answered "not the
## same" for it, so under a folding cwd an optional output `OUT` beside
## another action's `out/gen.h` was accepted, and its removal before the
## consumer ran deleted the producer's output. The cross-action checks (an
## opaque directory `OUT` and another action's `out/x`, an optional
## candidate `OUT` and an obligatory output `out`, or a concurrent writer of
## `out/x`) compared spellings only, so they missed it whether `out` existed
## or not. Two absent names are now one entry when their parents are and the
## nearest existing directory folds case. The same graphs are run in a
## directory that does NOT fold, where `OUT` and `out` are two directories
## and every one must be accepted, and spelled in one case, where each must
## be refused for the rule its folded twin is tested for.
##
## WHERE THE FOLDING DIRECTORY COMES FROM. Where the temporary directory
## already folds case (macOS, Windows) the cases run in it, in this process.
## On Linux they need a directory with the `casefold` attribute, which an
## unprivileged user gets on a private tmpfs mounted `-o casefold` inside a
## user and mount namespace of its own: the test re-executes this binary
## under `unshare -rm` with that mount, the inner run sets the attribute on a
## fresh directory (`FS_IOC_SETFLAGS` with `FS_CASEFOLD_FL`), runs the cases
## and prints one line per case, and the outer run checks them. A host that
## allows neither skips with the reason. Only a failure BEFORE the inner run
## reports a folding directory is the host's; one after it fails the test.
##
## NO MOCKS: the real `runBuild` (dry run, which validates the graph and
## launches nothing) and the real `scratchDirProblem` (asked directly: it is
## what `resetScratchDirs` consults before removing anything), on a real
## case-folding filesystem.
##
## Falsifiability: with the engine comparing spellings only, or comparing
## absent entries by spelling only, every `refused` case fails (each is
## accepted); the `accepted` cases are the
## controls that keep the fix from refusing a different directory, a symlink
## to the cwd (removing it removes the link) or a distinct hard link to an
## input.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

when defined(linux):
  import std/posix

import repro_build_engine
import repro_test_support/reasoned_skip

const
  InnerRootEnv = "REPRO_T_CASEFOLD_ROOT"
  ResultMarker = "CASEFOLD-RESULT\t"
  # Printed once the inner run has a folding directory. Before it, a failure
  # is the host's (no namespace, no casefold mount, no casefold attribute)
  # and the cases skip; after it, a failure is the test's and is reported.
  ReadyMarker = "CASEFOLD-READY"
  # The inner run's exit status for "this host has no casefold directory".
  NoFoldingExit = 2

type CaseResult = tuple[name, refusal: string]

proc refusalOf(actions: openArray[BuildAction]; cacheRoot: string): string =
  ## The engine's refusal of the graph, or "" when it accepts it.
  var config = defaultBuildEngineConfig(cacheRoot)
  config.bypassRunQuota = true
  config.dryRun = true
  try:
    discard runBuild(graph(actions), config)
    ""
  except BuildEngineError as e:
    e.msg.replace('\n', ' ')

proc absentCases(dir: string; removal = "OUT"; deep = "GEN/Sub"):
    seq[CaseResult]

proc runCases(root: string): seq[CaseResult] =
  ## Every case, in the case-folding directory `root`. The tree:
  ##   <root>/work/src/in.txt     the cwd and a declared input under it
  ##   <root>/work/kept.txt       an input with a hard link `linked.txt`
  ##   <root>/alias -> work       a symlink to the cwd
  ##   <root>/nest/work           a cwd one level deeper
  ##   <root>/work/out/app        a declared output
  ##   <root>/other               a directory that is neither
  let dir = expandFilename(root)
  let work = dir / "work"
  createDir(work / "src")
  writeFile(work / "src" / "in.txt", "input\n")
  writeFile(work / "kept.txt", "input\n")
  createHardlink(work / "kept.txt", work / "linked.txt")
  createDir(dir / "nest" / "work")
  createDir(dir / "other")
  createDir(work / "out")
  writeFile(work / "out" / "app", "output\n")
  createSymlink("work", dir / "alias")
  let cache = dir / "cache"
  var acc: seq[CaseResult] = @[]
  proc base(id, cwd: string; inputs: openArray[string] = []): BuildAction =
    action(id, ["unused"], cwd = cwd, inputs = inputs,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
  proc optional(name, cwd, raw: string;
                inputs: openArray[string] = []) =
    var a = base("optional", cwd, inputs)
    a.optionalOutputs = @[raw]
    acc.add((name: name, refusal: refusalOf([a], cache)))
  proc removed(name, cwd, raw: string; inputs: openArray[string] = []) =
    var a = base("removed", cwd, inputs)
    a.outputs = @[raw]
    a.removeBeforeRun = @[raw]
    acc.add((name: name, refusal: refusalOf([a], cache)))

  optional("optional ../work", work, "../work")
  optional("optional ../WORK", work, "../WORK")
  optional("optional ../../NEST", dir / "nest" / "work", "../../NEST")
  optional("optional SRC", work, "SRC", ["src/in.txt"])
  optional("optional src/IN.TXT", work, "src/IN.TXT", ["src/in.txt"])
  optional("optional ../other", work, "../other")
  optional("optional linked.txt", work, "linked.txt", ["kept.txt"])
  optional("optional ../alias", work, "../alias")
  removed("removed ../WORK", work, "../WORK")
  removed("removed SRC", work, "SRC", ["src/in.txt"])

  # Scratch directories are emptied before the action runs
  # (`resetScratchDirs`), so they are held to the same rule
  # (`scratchDirProblem`), and may not overlap a declared output either.
  proc scratch(name, cwd, raw: string; inputs: openArray[string] = [];
               outputs: openArray[string] = []) =
    var a = base("scratch", cwd, inputs)
    a.outputs = @outputs
    a.scratchDirs = @[raw]
    acc.add((name: name, refusal: scratchDirProblem(a).replace('\n', ' ')))
  scratch("scratch ../work", work, "../work")
  scratch("scratch ../WORK", work, "../WORK")
  scratch("scratch " & dir & "/WORK", work, dir & "/WORK")
  scratch("scratch ../../NEST", dir / "nest" / "work", "../../NEST")
  scratch("scratch SRC", work, "SRC", ["src/in.txt"])
  scratch("scratch SRC/tmp", work, "SRC/tmp", ["src"])
  scratch("scratch OUT", work, "OUT", outputs = ["out/app"])
  scratch("scratch ../other", work, "../other")
  scratch("scratch ../alias", work, "../alias")
  scratch("scratch Tmp", work, "Tmp")
  acc & absentCases(dir)

proc absentCases(dir: string; removal = "OUT"; deep = "GEN/Sub"):
    seq[CaseResult] =
  ## The cases whose entries do not exist when the graph is validated, as on
  ## a fresh build: issue
  ## `2026-11-21-output-removal-checks-compare-spellings-for-entries-that-do-not-exist-yet`.
  ## Under `<dir>/fresh` nothing but the cwd exists; under `<dir>/present`
  ## the directory `out` does. Each case is named once and run both here, in
  ## a folding `dir` (where each removal takes the other entry and must be
  ## refused), and in a directory that does not fold (where `OUT` and `out`
  ## are two directories and every case must be accepted). With `removal`
  ## and `deep` spelled as the other actions spell them (`out`, `gen/sub`)
  ## the same graphs are the same-case controls: refused on any volume.
  let fresh = dir / "fresh"
  let present = dir / "present"
  createDir(fresh)
  createDir(present / "out")
  let cache = dir / "cache-absent"
  var acc: seq[CaseResult] = @[]
  proc base(id, cwd: string; inputs: openArray[string] = [];
            outputs: openArray[string] = []): BuildAction =
    result = action(id, ["unused"], cwd = cwd, inputs = inputs,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    result.outputs = @outputs
  proc run(name: string; actions: openArray[BuildAction]) =
    acc.add((name: name, refusal: refusalOf(actions, cache)))

  # A produces `out/gen.h`; B reads it and may produce `OUT`, which it
  # removes before it runs. On a folding volume that removal deletes A's
  # product, however the graph is ordered.
  block:
    var b = base("consumer", fresh, inputs = ["out/gen.h"])
    b.optionalOutputs = @[removal]
    run("absent optional OUT", [base("producer", fresh,
      outputs = ["out/gen.h"]), b])
  block:
    var b = base("consumer", fresh, inputs = ["out/gen.h"],
      outputs = [removal])
    b.removeBeforeRun = @[removal]
    run("absent removed OUT", [base("producer", fresh,
      outputs = ["out/gen.h"]), b])
  block:
    # More than one absent component: `GEN/Sub` is `gen/sub`.
    var b = base("consumer", fresh, inputs = ["gen/sub/x.h"])
    b.optionalOutputs = @[deep]
    run("absent optional GEN/Sub", [base("producer", fresh,
      outputs = ["gen/sub/x.h"]), b])
  block:
    # Control: a different name is a different entry wherever it lands.
    var b = base("consumer", fresh, inputs = ["out/gen.h"])
    b.optionalOutputs = @["OUTPUT"]
    run("absent optional OUTPUT", [base("producer", fresh,
      outputs = ["out/gen.h"]), b])
  block:
    # An opaque directory `OUT` and another action's output `out/x`.
    var a = base("opaque", fresh, outputs = [removal])
    a.removeBeforeRun = @[removal]
    run("absent opaque OUT", [a, base("other", fresh, outputs = ["out/x"])])
  block:
    # The same with `out` on disk and `OUT` spelled in another case.
    var a = base("opaque", present, outputs = [removal])
    a.removeBeforeRun = @[removal]
    run("present opaque OUT", [a,
      base("other", present, outputs = ["out/x"])])
  block:
    var a = base("optional", fresh, outputs = ["out"])
    a.optionalOutputs = @[removal]
    run("absent optional OUT obligatory out", [a])
  block:
    # An optional candidate is removed before its action runs, so another
    # action that writes under it concurrently is a double write (R7).
    var a = base("optional", fresh)
    a.optionalOutputs = @[removal]
    run("absent optional OUT other out/x", [a,
      base("other", fresh, outputs = ["out/x"])])
  acc

proc folds(dir: string): bool =
  ## Whether `dir` resolves a name in another letter case.
  let probe = dir / "case-probe"
  writeFile(probe, "")
  defer: removeFile(probe)
  fileExists(dir / "CASE-PROBE")

when defined(linux):
  const
    FS_IOC_GETFLAGS = 0x80086601'u
    FS_IOC_SETFLAGS = 0x40086602'u
    FS_CASEFOLD_FL = 0x40000000.clong

  proc setCaseFold(dir: string) =
    ## Gives the empty directory `dir` the `casefold` attribute (what
    ## `chattr +F` does): https://docs.kernel.org/filesystems/ext4/
    ## directory.html#case-insensitive-directories ; tmpfs honours it on a
    ## mount made with `-o casefold` (Linux 6.13+).
    let fd = posix.open(dir.cstring, O_RDONLY)
    if fd < 0:
      raiseOSError(osLastError(), dir)
    defer: discard posix.close(fd)
    var flags: clong = 0
    if ioctl(fd, FS_IOC_GETFLAGS, addr flags) != 0:
      raiseOSError(osLastError(), "FS_IOC_GETFLAGS " & dir)
    flags = flags or FS_CASEFOLD_FL
    if ioctl(fd, FS_IOC_SETFLAGS, addr flags) != 0:
      raiseOSError(osLastError(), "FS_IOC_SETFLAGS " & dir)

# The inner run: inside the namespace, on the folding mount. It prints its
# results and exits before the suite below is reached.
when defined(linux):
  if existsEnv(InnerRootEnv):
    let root = getEnv(InnerRootEnv) / "folded"
    try:
      createDir(root)
      setCaseFold(root)
    except CatchableError as e:
      # E.g. EOPNOTSUPP: a kernel whose tmpfs mounts `-o casefold` but does
      # not take the attribute. The host's limitation, not the engine's.
      echo "no casefold attribute on the casefold mount: ", e.msg
      quit(NoFoldingExit)
    if not folds(root):
      echo "no case folding on the casefold mount at ", root
      quit(NoFoldingExit)
    echo ReadyMarker
    try:
      for r in runCases(root):
        echo ResultMarker, r.name, "\t", r.refusal
      quit(0)
    except CatchableError as e:
      echo "inner run failed: ", e.msg
      quit(3)

proc foldedResults(): tuple[results: seq[CaseResult]; skipReason: string] =
  ## The case results from a folding directory, or why none is available.
  let scratch = createTempDir("repro-casefold-", "")
  defer: removeDir(scratch)
  if folds(scratch):
    let root = scratch / "folded"
    createDir(root)
    return (runCases(root), "")
  when not defined(linux):
    return (@[], "the temporary directory does not fold case and this " &
      "platform has no unprivileged way to make one that does")
  else:
    if findExe("unshare").len == 0:
      return (@[], "needs unshare(1) for a private casefold tmpfs mount")
    let mountPoint = scratch / "mnt"
    createDir(mountPoint)
    let script = "mount -t tmpfs -o casefold tmpfs \"$1\" && " &
      "export " & InnerRootEnv & "=\"$1\" && exec \"$2\""
    let res = execCmdEx("unshare -rm sh -c " & quoteShell(script) & " sh " &
      quoteShell(mountPoint) & " " & quoteShell(getAppFilename()) & " 2>&1")
    let ready = res.output.splitLines().anyIt(it == ReadyMarker)
    if res.exitCode != 0 and not ready:
      # `unshare` or `mount` failed, or the mount does not fold
      # (`NoFoldingExit`): the inner run never reached the cases.
      return (@[], "this host gives an unprivileged user no casefold " &
        "tmpfs in a private namespace: " & res.output.strip())
    if res.exitCode != 0:
      raise newException(OSError, "the inner run failed (exit " &
        $res.exitCode & "):\n" & res.output)
    var results: seq[CaseResult] = @[]
    for line in res.output.splitLines():
      if line.startsWith(ResultMarker):
        let fields = line[ResultMarker.len .. ^1].split('\t', maxsplit = 1)
        results.add((name: fields[0],
          refusal: if fields.len > 1: fields[1] else: ""))
    if results.len == 0:
      raise newException(OSError, "the inner run printed no results:\n" &
        res.output)
    (results, "")

proc refusalFor(results: seq[CaseResult]; name: string): string =
  for r in results:
    if r.name == name:
      return r.refusal
  raise newException(KeyError, "no result for case " & name)

suite "an output removal is checked against the cwd and inputs on disk, not by spelling":
  let (results, skipReason) = foldedResults()

  test "control: the cwd's parent walk spelled in its own case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output contains the action's cwd" in
        results.refusalFor("optional ../work")

  test "an optional output naming the cwd in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output contains the action's cwd" in
        results.refusalFor("optional ../WORK")

  test "an optional output naming an ancestor of the cwd in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output contains the action's cwd" in
        results.refusalFor("optional ../../NEST")

  test "an optional output naming a declared input's directory in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output contains a declared input" in
        results.refusalFor("optional SRC")

  test "an optional output naming a declared input file in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output contains a declared input" in
        results.refusalFor("optional src/IN.TXT")

  test "an output removed before run naming the cwd in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "output removed before run contains the action's cwd" in
        results.refusalFor("removed ../WORK")

  test "an output removed before run naming a declared input's directory in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "output removed before run contains a declared input" in
        results.refusalFor("removed SRC")

  test "control: a scratch directory naming the cwd in its own case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "contains the action's cwd" in
        results.refusalFor("scratch ../work")

  test "a scratch directory naming the cwd in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "contains the action's cwd" in
        results.refusalFor("scratch ../WORK")

  test "an absolute scratch directory naming the cwd in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check results.anyIt(it.name.startsWith("scratch /") and
        "contains the action's cwd" in it.refusal)

  test "a scratch directory naming an ancestor of the cwd in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "contains the action's cwd" in
        results.refusalFor("scratch ../../NEST")

  test "a scratch directory containing a declared input in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "declared input" in results.refusalFor("scratch SRC")

  test "a scratch directory inside a declared input directory in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "declared input" in results.refusalFor("scratch SRC/tmp")

  test "a scratch directory containing a declared output in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "declared output" in results.refusalFor("scratch OUT")

  test "control: a scratch directory that is a different directory is accepted":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check results.refusalFor("scratch ../other") == ""
      check results.refusalFor("scratch Tmp") == ""

  test "control: a scratch directory that is a symlink to the cwd is accepted":
    # Emptying it unlinks the link (`removePathNoFollow`) and leaves the cwd;
    # `t_scratch_dirs` empties one and checks that the cwd survives.
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check results.refusalFor("scratch ../alias") == ""

  test "control: a different directory is accepted":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check results.refusalFor("optional ../other") == ""

  test "control: a symlink to the cwd is a different entry and is accepted":
    # Removing `../alias` removes the link, not the directory it points at,
    # so its identity is the link's own (`lstat`), not the cwd's.
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check results.refusalFor("optional ../alias") == ""

  test "control: a hard link to a declared input is a different entry and is accepted":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check results.refusalFor("optional linked.txt") == ""

proc sensitiveResults(): tuple[results, sameCase: seq[CaseResult];
                               skipReason: string] =
  ## `absentCases` in a directory that does not fold case: the controls that
  ## keep the fix from refusing two directories that merely share a folded
  ## spelling, and (`sameCase`) the same graphs spelled in one case, which
  ## show each graph trips the rule its folded case is tested for.
  let scratch = createTempDir("repro-casesensitive-", "")
  defer: removeDir(scratch)
  if folds(scratch):
    return (@[], @[], "the temporary directory folds case")
  let dir = expandFilename(scratch)
  createDir(dir / "other-case")
  createDir(dir / "same-case")
  (absentCases(dir / "other-case"),
   absentCases(dir / "same-case", "out", "gen/sub"), "")

suite "an output removal is checked against entries that do not exist yet":
  let (results, skipReason) = foldedResults()
  let (sensitive, sameCase, sensitiveSkip) = sensitiveResults()

  test "control: each graph spelled in one case is refused for its rule":
    if sensitiveSkip.len > 0:
      skip(sensitiveSkip)
    else:
      for (name, rule) in [
          ("absent optional OUT", "optional output contains a declared input"),
          ("absent removed OUT",
           "output removed before run contains a declared input"),
          ("absent optional GEN/Sub",
           "optional output contains a declared input"),
          ("absent opaque OUT", "an opaque output directory belongs"),
          ("present opaque OUT", "an opaque output directory belongs"),
          # Spelled in one case, the candidate is the same declared path
          # twice, which an earlier check refuses.
          ("absent optional OUT obligatory out",
           "duplicate declared output: out"),
          ("absent optional OUT other out/x", "double-write reject (R7)")]:
        checkpoint name
        check rule in sameCase.refusalFor(name)
      check sameCase.refusalFor("absent optional OUTPUT") == ""

  test "an optional output in another case containing another action's not-yet-produced input is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output contains a declared input" in
        results.refusalFor("absent optional OUT")

  test "an output removed before run in another case containing a not-yet-produced input is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "output removed before run contains a declared input" in
        results.refusalFor("absent removed OUT")

  test "several absent components are folded":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output contains a declared input" in
        results.refusalFor("absent optional GEN/Sub")

  test "another action's absent output under an opaque directory in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "an opaque output directory belongs" in
        results.refusalFor("absent opaque OUT")

  test "another action's output under an opaque directory spelled in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "an opaque output directory belongs" in
        results.refusalFor("present opaque OUT")

  test "an optional output that is an absent obligatory output in another case is refused":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "optional output is also an obligatory output" in
        results.refusalFor("absent optional OUT obligatory out")

  test "another action's absent output under an optional output in another case is a double write":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check "double-write reject (R7)" in
        results.refusalFor("absent optional OUT other out/x")

  test "control: a different absent name is accepted on a folding volume":
    if skipReason.len > 0:
      skip(skipReason)
    else:
      check results.refusalFor("absent optional OUTPUT") == ""

  test "control: on a volume that does not fold case every such graph is accepted":
    if sensitiveSkip.len > 0:
      skip(sensitiveSkip)
    else:
      check sensitive.len == 8
      for r in sensitive:
        checkpoint r.name & ": " & r.refusal
        check r.refusal == ""

## An output the engine removes before the action runs -- an optional output
## candidate, or a ``removeBeforeRun`` entry -- may not be the action's
## working directory or contain it, and may not contain a declared input.
## On a filesystem that folds case those are refused whatever letter case the
## output is spelled in.
##
## Build-Engine-And-Scheduler.md §"A declared output is an obligation"
## (optional paths) and §"Opaque output directories" (bullet "Exclusive").
##
## The defect this pins: validation compared the removal's location with the
## cwd and the inputs by spelling (`==`, `startsWith`). The location's parent
## is resolved through the filesystem, which answers in the on-disk case, but
## its last component is kept as spelled, so under a cwd `<D>/work` on a
## case-insensitive volume the optional output `../WORK` named `<D>/WORK`,
## equal to nothing the cwd is spelled as, and was accepted. Removing it
## removes the working directory. The same held for an output `SRC` and an
## input `src/in.txt`. macOS's default APFS volume folds case, so this was
## the ordinary configuration there.
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
## launches nothing), on a real case-folding filesystem.
##
## Falsifiability: with the engine comparing spellings only, every
## `refused` case fails (each is accepted); the two `accepted` cases are the
## controls that keep the fix from refusing a different directory or a
## distinct hard link to an input.

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

proc runCases(root: string): seq[CaseResult] =
  ## Every case, in the case-folding directory `root`. The tree:
  ##   <root>/work/src/in.txt     the cwd and a declared input under it
  ##   <root>/work/kept.txt       an input with a hard link `linked.txt`
  ##   <root>/alias -> work       a symlink to the cwd
  ##   <root>/nest/work           a cwd one level deeper
  ##   <root>/other               a directory that is neither
  let dir = expandFilename(root)
  let work = dir / "work"
  createDir(work / "src")
  writeFile(work / "src" / "in.txt", "input\n")
  writeFile(work / "kept.txt", "input\n")
  createHardlink(work / "kept.txt", work / "linked.txt")
  createDir(dir / "nest" / "work")
  createDir(dir / "other")
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

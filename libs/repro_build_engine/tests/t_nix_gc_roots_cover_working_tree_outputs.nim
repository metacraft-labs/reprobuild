## A working-tree build output keeps the Nix store paths it names alive, and
## an output whose store paths were collected anyway is never reported up to
## date.
##
## The defect (reprobuild-pm issue 2026-10-02, "the dev-env profile gcroot
## covers the shell but not the libraries a working-tree build output
## links"): the only GC root reprobuild created was the dev-shell profile
## (`nix print-dev-env --profile`). A linked binary in the working tree names
## `/nix/store/<hash>-openssl-…` in its load commands, the profile names a
## DIFFERENT openssl, a garbage collection deletes the binary's one, and the
## next `repro build` reports the now unrunnable binary as up to date.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler, the real action
## cache, real `/bin/sh` subprocesses, and the host's REAL Nix store through
## the real `nix-store` CLI. The property under test is "Nix refuses to
## delete this path because reprobuild rooted it", which only the real store
## can answer: a fake `nix-store` would make the test agree with whatever the
## engine believes it registered.
##
## Store hygiene. The test never runs a garbage collection and never passes
## `--ignore-liveness`. It deletes ONLY store paths it created itself with
## `nix-store --add` over a file whose bytes are unique to this process, so
## nothing else on the host can reference them, and it deletes them with
## `nix-store --delete`, which refuses a live path. The private paths are
## removed again at the end of every case.
##
## Governing text: the `useFlakeDevShell` doc comment in
## `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/foreign_env/flake.nim` and the
## issue's options 1 (root the output's references) and 3 (detect the damage
## and rebuild).

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_core/paths
import repro_hash
import repro_local_store

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("nix-gc-roots-working-tree." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc nixStoreExe(): string =
  ## The host's `nix-store`. Required, not optional: this file is the
  ## real-Nix gate for the retention fix, and a host without Nix cannot say
  ## anything about it. A missing binary fails loudly rather than skipping.
  ##
  ## `followSymlinks = false` is load-bearing: `nix-store` is a symlink to
  ## the multi-call `nix` binary, which dispatches on `argv[0]`, so the
  ## resolved target answers `--add` with "unrecognised flag".
  result = findExe("nix-store", followSymlinks = false)
  if result.len == 0:
    raise newException(OSError,
      "nix-store is not on PATH; this real-Nix test needs the host's Nix")

proc nixStore(args: openArray[string]): tuple[output: string; code: int] =
  var cmd = quoteShell(nixStoreExe())
  for arg in args:
    cmd.add(" " & quoteShell(arg))
  let (output, code) = execCmdEx(cmd)
  (output: output, code: code)

proc addPrivateStorePath(scratch, tag: string): string =
  ## A fresh store path nothing else on the host can reference: its bytes
  ## name this process, this case and the current time. `nix-store --add`
  ## leaves it valid, unreferenced and UNROOTED.
  let file = scratch / ("gc-roots-" & tag & ".txt")
  writeFile(file, "reprobuild nix-gc-roots test " & tag & " pid=" &
    $getCurrentProcessId() & " t=" & $epochTime() & "\n")
  let res = nixStore(["--add", file])
  doAssert res.code == 0, "nix-store --add failed: " & res.output
  for line in res.output.splitLines():
    if line.strip().startsWith("/"):
      result = line.strip()
  doAssert result.len > 0, "nix-store --add printed no path: " & res.output
  doAssert dirExists(result) or fileExists(result)

proc rootLinksOf(storePath: string): seq[string] =
  ## Every GC root Nix itself reports for `storePath`, as the root's own
  ## path (the left-hand side of `<root> -> <path>`).
  let res = nixStore(["--query", "--roots", storePath])
  for line in res.output.splitLines():
    let arrow = line.find(" -> ")
    if arrow > 0 and line[arrow + 4 .. ^1].strip() == storePath:
      result.add(line[0 ..< arrow].strip())

proc canonical(path: string): string =
  ## macOS temp directories live under `/var`, which is a symlink to
  ## `/private/var`; Nix may report a root under either spelling.
  try: expandFilename(path) except OSError: path

proc rootsUnder(storePath, dir: string): seq[string] =
  let a = dir
  let b = canonical(dir)
  for root in rootLinksOf(storePath):
    if root.startsWith(a & "/") or root.startsWith(b & "/") or
        canonical(root).startsWith(b & "/"):
      result.add(root)

proc dropRootsUnder(storePath, dir: string) =
  ## Simulate "the root went away" without touching anything this test did
  ## not create: remove only the links under the engine's cache root.
  for root in rootsUnder(storePath, dir):
    removeFile(root)

proc deleteIsRefused(storePath: string): bool =
  let res = nixStore(["--delete", storePath])
  checkpoint("nix-store --delete " & storePath & " -> exit " & $res.code &
    "\n" & res.output)
  res.code != 0 and (dirExists(storePath) or fileExists(storePath))

proc deleteSucceeds(storePath: string): bool =
  let res = nixStore(["--delete", storePath])
  checkpoint("nix-store --delete " & storePath & " -> exit " & $res.code &
    "\n" & res.output)
  res.code == 0 and not (dirExists(storePath) or fileExists(storePath))

proc cleanupStorePath(storePath, cacheRoot: string) =
  if storePath.len == 0 or not (dirExists(storePath) or fileExists(storePath)):
    return
  dropRootsUnder(storePath, cacheRoot)
  discard nixStore(["--delete", storePath])

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  runLog: string
  action: BuildAction

proc makeFixture(): Fixture =
  let root = createTempDir("repro-nix-gc-roots-", "")
  let workRoot = root / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  # The "linker": copies the store path named by the input into a binary-ish
  # output, between NUL bytes and inside a longer path, the way a load
  # command or an RPATH entry carries it. Appends to a log on every run so
  # "was re-executed" is a fact about the filesystem.
  let script = workRoot / "link.sh"
  writeFile(script,
    "#!/bin/sh\n" &
    "echo ran >> out/run.log\n" &
    "ref=$(cat src/ref.txt)\n" &
    "printf '\\177ELF\\000\\001junk\\000%s/lib/libfixture.dylib\\000tail\\n' " &
    "\"$ref\" > out/app.bin\n" &
    "printf '%s: %s\\n' out/app.bin src/ref.txt > out/app.dep\n")
  setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    runLog: workRoot / "out" / "run.log",
    action: action("gc/link", [script],
      cwd = workRoot,
      inputs = ["src/ref.txt"],
      outputs = ["out/app.bin"],
      depfile = "out/app.dep",
      cacheable = true,
      weakFingerprint = weak("gc/link"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph()))

proc setReference(f: Fixture; storePath: string) =
  # A fresh mtime each time, so the timestamp policy sees the input move.
  writeFile(f.workRoot / "src" / "ref.txt", storePath & "\n")
  setLastModificationTime(f.workRoot / "src" / "ref.txt",
    getTime() + initDuration(seconds = 1))

proc runCount(f: Fixture): int =
  if not fileExists(f.runLog):
    return 0
  for line in readFile(f.runLog).splitLines():
    if line.strip().len > 0:
      inc result

proc warmConfig(cacheRoot: string): BuildEngineConfig =
  ## Exactly the mode `repro build` runs the engine in, which is also the
  ## mode in which the whole-graph fast no-op scan may answer.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32

proc traceMentions(res: BuildRunResult; actionId, needle: string): bool =
  for event in res.trace:
    if event.actionId == actionId and needle in event.detail:
      return true

proc traceHas(res: BuildRunResult; actionId, event: string): bool =
  for item in res.trace:
    if item.actionId == actionId and item.event == event:
      return true

proc dumpTrace(res: BuildRunResult): string =
  for event in res.trace:
    result.add(event.actionId & " " & event.event & " " & event.detail & "\n")

suite "Nix GC roots cover working-tree build outputs":

  test "an output's store references are rooted, re-rooted, detected and pruned":
    let f = makeFixture()
    var p1, p2, p3: string
    defer:
      cleanupStorePath(p1, f.cacheRoot)
      cleanupStorePath(p2, f.cacheRoot)
      cleanupStorePath(p3, f.cacheRoot)
      removeDir(f.root)
    let scratch = f.root / "store-src"
    createDir(scratch)
    let g = graph([f.action])
    let config = warmConfig(f.cacheRoot)

    # (1) A fresh output that names a fresh, unrooted store path must leave
    # that path rooted under the engine's cache root. Against the unfixed
    # engine nothing roots it and `nix-store --delete` succeeds: exactly the
    # collection the issue observed, on a path this test owns.
    p1 = addPrivateStorePath(scratch, "p1")
    check rootLinksOf(p1).len == 0
    f.setReference(p1)
    let first = runBuild(g, config)
    check first.byId("gc/link").status == asSucceeded
    check first.byId("gc/link").launched
    check f.runCount == 1
    checkpoint("roots of p1: " & $rootLinksOf(p1))
    check rootsUnder(p1, f.cacheRoot).len > 0
    check deleteIsRefused(p1)

    # A warm rebuild stays a no-op: rooting must not cost a re-execution.
    let warm = runBuild(g, config)
    check not warm.byId("gc/link").launched
    check f.runCount == 1

    # (3a) The output stops naming p1 and names p2: the root set follows the
    # output, so p2 is rooted and p1 is no longer held by the engine.
    p2 = addPrivateStorePath(scratch, "p2")
    f.setReference(p2)
    let second = runBuild(g, config)
    check second.byId("gc/link").launched
    check f.runCount == 2
    check rootsUnder(p2, f.cacheRoot).len > 0
    check rootsUnder(p1, f.cacheRoot).len == 0
    check deleteSucceeds(p1)
    check deleteIsRefused(p2)

    # (2) The damage happens anyway — a root removed by hand, an older
    # engine, a GC on another checkout's behalf. Remove the engine's root and
    # delete p2. The output still exists and names p2, so an engine that only
    # asks "do the outputs exist" reports it up to date. It must re-execute
    # instead, and say which store path is gone.
    dropRootsUnder(p2, f.cacheRoot)
    check rootsUnder(p2, f.cacheRoot).len == 0
    check deleteSucceeds(p2)
    let detected = runBuild(g, config)
    checkpoint("trace after deleting p2:\n" & detected.dumpTrace())
    check detected.byId("gc/link").launched
    check detected.byId("gc/link").status == asSucceeded
    check f.runCount == 3
    check detected.traceMentions("gc/link", p2)
    # And it does not loop: the re-executed output still names p2 (this
    # fixture cannot re-realise it), but a path that was absent when the
    # output was produced is not one the output can have lost.
    let settled = runBuild(g, config)
    check not settled.byId("gc/link").launched
    check f.runCount == 3

    # (3b) The output is deleted and its producer leaves the graph: the next
    # build prunes the action's roots, so the path it named is collectable.
    p3 = addPrivateStorePath(scratch, "p3")
    f.setReference(p3)
    discard runBuild(g, config)
    check f.runCount == 4
    check rootsUnder(p3, f.cacheRoot).len > 0
    removeFile(f.workRoot / "out" / "app.bin")
    let otherScript = f.workRoot / "other.sh"
    writeFile(otherScript, "#!/bin/sh\necho other > out/other.txt\n" &
      "printf 'out/other.txt: other.sh\\n' > out/other.dep\n")
    setFilePermissions(otherScript, {fpUserRead, fpUserWrite, fpUserExec})
    let other = action("gc/other", [otherScript],
      cwd = f.workRoot,
      inputs = ["other.sh"],
      outputs = ["out/other.txt"],
      depfile = "out/other.dep",
      cacheable = true,
      weakFingerprint = weak("gc/other"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let pruned = runBuild(graph([other]), config)
    checkpoint("gc/other: status=" & $pruned.byId("gc/other").status &
      " reason=" & pruned.byId("gc/other").reason & " stderr=" &
      pruned.byId("gc/other").stderr)
    check pruned.byId("gc/other").status == asSucceeded
    check rootsUnder(p3, f.cacheRoot).len == 0
    check deleteSucceeds(p3)

  test "an output produced before the ledger existed is checked, not trusted":
    # The issue's own case: `ct` was linked weeks before anything recorded
    # what it names, and by the time an engine looks at it the libraries are
    # gone. The first engine to see such an output has no manifest to
    # compare with; it must not conclude "nothing recorded, nothing lost"
    # and report the output up to date.
    let f = makeFixture()
    var p: string
    defer:
      cleanupStorePath(p, f.cacheRoot)
      removeDir(f.root)
    let scratch = f.root / "store-src"
    createDir(scratch)
    let g = graph([f.action])
    let config = warmConfig(f.cacheRoot)
    p = addPrivateStorePath(scratch, "pre-ledger")
    f.setReference(p)
    check runBuild(g, config).byId("gc/link").launched
    check f.runCount == 1
    # Back to "before the ledger existed": no manifest, no index, no roots
    # (the links lived in the ledger, so Nix's auto-roots now dangle). The
    # action cache and the output are untouched, so every other arm still
    # calls the output up to date. Then the collection happens.
    removeDir(f.cacheRoot / "nix-gc-roots")
    check rootsUnder(p, f.cacheRoot).len == 0
    check deleteSucceeds(p)
    let detected = runBuild(g, config)
    checkpoint("trace after deleting the pre-ledger path:\n" &
      detected.dumpTrace())
    check detected.byId("gc/link").launched
    check detected.byId("gc/link").status == asSucceeded
    check f.runCount == 2
    check detected.traceMentions("gc/link", p)
    # Once re-executed it settles: the new output was PRODUCED naming the
    # absent path, which no re-execution can change.
    let settled = runBuild(g, config)
    check not settled.byId("gc/link").launched
    check f.runCount == 2

  test "the portable pre-pass does not serve an output whose store paths were collected":
    # The portable pre-pass resolves an action from its portable record and
    # completes it as a hit BEFORE the scheduler's decision chain runs, so
    # the detection rule has to hold there too. A restore could not help:
    # the record's bytes name the same collected path.
    let f = makeFixture()
    var p: string
    defer:
      cleanupStorePath(p, f.cacheRoot)
      removeDir(f.root)
    let scratch = f.root / "store-src"
    createDir(scratch)
    p = addPrivateStorePath(scratch, "portable")
    f.setReference(p)
    # A builtin writer: the portable record is recorded for it on this host
    # without any monitor, so the second build is served by the pre-pass.
    let writer = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText,
      id: "gc/portable",
      deps: @[],
      inputs: @[f.workRoot / "src" / "ref.txt"],
      outputs: @[f.workRoot / "out" / "portable.txt"],
      cwd: f.workRoot,
      cacheable: true,
      actionCachePolicy: ffpTimestamp,
      weakFingerprint: weak("gc/portable"),
      builtinText: "rpath=" & p & "/lib\n")
    let g = graph(@[writer], newSeq[BuildPool]())
    var config = warmConfig(f.cacheRoot)
    config.actionCacheRoot = f.root / "shared"
    config.portableRoots = @[
      LogicalRoot(label: "project", path: f.workRoot, kind: lrkTracked)]
    config.portableLookup = true

    let first = runBuild(g, config)
    check first.byId("gc/portable").launched
    check rootsUnder(p, f.cacheRoot).len > 0
    # The pre-pass really is the arm that answers a warm build here;
    # otherwise this case would be testing the scheduler again.
    let warm = runBuild(g, config)
    checkpoint("warm trace:\n" & warm.dumpTrace())
    check not warm.byId("gc/portable").launched
    require warm.traceHas("gc/portable", "portable-resolved")

    dropRootsUnder(p, f.cacheRoot)
    check deleteSucceeds(p)
    let detected = runBuild(g, config)
    checkpoint("trace after deleting p:\n" & detected.dumpTrace())
    check detected.byId("gc/portable").launched
    check detected.byId("gc/portable").status == asSucceeded
    check detected.traceMentions("gc/portable", p)
    check not detected.traceHas("gc/portable", "portable-resolved")

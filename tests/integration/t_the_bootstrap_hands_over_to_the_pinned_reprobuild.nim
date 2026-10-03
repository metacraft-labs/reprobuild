## M5 "pin the provider-compile toolchain", rules 1 and 3, end to end: the
## ENGINE, started as the bootstrap in a scratch project, hands over to the
## reprobuild the project's lock pins -- and does not in a project that pins
## nothing.
##
## WHAT IS REAL HERE. The bootstrap is `build/bin/reprobuild` from this
## checkout. The store is a real `repro_local_store` in a temp directory, the
## locks are written by `repro_lock`'s real writer and MO-11 lift (what
## `repro lock refresh` writes), and the pinned images are realized by the
## real `installSelfImage` / `installPinnedImage`.
##
## THE PINNED IMAGE, TWO WAYS.
##
##   * A COPY of this checkout's own `build/bin` tree (the thin client, the
##     engine and the DLLs beside them), registered under a version label the
##     bootstrap is not. Copied, not hardlinked, so the pinned engine is a
##     different FILE from the bootstrap and `sameFile` cannot recognize one
##     as the other. This is the hand-over into a real reprobuild: the pinned
##     engine starts, sees the same pin, recognizes itself, and runs.
##   * The M5 stub image (`tests/fixtures/selfhost/m5_stub_repro_image`),
##     whose `print-handover` arm prints its argv and the environment a
##     hand-over is specified to set. That verb is not a reprobuild verb, so
##     the bootstrap answering it itself would print a usage error: the stub's
##     lines appearing at all is the proof that the argv reached the pinned
##     image unchanged.
##
## THE PROPERTIES, EACH WITH THE DEFECT IT CATCHES:
##
##   1. In a project pinning another reprobuild, the bootstrap execs the
##      pinned prefix's `bin/repro` with the caller's argv and environment,
##      plus the marker and the pinned engine, and minus `REPRO_FULL_CLI`.
##      Catches the bootstrap evaluating a recipe it is not pinned to.
##   2. The real pinned engine recognizes itself and does not hand over
##      again. Catches a loop.
##   3. In an unpinned project the bootstrap does not hand over. Catches a
##      bootstrap that always execs something.
##   4. Version-equal: no hand-over.
##   5. A pinned version that is not resident is REFUSED (exit 70), never
##      run by the bootstrap instead.
##   6. A pinned provider compiler is handed to the pinned reprobuild in
##      `REPRO_NIM_COMPILER`, and when the bootstrap builds the project itself
##      the provider compile invokes THAT compiler.
##
## Test-double policy: no mocks. The one stub, and its reason, are above.

import std/[os, osproc, streams, strtabs, strutils, tables, tempfiles,
            unittest]

import repro_core/cli_images
import repro_lock
import repro_selfhost
import repro_selfhost/install as selfinstall

# Ambient-execution hatch: this test runs the engine binary it is testing and
# the images a committed lock decided on. `git grep uncontrolled` is the audit
# surface.
import repro_core/ambient_execution

const
  RepoMarker = "repro.nim"
  PinnedLabel = "0.0.1-m5-handover"
  StubLabel = "0.0.2-m5-stub"
  AbsentLabel = "0.0.9-m5-absent"
  PinnedNim = "2.2.10"

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

proc requireFile(path, remedy: string): string =
  ## A missing binary is a BUILD defect, not an environment limitation: it
  ## raises rather than skipping, so no assertion below can disappear on the
  ## tree where the binary stopped being built.
  if not fileExists(path):
    raise newException(IOError, path & " is missing. " & remedy)
  path

proc engineBinary(): string =
  requireFile(findRepoRoot() / "build" / "bin" / reprobuildEngineExeName(),
    "Build it with `just build` / scripts/build_apps.sh.")

proc thinClientBinary(): string =
  requireFile(findRepoRoot() / "build" / "bin" / selfExecutableName(),
    "Build it with `just build` / scripts/build_apps.sh.")

proc stubBinary(): string =
  requireFile(findRepoRoot() / "build" / "test-bin" /
    addFileExt("m5_stub_repro_image", ExeExt),
    "It is built by the `reprobuild.test_helpers.m5_stub_repro_image` edge " &
    "in repro.nim; run `repro build .#test-helpers`.")

proc lockFor(packages: openArray[(string, string, string)];
             platform: string): string =
  ## (name, version, source) -> a committed lock, via the real writer + lift.
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version, _) in packages:
    sol.packages[name] = version
  var ld = lockedDepsFromSolved(solutionToLock(sol, platform, ""))
  for i in 0 ..< ld.packages.len:
    for (name, _, source) in packages:
      if ld.packages[i].name == name:
        ld.packages[i].source = source
  ld.deps = lockedDepsFromPackages(ld.packages, platform)
  serializeLockedDependencies(ld)

proc makeExecutable(path: string) =
  when not defined(windows):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc copyOfCheckoutImage(dest: string): string =
  ## This checkout's `build/bin` image, COPIED: the thin client, the engine
  ## and every shared library beside them (the engine loads `sqlite3`,
  ## `clingo`, OpenSSL by leaf name from its own directory on Windows).
  let src = parentDir(engineBinary())
  discard thinClientBinary()
  createDir(dest / "bin")
  for kind, path in walkDir(src):
    if kind != pcFile:
      continue
    let name = lastPathPart(path)
    let keep = name == reprobuildEngineExeName() or
      name == selfExecutableName() or
      name.toLowerAscii.endsWith(".dll") or name.contains(".so") or
      name.endsWith(".dylib") or name == "cacert.pem"
    if keep:
      copyFile(path, dest / "bin" / name)
      makeExecutable(dest / "bin" / name)
  dest

proc stubImage(dest, label: string): string =
  createDir(dest / "bin")
  for name in [selfExecutableName(), reprobuildEngineExeName()]:
    copyFile(stubBinary(), dest / "bin" / name)
    makeExecutable(dest / "bin" / name)
  writeFile(dest / "VERSION", label & "\n")
  dest

proc fakeNimDistribution(dest: string): string =
  ## A Nim distribution tree whose `bin/nim` is the stub, so its invocations
  ## can be recorded, and whose `lib/system.nim` satisfies install-time
  ## validation.
  createDir(dest / "bin")
  createDir(dest / "lib")
  copyFile(stubBinary(), dest / "bin" / addFileExt("nim", ExeExt))
  makeExecutable(dest / "bin" / addFileExt("nim", ExeExt))
  writeFile(dest / "lib" / "system.nim", "# stand-in\n")
  writeFile(dest / "VERSION", "nim-" & PinnedNim & "\n")
  dest

proc drain(s: Stream): string =
  var chunk = newString(4096)
  while true:
    let n = s.readData(addr chunk[0], chunk.len)
    if n <= 0:
      break
    result.add(chunk[0 ..< n])

type Run = object
  code: int
  output: string
    ## stdout and stderr as ONE stream. Captured merged because draining
    ## stdout to EOF while the child blocks writing a full stderr pipe is a
    ## deadlock -- it was one, twice, on the first runs of this test, and the
    ## second time it was the FAILING case (a pre-change engine answering an
    ## unknown verb with a 10 KB usage text) that hung instead of failing.
    ## Narration is told apart by its prefix: every `REPRO_SELFHOST_DEBUG`
    ## line starts `repro(<version>):` and every refusal `repro: `.

proc runEngine(cwd, storeRoot: string; args: seq[string];
               extraEnv: openArray[(string, string)] = []): Run =
  ## The bootstrap, run in ``cwd`` against ``storeRoot``.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["REPRO_STORE_ROOT"] = storeRoot
  env["REPRO_SELFHOST_DEBUG"] = "1"
  env["M5_HANDOVER_PROBE"] = "probe value with spaces"
  # Set deliberately, to the BOOTSTRAP: a hand-over must replace both, or the
  # pinned thin client would hand straight back to the bootstrap engine.
  env["REPRO_FULL_CLI"] = engineBinary()
  env["REPRO_PUBLIC_CLI_PATH"] = engineBinary()
  for name in ["REPRO_SELFHOST_RESOLVED", "REPRO_NIM_COMPILER"]:
    if env.hasKey(name):
      env.del(name)
  for (k, v) in extraEnv:
    env[k] = v
  var p = uncontrolledStartProcess(engineBinary(), workingDir = cwd,
    args = args, env = env, options = {poStdErrToStdOut})
  try:
    result.output = drain(p.outputStream)
    result.code = p.waitForExit()
  finally:
    p.close()

proc textLines(s: string): seq[string] =
  for ln in s.replace("\r", "").splitLines:
    if ln.strip.len > 0:
      result.add(ln)

proc hasLine(s, want: string): bool =
  want in textLines(s)

proc isNarration(line: string): bool =
  line.startsWith("repro(") or line.startsWith("repro: ")

proc answerLines(s: string): seq[string] =
  ## The lines that are the COMMAND's answer, not the pin machinery's.
  for ln in textLines(s):
    if not ln.isNarration:
      result.add(ln)

proc bootstrapVersion(): string =
  ## The bootstrap's own version, as it reports it outside any project.
  let dir = createTempDir("repro-m5-noproject-", "")
  defer: removeDir(dir)
  let r = runEngine(dir, dir / "store", @["--version"])
  doAssert r.code == 0, r.output
  let words = answerLines(r.output)[0].splitWhitespace()
  words[^1]

type Scenario = object
  root, store, platform: string
  pinnedReal, pinnedStub, unpinned, absent: string

proc newScenario(): Scenario =
  result.root = createTempDir("repro-m5-handover-e2e-", "")
  result.store = result.root / "store"
  result.platform = currentPlatformId()
  createDir(result.store)
  result.pinnedReal = result.root / "pinned-real"
  result.pinnedStub = result.root / "pinned-stub"
  result.unpinned = result.root / "unpinned"
  result.absent = result.root / "pinned-absent"
  for d in [result.pinnedReal, result.pinnedStub, result.unpinned,
            result.absent]:
    createDir(d)
  writeFile(result.pinnedReal / "repro.lock",
    lockFor([("reprobuild", PinnedLabel, "store")], result.platform))
  writeFile(result.pinnedStub / "repro.lock",
    lockFor([("reprobuild", StubLabel, "store")], result.platform))
  writeFile(result.absent / "repro.lock",
    lockFor([("reprobuild", AbsentLabel, "store")], result.platform))
  writeFile(result.unpinned / "repro.lock",
    lockFor([("nim", "2.2.0", "nim"), ("reprobuild", "0.1.0", "reprobuild")],
      result.platform))
  discard selfinstall.installSelfImage(result.store, PinnedLabel,
    result.platform, copyOfCheckoutImage(result.root / "img-real"))
  discard selfinstall.installSelfImage(result.store, StubLabel,
    result.platform, stubImage(result.root / "img-stub", StubLabel))

proc prefixOf(s: Scenario; project: string): string =
  selfPrefixAbsolutePath(s.store, selfPinForProject(project))

suite "the bootstrap hands over to the reprobuild the lock pins":

  test "argv and environment reach the pinned image, with the marker":
    let s = newScenario()
    defer: removeDir(s.root)
    let prefix = s.prefixOf(s.pinnedStub)
    let r = runEngine(s.pinnedStub, s.store,
      @["print-handover", "a b", "--flag=x"])
    checkpoint("rc=" & $r.code & "\noutput=" & r.output)
    check r.code == 0
    check r.output.hasLine("stub-repro " & StubLabel & ": handed over")
    check r.output.hasLine("argv[0]=print-handover")
    check r.output.hasLine("argv[1]=a b")
    check r.output.hasLine("argv[2]=--flag=x")
    check r.output.hasLine("env M5_HANDOVER_PROBE=probe value with spaces")
    check r.output.hasLine("env REPRO_SELFHOST_RESOLVED=" &
      prefixIdHex(selfPrefixId(selfPinForProject(s.pinnedStub))))
    check r.output.hasLine("env REPRO_PUBLIC_CLI_PATH=" &
      (prefix / "bin" / reprobuildEngineExeName()))
    check r.output.hasLine("env REPRO_FULL_CLI=<unset>")
    check r.output.hasLine("env REPRO_NIM_COMPILER=<unset>")

  test "a real pinned reprobuild starts, recognizes itself, and runs":
    let s = newScenario()
    defer: removeDir(s.root)
    let prefix = s.prefixOf(s.pinnedReal)
    let pinnedEngine = prefix / "bin" / reprobuildEngineExeName()
    let r = runEngine(s.pinnedReal, s.store, @["--version"])
    checkpoint("rc=" & $r.code & "\noutput=" & r.output)
    check r.code == 0
    check answerLines(r.output).len == 1
    check answerLines(r.output)[0].startsWith("repro ")
    # The bootstrap handed over to the prefix...
    check r.output.contains("exec " & (prefix / "bin" /
      selfExecutableName()))
    # ...and the image that then decided was the pinned engine, which ran
    # rather than handing over again.
    check r.output.contains("running as the pinned image " &
      pinnedEngine)
    check r.output.count("): exec ") == 1

  test "an unpinned project does not hand over":
    let s = newScenario()
    defer: removeDir(s.root)
    let r = runEngine(s.unpinned, s.store, @["print-handover", "a b"])
    checkpoint("rc=" & $r.code & "\noutput=" & r.output)
    # The bootstrap answered the unknown verb itself.
    check r.code != 0
    check not r.output.contains("handed over")
    check not r.output.contains("): exec ")
    let v = runEngine(s.unpinned, s.store, @["--version"])
    check v.code == 0
    check not v.output.contains("): exec ")

  test "version-equal: the bootstrap does not hand over":
    let s = newScenario()
    defer: removeDir(s.root)
    let own = bootstrapVersion()
    let project = s.root / "pinned-equal"
    createDir(project)
    writeFile(project / "repro.lock",
      lockFor([("reprobuild", own, "store")], s.platform))
    discard selfinstall.installSelfImage(s.store, own, s.platform,
      stubImage(s.root / "img-equal", own))
    let r = runEngine(project, s.store, @["print-handover"])
    checkpoint("rc=" & $r.code & "\noutput=" & r.output)
    check not r.output.contains("handed over")
    check not r.output.contains("): exec ")
    check r.output.contains("this image's own version")

  test "a pinned version that is not resident is refused, not run here":
    let s = newScenario()
    defer: removeDir(s.root)
    let r = runEngine(s.absent, s.store, @["--version"])
    checkpoint("rc=" & $r.code & "\noutput=" & r.output)
    check r.code == 70
    check answerLines(r.output).len == 0
    check r.output.contains(AbsentLabel)
    check r.output.contains("does not evaluate a recipe it is not " &
      "pinned to")
    check r.output.contains("repro self install")

suite "the pinned provider compiler reaches the provider compile":

  test "the hand-over passes the pinned compiler to the pinned reprobuild":
    let s = newScenario()
    defer: removeDir(s.root)
    let project = s.root / "pinned-stub-nim"
    createDir(project)
    writeFile(project / "repro.lock", lockFor([
      ("reprobuild", StubLabel, "store"), ("nim", PinnedNim, "store")],
      s.platform))
    let nimRes = selfinstall.installPinnedImage(providerNimPin(), s.store,
      PinnedNim, s.platform, fakeNimDistribution(s.root / "nim-tree"))
    let r = runEngine(project, s.store, @["print-handover"])
    checkpoint("rc=" & $r.code & "\noutput=" & r.output)
    check r.code == 0
    check r.output.hasLine("env REPRO_NIM_COMPILER=" &
      nimRes.executablePath)

  test "a bootstrap building its own pinned project compiles with that Nim":
    ## No reprobuild pin (so no hand-over), a provider-compiler pin, and a
    ## real `repro build`. The compiler is the stub, which records every
    ## invocation: the provider compile invoking it is the observable. The
    ## build then fails, because the stub produces no provider -- that is
    ## expected and not what is asserted.
    let s = newScenario()
    defer: removeDir(s.root)
    let project = s.root / "nim-only"
    createDir(project)
    writeFile(project / "repro.nim",
      "import repro_project_dsl\n\npackage m5HandoverProbe:\n" &
      "  version \"0.0.1\"\n")
    writeFile(project / "repro.lock", lockFor([("nim", PinnedNim, "store")],
      s.platform))
    let nimRes = selfinstall.installPinnedImage(providerNimPin(), s.store,
      PinnedNim, s.platform, fakeNimDistribution(s.root / "nim-tree"))
    let record = s.root / "nim-invocations.txt"
    var extra = @[("M5_STUB_RECORD", record), ("REPROBUILD_NO_RUNQUOTA", "1"),
      ("REPROBUILD_PROGRESS", "quiet")]
    # The provider compile also needs a C compiler. Name the host's so the
    # bootstrap does not realize its pinned one into this temp store.
    let cc = findExe("gcc")
    if cc.len > 0:
      extra.add(("REPRO_BOOTSTRAP_CC", cc))
    let r = runEngine(project, s.store,
      @["build", "--no-runquota", "--daemon=off"], extra)
    checkpoint("rc=" & $r.code & "\noutput=" & r.output)
    check fileExists(record)
    let calls = if fileExists(record): textLines(readFile(record)) else: @[]
    checkpoint("nim invocations: " & $calls)
    var compiled = false
    for c in calls:
      let parts = c.split('\t')
      check parts[0] == nimRes.executablePath
      if parts.len > 1 and parts[1].startsWith("c "):
        compiled = true
    check compiled
    check r.output.contains("provider compiler " & nimRes.executablePath)

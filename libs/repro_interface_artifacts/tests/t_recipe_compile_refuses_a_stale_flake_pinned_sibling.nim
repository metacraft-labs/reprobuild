## A recipe compile of a reprobuild CHECKOUT refuses a workspace sibling that
## is stale against the revision the checkout's `flake.lock` pins, for the
## packages it resolves `$<PKG>_SRC` first (io-mon, runquota, ...) as well as
## for the sibling-first ones, and names the sibling, its HEAD and the pin.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "The sources a recipe compile
## reads" (amended 2026-11-22); Nix-Flake-Coexistence.md §3.2. Measured
## 2026-11-21: `repro exec` in the reprobuild checkout compiled the
## dev env's interface-extraction runner against an `io-mon` sibling at
## `5477f9f1` while `flake.lock` pins `b1c32599`, and failed with
## `action_index.nim(746, 16) Error: attempting to call undeclared routine:
## 'insertShardIndex'`, an error naming neither checkout. The stale check
## applied only to the five packages `config.nims` resolves sibling-first, and
## io-mon is not one of them. The fixture pins its siblings in `flake.lock`
## ONLY, so it also covers the pin lookup reading that file: a tree whose
## `.github/sibling-repos` does not repeat a flake pin is still judged.
##
## Fixture: a real reprobuild-shaped git checkout whose `flake.lock` (and NOT
## its `repro.lock`) pins `io-mon` and `runquota`; real `io-mon` and
## `runquota` sibling repositories with history on both sides of the pin; a
## "pinned tree" directory for `$IO_MON_SRC`. The flags come from the real
## `consumerCompilePathFlags`, the assembly the interface extraction and the
## provider compile use.
##
## Cases, and what the unfixed code does:
##   1. io-mon sibling behind the pin: refused, naming io-mon, its HEAD and
##      the pin (unfixed: the stale sibling, silently);
##   2. io-mon sibling at the pin, and ahead of it: that sibling, the only
##      io-mon root (unfixed: the same; the control for 1);
##   3. stale sibling, `$IO_MON_SRC` names a tree: that tree, the only root
##      (unfixed: the same; the caller's variable still comes first);
##   4. `REPRO_SIBLING_POLICY=sibling` with a stale sibling: the sibling
##      (unfixed: the same);
##   5. stale sibling carrying local changes: the sibling (work in progress;
##      unfixed: the same);
##   6. io-mon AND runquota stale: ONE refusal naming both (unfixed: both
##      stale siblings, silently).
##
## And for an SDK tree that is NOT a checkout (no `.git`: the store copy of
## the sources a packaged engine compiles recipes against), judged against
## the pins that tree carries:
##   7. it is the engine's OWN tree (named by the seeded
##      `$REPROBUILD_SOURCE_ROOT`, as the package's wrapper seeds it) and the
##      sibling is stale: the io-mon root the engine was BUILT with, the only
##      io-mon root, and a notice naming the sibling, its HEAD and the pin
##      (unfixed: the stale sibling, silently);
##   8. it is a foreign tree and the sibling is stale: refused (unfixed: the
##      stale sibling, silently);
##   9. the sibling is at or ahead of the pin: the sibling (unfixed: the
##      same; the control for 7 and 8).
##
## NO MOCKS: real git repositories and directories, the real flag assembly,
## the real seeding procedure (`seedSourcePackageEnvironment`, which a
## packaged engine's start-up runs). The one seam is
## `bootstrapSiblingPackagePathFlagsFor`, the resolver itself with its
## notices returned rather than printed, so case 7 can read the notice; its
## root is also checked through `consumerCompilePathFlags`. The io-mon root
## the engine was built with is THIS binary's build-time `$IO_MON_SRC`
## (`builtIoMon`): a real pinned tree, which the development shell exports.
## The process environment and working directory are mutated, so this binary
## runs on its own.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_test_support/reasoned_skip

const
  IoMonMarker = "io_mon.nim"
  RunquotaMarker = "runquota_core.nim"
  ClearedVariables = ["IO_MON_SRC", "RUNQUOTA_SRC", "REPRO_SIBLING_POLICY",
    "REPROBUILD_SOURCE_ROOT", "REPROBUILD_REPO_ROOT", "REPROBUILD_LIBS_DIR",
    SeededSourceEnvironmentVar]
  builtIoMonEnv = static(getEnv("IO_MON_SRC"))
    ## The io-mon tree this test binary -- and so the resolver in it -- was
    ## built with (`compileTimeSourceRoot`): the checkout root or its `src`.

proc builtIoMon(): string =
  ## The directory of that tree holding the marker, "" when there is none.
  if builtIoMonEnv.len > 0 and fileExists(builtIoMonEnv / IoMonMarker):
    builtIoMonEnv
  elif builtIoMonEnv.len > 0 and
      fileExists(builtIoMonEnv / "src" / IoMonMarker):
    builtIoMonEnv / "src"
  else: ""

proc sh(cmd: string; cwd: string) =
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint(cmd & " failed:\n" & res.output)
    raise newException(OSError, cmd & " failed: " & res.output)

proc gitOut(cmd: string; cwd: string): string =
  let res = execCmdEx("git " & cmd, workingDir = cwd)
  doAssert res.exitCode == 0, cmd & ": " & res.output
  res.output.strip()

proc initRepo(dir: string) =
  createDir(dir)
  sh("git init -q -b main", dir)
  sh("git config user.email tester@example.invalid", dir)
  sh("git config user.name Tester", dir)
  sh("git config commit.gpgsign false", dir)

proc commitFile(dir, rel, content, message: string): string =
  createDir(parentDir(dir / rel))
  writeFile(dir / rel, content)
  sh("git add -A", dir)
  sh("git commit -q -m " & quoteShell(message), dir)
  gitOut("rev-parse HEAD", dir)

proc rootsHolding(flags: seq[string]; marker: string): seq[string] =
  ## The distinct `--path` roots that hold ``marker``.
  for flag in flags:
    if flag.startsWith("--path:"):
      let dir = flag["--path:".len .. ^1]
      if fileExists(dir / marker) and dir notin result:
        result.add(dir)

type
  SiblingRepo = object
    dir: string
    base, pin, ahead, stale: string

  Fixture = object
    root, ws, reprobuild, pinnedTree: string
    ioMon, runquota: SiblingRepo

proc buildSibling(dir, marker: string): SiblingRepo =
  ## base -> pin -> ahead on main, and `stale` on a side branch off base,
  ## which neither is nor contains the pin. Left at the pin.
  result.dir = dir
  initRepo(dir)
  result.base = commitFile(dir, marker, "# base\n", "base")
  result.pin = commitFile(dir, marker, "# pin\n", "pin")
  result.ahead = commitFile(dir, marker, "# ahead\n", "ahead")
  sh("git checkout -q -b side " & result.base, dir)
  result.stale = commitFile(dir, marker, "# stale\n", "stale")
  sh("git checkout -q --detach " & result.pin, dir)

proc githubNode(repo, rev: string): string =
  "{ \"locked\": { \"lastModified\": 1, \"narHash\": \"sha256-x=\", " &
    "\"owner\": \"metacraft-labs\", \"repo\": \"" & repo & "\", \"rev\": \"" &
    rev & "\", \"type\": \"github\" }, \"original\": { \"owner\": " &
    "\"metacraft-labs\", \"repo\": \"" & repo & "\", \"type\": \"github\" } }"

proc buildFixture(sdkIsCheckout = true): Fixture =
  result.root = createTempDir("repro-flake-pinned-sibling-", "")
  result.ws = result.root / "ws"
  result.reprobuild = result.ws / "reprobuild"
  result.pinnedTree = result.root / "pinned-io-mon"
  result.ioMon = buildSibling(result.ws / "io-mon", "src" / IoMonMarker)
  result.runquota = buildSibling(result.ws / "runquota",
    "libs" / "runquota_core" / "src" / RunquotaMarker)
  createDir(result.pinnedTree / "src")
  writeFile(result.pinnedTree / "src" / IoMonMarker, "# pinned tree\n")
  # The reprobuild checkout: the DSL marker that makes it a reprobuild tree,
  # a repro.lock that pins NEITHER sibling, and a flake.lock that pins both
  # through direct inputs named, as reprobuild's are, `<repo>-src`.
  createDir(result.reprobuild / "libs" / "repro_project_dsl" / "src")
  writeFile(result.reprobuild / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim", "")
  writeFile(result.reprobuild / "repro.lock",
    "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\ndeps = []\n")
  writeFile(result.reprobuild / "flake.lock",
    "{\n  \"nodes\": {\n" &
    "    \"io-mon-src\": " & githubNode("io-mon", result.ioMon.pin) & ",\n" &
    "    \"runquota-src\": " & githubNode("runquota", result.runquota.pin) &
    ",\n    \"root\": { \"inputs\": { \"io-mon-src\": \"io-mon-src\", " &
    "\"runquota-src\": \"runquota-src\" } }\n  },\n  \"root\": \"root\",\n" &
    "  \"version\": 7\n}\n")
  if sdkIsCheckout:
    initRepo(result.reprobuild)
    discard commitFile(result.reprobuild, "README", "fixture\n", "seed")

proc checkout(repo: SiblingRepo; rev: string) =
  sh("git checkout -q --detach " & rev, repo.dir)

proc flagsFor(fx: Fixture): seq[string] =
  ## The real flag assembly for the checkout. The working directory anchors
  ## one of the sibling candidates; it is kept inside the fixture so no
  ## checkout of the host workspace can answer.
  setCurrentDir(fx.reprobuild)
  consumerCompilePathFlags(fx.reprobuild)

proc refusalFor(fx: Fixture): tuple[message: string; flags: seq[string]] =
  try:
    result.flags = fx.flagsFor()
  except SiblingSourceUnavailableError as err:
    result.message = err.msg

suite "a recipe compile refuses a stale flake-pinned sibling":
  var fx: Fixture
  var savedDir: string
  var saved: seq[(string, string)]

  setup:
    savedDir = getCurrentDir()
    saved = @[]
    for name in ClearedVariables:
      if existsEnv(name): saved.add((name, getEnv(name)))
      delEnv(name)
    clearSeededSourcePackageEnvironment()

  teardown:
    for name in ClearedVariables: delEnv(name)
    for (name, value) in saved: putEnv(name, value)
    setCurrentDir(savedDir)
    removeDir(fx.root)

  test "a sibling behind the flake.lock pin is refused, naming it":
    fx = buildFixture()
    fx.ioMon.checkout(fx.ioMon.stale)
    let (message, flags) = fx.refusalFor()
    checkpoint("roots: " & $rootsHolding(flags, IoMonMarker))
    checkpoint("refusal: " & message)
    check message.len > 0
    check message.contains("io-mon")
    check message.contains(fx.ioMon.pin)
    check message.contains(fx.ioMon.stale[0 ..< 12])
    check message.contains("IO_MON_SRC")
    check message.contains("REPRO_SIBLING_POLICY=sibling")
    # runquota is at its pin: not named.
    check not message.contains(fx.runquota.pin)

  test "a sibling at or ahead of the pin is the only root":
    fx = buildFixture()
    for rev in [fx.ioMon.pin, fx.ioMon.ahead]:
      fx.ioMon.checkout(rev)
      let roots = rootsHolding(fx.flagsFor(), IoMonMarker)
      checkpoint("at " & rev & " roots: " & $roots)
      check roots == @[fx.ioMon.dir / "src"]

  test "a stale sibling yields to the tree the caller names":
    fx = buildFixture()
    fx.ioMon.checkout(fx.ioMon.stale)
    putEnv("IO_MON_SRC", fx.pinnedTree / "src")
    let roots = rootsHolding(fx.flagsFor(), IoMonMarker)
    checkpoint("roots: " & $roots)
    check roots == @[fx.pinnedTree / "src"]

  test "REPRO_SIBLING_POLICY=sibling compiles the stale sibling":
    fx = buildFixture()
    fx.ioMon.checkout(fx.ioMon.stale)
    fx.runquota.checkout(fx.runquota.stale)
    putEnv("REPRO_SIBLING_POLICY", "sibling")
    let flags = fx.flagsFor()
    check rootsHolding(flags, IoMonMarker) == @[fx.ioMon.dir / "src"]
    check ("--path:" & fx.runquota.dir / "libs" / "runquota_core" / "src") in
      flags

  test "a stale sibling with local changes is work in progress":
    fx = buildFixture()
    fx.ioMon.checkout(fx.ioMon.stale)
    writeFile(fx.ioMon.dir / "src" / IoMonMarker, "# edited\n")
    let roots = rootsHolding(fx.flagsFor(), IoMonMarker)
    checkpoint("roots: " & $roots)
    check roots == @[fx.ioMon.dir / "src"]

  test "the engine's own non-checkout tree uses its built root, and says so":
    if builtIoMon().len == 0:
      skip("this binary was built without a $IO_MON_SRC holding " &
        IoMonMarker & " (build it in the development shell, which exports it)")
    else:
      fx = buildFixture(sdkIsCheckout = false)
      fx.ioMon.checkout(fx.ioMon.stale)
      # The package's wrapper names its own source tree this way.
      seedSourcePackageEnvironment([("REPROBUILD_SOURCE_ROOT", fx.reprobuild)])
      let roots = rootsHolding(fx.flagsFor(), IoMonMarker)
      checkpoint("roots: " & $roots)
      check roots == @[builtIoMon()]
      setCurrentDir(fx.reprobuild)
      let resolved = bootstrapSiblingPackagePathFlagsFor(fx.reprobuild,
        fx.ws, runningEngineSourceIdentity())
      check rootsHolding(resolved.flags, IoMonMarker) == @[builtIoMon()]
      checkpoint("notices: " & $resolved.notices)
      check resolved.notices.len == 1
      if resolved.notices.len == 1:
        let notice = resolved.notices[0]
        check notice.contains(fx.ioMon.dir)
        check notice.contains(fx.ioMon.stale[0 ..< 12])
        check notice.contains(fx.ioMon.pin)
        check notice.contains(builtIoMon())
        check notice.contains("REPRO_SIBLING_POLICY=sibling")

  test "a foreign non-checkout tree refuses a stale sibling":
    fx = buildFixture(sdkIsCheckout = false)
    fx.ioMon.checkout(fx.ioMon.stale)
    let (message, flags) = fx.refusalFor()
    checkpoint("roots: " & $rootsHolding(flags, IoMonMarker))
    checkpoint("refusal: " & message)
    check message.contains("io-mon")
    check message.contains(fx.ioMon.pin)
    check message.contains("IO_MON_SRC")

  test "a non-checkout tree keeps a sibling at or ahead of its pin":
    fx = buildFixture(sdkIsCheckout = false)
    seedSourcePackageEnvironment([("REPROBUILD_SOURCE_ROOT", fx.reprobuild)])
    for rev in [fx.ioMon.pin, fx.ioMon.ahead]:
      fx.ioMon.checkout(rev)
      let roots = rootsHolding(fx.flagsFor(), IoMonMarker)
      checkpoint("at " & rev & " roots: " & $roots)
      check roots == @[fx.ioMon.dir / "src"]

  test "every stale sibling is named in one refusal":
    fx = buildFixture()
    fx.ioMon.checkout(fx.ioMon.stale)
    fx.runquota.checkout(fx.runquota.stale)
    let (message, flags) = fx.refusalFor()
    checkpoint("runquota roots: " & $rootsHolding(flags, RunquotaMarker))
    checkpoint("refusal: " & message)
    check message.contains(fx.ioMon.pin)
    check message.contains("runquota")
    check message.contains(fx.runquota.pin)
    check message.contains("RUNQUOTA_SRC")

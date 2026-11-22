## A recipe compile of a reprobuild CHECKOUT reads each sibling-first package
## from exactly one root, chosen by the sibling-source policy `config.nims`
## applies, and never from the tree compiled into the engine when nothing
## shows that tree to be the pin.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "The sources a recipe compile
## reads" (amended 2026-11-22). Observed 2026-11-22: the pre-push gate's interface extract compiled reprobuild's recipe against
## a `nim-shm-gset` other than the one `just lint` used —
##
##   * with the `*_SRC` variables unset, the engine's own snapshot of
##     `shm_gset` (seeded from its build) was put on `--path` beside the
##     checkout, and later, so it shadowed the checkout even when the checkout
##     was AT the pin (`Error: attempting to call undeclared routine:
##     'insertShardIndex'`);
##   * `REPRO_SIBLING_POLICY` was not consulted at all.
##
## Fixture: a real reprobuild-shaped checkout (git, a `repro.lock` pinning
## `nim-shm-gset`), a real `nim-shm-gset` sibling repository with history on
## both sides of the pin, a "pinned tree" directory for `$SHM_GSET_SRC`, and
## an "engine snapshot" seeded through the real `seedSourcePackageEnvironment`
## — the state a packaged `repro` run outside the dev shell is in. The flags
## come from the real `consumerCompilePathFlags`, the same assembly the
## interface extraction and the provider compile use.
##
## Cases, and what the unfixed code does:
##   1. sibling AT the pin, nothing exported: exactly one root, the sibling
##      (unfixed: the sibling AND the seeded snapshot);
##   2. sibling stale against the pin, nothing exported: refused, naming the
##      sibling and the pin (unfixed: the stale sibling and the snapshot);
##   3. sibling stale, `$SHM_GSET_SRC` names the pinned tree: that tree only
##      (unfixed: the same — the control for case 2);
##   4. `REPRO_SIBLING_POLICY=sibling` with a stale sibling and a pinned tree
##      named: the sibling only (unfixed: the pinned tree — the policy was
##      ignored); `REPRO_SIBLING_POLICY=pin` with a sibling AHEAD of the pin:
##      the pinned tree only;
##   5. no sibling, nothing exported: refused, naming the pin (unfixed: the
##      engine snapshot);
##   6. control: the same as 5 but the SDK is not a checkout (no `.git`, as a
##      store snapshot or an installed SDK): the snapshot is still used.
##
## NO MOCKS: real git repositories and directories, the real seeding
## procedure, the real flag assembly. The process environment and working
## directory are mutated, so this binary runs on its own.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts

const ShmGsetMarker = "shm_gset.nim"

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

proc shmGsetRoots(flags: seq[string]): seq[string] =
  ## The distinct `--path` roots that provide `shm_gset`.
  for flag in flags:
    if flag.startsWith("--path:"):
      let dir = flag["--path:".len .. ^1]
      if fileExists(dir / ShmGsetMarker) and dir notin result:
        result.add(dir)

type Fixture = object
  root, ws, reprobuild, sibling, pinnedTree, snapshot: string
  base, pin, ahead, stale: string

proc buildFixture(sdkIsCheckout = true): Fixture =
  result.root = createTempDir("repro-sibling-policy-", "")
  result.ws = result.root / "ws"
  result.reprobuild = result.ws / "reprobuild"
  result.sibling = result.ws / "nim-shm-gset"
  result.pinnedTree = result.root / "pinned-gset"
  result.snapshot = result.root / "engine-snapshot"
  # The sibling: base -> pin -> ahead on main, and `stale` on a side branch
  # off base, which neither is nor contains the pin.
  initRepo(result.sibling)
  result.base = commitFile(result.sibling, "src" / ShmGsetMarker, "# base\n",
    "base")
  result.pin = commitFile(result.sibling, "src" / ShmGsetMarker, "# pin\n",
    "pin")
  result.ahead = commitFile(result.sibling, "src" / ShmGsetMarker,
    "# ahead\n", "ahead")
  sh("git checkout -q -b side " & result.base, result.sibling)
  result.stale = commitFile(result.sibling, "src" / ShmGsetMarker,
    "# stale\n", "stale")
  sh("git checkout -q main", result.sibling)
  # The pinned tree and the engine snapshot: two other copies of the package.
  createDir(result.pinnedTree / "src")
  writeFile(result.pinnedTree / "src" / ShmGsetMarker, "# pinned tree\n")
  createDir(result.snapshot / "src")
  writeFile(result.snapshot / "src" / ShmGsetMarker, "# engine snapshot\n")
  # The reprobuild checkout: the DSL marker that makes it a reprobuild tree,
  # and a committed repro.lock pinning the sibling.
  createDir(result.reprobuild)
  createDir(result.reprobuild / "libs" / "repro_project_dsl" / "src")
  writeFile(result.reprobuild / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim", "")
  writeFile(result.reprobuild / "repro.lock",
    "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
    "deps = [{ name = \"nim-shm-gset\", coord_kind = \"vcs\", url = " &
    "\"https://example.invalid/nim-shm-gset\", revision = \"" & result.pin &
    "\" }]\n")
  if sdkIsCheckout:
    initRepo(result.reprobuild)
    discard commitFile(result.reprobuild, "README", "fixture\n", "seed")

proc checkoutSibling(fx: Fixture; rev: string) =
  sh("git checkout -q --detach " & rev, fx.sibling)

proc resetEnvironment() =
  clearSeededSourcePackageEnvironment()
  delEnv("SHM_GSET_SRC")
  delEnv(SeededSourceEnvironmentVar)
  delEnv("REPRO_SIBLING_POLICY")

proc flagsFor(fx: Fixture): seq[string] =
  ## The real flag assembly for the checkout. The working directory anchors
  ## one of the sibling candidates; it is kept inside the fixture so no
  ## checkout of the host workspace can answer.
  setCurrentDir(fx.reprobuild)
  consumerCompilePathFlags(fx.reprobuild)

proc seedSnapshot(fx: Fixture) =
  ## The engine snapshot, seeded as a packaged `repro` seeds its build's roots.
  seedSourcePackageEnvironment([("SHM_GSET_SRC", fx.snapshot / "src")])
  doAssert getEnv("SHM_GSET_SRC") == fx.snapshot / "src"

suite "recipe compile sources follow the sibling policy":
  var fx: Fixture
  var savedDir, savedGset, savedPolicy: string
  var hadGset, hadPolicy: bool

  setup:
    savedDir = getCurrentDir()
    hadGset = existsEnv("SHM_GSET_SRC")
    savedGset = getEnv("SHM_GSET_SRC")
    hadPolicy = existsEnv("REPRO_SIBLING_POLICY")
    savedPolicy = getEnv("REPRO_SIBLING_POLICY")
    resetEnvironment()

  teardown:
    resetEnvironment()
    if hadGset: putEnv("SHM_GSET_SRC", savedGset)
    if hadPolicy: putEnv("REPRO_SIBLING_POLICY", savedPolicy)
    setCurrentDir(savedDir)
    removeDir(fx.root)

  test "a sibling at the pin is the only root, beside a seeded snapshot":
    fx = buildFixture()
    fx.checkoutSibling(fx.pin)
    fx.seedSnapshot()
    let roots = shmGsetRoots(fx.flagsFor())
    checkpoint("roots: " & $roots)
    check roots == @[fx.sibling / "src"]

  test "a stale sibling with no pinned tree is refused, naming the pin":
    fx = buildFixture()
    fx.checkoutSibling(fx.stale)
    fx.seedSnapshot()
    var message = ""
    try:
      checkpoint("roots: " & $shmGsetRoots(fx.flagsFor()))
    except SiblingSourceUnavailableError as err:
      message = err.msg
    checkpoint("refusal: " & message)
    check message.len > 0
    check message.contains("nim-shm-gset")
    check message.contains(fx.pin)
    check message.contains("SHM_GSET_SRC")

  test "a stale sibling yields to the pinned tree the caller names":
    fx = buildFixture()
    fx.checkoutSibling(fx.stale)
    putEnv("SHM_GSET_SRC", fx.pinnedTree / "src")
    let roots = shmGsetRoots(fx.flagsFor())
    checkpoint("roots: " & $roots)
    check roots == @[fx.pinnedTree / "src"]

  test "REPRO_SIBLING_POLICY forces either choice":
    fx = buildFixture()
    fx.checkoutSibling(fx.stale)
    putEnv("SHM_GSET_SRC", fx.pinnedTree / "src")
    putEnv("REPRO_SIBLING_POLICY", "sibling")
    let forcedSibling = shmGsetRoots(fx.flagsFor())
    checkpoint("policy=sibling roots: " & $forcedSibling)
    check forcedSibling == @[fx.sibling / "src"]
    fx.checkoutSibling(fx.ahead)
    putEnv("REPRO_SIBLING_POLICY", "pin")
    let forcedPin = shmGsetRoots(fx.flagsFor())
    checkpoint("policy=pin roots: " & $forcedPin)
    check forcedPin == @[fx.pinnedTree / "src"]

  test "with no sibling, the engine snapshot is refused, not compiled":
    fx = buildFixture()
    removeDir(fx.sibling)
    fx.seedSnapshot()
    var message = ""
    var roots: seq[string]
    try:
      roots = shmGsetRoots(fx.flagsFor())
    except SiblingSourceUnavailableError as err:
      message = err.msg
    checkpoint("roots: " & $roots & "; refusal: " & message)
    check message.contains(fx.pin)
    check message.contains(fx.snapshot / "src")
    check (fx.snapshot / "src") notin roots

  test "control: an SDK that is not a checkout still uses the snapshot":
    fx = buildFixture(sdkIsCheckout = false)
    removeDir(fx.sibling)
    fx.seedSnapshot()
    let roots = shmGsetRoots(fx.flagsFor())
    checkpoint("roots: " & $roots)
    check roots == @[fx.snapshot / "src"]

## A Nix tool realization recorded in the project's tool store has a GC root
## of its own.
##
## The defect (reprobuild-pm issue 2026-10-02, addendum 2026-10-03):
## `resolveNixTool` realizes a tool with `nix build --no-link` (through the
## `reprobuild-nix-daemon` helper, or directly as a fallback) and records the
## realized path in `<tool-store>/prefixes/…/nix-store-path.txt` and in the
## nix materialization cache. `--no-link` registers NO root, so the recorded
## path stays alive only while something else — usually the dev-shell profile,
## at whatever version IT resolved — happens to name the same path. When the
## two drift, a garbage collection deletes the recorded tool and the record
## survives it.
##
## The root follows the CURRENT realization of a tool request: when a pin
## bump re-realizes the same package and executable, the new path is rooted
## and the superseded one is released, so the tool store does not keep every
## realization a project ever used alive.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED. The
## tool is realized by the real `reprobuild-nix-daemon` helper running the
## host's real `nix build` over the repository's local fixture flake
## (`tests/fixtures/nix-daemon-local-flake`, the same fixture
## `t_nix_daemon_provisioner.nim` uses), and every liveness claim is asked of
## the real store with the real `nix-store` CLI. A fake helper or a fake
## `nix-store` could only report what the client believes it registered.
##
## A FRESH, PRIVATE OUTPUT. The fixture is copied and its one line of shell
## text is made unique to this process before it is built, so the realized
## output is a store path nothing else on the host has ever referenced or
## rooted. That is what makes "it has a root under the tool store" mean "the
## provisioner rooted it" rather than "some other checkout's profile happens
## to hold the same path". The private output is deleted again at the end
## with `nix-store --delete` (never a garbage collection, never
## `--ignore-liveness`).

import std/[os, osproc, strutils, tempfiles, times, unittest]
import repro_build_engine
import repro_interface_artifacts
import repro_tool_profiles

const RepoMarker = "repro.nim"
const FixtureRelRoot = "tests/fixtures/nix-daemon-local-flake"
const FixtureSelector = ".#hello-sh"
const FixtureExecutable = "bin/reprobuild-nix-daemon-fixture"
const FixtureText = "printf '%s\\n' reprobuild-nix-daemon-fixture"

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

proc findNixDaemon(repoRoot: string): string =
  for candidate in [
    getEnv("REPROBUILD_NIX_DAEMON_BIN"),
    repoRoot / "build" / "bin" / "reprobuild-nix-daemon",
    repoRoot / "tools" / "reprobuild-nix-daemon" / "reprobuild-nix-daemon"
  ]:
    if candidate.len > 0 and fileExists(candidate):
      return candidate
  raise newException(IOError,
    "reprobuild-nix-daemon missing; set REPROBUILD_NIX_DAEMON_BIN")

proc nixStoreExe(): string =
  ## `followSymlinks = false`: `nix-store` is a symlink to the multi-call
  ## `nix`, which dispatches on `argv[0]`.
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

proc rootLinksOf(storePath: string): seq[string] =
  let res = nixStore(["--query", "--roots", storePath])
  for line in res.output.splitLines():
    let arrow = line.find(" -> ")
    if arrow > 0 and line[arrow + 4 .. ^1].strip() == storePath:
      result.add(line[0 ..< arrow].strip())

proc canonical(path: string): string =
  try: expandFilename(path) except OSError: path

proc rootsUnder(storePath, dir: string): seq[string] =
  let b = canonical(dir)
  for root in rootLinksOf(storePath):
    if root.startsWith(dir & "/") or root.startsWith(b & "/") or
        canonical(root).startsWith(b & "/"):
      result.add(root)

proc preparePrivateFixture(repoRoot, tag: string): string =
  ## The fixture flake, with its shell text made unique so the derivation —
  ## and therefore the realized output — is private to this run.
  let sourceRoot = repoRoot / FixtureRelRoot
  result = createTempDir("repro-nix-tool-gc-root-", "")
  let flake = readFile(sourceRoot / "flake.nix")
  doAssert FixtureText in flake,
    "fixture flake no longer carries the line this test makes unique"
  writeFile(result / "flake.nix", flake.replace(FixtureText,
    "printf '%s\\n' reprobuild-gc-root-probe-" & tag))
  copyFile(sourceRoot / "flake.lock", result / "flake.lock")
  for args in ["init -q", "add flake.nix flake.lock"]:
    let (output, code) = execCmdEx("git -C " & quoteShell(result) & " " & args)
    doAssert code == 0, "failed to prepare fixture git index: " & output

suite "Nix tool realizations are GC-rooted under the tool store":

  test "resolveNixTool roots what it records, and restores a lost root on reuse":
    let repoRoot = findRepoRoot()
    let tag = $getCurrentProcessId() & "-" & $int64(epochTime() * 1000)
    let fixtureRoot = preparePrivateFixture(repoRoot, tag)
    let storeRoot = createTempDir("repro-nix-tool-store-", "")
    let previousDir = getCurrentDir()
    let previousDaemonBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
    let previousUser = getEnv("USER")
    let daemonPath = findNixDaemon(repoRoot)
    putEnv("REPROBUILD_NIX_DAEMON_BIN", daemonPath)
    # A private helper (its socket is keyed by user and helper identity), so
    # no other test's helper — or its response cache — answers this request.
    putEnv("USER", "repro-nix-tool-gc-root-" & $getCurrentProcessId())
    let socketPath = nixDaemonSocketPath(nixDaemonHelperKey(daemonPath))
    var realized = ""
    var bumpedRoot = ""
    var bumped = ""
    defer:
      setCurrentDir(previousDir)
      discard execCmd("pkill -f -u " & quoteShell(previousUser) & " " &
        quoteShell(socketPath) & " || true")
      putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemonBin)
      putEnv("USER", previousUser)
      removeDir(storeRoot)
      removeDir(fixtureRoot)
      if bumpedRoot.len > 0:
        removeDir(bumpedRoot)
      for path in [realized, bumped]:
        if path.len > 0 and dirExists(path):
          discard nixStore(["--delete", path])

    # `resolveNixTool` resolves `.#…` against the working directory, the way
    # a project's own `repro` invocation does.
    setCurrentDir(fixtureRoot)
    var useDef = InterfaceToolUse(
      rawConstraint: "gc-root-fixture",
      packageSelector: "gc-root-fixture@1.0.0",
      executableName: "reprobuild-nix-daemon-fixture",
      location: SourceLocation(file: "fixture", line: 1))
    useDef.nixProvisioning = @[InterfaceNixProvisioning(
      packageName: "gc-root-fixture",
      selector: FixtureSelector,
      executablePath: FixtureExecutable,
      packageId: "gc-root-fixture.1.0.0",
      lockIdentity: "fixture#gc-root-" & tag,
      location: SourceLocation(file: "fixture", line: 2))]

    let profile = resolveNixTool(useDef, storeRoot)
    realized = profile.selectedStorePath
    checkpoint("realized: " & realized)
    checkpoint("roots: " & $rootLinksOf(realized))
    check realized.startsWith("/nix/store/")
    check fileExists(profile.resolvedExecutablePath)
    # The record that outlives a collection exists...
    var recorded = false
    for path in walkDirRec(storeRoot):
      if path.extractFilename == "nix-store-path.txt" and
          readFile(path).strip() == realized:
        recorded = true
    check recorded
    # ...and so does the root that stops the collection. Against the unfixed
    # provisioner this list is empty: `--no-link` left nothing behind.
    let gcRootsDir = storeRoot / "nix-gc-roots"
    check rootsUnder(realized, gcRootsDir).len > 0
    let refused = nixStore(["--delete", realized])
    checkpoint("nix-store --delete -> " & $refused.code & "\n" & refused.output)
    check refused.code != 0
    check dirExists(realized)

    # The cached-materialization reuse path. The root is lost (removed by
    # hand here; an older engine never wrote one); the cached record is
    # still valid because the path still exists. Reusing it must put the
    # root back rather than serve the record unprotected.
    for root in rootsUnder(realized, gcRootsDir):
      removeFile(root)
    check rootsUnder(realized, gcRootsDir).len == 0
    let reused = resolveNixTool(useDef, storeRoot)
    check reused.selectedStorePath == realized
    check rootsUnder(realized, gcRootsDir).len > 0

    # A nixpkgs bump: the SAME tool request (package and executable) is
    # realized from a different pin and so names a different store path.
    # The new realization must be rooted, and the superseded one must stop
    # being held by the tool store — otherwise every bump leaves another
    # realization rooted for good. The second fixture differs only in its
    # private text, so its output is a second private path.
    bumpedRoot = preparePrivateFixture(repoRoot, tag & "-bumped")
    setCurrentDir(bumpedRoot)
    var bumpedUse = useDef
    bumpedUse.nixProvisioning[0].lockIdentity = "fixture#gc-root-" & tag &
      "-bumped"
    let next = resolveNixTool(bumpedUse, storeRoot)
    bumped = next.selectedStorePath
    checkpoint("bumped realization: " & bumped)
    require bumped.startsWith("/nix/store/")
    require bumped != realized
    check rootsUnder(bumped, gcRootsDir).len > 0
    check rootsUnder(realized, gcRootsDir).len == 0
    var rootDirs = 0
    for kind, _ in walkDir(gcRootsDir):
      if kind == pcDir:
        inc rootDirs
    check rootDirs == 1
    # Nothing else on the host can hold the private superseded output, so
    # Nix now lets it go, while it still refuses the current one.
    let released = nixStore(["--delete", realized])
    checkpoint("nix-store --delete superseded -> " & $released.code & "\n" &
      released.output)
    check released.code == 0
    check not dirExists(realized)
    check nixStore(["--delete", bumped]).code != 0
    check dirExists(bumped)

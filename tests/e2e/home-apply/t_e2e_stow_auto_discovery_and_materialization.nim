## M63 gate 5: `e2e_stow_auto_discovery_and_materialization`.
##
## Drives the public `repro home apply` CLI against fixture profiles
## that contain a `stow/` subtree but no `activity` body. Verifies:
##
##   * `~/.gitconfig` and `~/.config/foo/bar.toml` are created as
##     symlinks to the corresponding `stow/` source files.
##   * The activation manifest records each as a `GeneratedFile` with
##     `ownershipPolicy = stow-symlink` and the correct `stowSource`.
##   * Editing through the symlink reflects immediately (read after
##     write through the link returns the new bytes).
##   * A no-op re-apply is a cache hit (exit 0, "no-op" log line).
##
## Two Windows fallback variants:
##
##   * REPRO_TEST_STOW_DISABLE_SYMLINK=1 forces symlink creation to
##     fail. The planner falls back to a junction at the deepest
##     stow-exclusive ancestor (the `.config` directory in this
##     fixture). The manifest records `ownershipPolicy = stow-junction`
##     and `IStowFellBack` is emitted once.
##   * REPRO_TEST_STOW_DISABLE_SYMLINK=1 + DISABLE_JUNCTION=1 forces
##     the copy fallback. `ownershipPolicy = stow-copy`,
##     `IStowFellBack` emitted once.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-apply" / "stow_basic"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate)
  candidate

proc copyTree(src, dst: string) =
  createDir(dst)
  for kind, entry in walkDir(src, relative = true):
    let leaf = entry
    let from0 = src / leaf
    let to0 = dst / leaf
    case kind
    of pcFile:
      createDir(parentDir(to0))
      copyFile(from0, to0)
    of pcDir:
      copyTree(from0, to0)
    else: discard

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(reproBinary(), args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0: break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, output: combined)

proc setupFixture(tempRoot: string;
                  extraEnv: seq[tuple[k, v: string]] = @[]):
    tuple[stateDir, storeRoot, homeDir, profileDir: string;
          baseEnv: seq[tuple[k, v: string]]] =
  result.stateDir = tempRoot / "state"
  result.storeRoot = tempRoot / "store"
  result.homeDir = tempRoot / "home"
  result.profileDir = tempRoot / "profile"
  createDir(result.stateDir)
  createDir(result.storeRoot)
  createDir(result.homeDir)
  copyTree(FixtureSrc, result.profileDir)
  result.baseEnv = @[
    (k: "REPRO_HOME_PROFILE_DIR", v: result.profileDir),
    (k: "REPRO_HOME_STATE_DIR", v: result.stateDir),
    (k: "REPRO_STORE_ROOT", v: result.storeRoot),
    (k: "HOME", v: result.homeDir),
    (k: "USERPROFILE", v: result.homeDir),
    (k: "REPRO_HOST", v: "stow-host"),
    (k: "REPRO_HOME_PACKAGE_CATALOG", v: "")]
  for kv in extraEnv:
    result.baseEnv.add kv

proc loadManifestEntries(stateDir, storeRoot: string):
    seq[GeneratedFile] =
  let activeId = readCurrentGenerationId(stateDir)
  let env = readPointerFile(pointerPath(stateDir, activeId))
  var store = openStore(storeRoot)
  defer: store.close()
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.activationManifestDigest[i]
  let manifest = decodeManifestBytes(readCasBlob(store, key))
  manifest.generatedFiles

suite "M63 gate 5: e2e_stow_auto_discovery_and_materialization":
  test "symlink materialization (default path)":
    let tempRoot = createTempDir("repro-m63-stow-symlink-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let fixture = setupFixture(tempRoot)
    let res = runRepro(fixture.baseEnv, ["home", "apply"])
    check res.exitCode == 0
    check res.output.contains("applied generation ")
    # Targets exist as symlinks (or junctions on systems without
    # developer mode; either way both spec policies — stow-symlink and
    # stow-junction — assert the file is reachable).
    check fileExists(fixture.homeDir / ".gitconfig") or
          symlinkExists(fixture.homeDir / ".gitconfig")
    check fileExists(fixture.homeDir / ".config" / "foo" / "bar.toml") or
          symlinkExists(fixture.homeDir / ".config" / "foo" / "bar.toml")
    let files = loadManifestEntries(fixture.stateDir, fixture.storeRoot)
    check files.len == 2
    var sawGit, sawBar = false
    for f in files:
      if f.absoluteOutputPath.endsWith(".gitconfig"):
        sawGit = true
        # Spec: on a developer-mode-on Windows host (and on Linux/macOS
        # where the symlink syscall is universal) the default policy is
        # stow-symlink. If symlink creation fails on the dev host, the
        # gate SHOULD fail loud — that is a real environment problem,
        # not a fixture issue.
        check f.ownershipPolicy == gfoStowSymlink
        check f.stowSource.endsWith(".gitconfig")
      if f.absoluteOutputPath.endsWith("bar.toml"):
        sawBar = true
        check f.ownershipPolicy == gfoStowSymlink
        check f.stowSource.endsWith("bar.toml")
    check sawGit
    check sawBar

    # Editing through the symlink reflects immediately when symlink
    # mode was selected (only assert when the policy IS stow-symlink).
    var anySymlink = false
    for f in files:
      if f.ownershipPolicy == gfoStowSymlink:
        anySymlink = true
        # Touch the source through the link.
        writeFile(f.absoluteOutputPath, "edited-via-link")
        let reread = readFile(f.stowSource)
        check reread == "edited-via-link"
    # Restore the source file for the no-op re-apply.
    if anySymlink:
      writeFile(fixture.profileDir / "stow" / ".gitconfig",
        "[user]\n  email = stow-basic@example.com\n")
      writeFile(fixture.profileDir / "stow" / ".config" / "foo" / "bar.toml",
        "[a]\nvalue = \"stow-basic\"\n")

    let noop = runRepro(fixture.baseEnv, ["home", "apply"])
    check noop.exitCode == 0
    check noop.output.contains("no-op: generation matches; verified ")

  when defined(windows):
    test "symlink-disabled forces junction fallback":
      let tempRoot = createTempDir("repro-m63-stow-junction-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let fixture = setupFixture(tempRoot,
        @[(k: "REPRO_TEST_STOW_DISABLE_SYMLINK", v: "1")])
      let res = runRepro(fixture.baseEnv, ["home", "apply"])
      check res.exitCode == 0
      check res.output.contains("IStowFellBack")
      let files = loadManifestEntries(fixture.stateDir, fixture.storeRoot)
      # `.gitconfig` is at the stow root → not junctionable → copy.
      # The `.config/foo/bar.toml` lives under a stow-exclusive
      # ancestor → eligible for junction, so the spec mandates
      # ownershipPolicy = stow-junction here.
      var sawGit, sawBar = false
      for f in files:
        if f.absoluteOutputPath.endsWith(".gitconfig"):
          sawGit = true
          check f.ownershipPolicy == gfoStowCopy
        if f.absoluteOutputPath.endsWith("bar.toml"):
          sawBar = true
          check f.ownershipPolicy == gfoStowJunction
      check sawGit
      check sawBar

    test "symlink+junction disabled forces copy fallback":
      let tempRoot = createTempDir("repro-m63-stow-copy-", "")
      defer:
        try: removeDir(tempRoot) except OSError: discard
      let fixture = setupFixture(tempRoot,
        @[(k: "REPRO_TEST_STOW_DISABLE_SYMLINK", v: "1"),
          (k: "REPRO_TEST_STOW_DISABLE_JUNCTION", v: "1")])
      let res = runRepro(fixture.baseEnv, ["home", "apply"])
      check res.exitCode == 0
      check res.output.contains("IStowFellBack")
      let files = loadManifestEntries(fixture.stateDir, fixture.storeRoot)
      var allCopy = true
      for f in files:
        if f.ownershipPolicy != gfoStowCopy:
          allCopy = false
      check allCopy

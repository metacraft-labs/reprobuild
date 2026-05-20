## M73 gate: `integration_stow_gnu_package_layout`.
##
## Verifies that stow auto-discovery follows the GNU `stow` *package*
## convention: each immediate subdirectory of `<profile-dir>/stow/` is
## a package, and a file at `stow/<package>/<rel>` materializes at
## `$HOME/<rel>` with the `<package>` level STRIPPED.
##
## Sub-tests (all against a sandboxed `$HOME` for the test):
##
##   1. Package-stripped materialization. The fixture's `stow/` has
##      packages `stow/gitpkg/.gitconfig` and
##      `stow/confpkg/.config/foo/bar.toml`. After apply,
##      `$HOME/.gitconfig` and `$HOME/.config/foo/bar.toml` exist —
##      the package-name level (`gitpkg`, `confpkg`) is stripped, the
##      within-package relative path is preserved including the nested
##      directories and the dotfile names. NO `$HOME/gitpkg/` or
##      `$HOME/confpkg/` parallel path is created.
##
##   2. Loose-file skip. A file placed directly under `stow/`
##      (`stow/loose.txt`) is NOT inside a package directory and is
##      therefore not valid GNU `stow` layout. Apply emits an
##      informational `IStowLooseFile` diagnostic and does NOT
##      materialize it: `$HOME/loose.txt` does not exist, and the apply
##      still succeeds (exit 0 — a loose file is informational, not an
##      error).
##
##   3. Manifest `stowSource`. The activation manifest's `GeneratedFile`
##      record for `.gitconfig` carries `stowSource` pointing at the
##      REAL `stow/gitpkg/.gitconfig` source — the package-nested path,
##      not the stripped target path.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "m73" / "stow_gnu_package_layout"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc copyTree(src, dst: string) =
  createDir(dst)
  for kind, entry in walkDir(src, relative = true):
    let from0 = src / entry
    let to0 = dst / entry
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

proc setup(tempRoot: string): tuple[stateDir, storeRoot, homeDir,
    profileDir: string; baseEnv: seq[tuple[k, v: string]]] =
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
    (k: "REPRO_HOST", v: "m73-gate-host"),
    (k: "REPRO_HOME_PACKAGE_CATALOG", v: "")]

proc loadManifest(stateDir, storeRoot: string): ActivationManifest =
  let activeId = readCurrentGenerationId(stateDir)
  doAssert activeId.len > 0, "no active generation after apply"
  let env = readPointerFile(pointerPath(stateDir, activeId))
  var store = openStore(storeRoot)
  defer: store.close()
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.activationManifestDigest[i]
  decodeManifestBytes(readCasBlob(store, key))

suite "M73 gate: integration_stow_gnu_package_layout":

  test "package level is stripped on materialization":
    let tempRoot = createTempDir("repro-m73-gnu-layout-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let f = setup(tempRoot)

    let res = runRepro(f.baseEnv, ["home", "apply"])
    check res.exitCode == 0
    check res.output.contains("applied generation ")

    # The package-name level (`gitpkg`, `confpkg`) is STRIPPED. The
    # within-package relative path — including the nested `.config/foo`
    # directories and the `.gitconfig` / `bar.toml` dotfile names — is
    # preserved verbatim under `$HOME`.
    let gitconfigTarget = f.homeDir / ".gitconfig"
    let barTomlTarget = f.homeDir / ".config" / "foo" / "bar.toml"
    check (fileExists(gitconfigTarget) or symlinkExists(gitconfigTarget))
    check (fileExists(barTomlTarget) or symlinkExists(barTomlTarget))

    # NO parallel package-named path is created — that is exactly the
    # flat-mapping bug M73 fixes.
    check not fileExists(f.homeDir / "gitpkg" / ".gitconfig")
    check not dirExists(f.homeDir / "gitpkg")
    check not fileExists(f.homeDir / "confpkg" / ".config" / "foo" /
      "bar.toml")
    check not dirExists(f.homeDir / "confpkg")

    # The materialized content matches the package source.
    let liveGit =
      if symlinkExists(gitconfigTarget): readFile(expandSymlink(gitconfigTarget))
      else: readFile(gitconfigTarget)
    check liveGit ==
      readFile(f.profileDir / "stow" / "gitpkg" / ".gitconfig")
    let liveBar =
      if symlinkExists(barTomlTarget): readFile(expandSymlink(barTomlTarget))
      else: readFile(barTomlTarget)
    check liveBar ==
      readFile(f.profileDir / "stow" / "confpkg" / ".config" / "foo" /
        "bar.toml")

    # The manifest records exactly the two package files (the loose
    # file is NOT a generated file).
    let manifest = loadManifest(f.stateDir, f.storeRoot)
    check manifest.generatedFiles.len == 2
    var sawGit, sawBar = false
    for gf in manifest.generatedFiles:
      if gf.absoluteOutputPath == gitconfigTarget:
        sawGit = true
      if gf.absoluteOutputPath == barTomlTarget:
        sawBar = true
    check sawGit
    check sawBar

  test "manifest stowSource points at the package-nested real source":
    let tempRoot = createTempDir("repro-m73-stowsource-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let f = setup(tempRoot)

    let res = runRepro(f.baseEnv, ["home", "apply"])
    check res.exitCode == 0

    # `GeneratedFile.stowSource` for `.gitconfig` must point at the
    # REAL `stow/gitpkg/.gitconfig` — the package-nested source path,
    # NOT the package-stripped target path.
    let manifest = loadManifest(f.stateDir, f.storeRoot)
    let expectedSource =
      f.profileDir / "stow" / "gitpkg" / ".gitconfig"
    var checkedGit = false
    for gf in manifest.generatedFiles:
      if gf.absoluteOutputPath == f.homeDir / ".gitconfig":
        checkedGit = true
        check gf.stowSource == expectedSource
        check gf.stowSource.contains("gitpkg")
        # The stowSource is the real source on disk.
        check fileExists(gf.stowSource)
        # It is a stow-materialization record.
        check gf.ownershipPolicy in
          {gfoStowSymlink, gfoStowJunction, gfoStowCopy}
    check checkedGit

  test "loose file directly under stow/ is skipped with a diagnostic":
    let tempRoot = createTempDir("repro-m73-loose-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let f = setup(tempRoot)
    # Pre-condition: the fixture has a loose file directly under stow/.
    check fileExists(f.profileDir / "stow" / "loose.txt")

    let res = runRepro(f.baseEnv, ["home", "apply"])
    # A loose file is INFORMATIONAL — apply still succeeds.
    check res.exitCode == 0
    check res.output.contains("applied generation ")
    # The informational `IStowLooseFile` diagnostic is emitted naming
    # the loose file.
    check res.output.contains("IStowLooseFile")
    check res.output.contains("loose.txt")

    # The loose file is NOT materialized: no `$HOME/loose.txt`.
    check not fileExists(f.homeDir / "loose.txt")
    check not symlinkExists(f.homeDir / "loose.txt")

    # The loose file did not become a generated-file manifest record.
    let manifest = loadManifest(f.stateDir, f.storeRoot)
    for gf in manifest.generatedFiles:
      check not gf.absoluteOutputPath.endsWith("loose.txt")
      check not gf.stowSource.endsWith("loose.txt")

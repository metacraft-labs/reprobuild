## M63 gate 6: `e2e_stow_suppression_and_warnings`.
##
## Two sub-tests:
##
##   A. A single package (`git-config`) would have generated
##      `~/.gitconfig`, the profile also has a `stow/.gitconfig`, and
##      the profile's `config:` block contributes overrides to
##      `git-config.userEmail`. Apply: only the stow file is
##      materialized; the package's would-be-generated file is
##      suppressed; `WStowOverridesShadowed` is emitted naming the
##      path, the package, and the dead config keys.
##
##   B. Two packages (`git-config` and `git-overrides`) both want to
##      write `~/.gitconfig`. Apply: stow wins;
##      `WStowAmbiguousSuppression` is emitted listing both packages.
##
## The fixture declares each package via the path adapter so the
## realize step runs (per spec, only the conflicting file output is
## suppressed — other package outputs and the realization itself
## proceed normally).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-apply"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate)
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

proc writeStub(path: string) =
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo stub-config 0.0.0\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 0\r\n")
  else:
    writeFile(path,
      "#!/bin/sh\nexit 0\n")
    setFilePermissions(path, {fpUserExec, fpUserWrite, fpUserRead,
      fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

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

proc loadManifest(stateDir, storeRoot: string): ActivationManifest =
  let activeId = readCurrentGenerationId(stateDir)
  let env = readPointerFile(pointerPath(stateDir, activeId))
  var store = openStore(storeRoot)
  defer: store.close()
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.activationManifestDigest[i]
  decodeManifestBytes(readCasBlob(store, key))

suite "M63 gate 6: e2e_stow_suppression_and_warnings":
  test "single package shadowed by stow → WStowOverridesShadowed":
    let tempRoot = createTempDir("repro-m63-suppress-single-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let homeDir = tempRoot / "home"
    let profileDir = tempRoot / "profile"
    let fixturesDir = tempRoot / "fix"
    createDir(stateDir); createDir(storeRoot); createDir(homeDir)
    createDir(fixturesDir)
    copyTree(FixtureRoot / "stow_suppression", profileDir)
    let stubName = when defined(windows): "git-config.cmd" else: "git-config"
    let stubPath = fixturesDir / stubName
    writeStub(stubPath)
    let baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate6a-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "git-config=" & stubPath),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "git-config"),
      (k: "REPRO_TEST_PACKAGE_GENERATES",
       v: "git-config=.gitconfig:[user]`r`n  email = pkg@example.com`r`n")]
    let res = runRepro(baseEnv, ["home", "apply"])
    check res.exitCode == 0
    check res.output.contains("WStowOverridesShadowed")
    check res.output.contains("git-config")
    check res.output.contains("userEmail")
    # Only the stow file is materialized — the manifest's
    # generatedFiles list has exactly one entry pointing at .gitconfig.
    let manifest = loadManifest(stateDir, storeRoot)
    var gitconfigEntries = 0
    var stowEntryFound = false
    for gf in manifest.generatedFiles:
      if gf.absoluteOutputPath.endsWith(".gitconfig"):
        inc gitconfigEntries
        if gf.ownershipPolicy in {gfoStowSymlink, gfoStowJunction, gfoStowCopy}:
          stowEntryFound = true
    check gitconfigEntries == 1
    check stowEntryFound

  test "two packages both shadowed → WStowAmbiguousSuppression":
    let tempRoot = createTempDir("repro-m63-suppress-ambig-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let homeDir = tempRoot / "home"
    let profileDir = tempRoot / "profile"
    let fixturesDir = tempRoot / "fix"
    createDir(stateDir); createDir(storeRoot); createDir(homeDir)
    createDir(fixturesDir)
    copyTree(FixtureRoot / "stow_suppression_ambiguous", profileDir)
    let stubA = fixturesDir / (when defined(windows): "git-config.cmd" else: "git-config")
    let stubB = fixturesDir / (when defined(windows): "git-overrides.cmd" else: "git-overrides")
    writeStub(stubA)
    writeStub(stubB)
    let baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "gate6b-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE",
       v: "git-config=" & stubA & ";git-overrides=" & stubB),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "git-config,git-overrides"),
      (k: "REPRO_TEST_PACKAGE_GENERATES",
       v: "git-config=.gitconfig:from-git-config;" &
          "git-overrides=.gitconfig:from-git-overrides")]
    let res = runRepro(baseEnv, ["home", "apply"])
    check res.exitCode == 0
    check res.output.contains("WStowAmbiguousSuppression")
    check res.output.contains("git-config")
    check res.output.contains("git-overrides")
    # Apply still proceeded.
    check res.output.contains("applied generation ")

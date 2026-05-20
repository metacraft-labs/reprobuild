## M65 gate: `e2e_repro_home_set_triggers_focused_rebuild`.
##
## Drives `repro home set` and `repro home get` end-to-end via the
## public CLI subprocess:
##
##   1. Apply a fixture profile with `git` and `foo` packages. The
##      `git` package's `REPRO_TEST_PACKAGE_GENERATES` content
##      consumes the `git.userName` configurable through the
##      `{{configurable:git.userName}}` placeholder; `foo`'s does
##      NOT consume any configurable. Two files end up on disk:
##      `~/.gitconfig` (consumes the configurable) and `~/.fooconfig`
##      (unrelated).
##   2. `repro home set git.userName "Zahary"` — exits 0, edits
##      `home.nim`, and runs apply inline. The apply log includes a
##      step-3 incremental-refinalize marker and an
##      `apply: cache-hit X rebuilt Y` line distinguishing
##      configurable-dependent rebuilds from unrelated cache hits.
##   3. Assert `~/.gitconfig` has the new content (rebuilt) and
##      `~/.fooconfig` is byte-identical to before (cache-hit).
##   4. `repro home get git.userName` prints `Zahary` to stdout with
##      exit 0.
##   5. Rollback to the prior generation. Under interpretation (B),
##      `home.nim` retains the edit but the active generation is the
##      prior one, so `~/.gitconfig` reverts and `repro home get
##      git.userName` returns the prior value (no override recorded).
##   6. `repro home set ghost.foo "bar"` against a package not
##      enabled by any active activity exits non-zero with a
##      structured diagnostic; `home.nim` is byte-identical to before.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-set-get"
const ProfileSrc = FixtureRoot / "profile"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc writeFixtureExe(path: string) =
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo fixture-pkg 0.0.0\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 1\r\n")
  else:
    writeFile(path,
      "#!/bin/sh\n" &
      "if [ \"$1\" = \"--version\" ]; then\n" &
      "  echo fixture-pkg 0.0.0\n" &
      "  exit 0\n" &
      "fi\n" &
      "exit 1\n")
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

const
  # The `git` content embeds a configurable placeholder; the planner
  # resolves it from the harvested `config:` block at apply time. The
  # `foo` content is configurable-independent: it should cache-hit
  # across a `repro home set git.userName ...` run.
  GitConfigTemplate = "[user]\nname = {{configurable:git.userName}}"
  FooConfigContent = "[foo]\nstable = yes"
  GitPkgSpec = "git=.gitconfig:" & GitConfigTemplate
  FooPkgSpec = "foo=.fooconfig:" & FooConfigContent

suite "M65 gate: e2e_repro_home_set_triggers_focused_rebuild":
  test "set triggers focused rebuild; unrelated files cache-hit; rollback restores; inactive rejected":
    let tempRoot = createTempDir("repro-m65-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let profileDir = tempRoot / "profile"
    let homeDir = tempRoot / "home"
    let fixtureDir = tempRoot / "fixtures"
    createDir(stateDir)
    createDir(storeRoot)
    createDir(homeDir)
    createDir(profileDir)
    createDir(fixtureDir)

    let exeExt = when defined(windows): ".cmd" else: ""
    let gitExe = fixtureDir / ("git" & exeExt)
    let fooExe = fixtureDir / ("foo" & exeExt)
    writeFixtureExe(gitExe)
    writeFixtureExe(fooExe)
    let pkgSourceMap = "git=" & gitExe & ";foo=" & fooExe

    copyFile(ProfileSrc / "home.nim", profileDir / "home.nim")
    let homeNimBeforeSet = readFile(profileDir / "home.nim")
    let baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "m65-host"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: pkgSourceMap),
      (k: "REPRO_TEST_PACKAGE_GENERATES", v: GitPkgSpec & ";" & FooPkgSpec),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "git,foo"),
      (k: "REPRO_HOME_CONFIGURABLE_SCHEMA",
        v: "git.userName,git.userEmail")]

    # --- Step 1: initial apply -------------------------------------------
    let apply1 = runRepro(baseEnv, ["home", "apply"])
    check apply1.exitCode == 0
    check apply1.output.contains("applied generation ")
    let initialGen = readCurrentGenerationId(stateDir)
    check initialGen.len > 0
    check fileExists(homeDir / ".gitconfig")
    check fileExists(homeDir / ".fooconfig")
    # Before any `set`, the placeholder is unresolved (no `config:`
    # block exists). The literal text is what landed.
    let gitConfigInitial = readFile(homeDir / ".gitconfig")
    check gitConfigInitial.contains("{{configurable:git.userName}}")
    let fooConfigInitial = readFile(homeDir / ".fooconfig")
    check fooConfigInitial == FooConfigContent

    # --- Step 2: repro home set git.userName "Zahary" --------------------
    let setRes = runRepro(baseEnv,
      ["home", "set", "git.userName", "Zahary"])
    check setRes.exitCode == 0
    # The incremental-refinalize seam logged its key.
    check setRes.output.contains("step 3 refinalize incremental key=git.userName")
    # The apply log distinguishes cache-hit from rebuilt.
    # We expect exactly 1 cache-hit (foo) and 1 rebuilt (git).
    check setRes.output.contains("cache-hit 1 rebuilt 1")
    check setRes.output.contains("applied generation ")
    let postSetGen = readCurrentGenerationId(stateDir)
    check postSetGen.len > 0
    check postSetGen != initialGen
    # Profile was edited.
    let homeNimAfterSet = readFile(profileDir / "home.nim")
    check homeNimAfterSet.contains("userName = \"Zahary\"")
    check homeNimAfterSet.contains("config:")
    check homeNimAfterSet.contains("git:")
    # ~/.gitconfig rebuilt with the resolved value.
    let gitConfigAfterSet = readFile(homeDir / ".gitconfig")
    check gitConfigAfterSet == "[user]\nname = Zahary"
    # ~/.fooconfig must be byte-identical to before.
    let fooConfigAfterSet = readFile(homeDir / ".fooconfig")
    check fooConfigAfterSet == fooConfigInitial

    # --- Step 3: repro home get git.userName -----------------------------
    let getRes = runRepro(baseEnv, ["home", "get", "git.userName"])
    check getRes.exitCode == 0
    check getRes.output.strip() == "Zahary"

    # --- Step 4: rollback to the initial generation ----------------------
    let rbRes = runRepro(baseEnv, ["home", "rollback"])
    check rbRes.exitCode == 0
    check rbRes.output.contains("rolled back from " & postSetGen &
      " to " & initialGen)
    check readCurrentGenerationId(stateDir) == initialGen
    # ~/.gitconfig reverted to the prior content.
    let gitConfigAfterRb = readFile(homeDir / ".gitconfig")
    check gitConfigAfterRb == gitConfigInitial
    # Interpretation (B): the on-disk `home.nim` still has the edit
    # (rollback rotates `current`, not the user's source of truth).
    let homeNimAfterRb = readFile(profileDir / "home.nim")
    check homeNimAfterRb == homeNimAfterSet
    # `get` reads from the rolled-back snapshot, so the prior value
    # (no override recorded → "not declared" diagnostic) surfaces.
    let getAfterRb = runRepro(baseEnv, ["home", "get", "git.userName"])
    check getAfterRb.exitCode != 0
    check getAfterRb.output.contains("no value recorded")

    # --- Step 5: set against an inactive package is rejected -------------
    let homeNimBeforeReject = readFile(profileDir / "home.nim")
    let rejectRes = runRepro(baseEnv,
      ["home", "set", "ghost.foo", "bar"])
    check rejectRes.exitCode != 0
    # Diagnostic shape: structured, mentions the inactive package.
    check rejectRes.output.contains("NOT enabled by any active activity")
    # The profile must be byte-identical — the rejected edit did NOT
    # land on disk.
    let homeNimAfterReject = readFile(profileDir / "home.nim")
    check homeNimAfterReject == homeNimBeforeReject

    discard homeNimBeforeSet

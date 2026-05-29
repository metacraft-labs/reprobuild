## M83 Phase F1 end-to-end gate: drive the FULL apply pipeline
## against the canonical example profile at
## `examples/profile-modules/home-with-modules/`.
##
## The gate proves the architectural unlock landed by the prior M83
## phases is real:
##
##   1. `compileProfileToRbpi(<example-home.nim>, opts)` succeeds —
##      the compile-then-apply pipeline can consume a profile root
##      that imports user-authored sibling modules.
##   2. The decoded `ProfileIntent` contains the package references
##      contributed by `gitDevTooling()` and `developerShell()` (the
##      activity-body splat composed both helpers in) and the
##      `ConfigOverride` records contributed by `gitIdentity()` (the
##      config-block helper convention).
##   3. The apply pipeline accepts the adapted profile and runs
##      `runApplyPlan` against a sandboxed tempdir, emitting a plan
##      preview that lists the helper-contributed packages.
##   4. The plan re-emit is identical between (a) the import-resolved
##      compile path and (b) a hand-rolled `ProfileIntent` with the
##      same content inlined directly. This anchors the equivalence
##      property: imports are pure composition.
##
## The example profile is COPIED into a tempdir before the compile
## runs, so the test never mutates the in-tree example. The Nim
## compile is driven by the production `compileProfileToRbpi` library
## entry point — this gate exercises the same code path apply uses
## in production.

import std/[os, osproc, sets, strtabs, strutils, tables, tempfiles,
            unittest]
from repro_core/paths import extendedPath

import repro_home_apply
import repro_local_store
import repro_profile
import repro_profile_intent
import repro_profile_compile

const ProjectRoot = currentSourcePath().parentDir().parentDir().
  parentDir().parentDir()
const ExampleDir = ProjectRoot / "examples" / "profile-modules" /
  "home-with-modules"

# ---------------------------------------------------------------------------
# Helpers — set up a fresh sandboxed tempdir copy of the example.
# ---------------------------------------------------------------------------

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(extendedPath(candidate)),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc copyExampleInto(dst: string) =
  ## Copy the entire example directory tree into `dst`. We do this
  ## (rather than pointing the compile pipeline at the in-tree path)
  ## so the test owns its sandbox and concurrent runs do not race
  ## on a shared profile-cache.
  createDir(extendedPath(dst))
  createDir(extendedPath(dst / "modules"))
  copyFile(ExampleDir / "home.nim", dst / "home.nim")
  copyFile(ExampleDir / "modules" / "git_dev_environment.nim",
    dst / "modules" / "git_dev_environment.nim")
  copyFile(ExampleDir / "modules" / "dev_shell.nim",
    dst / "modules" / "dev_shell.nim")

proc compileOpts(stateDir: string): ProfileCompileOptions =
  ProfileCompileOptions(
    stateDir: stateDir,
    publicCliPath: reproBinary(),
    repoRoot: ProjectRoot)

proc collectPackageNames(intent: ProfileIntent;
                         activityName: string): seq[string] =
  for a in intent.activities:
    if a.name == activityName:
      for el in a.body:
        if el.kind == aekPackageRef:
          result.add(el.pkgName)

# An in-process `ProfileIntent` matching what the example profile
# emits. Used to (a) prove the plan re-emit is identical with vs.
# without the import resolution and (b) anchor the assertions in
# golden form.
proc makeInlinedIntent(): ProfileIntent =
  result = ProfileIntent(name: "homeWithModules")
  result.activities.add(ActivityIntent(name: "default", body: @[
    ActivityElement(kind: aekPackageRef, pkgName: "ripgrep"),
    ActivityElement(kind: aekPackageRef, pkgName: "fd"),
    ActivityElement(kind: aekPackageRef, pkgName: "jq"),
    ActivityElement(kind: aekPackageRef, pkgName: "neovim"),
  ]))
  result.activities.add(ActivityIntent(name: "develop_software",
    body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "git"),
      ActivityElement(kind: aekPackageRef, pkgName: "gh"),
      ActivityElement(kind: aekPackageRef, pkgName: "lazygit"),
      ActivityElement(kind: aekPackageRef, pkgName: "delta"),
    ]))
  result.configOverrides.add(ConfigOverride(pkg: "git",
    key: "userName",
    value: ConfigValue(kind: cvkString, s: "Example User")))
  result.configOverrides.add(ConfigOverride(pkg: "git",
    key: "userEmail",
    value: ConfigValue(kind: cvkString,
      s: "example-user@example.com")))
  result.hosts["example-host"] = @["default", "develop_software"]

# ---------------------------------------------------------------------------
# Apply-environment scaffolding for the runApplyPlan step.
# ---------------------------------------------------------------------------

type ApplyEnv = object
  profileDir, profilePath, stateDir, storeRoot, homeDir: string

proc setupApplyEnv(tempRoot, profileDir, profilePath: string):
    ApplyEnv =
  result.profileDir = profileDir
  result.profilePath = profilePath
  result.stateDir = tempRoot / "state"
  result.storeRoot = tempRoot / "store"
  result.homeDir = tempRoot / "home"
  createDir(extendedPath(result.stateDir))
  createDir(extendedPath(result.storeRoot))
  createDir(extendedPath(result.homeDir))
  putEnv("REPRO_HOME_PACKAGE_CATALOG", "")
  putEnv("REPRO_TEST_RESOURCES", "")
  # Wire every package the example contributes as a path-adapter
  # source so the planner can resolve every name through the test
  # seam. The bytes are unimportant; only the path needs to exist.
  let placeholder = profilePath
  var pkgs = @["ripgrep", "fd", "jq", "neovim",
               "git", "gh", "lazygit", "delta"]
  var mapping = ""
  for i, name in pkgs:
    if i > 0:
      mapping.add(';')
    mapping.add(name)
    mapping.add('=')
    mapping.add(placeholder)
  putEnv("REPRO_TEST_PACKAGE_SOURCE", mapping)

# ---------------------------------------------------------------------------
# Test scenarios.
# ---------------------------------------------------------------------------

suite "M83 Phase F1: canonical profile-modules example":

  test "compileProfileToRbpi succeeds against the import-composed " &
       "example profile":
    let stateDir = createTempDir("repro-m83-f1-compile-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard
    let profileSrcDir = createTempDir("repro-m83-f1-src-", "")
    defer:
      try: removeDir(profileSrcDir) except OSError: discard
    copyExampleInto(profileSrcDir)

    let artifact = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    check artifact.rbpiBytes.len > 0
    check artifact.digestHex.len == 64
    # All three source files must be in the discovered set — the
    # source-discovery walk transitively reached both sibling modules.
    var rels: seq[string]
    for s in artifact.inputSources:
      rels.add(s.relativePath(profileSrcDir).replace('\\', '/'))
    check "home.nim" in rels
    check "modules/git_dev_environment.nim" in rels
    check "modules/dev_shell.nim" in rels

  test "decoded ProfileIntent contains every helper-contributed " &
       "package + ConfigOverride":
    let stateDir = createTempDir("repro-m83-f1-decode-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard
    let profileSrcDir = createTempDir("repro-m83-f1-src-", "")
    defer:
      try: removeDir(profileSrcDir) except OSError: discard
    copyExampleInto(profileSrcDir)

    let artifact = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    let intent = decodeRbpi(artifact.rbpiBytes)
    check intent.name == "homeWithModules"

    # developerShell() splatted into the `default` activity body.
    let devPkgs = collectPackageNames(intent, "default")
    var devSet = initHashSet[string]()
    for p in devPkgs: devSet.incl(p)
    check "ripgrep" in devSet
    check "fd" in devSet
    check "jq" in devSet
    check "neovim" in devSet

    # gitDevTooling() splatted into the `develop_software` activity.
    let gitPkgs = collectPackageNames(intent, "develop_software")
    var gitSet = initHashSet[string]()
    for p in gitPkgs: gitSet.incl(p)
    check "git" in gitSet
    check "gh" in gitSet
    check "lazygit" in gitSet
    check "delta" in gitSet

    # gitIdentity(name, email) appended two ConfigOverride records.
    var byKey = initTable[string, ConfigOverride]()
    for ov in intent.configOverrides:
      if ov.pkg == "git":
        byKey[ov.key] = ov
    check "userName" in byKey
    check byKey["userName"].value.kind == cvkString
    check byKey["userName"].value.s == "Example User"
    check "userEmail" in byKey
    check byKey["userEmail"].value.kind == cvkString
    check byKey["userEmail"].value.s == "example-user@example.com"

  test "runApplyPlan against the adapted ProfileIntent previews the " &
       "helper-contributed packages":
    let tempRoot = createTempDir("repro-m83-f1-plan-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let profileSrcDir = tempRoot / "profile"
    copyExampleInto(profileSrcDir)
    let stateDir = createTempDir("repro-m83-f1-plan-state-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard

    let artifact = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    let intent = decodeRbpi(artifact.rbpiBytes)

    let env = setupApplyEnv(tempRoot, profileSrcDir,
      profileSrcDir / "home.nim")

    var opts: ApplyOptions
    opts.profileDir = env.profileDir
    opts.profilePath = env.profilePath
    opts.stateDir = env.stateDir
    opts.storeRoot = env.storeRoot
    opts.homeDir = env.homeDir
    # The example's `hosts:` block names `example-host` as the host
    # that activates both `default` and `develop_software`. Using
    # any other host name would activate only `default` (per the
    # apply planner's enabledActivitiesFor rule).
    opts.host = "example-host"
    opts.preLoadedProfile = profileIntentToHomeProfile(intent,
      env.profilePath)

    let preview = runApplyPlan(opts)
    check preview.generationIdHex.len > 0

    var packageItems = initHashSet[string]()
    for item in preview.items:
      if item.category == "package":
        packageItems.incl(item.name)

    # Every helper-contributed package appears in the package
    # preview. The activity composition (`default` +
    # `develop_software`) hit the planner unchanged.
    for name in [
      "ripgrep", "fd", "jq", "neovim",
      "git", "gh", "lazygit", "delta"
    ]:
      check name in packageItems

  test "plan re-emit is identical between import-resolved compile " &
       "and inlined ProfileIntent":
    # The architectural unlock means sibling-module imports are pure
    # composition — the resulting ProfileIntent must be byte-for-byte
    # the same as one built by hand with the same content. We anchor
    # that property by comparing the JSON canonical form of the two
    # intents (the JSON encoder emits sorted keys + deterministic
    # ordering, so byte-equality is the right check).
    let stateDir = createTempDir("repro-m83-f1-reemit-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard
    let profileSrcDir = createTempDir("repro-m83-f1-reemit-src-", "")
    defer:
      try: removeDir(profileSrcDir) except OSError: discard
    copyExampleInto(profileSrcDir)

    let artifact = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    let compiled = decodeRbpi(artifact.rbpiBytes)
    let inlined = makeInlinedIntent()

    let compiledJson = emitProfileIntentJson(compiled)
    let inlinedJson = emitProfileIntentJson(inlined)
    check compiledJson == inlinedJson

  test "touching a sibling module invalidates the compile cache":
    # Anchor that the digest covers the full source closure: editing
    # ONLY a sibling module (without changing home.nim) must produce
    # a fresh artifact path. This is the load-bearing guarantee that
    # users can author modules and reprobuild will recompile when
    # they change them.
    let stateDir = createTempDir("repro-m83-f1-touch-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard
    let profileSrcDir = createTempDir("repro-m83-f1-touch-src-", "")
    defer:
      try: removeDir(profileSrcDir) except OSError: discard
    copyExampleInto(profileSrcDir)

    let first = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))

    let modulePath = profileSrcDir / "modules" / "dev_shell.nim"
    var contents = readFile(extendedPath(modulePath))
    contents.add("\n## touch-comment to perturb the digest\n")
    writeFile(extendedPath(modulePath), contents)

    let second = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    check second.digestHex != first.digestHex
    check second.rbpiPath != first.rbpiPath

  test "re-compiling the same source set hits the cache":
    let stateDir = createTempDir("repro-m83-f1-hit-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard
    let profileSrcDir = createTempDir("repro-m83-f1-hit-src-", "")
    defer:
      try: removeDir(profileSrcDir) except OSError: discard
    copyExampleInto(profileSrcDir)

    let first = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    let second = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    check second.digestHex == first.digestHex
    check second.rbpiPath == first.rbpiPath
    check second.rbpiBytes == first.rbpiBytes

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
import repro_build_engine
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

proc observedUnder(observed: openArray[string]; dir: string): seq[string] =
  ## The observed reads that lie under `dir`, relative to it with `/`
  ## separators. io-mon records the path the kernel resolved, which on macOS
  ## is the canonical one. `createTempDir` hands out a path under `$TMPDIR`,
  ## which on macOS lies behind a symlink: `/var/folders/...` normally, or
  ## `/tmp/nix-shell.*` inside `nix develop`, while the monitor records
  ## `/private/var/folders/...` or `/private/tmp/...`. Matching only the
  ## spelling the test created finds none of the module files, so both the
  ## lexical and the resolved spelling of `dir` are accepted. This is the
  ## same rule `profileInputs` (`repro home export`) applies to this record.
  ## The separator in the prefix keeps out a sibling such as `<dir>-other`
  ## and the bare `dir`.
  var roots = @[absolutePath(dir)]
  try:
    let real = expandFilename(dir)
    if real notin roots:
      roots.add real
  except OSError:
    discard
  for s in observed:
    for root in roots:
      if s.startsWith(root & DirSep):
        result.add(s.relativePath(root).replace('\\', '/'))
        break

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
    # A cold compile executes the edge, and all three source files are in
    # the dependency record io-mon observed `nim` read — not in a list a
    # text walk produced. This is what the action cache keys on.
    check artifact.edgeLaunched
    let rels = observedUnder(artifact.observedInputs, profileSrcDir)
    checkpoint("observed under profile dir: " & rels.join(", "))
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
    # Editing ONLY a sibling module (without changing home.nim) must
    # re-execute the edge. This is the load-bearing guarantee that users
    # can author modules and reprobuild will recompile when they change
    # them — and it now holds because the module is in the edge's
    # monitored read set, not because a text walk listed it.
    let stateDir = createTempDir("repro-m83-f1-touch-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard
    let profileSrcDir = createTempDir("repro-m83-f1-touch-src-", "")
    defer:
      try: removeDir(profileSrcDir) except OSError: discard
    copyExampleInto(profileSrcDir)

    let first = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    check first.edgeLaunched

    let modulePath = profileSrcDir / "modules" / "dev_shell.nim"
    var contents = readFile(extendedPath(modulePath))
    contents.add("\n## touch-comment to perturb the module\n")
    writeFile(extendedPath(modulePath), contents)

    let second = compileProfileToRbpi(profileSrcDir / "home.nim",
      compileOpts(stateDir))
    checkpoint("cacheDecision=" & $second.cacheDecision &
      " missReason=" & second.cacheMissReason)
    check second.edgeLaunched
    # A comment does not change the intent, and the edge publishes to one
    # stable, per-profile location: the output name is not a cache key.
    check second.digestHex == first.digestHex
    check second.rbpiPath == first.rbpiPath

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
    checkpoint("second: cacheDecision=" & $second.cacheDecision &
      " missReason=" & second.cacheMissReason &
      " publishSkip=" & first.cachePublishSkipReason)
    check first.edgeLaunched
    # The answer comes from the engine's action cache, not from a
    # structural probe in front of it.
    check not second.edgeLaunched
    check second.cacheDecision == cdHit
    check second.digestHex == first.digestHex
    check second.rbpiPath == first.rbpiPath
    check second.rbpiBytes == first.rbpiBytes

  test "editing a leaf of a transitive module chain re-runs the edge":
    # home.nim -> modules/outer.nim -> modules/inner.nim. The leaf is two
    # imports away from the root; editing it (and only it) must re-execute
    # the edge and change the intent, and an unchanged closure must not.
    let stateDir = createTempDir("repro-m83-f1-leaf-", "")
    defer:
      try: removeDir(stateDir) except OSError: discard
    let dir = createTempDir("repro-m83-f1-leaf-src-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    createDir(extendedPath(dir / "modules"))
    writeFile(extendedPath(dir / "home.nim"), """
import repro_profile
import ./modules/outer

profile "leafChain":
  activity default:
    outerBundle()
""")
    writeFile(extendedPath(dir / "modules" / "outer.nim"), """
import repro_profile
import ./inner

proc outerBundle*(): seq[ActivityElement] =
  result = innerBundle()
  result.add package("outer-pkg")
""")
    let leaf = dir / "modules" / "inner.nim"
    proc writeLeaf(pkg: string) =
      writeFile(extendedPath(leaf), "import repro_profile\n\n" &
        "proc innerBundle*(): seq[ActivityElement] =\n" &
        "  @[package \"" & pkg & "\"]\n")
    writeLeaf("inner-one")

    let first = compileProfileToRbpi(dir / "home.nim", compileOpts(stateDir))
    check first.edgeLaunched
    let rels = observedUnder(first.observedInputs, dir)
    checkpoint("observed under profile dir: " & rels.join(", "))
    check "home.nim" in rels
    check "modules/outer.nim" in rels
    check "modules/inner.nim" in rels
    check collectPackageNames(decodeRbpi(first.rbpiBytes), "default") ==
      @["inner-one", "outer-pkg"]

    let unchanged = compileProfileToRbpi(dir / "home.nim",
      compileOpts(stateDir))
    check not unchanged.edgeLaunched
    check unchanged.rbpiBytes == first.rbpiBytes

    writeLeaf("inner-two")
    let second = compileProfileToRbpi(dir / "home.nim", compileOpts(stateDir))
    check second.edgeLaunched
    check collectPackageNames(decodeRbpi(second.rbpiBytes), "default") ==
      @["inner-two", "outer-pkg"]

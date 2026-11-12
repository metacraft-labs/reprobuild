## The `cargo` typed tool.
##
## The package declaration -- cargo's subcommands, flags and provisioning --
## is in `cargo_cli.nim`, and everything it declares is re-exported from here
## except `build`, `install` and `test`, which this module wraps.
##
## WHY THEY ARE WRAPPED. Each of the three edges has to agree with cargo about
## where its target directory is: the declared output, the depfile globs the
## engine reads as dependency evidence, and the action key all name it. A
## `cli:` declaration carries one literal policy per subcommand, so it could
## only say `target/...` relative to the action's working directory, and that
## was wrong twice:
##
##   * A crate below the working directory (`--manifest-path rust/Cargo.toml`
##     from the repository root) writes `rust/target/...`, which the globs never
##     matched. The edge read no depfile and reported up-to-date after a real
##     source change.
##   * A host that sets `CARGO_TARGET_DIR` or `CARGO_BUILD_TARGET_DIR` (the CI
##     runners on high-mem-server do, per runner) moved the output away from the
##     declared one, so a cache miss failed with "exited 0 but did not produce
##     its declared output".
##
## So the edge owns the directory: every call passes an explicit `--target-dir`
## (the caller's `targetDir`, else `<crate directory>/target`), and the depfile
## globs are resolved under that same directory. cargo ranks `--target-dir`
## above the environment variables and a config file's `build.target-dir`
## (https://doc.rust-lang.org/cargo/reference/config.html#buildtarget-dir), so
## the flag makes the ambient settings inert, and the action no longer depends
## on them.
##
## The wrapper parameter lists repeat the generated ones in `cargo_cli.nim`: a
## flag added to the `cli:` spec has to be added here too, or it is not
## reachable from a recipe.

import std/[os, sequtils, strutils]

import repro_project_dsl
import cargo_cli
export cargo_cli except build, install, test

type CargoTool = typeof(cargo_cli.cargo)
  ## The type of the `cargo` value the package block declares.

func slashJoin(dir, name: string): string =
  ## `dir/name` with a forward slash on every host. The engine and cargo both
  ## accept it on Windows, and it keeps the declared globs spelled the same
  ## everywhere, which the action key depends on.
  if dir.len == 0: name
  elif dir[^1] == '/': dir & name
  else: dir & "/" & name

func slashed(path: string): string =
  ## `path` with forward slashes, so a Windows spelling (`rust\\Cargo.toml`)
  ## is split into directory and file name the same way on every host.
  path.replace('\\', '/')

const DefaultTargetDirName = "target"
  ## cargo's own default target directory name, relative to its crate.

proc cargoTargetDir*(targetDir, crateDir: string): string =
  ## The target directory a cargo edge builds in: `targetDir` when the caller
  ## named one, else `<crateDir>/target`. An empty `crateDir` is the action's
  ## working directory.
  if targetDir.len > 0: targetDir
  elif crateDir == ".": DefaultTargetDirName
  else: slashJoin(crateDir, DefaultTargetDirName)

proc cargoBuildDepfileGlobs*(targetDir, target: string): seq[string] =
  ## The depfile globs of a `cargo build` or `cargo install` whose target
  ## directory is `targetDir` (and whose `--target` triple is `target`, or
  ## empty). Only the profile cargo actually built has files; the other glob
  ## legitimately expands to zero matches.
  ##
  ## These are the dep-info files cargo places beside each artefact it links
  ## (`<target-dir>/<profile>/<artefact>.d`), not the per-crate ones under
  ## `deps/`. Both list the sources of the build, but rustc writes the `deps/`
  ## ones with paths relative to the cargo workspace root, which the engine
  ## would resolve against the action's working directory: for a crate below
  ## it (`--manifest-path rust/Cargo.toml`) they name files that do not exist
  ## there. cargo renders the linked artefacts' files with absolute paths.
  let root = if target.len > 0: slashJoin(targetDir, target) else: targetDir
  @[slashJoin(root, "debug/*.d"), slashJoin(root, "release/*.d")]

proc cargoTestDepfileGlobs*(targetDir: string): seq[string] =
  ## The depfile globs of a `cargo test --no-run` whose target directory is
  ## `targetDir`. cargo does not link test executables into the profile
  ## directory, so only the per-crate `deps/` files exist for them. Their
  ## paths are relative to the cargo workspace root, so `test` runs the edge in
  ## the manifest's directory (see there) to make them resolve.
  @[slashJoin(targetDir, "debug/deps/*.d"),
    slashJoin(targetDir, "release/deps/*.d")]

proc cargoDepfilePolicy(policy: BuildActionDependencyPolicy;
                        globs: seq[string]): BuildActionDependencyPolicy =
  ## `policy` with `globs` filled in, unless the caller
  ## supplied a policy of their own: only the bare depfile policy, which is
  ## the default of the wrappers below, is completed.
  if policy.kind == bdpMakeDepfile and policy.depfiles.len == 0:
    makeDepfilePolicy(depfiles = globs,
      ignoredInputPrefixes = policy.ignoredInputPrefixes,
      captureBreadth = policy.captureBreadth,
      suppressMonitorShimSeed = policy.suppressMonitorShimSeed)
  else:
    policy

proc build*(pkg: CargoTool;
            config = "";
            locked = false;
            release = false;
            offline = false;
            noDefaultFeatures = false;
            features = "";
            manifestPath = "";
            targetDir = "";
            package = "";
            bin = "";
            target = "";
            actionId = "";
            deps: openArray[string] = [];
            after: openArray[BuildActionDef] = [];
            extraInputs: openArray[string] = [];
            extraOutputs: openArray[string] = [];
            extraEnv: openArray[(string, string)] = [];
            depfile = "";
            cacheable = true;
            actionCachePolicy = defaultActionCachePolicy();
            commandStatsId = "";
            dependencyPolicy = makeDepfilePolicy()): BuildActionDef
    {.discardable.} =
  ## `cargo build`. The target directory is `targetDir`, else the `target`
  ## directory beside `manifestPath` (the working directory's, without one).
  let effectiveTargetDir = cargoTargetDir(targetDir, parentDir(manifestPath.slashed))
  cargo_cli.build(pkg, config = config, locked = locked, release = release,
    offline = offline, noDefaultFeatures = noDefaultFeatures,
    features = features, manifestPath = manifestPath,
    targetDir = effectiveTargetDir, package = package, bin = bin,
    target = target, actionId = actionId, deps = deps, after = after,
    extraInputs = extraInputs, extraOutputs = extraOutputs,
    extraEnv = extraEnv, depfile = depfile, cacheable = cacheable,
    actionCachePolicy = actionCachePolicy, commandStatsId = commandStatsId,
    dependencyPolicy = cargoDepfilePolicy(dependencyPolicy,
      cargoBuildDepfileGlobs(effectiveTargetDir, target)))

proc install*(pkg: CargoTool;
              config = "";
              locked = false;
              offline = false;
              noTrack = false;
              force = false;
              noDefaultFeatures = false;
              features = "";
              path = "";
              root = "";
              targetDir = "";
              target = "";
              actionId = "";
              deps: openArray[string] = [];
              after: openArray[BuildActionDef] = [];
              extraInputs: openArray[string] = [];
              extraOutputs: openArray[string] = [];
              extraEnv: openArray[(string, string)] = [];
              depfile = "";
              cacheable = true;
              actionCachePolicy = defaultActionCachePolicy();
              commandStatsId = "";
              dependencyPolicy = makeDepfilePolicy()): BuildActionDef
    {.discardable.} =
  ## `cargo install`. The target directory is `targetDir`, else the `target`
  ## directory of the crate at `path`; a recipe that wants the install to
  ## reuse a build edge's artefacts passes that edge's `targetDir`.
  let effectiveTargetDir = cargoTargetDir(targetDir, path)
  cargo_cli.install(pkg, config = config, locked = locked, offline = offline,
    noTrack = noTrack, force = force, noDefaultFeatures = noDefaultFeatures,
    features = features, path = path, root = root,
    targetDir = effectiveTargetDir, target = target, actionId = actionId,
    deps = deps, after = after, extraInputs = extraInputs,
    extraOutputs = extraOutputs, extraEnv = extraEnv, depfile = depfile,
    cacheable = cacheable, actionCachePolicy = actionCachePolicy,
    commandStatsId = commandStatsId,
    dependencyPolicy = cargoDepfilePolicy(dependencyPolicy,
      cargoBuildDepfileGlobs(effectiveTargetDir, target)))

proc test*(pkg: CargoTool;
           locked = false;
           release = false;
           noRun = false;
           noDefaultFeatures = false;
           manifestPath = "";
           targetDir = "";
           package = "";
           bin = "";
           testBinaryPath = "";
           actionId = "";
           deps: openArray[string] = [];
           after: openArray[BuildActionDef] = [];
           extraInputs: openArray[string] = [];
           extraOutputs: openArray[string] = [];
           extraEnv: openArray[(string, string)] = [];
           depfile = "";
           cacheable = true;
           actionCachePolicy = defaultActionCachePolicy();
           commandStatsId = "";
           dependencyPolicy = makeDepfilePolicy()): CargoTestEdge
    {.discardable.} =
  ## `cargo test`. The target directory is `targetDir`, else the `target`
  ## directory beside `manifestPath` (the working directory's, without one).
  ##
  ## A manifest below the recipe root (`rust/Cargo.toml`) makes the edge run
  ## IN that directory, as `cargo test` itself does. cargo does not link test
  ## executables, so the only dependency evidence of the edge is rustc's
  ## per-crate `deps/*.d`, whose source paths are relative to the cargo
  ## workspace root, the manifest's directory; the engine resolves them against
  ## the action's working directory, so they name the crate's sources only
  ## when the two are the same. Every path of the call that cargo resolves
  ## against its working directory (`--manifest-path`, `--target-dir`, the
  ## extra outputs, the depfile globs) is re-spelled relative to it; declared
  ## inputs (the manifest among them) keep the recipe-root spelling, because
  ## the lowering materializes them against the recipe root.
  let crateDir = parentDir(manifestPath.slashed)
  let inCrateDir = crateDir notin ["", "."] and not manifestPath.isAbsolute and
    not crateDir.startsWith("..")
  proc fromCrateDir(path: string): string =
    if not inCrateDir or path.len == 0 or path.isAbsolute: path
    else: relativePath(path, crateDir, '/')
  let effectiveTargetDir =
    if inCrateDir:
      cargoTargetDir(fromCrateDir(targetDir), "")
    else:
      cargoTargetDir(targetDir, crateDir)
  result = cargo_cli.test(pkg, locked = locked, release = release,
    noRun = noRun, noDefaultFeatures = noDefaultFeatures,
    manifestPath = (if inCrateDir: extractFilename(manifestPath.slashed)
                    else: manifestPath),
    targetDir = effectiveTargetDir, package = package, bin = bin,
    testBinaryPath = fromCrateDir(testBinaryPath), actionId = actionId,
    deps = deps, after = after, extraInputs = extraInputs,
    extraOutputs = (if inCrateDir: extraOutputs.mapIt(fromCrateDir(it))
                    else: @extraOutputs),
    extraEnv = extraEnv, depfile = depfile, cacheable = cacheable,
    actionCachePolicy = actionCachePolicy, commandStatsId = commandStatsId,
    dependencyPolicy = cargoDepfilePolicy(dependencyPolicy,
      cargoTestDepfileGlobs(effectiveTargetDir)))
  if inCrateDir:
    setRegisteredActionCwd(result.action.id, acwdCustom, crateDir)
    result.action.cwdKind = acwdCustom
    result.action.cwdCustomPath = crateDir
    # The manifest is an input, and inputs are materialized against the
    # recipe root: put back the spelling the caller used, in the position the
    # re-spelled flag held.
    var inputs = result.action.inputs
    for i in 0 ..< inputs.len:
      if inputs[i] == extractFilename(manifestPath.slashed):
        inputs[i] = manifestPath
    setRegisteredActionInputs(result.action.id, inputs)
    result.action.inputs = inputs
    # The handle keeps the recipe-root spelling too: `.run()` takes its path
    # as an input of its own edge, which runs in the recipe root.
    if testBinaryPath.len > 0:
      result.testBinary = CargoTestBinary(path: testBinaryPath)

# ---------------------------------------------------------------------------
# Manual wrapper on the `CargoTestBinary` typed output — emits one
# execute edge per call. Recipes typically call `.run()` once per
# individual rust test discovered by enumerating the binary's
# `--list --format=terse` output at recipe-evaluation time (or once with
# `filter = ""` to run the whole binary as a single edge during the
# initial migration).
# ---------------------------------------------------------------------------

proc run*(self: CargoTestBinary; filter = "";
         actionId = ""; deps: openArray[string] = [];
         after: openArray[BuildActionDef] = [];
         extraEnv: openArray[(string, string)] = [];
         targetDir = ""): BuildActionDef
    {.discardable.} =
  ## Schedules one cargo-test execute edge for this binary. When
  ## `filter` is non-empty, the binary is invoked with
  ## `--exact <filter>` (libtest's per-test selection). When empty,
  ## the binary runs every test it contains in one process — the
  ## "whole binary as one edge" fallback used before per-test
  ## enumeration is wired.
  ##
  ## The handle's `path` is recorded as a typed input so the engine
  ## action-cache keys on the binary's content; a rebuild of the
  ## binary correctly invalidates every per-test execute edge that
  ## reads it.
  ##
  ## ``extraEnv`` (MR10): per-edge env-var injection threaded onto the
  ## spawned test process. Useful for tests whose runtime needs
  ## additional env vars (e.g. cairo-corelib's ``CAIRO_CORELIB_DIR``)
  ## without resorting to a shell-wrapper indirection.
  ##
  ## ``targetDir`` names the target directory of the ``cargo.test --no-run``
  ## build that produced the binary, for a handle whose ``path`` is not a
  ## path into it; the default is the working directory's ``target``.
  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg("binary", self.path))
  if filter.len > 0:
    cliArgs.add(cliArg("filter", filter))
  let call = publicCliCall("cargo",
    "cargo-test-binary", "run",
    "cargo.test_binary.run", cliArgs)
  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)
  # MR16: the test-binary execute edge reuses the build-time ``.d``
  # files left behind in ``<target-dir>/<profile>/deps/`` by the
  # ``cargo.test --no-run`` build that produced this binary. The
  # binary's true source-input set lives in that depfile (cargo's
  # rustc invocation wrote one ``.d`` per crate the binary links),
  # so keying the execute edge on it correctly invalidates the run
  # whenever a source file the binary depends on changed since the
  # last successful execution.
  #
  # A binary built into ``<target-dir>/<profile>/deps/`` names that
  # directory itself, so the depfiles are the ``*.d`` beside it, wherever
  # the build put its target directory. Otherwise both profile directories
  # are declared, as in the build subcommand: at most one exists per
  # workspace and the other glob legitimately expands to zero matches.
  #
  # The sources those files list are relative to the crate's directory and
  # this edge runs in the recipe root, so they are not resolved here. That
  # loses nothing: the binary is a declared input, and a changed source
  # changes the binary, which invalidates this edge.
  let binaryDir = parentDir(self.path)
  let depfileGlobs =
    if binaryDir.len > 0: @[slashJoin(binaryDir, "*.d")]
    else: cargoTestDepfileGlobs(cargoTargetDir(targetDir, ""))
  result = recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    dependencyPolicy = makeDepfilePolicy(depfiles = depfileGlobs),
    extraEnv = extraEnv)

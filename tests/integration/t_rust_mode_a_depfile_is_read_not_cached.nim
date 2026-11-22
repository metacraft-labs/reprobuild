## Rust convention (Mode A): each rustc edge's dep-info file is the edge's
## DEPFILE, read for its implicit inputs, and never one of its cached
## outputs.
##
## Mode A runs rustc itself, once with ``--emit=metadata,dep-info`` for a
## library's metadata pass and once with ``--emit=link,dep-info`` for its
## link pass (rustc book, "Command-line Arguments", ``--emit``:
## https://doc.rust-lang.org/rustc/command-line-arguments.html#--emit-specifies-the-types-of-output-files-to-generate).
## The ``.d`` file rustc writes lists every file the crate read: its
## ``mod`` files, and the files ``include_str!`` / ``include_bytes!`` /
## ``include!`` pulled in. Mode A declares only the crate's ``.rs`` files
## as inputs, so the ``.d`` is the one place an ``include_str!`` target is
## named, and the engine must keep reading it after every run.
##
## Why it must not be a cached output: the ``.d`` names the crate's sources
## and the edge's ``--out-dir`` by absolute path, and
## ``--remap-path-prefix`` does not rewrite dep-info (measured with rustc
## 1.94.0: with the remap the rlib and rmeta are path-free and the ``.d``
## still names the source prefix and the output directory). As a cached
## output it would carry this checkout's paths into the record, fail the
## cache's embedded-path scan of the outputs (``embeddedRootReason`` in
## ``repro_build_engine``, which scans ``outputs``, ``optionalOutputs`` and
## ``declaredOutputs``) and keep the record from being shared between
## checkouts. Nothing downstream consumes it.
##
## What the test checks, against a one-crate library whose ``lib.rs`` has a
## ``mod`` file and an ``include_str!`` of a file outside ``src/``:
##
##   1. The emitted metadata and link edges each declare a ``.d`` depfile
##      with a make-depfile policy over exactly that path, and the ``.d`` is
##      not among their ``outputs`` or ``optionalOutputs``.
##   2. Built through the real engine, both edges succeed, rustc writes both
##      ``.d`` files, and the engine reads them: each edge's tool-reported
##      (depfile) inputs name the ``include_str!`` target.
##   3. An unchanged rebuild is a cache hit for both edges.
##   4. With the rmeta, the rlib and both ``.d`` files deleted, a rebuild
##      with cached-output restore enabled is a cache hit for both edges
##      that brings back the rmeta and the rlib and NOT the ``.d`` files:
##      the cached outputs do not include them.
##   5. The embedded-path scan the engine applies to a portable record's
##      outputs (``scanOutputForEmbeddedRoots``, the same scanner), run over
##      the engine's declared outputs of each edge with the edge's output
##      directory as the needle, finds nothing. Positive control: the same
##      scan of each ``.d`` file finds the output directory, so the scan can
##      see what it is looking for, and would fail if the ``.d`` were still
##      declared.
##   6. After the ``include_str!`` target changes (with the ``.d`` files
##      still absent from disk, as the restore left them), the metadata edge
##      runs again. Its declared inputs are the crate's ``.rs`` files and
##      ``Cargo.toml`` only, so the record's copy of what its ``.d`` said is
##      the only thing that can invalidate it.
##
## Why the scan's needle is the output directory and not the project root:
## Mode A passes no ``--remap-path-prefix`` yet, and the crate's source path
## is absolute, so the rlib and rmeta may still carry the project path.
## Removing the ``.d`` from the outputs does not change that; it removes the
## one output that names the output directory. A scan for the project root
## would test the remap that Mode A does not have, not this change.
##
## Falsifying mutation: putting the ``.d`` back into either edge's
## ``outputs`` in ``conventions/rust.nim`` fails check 1, check 4 (the
## restore brings the ``.d`` back) and check 5 (the scan names it).
## Dropping the depfile instead fails checks 2 and 6.
##
## Mocks and stand-ins. ``cargo metadata``, the production emitter
## (``rustConvention().emitFragment``), the scheduler (``runBuild``), the
## evidence collector, the action cache, the CAS restore and rustc are all
## real; the cargo and rustc used are whichever are on ``PATH``, as in the
## other Mode A cases, and the case is skipped with a reason when either is
## missing. One step is re-done here rather than called: turning each
## emitted ``BuildActionDef`` into an engine ``BuildAction``. The CLI's
## lowering (``lowerGraphAction`` in ``repro_cli_support``) is private, so
## the test passes the emitted argv, cwd, deps, inputs, outputs, depfile and
## environment to the engine's ``action`` constructor unchanged. With a
## depfile and no explicit policy that constructor builds the same
## recognized-format policy the CLI lowers ``makeDepfilePolicy(path)`` to
## (one make-depfile report over that path, ``required = false``), and the
## outputs, the subject of this test, come straight from the emitter.
## RunQuota is bypassed (``bypassRunQuota``) so the test needs no daemon.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
from repro_test_support import testCaseScratchSlug

import repro_core
import repro_core/input_check_policy
import repro_build_engine
import repro_build_engine/embedded_root_scan
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

const
  CrateName = "depprobe"
  ReuseDecisions = {cdHit, cdHybridCutoff}

let TmpDir = "build/test-tmp/t_rust_mode_a_depfile_is_read_not_cached" /
  testCaseScratchSlug()

proc rustToolchainAvailable(): bool =
  findExe("rustc").len > 0 and findExe("cargo").len > 0

proc isolateFromAmbientCargo(root: string) =
  ## Clear what a developer shell may export to steer cargo or rustc, and
  ## give cargo an empty home, as the other Mode A cases do (Cargo
  ## reference, "Environment variables Cargo reads":
  ## https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-reads).
  ## Process-wide on purpose: this file is its own process.
  for name in ["CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR",
               "CARGO_BUILD_TARGET", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS",
               "CARGO_BUILD_RUSTFLAGS", "RUSTC", "CARGO_BUILD_RUSTC",
               "RUSTC_WRAPPER", "CARGO_BUILD_RUSTC_WRAPPER",
               "RUSTC_WORKSPACE_WRAPPER",
               "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER"]:
    delEnv(name)
  let cargoHome = root / "cargo-home"
  createDir(cargoHome)
  putEnv("CARGO_HOME", cargoHome)

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc callArg(action: BuildActionDef; name: string): string =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg.encodedValue
  ""

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  let encoded = action.callArg("argv")
  if encoded.len == 0:
    return @[]
  encoded.split("\x1f")

proc writeFixture(root: string) =
  ## A library crate with a ``mod`` file (declared: it is a ``.rs`` under
  ## ``src/``) and an ``include_str!`` of ``assets/data.txt`` (named only by
  ## rustc's dep-info).
  createDir(root / "src")
  createDir(root / "assets")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package " & CrateName & ":\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[package]\n" &
    "name = \"" & CrateName & "\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n")
  writeFile(root / "src" / "lib.rs",
    "mod helper;\n" &
    "pub const DATA: &str = include_str!(\"../assets/data.txt\");\n" &
    "pub fn answer() -> u32 { helper::value() }\n")
  writeFile(root / "src" / "helper.rs",
    "pub fn value() -> u32 { 4217 }\n")
  writeFile(root / "assets" / "data.txt", "generation-1\n")

proc toEngineAction(def: BuildActionDef; projectRoot: string): BuildAction =
  ## The emitted edge as the engine sees it. See the header for why this is
  ## spelled out here and what it keeps unchanged.
  let argv = inlineArgvOf(def)
  doAssert argv.len > 0, "edge " & def.id & " has no inline argv"
  let cwd =
    block:
      let declared = def.callArg("cwd")
      if declared.len > 0: declared else: projectRoot
  var env: seq[string] = @[]
  for (key, value) in def.env:
    env.add(key & "=" & value)
  action(def.id, argv,
    cwd = cwd,
    deps = def.deps,
    inputs = def.inputs,
    outputs = def.outputs,
    optionalOutputs = def.optionalOutputs,
    cacheable = def.cacheable,
    weakFingerprint = weakFingerprintFromText(
      "t_rust_mode_a_depfile_is_read_not_cached\n" & def.id & "\n" &
        argv.join("\x1f")),
    actionCachePolicy = ffpHybrid,
    depfile = def.depfile,
    env = env,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc engineOutputs(act: BuildAction): seq[string] =
  ## What the engine would store and restore, and what its embedded-path
  ## scan reads: ``outputs``, ``optionalOutputs`` and ``declaredOutputs``,
  ## resolved against the action's cwd.
  for output in act.outputs & act.optionalOutputs & act.declaredOutputs:
    result.add(if output.isAbsolute: output else: act.cwd / output)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc depfileInputsOf(res: ActionResult): seq[string] =
  for path in res.evidence.depfileInputs:
    result.add(path)

proc names(paths: openArray[string]; file, cwd: string): bool =
  ## Whether `paths` names `file`, compared after normalization (rustc
  ## writes the path as it reached it, `src/../assets/data.txt`); a relative
  ## entry is read against `cwd`, the edge's working directory.
  let wanted = os.normalizedPath(file)
  for path in paths:
    let absolute = if path.isAbsolute: path else: cwd / path
    if os.normalizedPath(absolute) == wanted:
      return true
  false

proc testConfig(cacheRoot: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32
  # Store the output payloads and restore deleted outputs from them on a
  # hit: the configuration in which "what the record caches" is observable
  # as "what a restore brings back".
  enableCachedOutputRestore(result)

proc traceOf(res: BuildRunResult; id: string): string =
  for event in res.trace:
    if event.actionId == id:
      result.add("\n  " & event.event & " " & event.detail)

suite "Rust Mode A: the dep-info file is read, not cached":

  test "the .d is the depfile, not an output, and still invalidates the edge":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let base = absolutePath(TmpDir / "read-not-cached")
      if dirExists(base):
        removeDir(base)
      defer: removeDir(base)
      isolateFromAmbientCargo(base)
      let project = base / "project"
      writeFixture(project)
      let dataFile = project / "assets" / "data.txt"

      let conv = rust_convention.rustConvention()
      let request = dummyRequest(project)
      require conv.recognize(project, request)
      let fragment = conv.emitFragment(project, request)

      var defs: seq[BuildActionDef] = @[]
      var metadataDef, linkDef: BuildActionDef
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let def = decodeBuildActionPayload(toBytes(node.payload))
        let argv = inlineArgvOf(def)
        if argv.len == 0 or not argv[0].extractFilename.startsWith("rustc"):
          continue
        # The library's unit-test crate (``rustc-test-compile-*``) belongs
        # to the non-default ``test`` target; the default target is the
        # library's metadata and link passes.
        if def.id.startsWith("rustc-metadata-"):
          metadataDef = def
          defs.add(def)
        elif def.id.startsWith("rustc-link-"):
          linkDef = def
          defs.add(def)
        else:
          checkpoint("not a default-target rustc edge: " & def.id)
      checkpoint("default-target rustc edges: " & $defs.len)
      require defs.len == 2
      require metadataDef.id.len > 0
      require linkDef.id.len > 0

      # --- 1. The emitted edges: the .d is the depfile and not an output.
      for def in [metadataDef, linkDef]:
        checkpoint(def.id & ": outputs " & $def.outputs & ", optional " &
          $def.optionalOutputs & ", depfile " & def.depfile)
        check def.depfile.endsWith(".d")
        check def.dependencyPolicy.kind == bdpMakeDepfile
        check def.dependencyPolicy.depfiles == @[def.depfile]
        check def.depfile notin def.outputs
        check def.depfile notin def.optionalOutputs
        check def.outputs.len == 1
        for output in def.outputs & def.optionalOutputs:
          check not output.endsWith(".d")
      check metadataDef.outputs[0].endsWith(".rmeta")
      check linkDef.outputs[0].endsWith(".rlib")

      let metadataAct = toEngineAction(metadataDef, project)
      let linkAct = toEngineAction(linkDef, project)
      let g = graph([metadataAct, linkAct])
      let config = testConfig(base / "cache")
      let rmeta = metadataDef.outputs[0]
      let rlib = linkDef.outputs[0]
      let depfiles = [metadataDef.depfile, linkDef.depfile]

      # --- 2. First build: rustc writes the .d files and the engine reads them.
      let first = runBuild(g, config)
      for act in [metadataAct, linkAct]:
        let r = first.byId(act.id)
        checkpoint("first " & act.id & ": status " & $r.status & ", exit " &
          $r.exitCode & ", depfile inputs " & $r.depfileInputsOf() &
          "\nstderr: " & r.stderr & "\ntrace:" & first.traceOf(act.id))
        require r.status == asSucceeded
        check r.launched
        check r.depfileInputsOf().names(dataFile, act.cwd)
      check fileExists(rmeta)
      check fileExists(rlib)
      for depfile in depfiles:
        check fileExists(depfile)
        check readFile(depfile).contains("data.txt")

      # --- 5. The embedded-path scan of the declared outputs. The output
      # directory is where the edges write; only the .d files name it.
      let outDirRoot = project / ".repro" / "build"
      let needles = [EmbeddedRootNeedle(label: "output directory",
        path: outDirRoot)]
      for depfile in depfiles:
        # Positive control: the scan sees the output directory in the .d.
        let control = scanOutputForEmbeddedRoots(depfile, needles)
        checkpoint("control scan of " & depfile & ": found " &
          $control.found & " " & control.where)
        check control.found
      for act in [metadataAct, linkAct]:
        for output in act.engineOutputs():
          let finding = scanOutputForEmbeddedRoots(output, needles)
          checkpoint("scan of " & output & ": found " & $finding.found &
            " " & finding.where & " " & finding.unscannable)
          check not finding.found
          check finding.unscannable.len == 0
          check not output.endsWith(".d")

      # --- 3. Unchanged: both edges are served from the cache.
      let warm = runBuild(g, config)
      for act in [metadataAct, linkAct]:
        let r = warm.byId(act.id)
        checkpoint("warm " & act.id & ": decision " & $r.cacheDecision &
          ", launched " & $r.launched & "\ntrace:" & warm.traceOf(act.id))
        check r.cacheDecision in ReuseDecisions
        check not r.launched

      # --- 4. Restore: the cached outputs are the rmeta and the rlib only.
      for path in [rmeta, rlib, depfiles[0], depfiles[1]]:
        removeFile(path)
      let restored = runBuild(g, config)
      for act in [metadataAct, linkAct]:
        let r = restored.byId(act.id)
        checkpoint("restore " & act.id & ": decision " & $r.cacheDecision &
          ", launched " & $r.launched & "\ntrace:" &
          restored.traceOf(act.id))
        check r.cacheDecision in ReuseDecisions
        check not r.launched
      check fileExists(rmeta)
      check fileExists(rlib)
      for depfile in depfiles:
        check not fileExists(depfile)

      # --- 6. The include_str! target changes: the metadata edge re-runs,
      # though no declared input changed and its .d is not on disk.
      writeFile(dataFile, "generation-2\n")
      let changed = runBuild(g, config)
      let rm = changed.byId(metadataAct.id)
      checkpoint("changed " & metadataAct.id & ": decision " &
        $rm.cacheDecision & ", launched " & $rm.launched & "\ntrace:" &
        changed.traceOf(metadataAct.id))
      check rm.status == asSucceeded
      check rm.cacheDecision notin ReuseDecisions
      check rm.launched
      # And it read the .d it wrote again.
      check rm.depfileInputsOf().names(dataFile, metadataAct.cwd)
      check fileExists(metadataDef.depfile)

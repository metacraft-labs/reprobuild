## Rust convention (Mode A): a package's library and binary are two targets,
## and a path dependency outside the workspace is not silently dropped.
##
## Two cases, each against the real toolchain:
##
## 1. **A library and a binary that share a crate name.** Cargo's default
##    layout, ``src/lib.rs`` plus ``src/main.rs``, gives both targets the
##    package's name (Cargo reference, "Cargo Targets", "Target
##    auto-discovery":
##    https://doc.rust-lang.org/cargo/reference/cargo-targets.html#target-auto-discovery),
##    and the binary uses the library by that name. The fixture is the
##    package ``foo`` whose ``main`` prints ``foo::x()``. The test requires:
##
##      * the fragment is one the engine accepts: no two actions share an
##        id, no two actions declare one output, every dependency names an
##        action of the fragment, and no two graph nodes share an id (the
##        library and the binary are two named targets). These are the
##        checks ``validateGraph`` in ``repro_build_engine`` applies, which
##        is private to that module;
##      * the units match cargo's: ``cargo build -v`` prints the rustc argv
##        of each unit, and for every Mode A rustc action the test finds
##        cargo's unit for the same target (crate name, crate type) and
##        requires the same ``--extern`` crate names. Cargo passes the
##        binary ``--extern foo=<the library's rlib>``;
##      * the library gets a metadata and a link action and the binary only
##        a link action. Pipelining exists so that dependents can
##        type-check against a library's metadata early; nothing depends
##        on a binary, and cargo itself emits no metadata-only pass for
##        one (``--emit=dep-info,link``);
##      * running the emitted actions with the real ``rustc``, in dependency
##        order and with the environment each declares, builds a binary
##        that prints what cargo's binary prints.
##
## 2. **A path dependency on a package outside the workspace.** Under a
##    scratch parent directory, ``ws/`` is a virtual workspace whose one
##    member depends on ``outside = { path = "../../outside" }``, a package
##    beside ``ws/`` that is no workspace member. ``cargo metadata
##    --no-deps``, which Mode A reads, lists the member alone, so Mode A
##    cannot compile ``outside``; dropping the dependency leaves ``rustc``
##    with an unresolved crate. Mode A compiles workspace members only, so
##    the whole workspace must build through cargo (Mode B). The test
##    checks with ``cargo build -v`` that cargo really compiles ``outside``
##    and hands the member's binary ``--extern outside=...`` (otherwise the
##    fixture, not Mode A, is wrong), then requires Mode A to emit no rustc
##    action and one cargo delegation (Mode B) action instead.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, and the cargo and
## rustc used are whichever are on ``PATH``. When either is missing the case
## is skipped with a reason, as the other Rust convention cases are.
##
## Each case first clears what a developer shell may export for cargo (see
## ``isolateFromAmbientCargo``): an inherited ``RUSTFLAGS``, wrapper or
## target directory would change cargo's units and not Mode A's.

import std/[algorithm, os, osproc, sets, streams, strtabs, strutils, tables,
            tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

type
  UnitKey = tuple[crateName, crateType: string]
    ## One non-test compile unit independently of who emitted it.

proc isolateFromAmbientCargo(root: string) =
  ## Clear, for this whole process, every variable through which the
  ## caller's shell could steer cargo: its output placement and target, the
  ## rustc it runs and the wrappers around it, and the flags it adds (Cargo
  ## reference, "Environment variables Cargo reads":
  ## https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-reads).
  ## ``CARGO_HOME`` moves to an empty directory under ``root`` so a user's
  ## ``$CARGO_HOME/config.toml`` cannot add flags either; the fixtures have
  ## no registry dependency, so nothing needs the real one. The same
  ## isolation as ``test_rust_convention_crate_env_vs_cargo``. Process-wide
  ## on purpose: this file is its own process.
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

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc rustToolchainAvailable(): bool =
  findExe("rustc").len > 0 and findExe("cargo").len > 0

proc flagValue(argv: openArray[string]; flag: string): string =
  ## The value of ``flag`` in ``argv``, in either the ``--flag value`` form
  ## (Mode A) or the ``--flag=value`` form (cargo). Empty when absent.
  for i, arg in argv:
    if arg == flag and i + 1 < argv.len:
      return argv[i + 1]
    if arg.startsWith(flag & "="):
      return arg[flag.len + 1 .. ^1]
  ""

proc externNames(argv: openArray[string]): seq[string] =
  ## The crate names of every ``--extern <name>=<path>``, sorted.
  for i, arg in argv:
    if arg == "--extern" and i + 1 < argv.len:
      result.add(argv[i + 1].split('=', maxsplit = 1)[0])
  result.sort()

proc externPath(argv: openArray[string]; crate: string): string =
  ## The path of ``--extern <crate>=<path>``; empty when absent.
  for i, arg in argv:
    if arg == "--extern" and i + 1 < argv.len and
        argv[i + 1].startsWith(crate & "="):
      return argv[i + 1][crate.len + 1 .. ^1]
  ""

proc unitKeyOf(argv: openArray[string]): UnitKey =
  (crateName: flagValue(argv, "--crate-name"),
   crateType: flagValue(argv, "--crate-type"))

proc runCapture(exe: string; args: openArray[string]; workingDir: string;
                extraEnv: openArray[(string, string)] = []):
    tuple[output: string; exitCode: int] =
  ## Run ``exe`` with the ambient environment plus ``extraEnv``, stderr
  ## folded into stdout.
  var envTab = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    envTab[k] = v
  for (name, value) in extraEnv:
    envTab[name] = value
  let p = startProcess(exe, workingDir = workingDir, args = args,
    env = envTab, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc cargoUnits(root, targetDir: string): Table[UnitKey, seq[string]] =
  ## ``cargo build -v`` of the workspace at ``root``: the rustc argv cargo
  ## ran for each unit, read from its ``Running `rustc ...``` lines. The
  ## fixtures' paths hold no space or quote, so splitting on whitespace is
  ## exact.
  let (output, exitCode) = runCapture(findExe("cargo"),
    ["build", "--workspace", "-v", "--offline", "--target-dir", targetDir],
    root)
  checkpoint "cargo build -v output:\n" & output
  doAssert exitCode == 0, "cargo build failed with exit " & $exitCode
  for line in output.splitLines():
    let start = line.find("Running `")
    if start < 0:
      continue
    let body = line[start + len("Running `") .. ^1].strip(chars = {'`', ' '})
    let argv = body.splitWhitespace()
    if argv.len == 0 or not argv[0].extractFilename.startsWith("rustc"):
      continue
    let key = unitKeyOf(argv)
    if key.crateName.len == 0:
      continue
    result[key] = argv

type
  ModeAFragment = object
    byId: Table[string, BuildActionDef]
    actionIds: seq[string]   ## every action id, in fragment order
    nodeIds: seq[string]     ## every graph node id, in fragment order
    rustcIds: seq[string]    ## the rustc actions' ids, sorted

proc modeAFragment(root: string): ModeAFragment =
  let conv = rust_convention.rustConvention()
  let request = dummyRequest(root)
  doAssert conv.recognize(root, request), "fixture not recognised"
  let fragment = conv.emitFragment(root, request)
  for node in fragment.nodes:
    result.nodeIds.add(node.id)
    if node.kind != gnkAction:
      continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    result.actionIds.add(action.id)
    result.byId[action.id] = action
    let argv = inlineArgvOf(action)
    if argv.len > 0 and argv[0].extractFilename.startsWith("rustc") and
        flagValue(argv, "--crate-name").len > 0:
      result.rustcIds.add(action.id)
  result.rustcIds.sort()

proc duplicates(values: openArray[string]): seq[string] =
  var seen = initHashSet[string]()
  for v in values:
    if v in seen and v notin result:
      result.add(v)
    seen.incl(v)

proc writeLibBinFixture(root: string) =
  createDir(root / "src")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package foo:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[package]\n" &
    "name = \"foo\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n")
  writeFile(root / "src" / "lib.rs",
    "pub fn x() -> u32 { 4217 }\n")
  writeFile(root / "src" / "main.rs",
    "fn main() {\n" &
    "    println!(\"foo says {}\", foo::x());\n" &
    "}\n")

proc writeOutsidePathDepFixture(parent: string) =
  ## ``parent/ws`` is the workspace (the project root Mode A sees);
  ## ``parent/outside`` is the path dependency beside it.
  createDir(parent / "ws" / "member" / "src")
  createDir(parent / "outside" / "src")
  writeFile(parent / "ws" / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package outsideDep:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(parent / "ws" / "Cargo.toml",
    "[workspace]\n" &
    "resolver = \"2\"\n" &
    "members = [\"member\"]\n")
  writeFile(parent / "ws" / "member" / "Cargo.toml",
    "[package]\n" &
    "name = \"member\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" &
    "[dependencies]\n" &
    "outside = { path = \"../../outside\" }\n")
  writeFile(parent / "ws" / "member" / "src" / "main.rs",
    "fn main() {\n" &
    "    println!(\"{}\", outside::y());\n" &
    "}\n")
  writeFile(parent / "outside" / "Cargo.toml",
    "[package]\n" &
    "name = \"outside\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n")
  writeFile(parent / "outside" / "src" / "lib.rs",
    "pub fn y() -> u32 { 9 }\n")

suite "rust convention: library and binary targets, path dependencies":
  test "a library and a binary sharing a crate name build like cargo's":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_lib_bin_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeLibBinFixture(root)
      let cargoTarget = root / "cargo-target"

      # Cargo first: it also writes the Cargo.lock recognition needs.
      let units = cargoUnits(root, cargoTarget)
      # The fixture is meaningful only if cargo builds two units named
      # ``foo`` and links the binary against the library.
      require ("foo", "lib") in units
      require ("foo", "bin") in units
      check externNames(units[("foo", "bin")]) == @["foo"]
      check externPath(units[("foo", "bin")], "foo").endsWith(".rlib")

      let modeA = modeAFragment(root)
      checkpoint "Mode A actions: " & $modeA.actionIds
      checkpoint "graph nodes: " & $modeA.nodeIds

      # What the engine's validateGraph refuses, and what the fragment's
      # own node table must not repeat.
      check duplicates(modeA.actionIds).len == 0
      check duplicates(modeA.nodeIds).len == 0
      var outputs: seq[string] = @[]
      for id in modeA.actionIds:
        for output in modeA.byId[id].outputs & modeA.byId[id].optionalOutputs:
          outputs.add(output)
        for dep in modeA.byId[id].deps:
          checkpoint id & " depends on " & dep
          check dep in modeA.byId
      checkpoint "declared outputs: " & $outputs
      check duplicates(outputs).len == 0

      # Each Mode A rustc action against cargo's unit for its target.
      var seen = initCountTable[UnitKey]()
      var binLink = ""
      for id in modeA.rustcIds:
        let argv = inlineArgvOf(modeA.byId[id])
        let key = unitKeyOf(argv)
        seen.inc(key)
        checkpoint id & " argv: " & argv.join(" ")
        if key notin units:
          checkpoint id & ": cargo built no unit " & $key
          check false
          continue
        check externNames(argv) == externNames(units[key])
        check flagValue(argv, "--edition") == flagValue(units[key], "--edition")
        if key == ("foo", "bin"):
          binLink = id
      # The library's metadata and link passes; the binary's link alone.
      check seen[("foo", "lib")] == 2
      check seen[("foo", "bin")] == 1
      require binLink.len > 0
      # The binary's ``--extern foo`` is the library's rlib, which another
      # action of the fragment produces and the binary's action waits for.
      let binArgv = inlineArgvOf(modeA.byId[binLink])
      let libRlib = externPath(binArgv, "foo")
      check libRlib.endsWith(".rlib")
      var producer = ""
      for id in modeA.actionIds:
        if libRlib in modeA.byId[id].outputs:
          producer = id
      checkpoint "rlib " & libRlib & " produced by " & producer
      check producer.len > 0
      check producer in modeA.byId[binLink].deps
      check libRlib in modeA.byId[binLink].inputs

      # Run the rustc actions with the real rustc, each after its deps and
      # with the environment it declares.
      var pending = modeA.rustcIds
      var ran: seq[string] = @[]
      while pending.len > 0:
        var next: seq[string] = @[]
        for id in pending:
          var ready = true
          for dep in modeA.byId[id].deps:
            if dep in modeA.rustcIds and dep notin ran:
              ready = false
          if ready:
            let argv = inlineArgvOf(modeA.byId[id])
            let (output, exitCode) = runCapture(argv[0], argv[1 .. ^1], root,
              modeA.byId[id].env)
            checkpoint id & " rustc output:\n" & output
            check exitCode == 0
            ran.add(id)
          else:
            next.add(id)
        require next.len < pending.len
        pending = next

      let cargoRun = runCapture(cargoTarget / "debug" / "foo", [], root)
      check cargoRun.exitCode == 0
      check cargoRun.output == "foo says 4217\n"
      let modeRun = runCapture(modeA.byId[binLink].outputs[0], [], root)
      checkpoint "Mode A binary output: " & modeRun.output
      check modeRun.exitCode == 0
      check modeRun.output == cargoRun.output

  test "a path dependency outside the workspace sends it to cargo (Mode B)":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_convention_outside_path_dep_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      writeOutsidePathDepFixture(parent)
      let root = parent / "ws"

      let units = cargoUnits(root, parent / "cargo-target")
      # Cargo compiles the outside package and hands it to the member. If
      # it did not, the fixture would not exercise the dependency at all.
      require ("outside", "lib") in units
      require ("member", "bin") in units
      check externNames(units[("member", "bin")]) == @["outside"]

      let modeA = modeAFragment(root)
      checkpoint "Mode A actions: " & $modeA.actionIds
      for id in modeA.rustcIds:
        checkpoint id & " argv: " & inlineArgvOf(modeA.byId[id]).join(" ")
      # Mode A lists only workspace members, so it can compile no unit of
      # this workspace with ``outside`` available: every unit goes to cargo.
      check modeA.rustcIds.len == 0
      var delegations: seq[string] = @[]
      for id in modeA.actionIds:
        if id.startsWith("crude-build-"):
          delegations.add(id)
      check delegations.len == 1
      if delegations.len == 1:
        let argv = inlineArgvOf(modeA.byId[delegations[0]])
        checkpoint delegations[0] & " argv: " & argv.join(" ")
        check "build" in argv
        var namesCargo = false
        for arg in argv:
          if arg.extractFilename == "cargo" or
              arg.extractFilename == "cargo.exe":
            namesCargo = true
        check namesCargo

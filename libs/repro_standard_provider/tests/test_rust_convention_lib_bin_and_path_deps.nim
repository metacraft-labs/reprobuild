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
## 3. **Test targets with ``harness = false``** (reprobuild-pm
##    issues/2026-11-17-rust-mode-a-compiles-harness-false-integration-tests-with-the-test-harness.md).
##    Such a target is a plain program whose own ``main`` is the test; cargo
##    compiles it without ``--test`` (Cargo reference, "Cargo Targets", "The
##    ``harness`` field":
##    https://doc.rust-lang.org/cargo/reference/cargo-targets.html#the-harness-field).
##    With ``--test`` rustc links libtest's runner instead: the binary
##    prints ``running 0 tests`` and exits 0 whatever the body would do.
##    ``cargo metadata`` does not report ``harness``. The fixture has two
##    such ``[[test]]`` targets, ``custom`` (its ``main`` prints a line only
##    it prints) and ``failing`` (its ``main`` panics), an ordinary test
##    ``normal`` with a ``#[test]`` function, and a ``[[bench]]`` with
##    ``harness = false`` (Mode A builds no bench). The test checks with
##    ``cargo test --no-run -v`` which units cargo builds with ``--test``,
##    requires each Mode A test compile to match (``--test``, or cargo's
##    ``--cfg test`` in its place), then runs Mode A's rustc actions and
##    test-run actions with the real ``rustc``: ``custom`` must print its
##    line and, from a ``cfg!(test)`` branch, ``cfg test on``, and pass;
##    ``failing`` must fail; ``normal`` must run its ``#[test]``.
##
##    A setting Mode A's manifest scan cannot tie to a named ``[[test]]``
##    (here the inline-table form ``test = [{ ..., harness = false }]`` in a
##    workspace member, a quoted key spelled with an escape, or a
##    multi-line string that holds a line like a table header) sends the
##    workspace to cargo (Mode B), as Rust.md §"Recognition" item 6 says.
##    ``harness = false`` that is only a comment changes nothing.
##
## 4. **A registry dev-dependency.** The package ``member`` (no
##    ``[workspace]``) has an integration test ``tests/it.rs`` that calls
##    ``seven::seven()``, and ``[dev-dependencies] seven = "1"``. The crate
##    is served offline by Cargo's source replacement (``[source.crates-io]
##    replace-with`` a ``directory`` source in the scratch ``CARGO_HOME``;
##    Cargo reference, "Source Replacement"), which ``cargo metadata
##    --no-deps`` does not reveal: it reports the dependency's ``source`` as
##    the crates.io registry, as for any registry dependency. Rust.md
##    §"Recognition", item 6 sends a workspace with any dependency that is
##    no workspace member to Mode B and exempts no dependency kind. Mode A
##    gives a test compile no ``--extern`` for a registry crate, so keeping
##    the workspace in Mode A fails ``repro build .#test`` with an
##    unresolved crate in ``rustc``. The test checks with ``cargo test
##    --no-run -v`` that cargo hands the test ``--extern seven=...``, then
##    requires Mode A to emit no rustc action and one cargo delegation.
##    Regression test for reprobuild-pm
##    issues/2026-11-17-rust-mode-a-tolerates-registry-dev-dependencies-that-its-test-compile-cannot-resolve.md.
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
  ## ``$CARGO_HOME/config.toml`` cannot add flags either. Nothing needs the
  ## real one: the one registry dependency (case 3) is served from a
  ## ``directory`` source that its fixture configures in this cargo home. The same
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

proc cargoTestUnits(root, targetDir: string): Table[string, seq[string]] =
  ## ``cargo test --no-run -v`` of the package at ``root``: the rustc argv
  ## of each unit, keyed by crate name. A test unit has ``--test`` and no
  ## ``--crate-type``, so ``cargoUnits``' key does not tell it apart.
  let (output, exitCode) = runCapture(findExe("cargo"),
    ["test", "--no-run", "-v", "--offline", "--target-dir", targetDir],
    root)
  checkpoint "cargo test --no-run -v output:\n" & output
  doAssert exitCode == 0, "cargo test --no-run failed with exit " & $exitCode
  for line in output.splitLines():
    let start = line.find("Running `")
    if start < 0:
      continue
    let body = line[start + len("Running `") .. ^1].strip(chars = {'`', ' '})
    let argv = body.splitWhitespace()
    if argv.len == 0 or not argv[0].extractFilename.startsWith("rustc"):
      continue
    let name = flagValue(argv, "--crate-name")
    if name.len > 0 and "--test" in argv:
      result[name] = argv

type
  ModeAFragment = object
    byId: Table[string, BuildActionDef]
    actionIds: seq[string]   ## every action id, in fragment order
    nodeIds: seq[string]     ## every graph node id, in fragment order
    rustcIds: seq[string]
      ## the rustc actions' ids, sorted, without the test crates of the
      ## ``test`` target (``rustc-test-compile-*``, compiled with
      ## ``--test`` or, for ``harness = false``, ``--cfg test``):
      ## ``cargo build`` builds none
    allRustcIds: seq[string]
      ## every rustc action's id, sorted, test crates included: what
      ## ``cargo test`` builds

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
      result.allRustcIds.add(action.id)
      if not action.id.startsWith("rustc-test-compile-"):
        result.rustcIds.add(action.id)
  result.rustcIds.sort()
  result.allRustcIds.sort()

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

proc writeNoHarnessFixture(root: string; manifestTail: string;
                           manifestHead = "") =
  ## A package ``noharness`` with a library and ``tests/custom.rs``, whose
  ## ``main`` prints a line only it prints. ``manifestTail`` (after the
  ## ``[package]`` table) or ``manifestHead`` (top-level keys, before it)
  ## declares, or does not declare, the test target.
  createDir(root / "src")
  createDir(root / "tests")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package noharness:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    manifestHead &
    "[package]\n" &
    "name = \"noharness\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" & manifestTail)
  writeFile(root / "src" / "lib.rs",
    "pub fn answer() -> u32 { 42 }\n")
  writeFile(root / "tests" / "custom.rs",
    "fn main() {\n" &
    "    assert_eq!(noharness::answer(), 42);\n" &
    "    println!(\"custom main ran\");\n" &
    "    if cfg!(test) {\n" &
    "        println!(\"cfg test on\");\n" &
    "    }\n" &
    "}\n")

proc cargoTestOutput(root: string): string =
  ## ``cargo test --test custom`` in ``root``; also writes ``Cargo.lock``,
  ## which recognition needs.
  let (output, exitCode) = runCapture(findExe("cargo"),
    ["test", "--offline", "--test", "custom", "--target-dir",
     root / "cargo-target"], root)
  checkpoint "cargo test output:\n" & output
  doAssert exitCode == 0, "cargo test failed with exit " & $exitCode
  output

proc cargoTestUnits(root: string): Table[string, seq[string]] =
  ## ``cargo test --no-run -v``: the rustc argv of each unit cargo builds
  ## for its tests, by crate name, from its ``Running `rustc ...``` lines.
  ## Only the integration tests' crate names are unique here, which is all
  ## the caller looks up. A target directory of its own, so that no unit is
  ## already fresh and every one prints its argv.
  let (output, exitCode) = runCapture(findExe("cargo"),
    ["test", "--no-run", "-v", "--offline", "--target-dir",
     root / "cargo-units-target"], root)
  checkpoint "cargo test --no-run -v output:\n" & output
  doAssert exitCode == 0, "cargo test --no-run failed with exit " & $exitCode
  for line in output.splitLines():
    let start = line.find("Running `")
    if start < 0:
      continue
    let body = line[start + len("Running `") .. ^1].strip(chars = {'`', ' '})
    let argv = body.splitWhitespace()
    if argv.len == 0 or not argv[0].extractFilename.startsWith("rustc"):
      continue
    let name = flagValue(argv, "--crate-name")
    if name.len > 0:
      result[name] = argv

template checkDelegatedToCargo(root: string) =
  ## Mode A emits no rustc action and one cargo delegation for ``root``.
  ## A template, not a proc: ``check`` marks the enclosing test failed only
  ## when it expands inside that test's body.
  let modeA = modeAFragment(root)
  checkpoint "Mode A actions: " & $modeA.actionIds
  for id in modeA.rustcIds:
    checkpoint id & " argv: " & inlineArgvOf(modeA.byId[id]).join(" ")
  check modeA.rustcIds.len == 0
  var delegations: seq[string] = @[]
  for id in modeA.actionIds:
    if id.startsWith("crude-build-"):
      delegations.add(id)
  check delegations.len == 1

proc testActionId(modeA: ModeAFragment; phase, target: string): string =
  ## The id of ``target``'s ``test-<phase>`` action; empty when absent.
  for id in modeA.actionIds:
    if id.startsWith("rustc-test-" & phase & "-") and
        id.endsWith(".test." & target):
      return id
  ""

proc writeRegistryDevDepFixture(parent: string) =
  ## ``parent/pkg`` is the package (the project root Mode A sees);
  ## ``parent/vendor/seven`` is the registry crate, served through a
  ## ``directory`` source that ``$CARGO_HOME/config.toml`` puts in place
  ## of crates.io, so cargo resolves it offline.
  let root = parent / "pkg"
  createDir(root / "src")
  createDir(root / "tests")
  createDir(parent / "vendor" / "seven" / "src")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package member:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[package]\n" &
    "name = \"member\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" &
    "[dev-dependencies]\n" &
    "seven = \"1\"\n")
  writeFile(root / "src" / "lib.rs",
    "pub fn x() -> u32 { 3 }\n")
  writeFile(root / "tests" / "it.rs",
    "#[test]\n" &
    "fn sums() {\n" &
    "    assert_eq!(member::x() + seven::seven(), 10);\n" &
    "}\n")
  writeFile(parent / "vendor" / "seven" / "Cargo.toml",
    "[package]\n" &
    "name = \"seven\"\n" &
    "version = \"1.0.0\"\n" &
    "edition = \"2021\"\n")
  writeFile(parent / "vendor" / "seven" / "src" / "lib.rs",
    "pub fn seven() -> u32 { 7 }\n")
  writeFile(parent / "vendor" / "seven" / ".cargo-checksum.json",
    "{\"files\":{},\"package\":" &
    "\"0000000000000000000000000000000000000000000000000000000000000000\"}\n")
  # Only ever the scratch cargo home ``isolateFromAmbientCargo(parent)``
  # set: never a developer's real ``~/.cargo/config.toml``.
  let cargoHome = getEnv("CARGO_HOME")
  doAssert cargoHome == parent / "cargo-home",
    "isolateFromAmbientCargo(parent) must run first; CARGO_HOME is " &
    cargoHome
  writeFile(cargoHome / "config.toml",
    "[source.crates-io]\n" &
    "replace-with = \"vendored\"\n" &
    "\n" &
    "[source.vendored]\n" &
    "directory = \"" & (parent / "vendor") & "\"\n")

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

  test "a [[test]] with harness = false is built without --test and its main runs":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_no_harness_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeNoHarnessFixture(root,
        "[[test]]\n" &
        "name = \"custom\"\n" &
        "path = \"tests/custom.rs\"\n" &
        "harness = false   # its main is the test\n" &
        "\n" &
        "[[test]]\n" &
        "harness = false\n" &
        "name = \"failing\"\n" &
        "\n" &
        "[[bench]]\n" &
        "name = \"b\"\n" &
        "harness = false\n")
      writeFile(root / "tests" / "failing.rs",
        "fn main() {\n" &
        "    assert_eq!(noharness::answer(), 41, \"failing main ran\");\n" &
        "}\n")
      writeFile(root / "tests" / "normal.rs",
        "#[test]\n" &
        "fn normal_test_ran() {\n" &
        "    assert_eq!(noharness::answer(), 42);\n" &
        "}\n")
      createDir(root / "benches")
      writeFile(root / "benches" / "b.rs", "fn main() {}\n")

      # Cargo runs custom's own main, and builds the two harness = false
      # tests without --test and the ordinary one with it. If it did not,
      # the fixture would not tell a harness build from a plain one.
      let cargoOutput = cargoTestOutput(root)
      require "custom main ran" in cargoOutput
      require "cfg test on" in cargoOutput
      let units = cargoTestUnits(root)
      require "custom" in units
      require "failing" in units
      require "normal" in units
      require "--test" notin units["custom"]
      require "--test" notin units["failing"]
      require "--test" in units["normal"]

      let modeA = modeAFragment(root)
      checkpoint "Mode A actions: " & $modeA.actionIds
      for id in modeA.actionIds:
        check not id.startsWith("crude-build-")
      for target in ["custom", "failing", "normal"]:
        let compileId = testActionId(modeA, "compile", target)
        checkpoint target & " compile action: " & compileId
        require compileId.len > 0
        let argv = inlineArgvOf(modeA.byId[compileId])
        checkpoint compileId & " argv: " & argv.join(" ")
        check ("--test" in argv) == ("--test" in units[target])
        # Cargo passes ``--cfg test`` to a harness = false build.
        check flagValue(argv, "--cfg") == flagValue(units[target], "--cfg")

      # Build every rustc action with the real rustc, in dependency order.
      var pending = modeA.allRustcIds
      var ran: seq[string] = @[]
      while pending.len > 0:
        var next: seq[string] = @[]
        for id in pending:
          var ready = true
          for dep in modeA.byId[id].deps:
            if dep in modeA.allRustcIds and dep notin ran:
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

      # Run each test as Mode A's test-run action does.
      proc runTest(modeA: ModeAFragment; root, target: string):
          tuple[output: string; exitCode: int] =
        let runId = testActionId(modeA, "run", target)
        doAssert runId.len > 0, "no test-run action for " & target
        let argv = inlineArgvOf(modeA.byId[runId])
        result = runCapture(argv[0], argv[1 .. ^1], root, modeA.byId[runId].env)
        checkpoint runId & " output (exit " & $result.exitCode & "):\n" &
          result.output
      let custom = runTest(modeA, root, "custom")
      check custom.exitCode == 0
      check "custom main ran" in custom.output
      check "cfg test on" in custom.output
      let failing = runTest(modeA, root, "failing")
      check failing.exitCode != 0
      check "failing main ran" in failing.output
      let normal = runTest(modeA, root, "normal")
      check normal.exitCode == 0
      check "normal_test_ran ... ok" in normal.output


  test "harness = false Mode A cannot attribute (an inline table) sends the workspace to cargo":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_convention_no_harness_ws_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let member = parent / "member"
      writeNoHarnessFixture(member, "",
        manifestHead =
          "test = [{ name = \"custom\", path = \"tests/custom.rs\", " &
            "harness = false }]\n")
      writeFile(parent / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package noharnessWs:\n" &
        "  uses:\n" &
        "    \"rust >=1.80\"\n")
      writeFile(parent / "Cargo.toml",
        "[workspace]\n" &
        "resolver = \"2\"\n" &
        "members = [\"member\"]\n")
      require "custom main ran" in cargoTestOutput(parent)
      checkDelegatedToCargo(parent)

  test "harness = false on a [lib] or a [[bin]] sends the workspace to cargo":
    # Mode A compiles a library's and a binary's test crate with
    # ``--test`` and nothing else. On a ``harness = false`` target that
    # would replace the target's own ``main`` with libtest's runner, which
    # finds no ``#[test]``, prints "running 0 tests" and passes whatever
    # the target does (Rust.md §"Test commands"). The scan does not
    # attribute such a setting, so the workspace must go to Mode B.
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      for (label, manifestTail) in [
          ("lib", "[lib]\nharness = false\n"),
          ("bin", "[[bin]]\nname = \"tool\"\npath = \"src/main.rs\"\n" &
            "harness = false\n")]:
        checkpoint "harness = false on the " & label
        let root = createTempDir("test_rust_convention_harness_" & label &
          "_", "")
        defer:
          removeDir(root)
        isolateFromAmbientCargo(root)
        writeNoHarnessFixture(root, manifestTail)
        writeFile(root / "src" / "main.rs",
          "fn main() { assert_eq!(noharness::answer(), 42); }\n")
        # Cargo accepts the manifest (and writes the ``Cargo.lock``
        # recognition needs); ``custom`` keeps the harness here.
        discard cargoTestOutput(root)
        checkDelegatedToCargo(root)

  test "a quoted harness key spelled with an escape sends the workspace to cargo":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_harness_escape_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      # ``"harness"`` is the key ``harness`` to a TOML reader; the
      # scan cannot read it, so it must not keep the package in Mode A.
      writeNoHarnessFixture(root,
        "[[test]]\n" &
        "name = \"custom\"\n" &
        "\"harn\\u0065ss\" = false\n")
      require "custom main ran" in cargoTestOutput(root)
      checkDelegatedToCargo(root)

  test "a multi-line string in the manifest sends the workspace to cargo":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_harness_mlstring_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      # A line that looks like ``[[bench]]`` inside a multi-line string: a
      # line-wise reader would credit custom's setting to a bench and keep
      # ``--test`` on custom.
      writeNoHarnessFixture(root,
        "[[test]]\n" &
        "name = \"custom\"\n" &
        "note = '''\n" &
        "[[bench]]\n" &
        "'''\n" &
        "harness = false\n")
      require "custom main ran" in cargoTestOutput(root)
      checkDelegatedToCargo(root)

  test "harness = false only in a comment leaves the package in Mode A":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_harness_comment_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeNoHarnessFixture(root,
        "# harness = false\n" &
        "[[test]]\n" &
        "name = \"custom\"\n" &
        "path = \"tests/custom.rs\"\n")
      # Under libtest's harness the file's main does not run: cargo prints
      # ``running 0 tests``. Mode A's ``--test`` build matches cargo here.
      let output = cargoTestOutput(root)
      require "custom main ran" notin output
      require "running 0 tests" in output
      let modeA = modeAFragment(root)
      checkpoint "Mode A actions: " & $modeA.actionIds
      check modeA.rustcIds.len > 0
      for id in modeA.actionIds:
        check not id.startsWith("crude-build-")
      let compileId = testActionId(modeA, "compile", "custom")
      require compileId.len > 0
      check "--test" in inlineArgvOf(modeA.byId[compileId])

  test "a registry dev-dependency sends the workspace to cargo (Mode B)":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_convention_registry_dev_dep_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      writeRegistryDevDepFixture(parent)
      let root = parent / "pkg"

      let units = cargoTestUnits(root, parent / "cargo-target")
      # Cargo hands the integration test the dev-dependency. If it did
      # not, the fixture would not exercise the dependency at all.
      require "it" in units
      check externNames(units["it"]) == @["member", "seven"]

      let modeA = modeAFragment(root)
      checkpoint "Mode A actions: " & $modeA.actionIds
      for id in modeA.rustcIds:
        checkpoint id & " argv: " & inlineArgvOf(modeA.byId[id]).join(" ")
      # Mode A would give the test compile ``--extern member`` alone and
      # ``rustc`` would fail to resolve ``seven``: every unit goes to cargo.
      check modeA.rustcIds.len == 0
      var delegations: seq[string] = @[]
      for id in modeA.actionIds:
        if id.startsWith("crude-build-"):
          delegations.add(id)
      check delegations.len == 1

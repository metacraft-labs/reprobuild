## Rust convention (Mode A): every rustc action compiles a target under the
## edition Cargo compiles it under.
##
## Cargo lets a target table (``[lib]``, ``[[bin]]``, ``[[test]]``, ...) set
## its own ``edition`` key, which overrides the package's ``edition`` for
## that target alone (Cargo reference, "Cargo Targets", "The `edition`
## field": https://doc.rust-lang.org/cargo/reference/cargo-targets.html#the-edition-field).
## ``cargo metadata`` reports the result per target. Compiling a crate under
## another edition changes what its source means or stops it compiling
## (Edition Guide: https://doc.rust-lang.org/edition-guide/), so a Mode A
## build that took the package's edition for every target would diverge from
## ``cargo build`` without any diagnostic.
##
## The fixture is one package with ``edition = "2024"`` and four targets:
##
##   * ``[lib]`` with ``edition = "2015"``: defines ``pub fn async()``, which
##     is legal only in 2015 (``async`` is a keyword from 2018 on).
##   * ``[[bin]] edition-mix-old`` with ``edition = "2021"``: binds a
##     variable named ``gen`` (a reserved keyword in 2024) and calls
##     ``u8::try_from`` without importing ``TryFrom`` (in the prelude from
##     2021 on).
##   * ``[[bin]] edition-mix-new`` with no ``edition`` key: inherits 2024 and
##     uses an ``if let`` chain, which only 2024 accepts.
##   * ``[[test]] it`` with ``edition = "2018"``: reaches the library through
##     the 2018 path rules (no ``extern crate``), calls ``r#async``, and binds
##     ``gen``.
##
## The library and the binaries have different crate names on purpose, so
## that this test does not depend on how Mode A names the actions of a
## library and a binary that share one.
##
## The test observes the edition two independent ways, both against the real
## toolchain:
##
##   1. **Cargo's own argv.** ``cargo test --no-run -v`` prints the rustc
##      command line of every unit it builds. For each Mode A rustc action
##      the test finds cargo's unit for the same target (crate name, crate
##      type, test harness or not) and requires the two ``--edition`` values
##      to be equal.
##   2. **Real rustc.** It runs every emitted rustc action in dependency
##      order with the real ``rustc``. Each source above compiles only under
##      its own target's edition, so a wrong edition fails here even if the
##      first comparison were somehow vacuous.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, and the cargo and
## rustc used are whichever are on ``PATH``. When either is missing the case
## is skipped with a reason, as the other Rust convention cases are.

import std/[algorithm, os, osproc, strutils, tables, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

const
  LibCrate = "edition_mix"
  OldBinCrate = "edition_mix_old"
  NewBinCrate = "edition_mix_new"
  TestCrate = "it"

type
  UnitKey = tuple[crateName, crateType: string; isTest: bool]
    ## Identifies one compile unit independently of who emitted it: the
    ## crate name, the ``--crate-type`` (empty for a test harness, which
    ## cargo emits without one), and whether it is a ``--test`` build.

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

proc unitKeyOf(argv: openArray[string]): UnitKey =
  let isTest = "--test" in argv
  (crateName: flagValue(argv, "--crate-name"),
   crateType: (if isTest: "" else: flagValue(argv, "--crate-type")),
   isTest: isTest)

proc writeFixture(root: string) =
  createDir(root / "src" / "bin")
  createDir(root / "tests")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package editionMix:\n" &
    "  uses:\n" &
    "    \"rust >=1.88\"\n")
  writeFile(root / "Cargo.toml",
    "[package]\n" &
    "name = \"edition-mix\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2024\"\n" &
    "publish = false\n" &
    "\n" &
    "[lib]\n" &
    "path = \"src/lib.rs\"\n" &
    "edition = \"2015\"\n" &
    "\n" &
    "[[bin]]\n" &
    "name = \"edition-mix-old\"\n" &
    "path = \"src/bin/old.rs\"\n" &
    "edition = \"2021\"\n" &
    "\n" &
    "[[bin]]\n" &
    "name = \"edition-mix-new\"\n" &
    "path = \"src/bin/new.rs\"\n" &
    "\n" &
    "[[test]]\n" &
    "name = \"it\"\n" &
    "path = \"tests/it.rs\"\n" &
    "edition = \"2018\"\n")
  # 2015 only: ``async`` is an ordinary identifier before 2018.
  writeFile(root / "src" / "lib.rs",
    "pub fn async() -> u32 { 2015 }\n")
  # 2021 only: ``gen`` is reserved in 2024, and ``TryFrom`` is in the
  # prelude from 2021 on.
  writeFile(root / "src" / "bin" / "old.rs",
    "fn main() {\n" &
    "    let gen: u8 = u8::try_from(21u32).unwrap();\n" &
    "    println!(\"{}\", gen);\n" &
    "}\n")
  # 2024 only: ``if let`` chains.
  writeFile(root / "src" / "bin" / "new.rs",
    "fn main() {\n" &
    "    let v = Some(24u32);\n" &
    "    if let Some(x) = v && x > 0 {\n" &
    "        println!(\"{}\", x);\n" &
    "    }\n" &
    "}\n")
  # 2018 or later for the ``use`` path, before 2024 for ``gen``.
  writeFile(root / "tests" / "it.rs",
    "use edition_mix::r#async;\n" &
    "\n" &
    "#[test]\n" &
    "fn library_is_2015() {\n" &
    "    let gen = r#async();\n" &
    "    assert_eq!(gen, 2015);\n" &
    "}\n")

proc cargoUnitEditions(root, targetDir: string): Table[UnitKey, string] =
  ## Build the fixture with cargo and return the ``--edition`` cargo passed
  ## to rustc for each unit, read from ``-v``'s ``Running `rustc ...``` lines.
  ## ``cargo test --no-run`` builds the library, both binaries and the
  ## integration test, which covers every unit Mode A emits for the fixture.
  let cmd = quoteShellCommand([findExe("cargo"), "test", "--no-run", "-v",
    "--offline", "--target-dir", targetDir])
  let (output, exitCode) = execCmdEx(cmd, workingDir = root)
  checkpoint "cargo test --no-run -v output:\n" & output
  doAssert exitCode == 0, "cargo test --no-run failed with exit " & $exitCode
  for line in output.splitLines():
    let start = line.find("Running `")
    if start < 0:
      continue
    let body = line[start + len("Running `") .. ^1].strip(chars = {'`', ' '})
    let argv = body.splitWhitespace()
    let edition = flagValue(argv, "--edition")
    let key = unitKeyOf(argv)
    if key.crateName.len == 0 or edition.len == 0:
      continue
    result[key] = edition

proc runAction(action: BuildActionDef; workingDir: string): tuple[
    output: string; exitCode: int] =
  let argv = inlineArgvOf(action)
  let cmd = quoteShellCommand(argv)
  execCmdEx(cmd, workingDir = workingDir)

suite "rust convention: target edition":
  test "every Mode A rustc action uses the edition cargo uses for its target":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_target_edition_", "")
      defer:
        removeDir(root)
      writeFixture(root)

      # Cargo first: it also writes the Cargo.lock recognition needs.
      let cargoEditions = cargoUnitEditions(root, root / "cargo-target")
      # The fixture is only meaningful if cargo really splits the editions
      # this way; if this fails, the fixture, not Mode A, is wrong.
      check cargoEditions.getOrDefault((LibCrate, "lib", false)) == "2015"
      check cargoEditions.getOrDefault((OldBinCrate, "bin", false)) == "2021"
      check cargoEditions.getOrDefault((NewBinCrate, "bin", false)) == "2024"
      check cargoEditions.getOrDefault((TestCrate, "", true)) == "2018"

      let conv = rust_convention.rustConvention()
      let request = dummyRequest(root)
      require conv.recognize(root, request)
      let fragment = conv.emitFragment(root, request)

      var actions = initTable[string, BuildActionDef]()
      var rustcActionIds: seq[string] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        actions[action.id] = action
        let argv = inlineArgvOf(action)
        if argv.len > 0 and flagValue(argv, "--edition").len > 0:
          rustcActionIds.add(action.id)
      rustcActionIds.sort()
      checkpoint "Mode A rustc actions: " & $rustcActionIds

      # Every unit cargo built that Mode A also compiles must be covered:
      # the library's two passes, each binary's link pass (a binary has no
      # metadata pass) and the integration test's compile.
      var seen = initTable[UnitKey, int]()
      for id in rustcActionIds:
        let argv = inlineArgvOf(actions[id])
        let key = unitKeyOf(argv)
        seen[key] = seen.getOrDefault(key) + 1
        checkpoint id & " argv: " & argv.join(" ")
        check key in cargoEditions
        check flagValue(argv, "--edition") ==
          cargoEditions.getOrDefault(key, "<no cargo unit>")
      check seen.getOrDefault((LibCrate, "lib", false)) == 2
      check seen.getOrDefault((OldBinCrate, "bin", false)) == 1
      check seen.getOrDefault((NewBinCrate, "bin", false)) == 1
      check seen.getOrDefault((TestCrate, "", true)) == 1

      # Run the rustc actions with the real rustc, each after its deps.
      # Every fixture source compiles only under its own target's edition.
      # A rustc action's deps are other rustc actions of this fragment, so
      # repeatedly running every action whose deps have all run reaches
      # each one in dependency order.
      var pending = rustcActionIds
      var ran: seq[string] = @[]
      while pending.len > 0:
        var next: seq[string] = @[]
        for id in pending:
          var ready = true
          for dep in actions[id].deps:
            if dep in rustcActionIds and dep notin ran:
              ready = false
          if ready:
            let (output, exitCode) = runAction(actions[id], root)
            checkpoint id & " rustc output:\n" & output
            check exitCode == 0
            ran.add(id)
          else:
            next.add(id)
        require next.len < pending.len
        pending = next
      check ran.len == rustcActionIds.len

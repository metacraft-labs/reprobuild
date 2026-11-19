## Rust convention (Mode A): the ``test`` target builds and runs the test
## crate of every library and binary whose ``test`` setting is on, not only
## the integration tests under ``tests/``.
##
## ``cargo test`` compiles a target's own ``#[cfg(test)]`` code as a
## separate crate (the target's root with ``--test``) for each library and
## binary whose ``test`` key is ``true``, Cargo's default (Cargo reference,
## "Cargo Targets", "The ``test`` field":
## https://doc.rust-lang.org/cargo/reference/cargo-targets.html#the-test-field).
## Rust.md §"Test commands" asks Mode A for "one action per ``tests/*.rs``
## ... plus one for the lib's inline ``#[cfg(test)]`` tests". Before this
## test, Mode A emitted the integration tests alone, so a package whose only
## tests were inline ran no test under ``repro build .#test`` and said
## nothing (reprobuild-pm issue
## ``2026-11-17-rust-mode-a-emits-no-test-binary-for-a-librarys-inline-tests.md``).
##
## The fixture ``inlinetest`` is built to make the omission and the easy
## mistakes around it visible:
##
##   * ``src/lib.rs`` has an inline test and ``src/main.rs`` another, which
##     calls the library, so the binary's test crate needs ``--extern
##     inlinetest=<the library's rlib>`` as cargo passes it;
##   * ``tests/inlinetest.rs`` is an integration test. With the library and
##     the binary, three test crates share the crate name ``inlinetest``:
##     their action ids and binaries must still be distinct;
##   * ``[[bin]] quiet`` sets ``test = false`` and carries an inline test
##     that panics. Cargo builds no test crate for it, and Mode A must not
##     either. ``[[test]] slow`` sets ``test = false`` too, and its test
##     panics: ``cargo test`` neither builds nor runs it;
##   * the package is a member ``inlinetest/`` of a virtual workspace, and
##     the library's inline test reads ``data/answer.txt`` relative to the
##     working directory. Cargo runs a test from its package's directory,
##     so the read only succeeds when the run action's working directory
##     is the package's, not the project root.
##
## The test requires:
##
##   * the ``--test`` units Mode A emits are cargo's: for every unit
##     ``cargo test --no-run -v`` compiles with ``--test``, one Mode A
##     action with the same crate name and crate root, and no other;
##   * the fragment is one the engine accepts: no two actions share an id
##     or declare one output, and every dependency names an action of the
##     fragment;
##   * running the emitted actions with the real ``rustc``, in dependency
##     order and with the environment each declares, runs all three test
##     crates and each reports its test passed.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, with whichever cargo
## and rustc are on ``PATH``. When either is missing the case is skipped
## with a reason, as the other Rust convention cases are. Ambient cargo
## settings are cleared first, as in
## ``test_rust_convention_lib_bin_and_path_deps``.

import std/[algorithm, os, osproc, sets, streams, strtabs, strutils, tables,
            tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

type
  TestUnit = tuple[crateName, crateRoot: string]
    ## A ``--test`` crate: its crate name and its crate root relative to
    ## the project (workspace) root.

proc isolateFromAmbientCargo(root: string) =
  ## Clear every variable through which the caller's shell could steer
  ## cargo, and give it an empty ``CARGO_HOME``, as
  ## ``test_rust_convention_lib_bin_and_path_deps`` does. Process-wide on
  ## purpose: this file is its own process.
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

proc crateRootOf(argv: openArray[string]; root: string): string =
  ## The ``.rs`` argument of a rustc argv, relative to ``root`` (cargo
  ## passes it relative, Mode A absolute).
  for arg in argv:
    if arg.endsWith(".rs"):
      return (if arg.isAbsolute: arg.relativePath(root) else: arg)
  ""

proc externPath(argv: openArray[string]; crate: string): string =
  for i, arg in argv:
    if arg == "--extern" and i + 1 < argv.len and
        argv[i + 1].startsWith(crate & "="):
      return argv[i + 1][crate.len + 1 .. ^1]
  ""

proc cwdOf(action: BuildActionDef): string =
  ## The working directory an inline-exec action declares; empty if none.
  for arg in action.call.arguments:
    if arg.name == "cwd":
      return arg.encodedValue
  ""

proc runCapture(exe: string; args: openArray[string]; workingDir: string;
                extraEnv: openArray[(string, string)] = []):
    tuple[output: string; exitCode: int] =
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

proc cargoTestUnits(root, targetDir: string): seq[TestUnit] =
  ## The units ``cargo test --no-run -v`` compiles with ``--test``, read
  ## from its ``Running `rustc ...``` lines. The fixture's paths hold no
  ## space or quote, so splitting on whitespace is exact.
  let (output, exitCode) = runCapture(findExe("cargo"),
    ["test", "--workspace", "--no-run", "-v", "--offline", "--target-dir",
     targetDir],
    root)
  checkpoint "cargo test --no-run -v output:\n" & output
  doAssert exitCode == 0, "cargo test --no-run failed with exit " & $exitCode
  for line in output.splitLines():
    let start = line.find("Running `")
    if start < 0:
      continue
    let body = line[start + len("Running `") .. ^1].strip(chars = {'`', ' '})
    let argv = body.splitWhitespace()
    if argv.len == 0 or not argv[0].extractFilename.startsWith("rustc") or
        "--test" notin argv:
      continue
    result.add((flagValue(argv, "--crate-name"), crateRootOf(argv, root)))
  result.sort()

proc duplicates(values: openArray[string]): seq[string] =
  var seen = initHashSet[string]()
  for v in values:
    if v in seen and v notin result:
      result.add(v)
    seen.incl(v)

proc writeFixture(root: string) =
  ## ``root`` is a virtual workspace whose one member is ``inlinetest/``.
  let pkg = root / "inlinetest"
  createDir(pkg / "src" / "bin")
  createDir(pkg / "tests")
  createDir(pkg / "data")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package inlinetest:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[workspace]\n" &
    "resolver = \"2\"\n" &
    "members = [\"inlinetest\"]\n")
  writeFile(pkg / "Cargo.toml",
    "[package]\n" &
    "name = \"inlinetest\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" &
    "[[bin]]\n" &
    "name = \"quiet\"\n" &
    "path = \"src/bin/quiet.rs\"\n" &
    "test = false\n" &
    "\n" &
    "[[test]]\n" &
    "name = \"slow\"\n" &
    "path = \"tests/slow.rs\"\n" &
    "test = false\n")
  writeFile(pkg / "data" / "answer.txt", "42")
  writeFile(pkg / "src" / "lib.rs",
    "pub fn answer() -> u32 { 42 }\n" &
    "\n" &
    "#[cfg(test)]\n" &
    "mod tests {\n" &
    "    #[test]\n" &
    "    fn inline_answer() { assert_eq!(super::answer(), 42); }\n" &
    "    #[test]\n" &
    "    fn reads_package_data() {\n" &
    "        let text = std::fs::read_to_string(\"data/answer.txt\").unwrap();\n" &
    "        assert_eq!(text, super::answer().to_string());\n" &
    "    }\n" &
    "}\n")
  writeFile(pkg / "src" / "main.rs",
    "fn main() { println!(\"{}\", inlinetest::answer()); }\n" &
    "\n" &
    "#[cfg(test)]\n" &
    "mod tests {\n" &
    "    #[test]\n" &
    "    fn bin_inline() { assert_eq!(inlinetest::answer() + 1, 43); }\n" &
    "}\n")
  writeFile(pkg / "src" / "bin" / "quiet.rs",
    "fn main() {}\n" &
    "\n" &
    "#[cfg(test)]\n" &
    "mod tests {\n" &
    "    #[test]\n" &
    "    fn must_not_run() { panic!(\"test = false was ignored\"); }\n" &
    "}\n")
  writeFile(pkg / "tests" / "inlinetest.rs",
    "#[test]\n" &
    "fn it_answer() { assert_eq!(inlinetest::answer(), 42); }\n")
  writeFile(pkg / "tests" / "slow.rs",
    "#[test]\n" &
    "fn slow_must_not_run() { panic!(\"[[test]] test = false was ignored\"); }\n")

suite "rust convention: test crates of libraries and binaries":
  test "inline #[cfg(test)] tests are built and run as cargo test does":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_unit_tests_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeFixture(root)

      # Cargo first: it also writes the Cargo.lock recognition needs.
      let cargoUnits = cargoTestUnits(root, root / "cargo-target")
      checkpoint "cargo --test units: " & $cargoUnits
      # The fixture means what the header says only if cargo builds these
      # three test crates and none for ``quiet``.
      require cargoUnits == @[
        ("inlinetest", "inlinetest/src/lib.rs"),
        ("inlinetest", "inlinetest/src/main.rs"),
        ("inlinetest", "inlinetest/tests/inlinetest.rs")]

      let conv = rust_convention.rustConvention()
      let request = dummyRequest(root)
      require conv.recognize(root, request)
      let fragment = conv.emitFragment(root, request)
      var byId = initTable[string, BuildActionDef]()
      var actionIds: seq[string] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        actionIds.add(action.id)
        byId[action.id] = action
      checkpoint "Mode A actions: " & $actionIds

      check duplicates(actionIds).len == 0
      var outputs: seq[string] = @[]
      for id in actionIds:
        for output in byId[id].outputs & byId[id].optionalOutputs:
          outputs.add(output)
        for dep in byId[id].deps:
          if dep notin byId:
            checkpoint id & " depends on a missing action " & dep
            check false
      check duplicates(outputs).len == 0

      # Mode A's ``--test`` units against cargo's.
      var modeUnits: seq[TestUnit] = @[]
      var compileByRoot = initTable[string, string]()
      var rustcIds: seq[string] = @[]
      for id in actionIds:
        let argv = inlineArgvOf(byId[id])
        if argv.len == 0 or not argv[0].extractFilename.startsWith("rustc"):
          continue
        rustcIds.add(id)
        if "--test" in argv:
          let crateRoot = crateRootOf(argv, root)
          modeUnits.add((flagValue(argv, "--crate-name"), crateRoot))
          compileByRoot[crateRoot] = id
      modeUnits.sort()
      checkpoint "Mode A --test units: " & $modeUnits
      check modeUnits == cargoUnits

      # The binary's test crate links the package's library, as cargo's.
      if "inlinetest/src/main.rs" in compileByRoot:
        let binTestArgv =
          inlineArgvOf(byId[compileByRoot["inlinetest/src/main.rs"]])
        let libRlib = externPath(binTestArgv, "inlinetest")
        checkpoint "bin test crate argv: " & binTestArgv.join(" ")
        check libRlib.endsWith(".rlib")

      # Compile everything with the real rustc, each action after its deps
      # and with the environment it declares, then run every test crate.
      var pending = rustcIds
      var ran: seq[string] = @[]
      while pending.len > 0:
        var next: seq[string] = @[]
        for id in pending:
          var ready = true
          for dep in byId[id].deps:
            if dep in rustcIds and dep notin ran:
              ready = false
          if ready:
            let argv = inlineArgvOf(byId[id])
            let (output, exitCode) = runCapture(argv[0], argv[1 .. ^1], root,
              byId[id].env)
            checkpoint id & " rustc output:\n" & output
            check exitCode == 0
            ran.add(id)
          else:
            next.add(id)
        require next.len < pending.len
        pending = next

      var passed = initHashSet[string]()
      for id in actionIds:
        if not id.startsWith("rustc-test-run-"):
          continue
        let argv = inlineArgvOf(byId[id])
        # From the working directory the action declares, as the engine
        # runs it.
        let cwd = cwdOf(byId[id])
        checkpoint id & " runs in " & cwd
        check cwd.len > 0
        let (output, exitCode) = runCapture(argv[0], argv[1 .. ^1],
          (if cwd.len > 0: cwd else: root), byId[id].env)
        checkpoint id & " output:\n" & output
        check exitCode == 0
        for line in output.splitLines():
          if line.startsWith("test ") and line.endsWith(" ... ok"):
            passed.incl(line["test ".len ..< line.len - " ... ok".len])
      checkpoint "tests that passed: " & $passed
      check "tests::inline_answer" in passed
      check "tests::bin_inline" in passed
      check "it_answer" in passed
      check "tests::reads_package_data" in passed
      check "tests::must_not_run" notin passed
      check "slow_must_not_run" notin passed

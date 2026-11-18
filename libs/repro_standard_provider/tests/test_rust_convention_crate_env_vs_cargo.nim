## Rust convention (Mode A): every rustc action compiles its crate with the
## features and the crate environment Cargo gives the same unit.
##
## Cargo hands rustc two things beyond the argv's paths that change what a
## crate compiles to:
##
##   * ``--cfg 'feature="<name>"'`` for each feature enabled on the unit
##     (Cargo reference, "Features":
##     https://doc.rust-lang.org/cargo/reference/features.html). Mode A does
##     no feature resolution, so a workspace in which any package declares a
##     feature or an optional dependency must not reach Mode A at all: it
##     builds through cargo instead.
##   * The variables Cargo sets for a crate at compile time (Cargo
##     reference, "Environment variables Cargo sets for crates":
##     https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-crates).
##     ``env!`` and ``option_env!`` bake their values into the output.
##
## The test takes cargo itself as the oracle, two independent ways:
##
##   1. **Cargo's own invocations.** ``cargo test --no-run -vv`` prints, for
##      every unit it compiles, the environment it sets and the rustc argv.
##      For each Mode A rustc action the test finds cargo's unit for the
##      same target (crate name, crate type, test harness or not) and
##      requires the same set of ``CARGO*`` variables with the same values,
##      and the same ``--cfg`` arguments.
##   2. **What the crates see.** Every fixture crate records, with
##      ``option_env!``, every variable Cargo may set for a crate, and the
##      binaries and the integration test print those records. The test runs
##      cargo's build and Mode A's build (the emitted actions, run with the
##      real rustc and the environment each action declares) and requires
##      the two to print the same thing. The integration test also uses
##      ``env!`` for ``CARGO_BIN_EXE_<name>`` and ``CARGO_TARGET_TMPDIR``,
##      runs the binary and writes into the directory, so a missing value
##      fails the compile or the run.
##
## Three values are paths into a build directory, so Mode A's cannot equal
## cargo's: ``CARGO_BIN_EXE_<name>`` must be the path Mode A links that
## binary at, and ``CARGO_TARGET_TMPDIR`` a directory that exists before the
## test runs. ``CARGO`` names the cargo executable; both sides must name the
## same file once symlinks are resolved. Cargo also sets ``LD_LIBRARY_PATH``
## (its dynamic-library search path, not a crate variable), which neither
## comparison looks at.
##
## The fixture is a virtual workspace of two members with no features:
##
##   * ``probe-kit``: library ``probe_kit``, binary ``probe-bin`` and the
##     integration test ``it-env``. It takes its version, authors, readme,
##     license file and minimum Rust version from ``[workspace.package]``,
##     and has a multi-line description, so the inherited and rewritten
##     values (``../README.md``) are exercised.
##   * ``bare``: library ``bare``, binary ``bare-bin`` and the integration
##     test ``bare-it``, with no optional manifest keys, depending on
##     ``probe-kit`` by path. Its variables are the empty strings Cargo sets
##     for keys a manifest leaves out.
##
## A library's records reach the output through its package's integration
## test, and ``probe_kit``'s also through ``bare-bin``, its dependent. No
## binary uses its own package's library, so that this test does not depend
## on how Mode A links a binary to the library beside it.
##
## A second fixture adds a default feature to ``bare`` whose absence is a
## ``compile_error!``. Cargo compiles ``bare`` with ``--cfg feature="x"``;
## Mode A must emit no rustc action for that workspace and hand it to cargo.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, and the cargo and rustc
## used are whichever are on ``PATH``. When either is missing the case is
## skipped with a reason, as the other Rust convention cases are.
##
## Each case first clears what a developer shell may export for cargo (see
## ``isolateFromAmbientCargo``): an inherited ``RUSTFLAGS`` or wrapper would
## change cargo's units and not Mode A's, and an inherited crate variable
## would reach both sides' crates and hide a value Mode A fails to set.

import std/[algorithm, os, osproc, sets, streams, strtabs, strutils, tables,
            tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

const
  ## Every variable Cargo may set for a crate's compile (the reference page
  ## cited above), plus the ones only a build script brings (``OUT_DIR``,
  ## ``CARGO_MANIFEST_LINKS``), which a Mode A crate must not see either.
  ObservedVariables = [
    "CARGO", "CARGO_MANIFEST_DIR", "CARGO_MANIFEST_PATH",
    "CARGO_PKG_NAME", "CARGO_PKG_VERSION", "CARGO_PKG_VERSION_MAJOR",
    "CARGO_PKG_VERSION_MINOR", "CARGO_PKG_VERSION_PATCH",
    "CARGO_PKG_VERSION_PRE", "CARGO_PKG_AUTHORS", "CARGO_PKG_DESCRIPTION",
    "CARGO_PKG_HOMEPAGE", "CARGO_PKG_REPOSITORY", "CARGO_PKG_LICENSE",
    "CARGO_PKG_LICENSE_FILE", "CARGO_PKG_RUST_VERSION", "CARGO_PKG_README",
    "CARGO_CRATE_NAME", "CARGO_BIN_NAME", "CARGO_PRIMARY_PACKAGE",
    "CARGO_TARGET_TMPDIR", "CARGO_BIN_EXE_probe-bin", "CARGO_BIN_EXE_bare-bin",
    "OUT_DIR", "CARGO_MANIFEST_LINKS", "CARGO_RUSTC_CURRENT_DIR"]
  BinNames = ["probe-bin", "bare-bin"]
  RecordPrefix = "crate-env "

type
  UnitKey = tuple[crateName, crateType: string; isTest: bool]
    ## One compile unit independently of who emitted it: the crate name,
    ## the ``--crate-type`` (empty for a test harness, which cargo emits
    ## without one), and whether it is a ``--test`` build.

  CargoUnit = object
    env: Table[string, string]   ## the ``CARGO*`` variables cargo set
    cfgs: seq[string]            ## every ``--cfg`` value, sorted

proc isolateFromAmbientCargo(root: string) =
  ## Clear, for this whole process, every variable through which the
  ## caller's shell could steer cargo or reach a crate: cargo's output
  ## placement and target, the rustc it runs and the wrappers around it,
  ## the flags it adds (Cargo reference, "Environment variables Cargo
  ## reads":
  ## https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-reads),
  ## and every variable the fixture's crates record. ``CARGO_HOME`` moves
  ## to an empty directory under ``root`` so that a user's
  ## ``$CARGO_HOME/config.toml`` cannot add ``build.rustflags`` either; the
  ## fixture has no registry dependency, so nothing needs the real one.
  ## The same reasoning as the thin-cargo-edge fixture's
  ## ``scrubAmbientCargoEnv``, widened to this test's oracle. Process-wide
  ## on purpose: this file is its own process.
  for name in ["CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR",
               "CARGO_BUILD_TARGET", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS",
               "CARGO_BUILD_RUSTFLAGS", "RUSTC", "CARGO_BUILD_RUSTC",
               "RUSTC_WRAPPER", "CARGO_BUILD_RUSTC_WRAPPER",
               "RUSTC_WORKSPACE_WRAPPER",
               "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER"]:
    delEnv(name)
  for name in ObservedVariables:
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

proc cfgValues(argv: openArray[string]): seq[string] =
  ## Every ``--cfg`` value in ``argv``, sorted.
  for i, arg in argv:
    if arg == "--cfg" and i + 1 < argv.len:
      result.add(argv[i + 1])
    elif arg.startsWith("--cfg="):
      result.add(arg[len("--cfg=") .. ^1])
  result.sort()

proc unitKeyOf(argv: openArray[string]): UnitKey =
  let isTest = "--test" in argv
  (crateName: flagValue(argv, "--crate-name"),
   crateType: (if isTest: "" else: flagValue(argv, "--crate-type")),
   isTest: isTest)

proc shellWords(text: string): seq[string] =
  ## Split a POSIX shell command line into words. Cargo prints each
  ## invocation with its ``shell-escape`` crate: a word with only safe
  ## characters bare, any other in single quotes with an embedded ``'``
  ## written ``'\''`` (https://docs.rs/shell-escape). Double quotes and
  ## backslash escapes are handled too, for completeness.
  var cur = ""
  var inWord = false
  var i = 0
  while i < text.len:
    let c = text[i]
    case c
    of '\'':
      inWord = true
      inc i
      while i < text.len and text[i] != '\'':
        cur.add(text[i])
        inc i
    of '"':
      inWord = true
      inc i
      while i < text.len and text[i] != '"':
        if text[i] == '\\' and i + 1 < text.len:
          inc i
        cur.add(text[i])
        inc i
    of '\\':
      inWord = true
      if i + 1 < text.len:
        inc i
        cur.add(text[i])
    of ' ', '\t', '\n':
      if inWord:
        result.add(cur)
        cur = ""
        inWord = false
    else:
      inWord = true
      cur.add(c)
    inc i
  if inWord:
    result.add(cur)

proc isEnvAssignment(word: string): bool =
  let eq = word.find('=')
  eq > 0 and word[0] in {'A' .. 'Z', '_'} and
    word[0 ..< eq].allCharsInSet({'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-'})

proc parseCargoUnits(output: string): Table[UnitKey, CargoUnit] =
  ## Every rustc unit in ``cargo -vv`` output. Each one is printed as
  ## ``Running `VAR=value ... rustc <argv>``` and may span lines when a
  ## value holds a newline; the fixture has no backtick in any value, so
  ## the closing backtick ends the command.
  var pos = 0
  while true:
    let start = output.find("Running `", pos)
    if start < 0:
      break
    let bodyStart = start + len("Running `")
    let stop = output.find('`', bodyStart)
    doAssert stop > bodyStart, "unterminated cargo command in -vv output"
    pos = stop + 1
    let words = shellWords(output[bodyStart ..< stop])
    var unit = CargoUnit()
    var argvStart = 0
    while argvStart < words.len and isEnvAssignment(words[argvStart]):
      let w = words[argvStart]
      let eq = w.find('=')
      if w.startsWith("CARGO"):
        unit.env[w[0 ..< eq]] = w[eq + 1 .. ^1]
      inc argvStart
    let argv = words[argvStart .. ^1]
    if argv.len == 0 or not argv[0].extractFilename.startsWith("rustc"):
      continue   # a build script run or another tool, not a compile
    let key = unitKeyOf(argv)
    if key.crateName.len == 0:
      continue   # e.g. ``rustc -vV`` probes
    unit.cfgs = cfgValues(argv)
    result[key] = unit

proc rustRecordSource(): string =
  ## Rust source of a ``pub const ENV`` table holding, for every observed
  ## variable, what ``option_env!`` saw when this crate was compiled, and a
  ## ``print_env`` that prints it one line per variable.
  result = "pub const ENV: &[(&str, Option<&str>)] = &[\n"
  for name in ObservedVariables:
    result.add("    (\"" & name & "\", option_env!(\"" & name & "\")),\n")
  result.add("];\n" &
    "pub fn print_env(origin: &str) {\n" &
    "    for (name, value) in ENV {\n" &
    "        println!(\"" & RecordPrefix & "{} {} {:?}\", origin, name, value);\n" &
    "    }\n" &
    "}\n")

proc integrationTestSource(lib, crate, bin: string): string =
  ## An integration test that prints its package library's records and its
  ## own, runs the package's binary through ``CARGO_BIN_EXE_<bin>`` and
  ## writes into ``CARGO_TARGET_TMPDIR``. It reads those two with ``env!``,
  ## not ``option_env!``: without them it does not compile.
  "mod own {\n" & rustRecordSource() & "}\n" &
    "#[test]\n" &
    "fn crate_env() {\n" &
    "    " & lib & "::print_env(\"lib:" & lib & "\");\n" &
    "    own::print_env(\"test:" & crate & "\");\n" &
    "    let out = std::process::Command::new(env!(\"CARGO_BIN_EXE_" & bin & "\"))\n" &
    "        .output().expect(\"run " & bin & "\");\n" &
    "    assert!(out.status.success());\n" &
    "    let tmp = std::path::Path::new(env!(\"CARGO_TARGET_TMPDIR\"));\n" &
    "    std::fs::write(tmp.join(\"written-by-" & crate & "\"), b\"x\")\n" &
    "        .expect(\"write tmpdir\");\n" &
    "}\n"

proc writeFixture(root: string; withFeature: bool) =
  createDir(root / "probe" / "src" / "bin")
  createDir(root / "probe" / "tests")
  createDir(root / "bare" / "src" / "bin")
  createDir(root / "bare" / "tests")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package crateEnvProbe:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[workspace]\n" &
    "resolver = \"2\"\n" &
    "members = [\"probe\", \"bare\"]\n" &
    "\n" &
    "[workspace.package]\n" &
    "version = \"3.4.5-rc.1+build.7\"\n" &
    "authors = [\"A <a@example.com>\", \"B\"]\n" &
    "readme = \"README.md\"\n" &
    "license-file = \"LICENSE.txt\"\n" &
    "rust-version = \"1.70\"\n")
  writeFile(root / "README.md", "workspace readme\n")
  writeFile(root / "LICENSE.txt", "license\n")
  writeFile(root / "probe" / "Cargo.toml",
    "[package]\n" &
    "name = \"probe-kit\"\n" &
    "version.workspace = true\n" &
    "authors.workspace = true\n" &
    "readme.workspace = true\n" &
    "license-file.workspace = true\n" &
    "rust-version.workspace = true\n" &
    "edition = \"2021\"\n" &
    "description = \"\"\"crate env probe\n" &
    "second line\"\"\"\n" &
    "homepage = \"https://example.com/home\"\n" &
    "repository = \"https://example.com/repo\"\n" &
    "license = \"MIT OR Apache-2.0\"\n" &
    "publish = false\n" &
    "\n" &
    "[lib]\n" &
    "name = \"probe_kit\"\n" &
    "path = \"src/lib.rs\"\n" &
    "\n" &
    "[[bin]]\n" &
    "name = \"probe-bin\"\n" &
    "path = \"src/bin/probe.rs\"\n" &
    "\n" &
    "[[test]]\n" &
    "name = \"it-env\"\n" &
    "path = \"tests/it_env.rs\"\n")
  writeFile(root / "probe" / "src" / "lib.rs", rustRecordSource())
  writeFile(root / "probe" / "src" / "bin" / "probe.rs",
    "mod own {\n" & rustRecordSource() & "}\n" &
    "fn main() {\n" &
    "    own::print_env(\"bin:probe_bin\");\n" &
    "}\n")
  writeFile(root / "probe" / "tests" / "it_env.rs",
    integrationTestSource("probe_kit", "it_env", "probe-bin"))
  var bareToml =
    "[package]\n" &
    "name = \"bare\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "\n" &
    "[[bin]]\n" &
    "name = \"bare-bin\"\n" &
    "path = \"src/bin/bare.rs\"\n" &
    "\n" &
    "[[test]]\n" &
    "name = \"bare-it\"\n" &
    "path = \"tests/bare_it.rs\"\n" &
    "\n" &
    "[dependencies]\n" &
    "probe-kit = { path = \"../probe\" }\n"
  var bareLib = rustRecordSource()
  if withFeature:
    bareToml.add("\n[features]\ndefault = [\"x\"]\nx = []\n")
    bareLib = "#[cfg(not(feature = \"x\"))]\ncompile_error!(\"feature x off\");\n" &
      bareLib
  writeFile(root / "bare" / "Cargo.toml", bareToml)
  writeFile(root / "bare" / "src" / "lib.rs", bareLib)
  writeFile(root / "bare" / "src" / "bin" / "bare.rs",
    "mod own {\n" & rustRecordSource() & "}\n" &
    "fn main() {\n" &
    "    probe_kit::print_env(\"lib:probe_kit\");\n" &
    "    own::print_env(\"bin:bare_bin\");\n" &
    "}\n")
  writeFile(root / "bare" / "tests" / "bare_it.rs",
    integrationTestSource("bare", "bare_it", "bare-bin"))

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

proc cargoBuild(root, targetDir: string): Table[UnitKey, CargoUnit] =
  ## Build every unit Mode A builds with cargo and return what ``-vv`` says
  ## it gave rustc. ``cargo build`` builds the libraries and every binary;
  ## ``cargo test --no-run`` then adds the test harness units. A binary is
  ## built under ``cargo test`` only for its own package's integration
  ## tests, which is why both runs are needed.
  for verb in [@["build", "--workspace"], @["test", "--workspace", "--no-run"]]:
    let (output, exitCode) = runCapture(findExe("cargo"),
      verb & @["-vv", "--offline", "--target-dir", targetDir], root)
    checkpoint "cargo " & verb.join(" ") & " -vv output:\n" & output
    doAssert exitCode == 0,
      "cargo " & verb.join(" ") & " failed with exit " & $exitCode
    for key, unit in parseCargoUnits(output):
      # A unit both runs compile (a library, a binary) must be compiled the
      # same way by both, or the oracle is ambiguous.
      if key in result:
        checkpoint "cargo compiled " & $key & " in both runs"
        check result[key].env == unit.env
        check result[key].cfgs == unit.cfgs
      result[key] = unit

proc records(output: string): Table[string, string] =
  ## ``<origin> <VAR>`` → the ``{:?}`` of what that crate saw, from the
  ## lines the fixture prints.
  ## A record can follow other text on its line: the test harness prints
  ## ``test <name> ... `` before the test's first output.
  for line in output.splitLines():
    let at = line.find(RecordPrefix)
    if at < 0:
      continue
    let rest = line[at + RecordPrefix.len .. ^1]
    let parts = rest.split(' ', maxsplit = 2)
    if parts.len == 3:
      result[parts[0] & " " & parts[1]] = parts[2]

proc canonical(path: string): string =
  ## ``path`` with every symlink resolved, for comparing two names of one
  ## executable.
  try:
    expandFilename(path)
  except OSError:
    path

proc modeAActions(root: string): tuple[byId: Table[string, BuildActionDef];
                                         rustcIds: seq[string]] =
  let conv = rust_convention.rustConvention()
  let request = dummyRequest(root)
  doAssert conv.recognize(root, request), "fixture not recognised"
  let fragment = conv.emitFragment(root, request)
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    result.byId[action.id] = action
    let argv = inlineArgvOf(action)
    if argv.len > 0 and argv[0].extractFilename.startsWith("rustc") and
        flagValue(argv, "--crate-name").len > 0:
      result.rustcIds.add(action.id)
  result.rustcIds.sort()

suite "rust convention: features and crate environment match cargo":
  test "every Mode A rustc action gets cargo's features and crate environment":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_crate_env_vs_cargo_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeFixture(root, withFeature = false)
      let cargoTarget = root / "cargo-target"

      # Cargo first: it also writes the Cargo.lock recognition needs.
      let cargoUnits = cargoBuild(root, cargoTarget)
      # The fixture is meaningful only if cargo builds these units with
      # these variables; if this fails, the fixture, not Mode A, is wrong.
      let cargoLib = cargoUnits.getOrDefault(("probe_kit", "lib", false))
      check cargoLib.env.getOrDefault("CARGO_PKG_README") == "../README.md"
      check cargoLib.env.getOrDefault("CARGO_PKG_DESCRIPTION") ==
        "crate env probe\nsecond line"
      check cargoUnits.getOrDefault(("bare", "lib", false)).env.
        getOrDefault("CARGO_PKG_README", "<unset>") == ""
      check "CARGO_BIN_EXE_probe-bin" in
        cargoUnits.getOrDefault(("it_env", "", true)).env
      for key, unit in cargoUnits:
        check unit.cfgs.len == 0

      let (byId, rustcIds) = modeAActions(root)
      checkpoint "Mode A rustc actions: " & $rustcIds

      # Where Mode A links each binary: the value its CARGO_BIN_EXE_<name>
      # must hold.
      var modeABinPath = initTable[string, string]()
      for id in rustcIds:
        let argv = inlineArgvOf(byId[id])
        if flagValue(argv, "--crate-type") == "bin" and "--test" notin argv and
            "link" in flagValue(argv, "--emit"):
          for name in BinNames:
            if flagValue(argv, "--crate-name") == name.replace('-', '_'):
              modeABinPath[name] = byId[id].outputs[0]
      check modeABinPath.len == BinNames.len

      # 1. Each Mode A rustc action against cargo's unit for its target.
      var seen = initCountTable[UnitKey]()
      var testCompileIds: seq[string] = @[]
      for id in rustcIds:
        let action = byId[id]
        let argv = inlineArgvOf(action)
        let key = unitKeyOf(argv)
        seen.inc(key)
        if key.isTest and ".test." in id:
          # An integration test's compile; the test crates of libraries
          # and binaries are checked against cargo's units here too, but
          # step 2 runs the integration tests only.
          testCompileIds.add(id)
        checkpoint id & " argv: " & argv.join(" ")
        if key notin cargoUnits:
          checkpoint id & ": cargo built no unit " & $key
          check false
          continue
        let cargoUnit = cargoUnits[key]
        check cfgValues(argv) == cargoUnit.cfgs
        var modeEnv = initTable[string, string]()
        for (name, value) in action.env:
          if name.startsWith("CARGO"):
            modeEnv[name] = value
        var cargoNames, modeNames: seq[string]
        for name in cargoUnit.env.keys: cargoNames.add(name)
        for name in modeEnv.keys: modeNames.add(name)
        cargoNames.sort()
        modeNames.sort()
        checkpoint id & " env names: cargo " & $cargoNames & ", Mode A " &
          $modeNames
        check modeNames == cargoNames
        for name in cargoNames:
          let cargoValue = cargoUnit.env[name]
          let modeValue = modeEnv.getOrDefault(name, "<unset>")
          checkpoint id & " " & name & ": cargo " & cargoValue.escape &
            ", Mode A " & modeValue.escape
          if name == "CARGO":
            check canonical(modeValue) == canonical(cargoValue)
          elif name.startsWith("CARGO_BIN_EXE_"):
            let bin = name[len("CARGO_BIN_EXE_") .. ^1]
            check modeValue == modeABinPath.getOrDefault(bin, "<no link action>")
          elif name == "CARGO_TARGET_TMPDIR":
            check modeValue.isAbsolute and dirExists(modeValue)
          else:
            check modeValue == cargoValue
      # Both passes of each library, each binary's link pass (a binary has
      # no metadata pass), each test's compile, and the test crate of each
      # library and binary (``cargo test`` builds one for every target
      # whose ``test`` setting is on, the default).
      check seen[("probe_kit", "lib", false)] == 2
      check seen[("bare", "lib", false)] == 2
      check seen[("probe_bin", "bin", false)] == 1
      check seen[("bare_bin", "bin", false)] == 1
      check seen[("it_env", "", true)] == 1
      check seen[("bare_it", "", true)] == 1
      check seen[("probe_kit", "", true)] == 1
      check seen[("bare", "", true)] == 1
      check seen[("probe_bin", "", true)] == 1
      check seen[("bare_bin", "", true)] == 1
      require testCompileIds.len == 2

      # 2. Run Mode A's rustc actions with the real rustc, each with the
      #    environment it declares and after its deps.
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

      # Then what each crate saw, cargo's build against Mode A's. Each
      # integration test runs its package's binary through CARGO_BIN_EXE
      # and writes into CARGO_TARGET_TMPDIR, so it must pass on both sides.
      let testArgs = ["--nocapture", "--test-threads=1"]
      let cargoTest = runCapture(findExe("cargo"),
        @["test", "--workspace", "--offline", "--target-dir", cargoTarget,
         "--test", "it-env", "--test", "bare-it", "--"] & @testArgs, root)
      checkpoint "cargo integration tests:\n" & cargoTest.output
      check cargoTest.exitCode == 0
      var cargoSaw = records(cargoTest.output)
      var modeSaw = initTable[string, string]()
      for id in testCompileIds:
        let modeTest = runCapture(byId[id].outputs[0], testArgs, root)
        checkpoint id & " test run:\n" & modeTest.output
        check modeTest.exitCode == 0
        for k, v in records(modeTest.output): modeSaw[k] = v
      for name in BinNames:
        let cargoRun = runCapture(cargoTarget / "debug" / name, [], root)
        check cargoRun.exitCode == 0
        for k, v in records(cargoRun.output): cargoSaw[k] = v
        let modeRun = runCapture(modeABinPath[name], [], root)
        check modeRun.exitCode == 0
        for k, v in records(modeRun.output): modeSaw[k] = v
      # Six crates printed every variable: two libraries, two binaries and
      # two integration tests.
      check cargoSaw.len == 6 * ObservedVariables.len
      check modeSaw.len == cargoSaw.len

      # The target tmpdirs each side chose: cargo's one ``target/tmp``, and
      # Mode A's per package.
      var cargoTmps, modeTmps: seq[string]
      for key in [("it_env", "", true), ("bare_it", "", true)]:
        cargoTmps.add(cargoUnits.getOrDefault(key).env.getOrDefault(
          "CARGO_TARGET_TMPDIR"))
      for id in testCompileIds:
        for (name, value) in byId[id].env:
          if name == "CARGO_TARGET_TMPDIR": modeTmps.add(value)
      proc masked(value: string; tmps: seq[string];
                  bins: Table[string, string]): string =
        ## The build-directory paths each side chose, replaced by a token.
        result = value
        for tmp in tmps:
          if tmp.len > 0 and value == "Some(" & tmp.escape & ")":
            result = "Some(<target-tmpdir>)"
        for name, path in bins:
          if value == "Some(" & path.escape & ")":
            result = "Some(<bin " & name & ">)"
      var cargoBins = initTable[string, string]()
      for name in BinNames:
        cargoBins[name] = cargoTarget / "debug" / name
      for k, cargoValue in cargoSaw:
        let modeValue = modeSaw.getOrDefault(k, "<not printed>")
        checkpoint k & ": cargo " & cargoValue & ", Mode A " & modeValue
        if k.endsWith(" CARGO"):
          check modeValue.startsWith("Some(") == cargoValue.startsWith("Some(")
        else:
          check masked(modeValue, modeTmps, modeABinPath) ==
            masked(cargoValue, cargoTmps, cargoBins)

  test "a workspace cargo compiles with a feature gets no Mode A rustc action":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_crate_env_feature_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeFixture(root, withFeature = true)
      let cargoUnits = cargoBuild(root, root / "cargo-target")
      # Cargo enables ``default`` and, through it, ``x``; without ``x``
      # ``bare`` refuses to compile.
      let bareCfgs = cargoUnits.getOrDefault(("bare", "lib", false)).cfgs
      checkpoint "cargo's --cfg for bare: " & $bareCfgs
      check bareCfgs == @["feature=\"default\"", "feature=\"x\""]
      let (byId, rustcIds) = modeAActions(root)
      checkpoint "Mode A rustc actions: " & $rustcIds
      # Mode A cannot give any unit cargo's feature set, so no unit of
      # this workspace may compile through it: every package goes to cargo.
      check rustcIds.len == 0
      var sawCargoBuild = false
      for id in byId.keys:
        if id.startsWith("crude-build-"):
          sawCargoBuild = true
      check sawCargoBuild

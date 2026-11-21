## Rust convention (Mode B): a workspace built through cargo has a ``test``
## target, and that target runs ``cargo test``.
##
## Language-Conventions/Rust.md, "Test commands", gives Mode B
## ``cargo test --release --locked --workspace``. The fixture is a package
## with a ``build.rs``, which sends it to Mode B (Rust.md, "Mode B — Crude
## fallback"), and a ``harness = false`` integration test whose ``main``
## prints a marker. The test requires:
##
##   * one cargo build delegation (``crude-build-*``), so the fixture really
##     is in Mode B;
##   * a ``test`` target (a ``reprobuild.build-target.v1`` node named
##     ``test``) with an action that runs ``cargo test`` over the workspace
##     (``--workspace --release --locked --no-fail-fast``) through the thin
##     cargo edge, sized by ``-j`` like the build action, waits for the
##     build action and is not part of ``default``; and a stamp action in
##     the same target that waits for it and declares one output;
##   * running the cargo command of that action runs the integration test:
##     it exits 0 and the test's marker is in its output;
##   * a second case makes the integration test exit non-zero, and the same
##     command then exits non-zero, so a failing test fails the action.
##
## Written as the adversarial confirmation of reprobuild-pm issue
## ``issues/2026-11-18-rust-mode-b-emits-no-test-target-so-cargo-test-never-runs.md``:
## before the fix the fragment had the ``default`` target alone, so
## ``repro build .#test`` ran none of a Mode B workspace's tests.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, and the cargo used is
## whichever is on ``PATH``. When cargo or rustc is missing the case is
## skipped with a reason, as the other Rust convention cases are. The
## engine is not involved: the test runs the part of the action's argv
## after the edge's ``--`` (the cargo command the edge runs) itself, in the
## action's working directory. The helper before ``--`` is the running
## executable (``getAppFilename``), which in production is
## ``repro-standard-provider`` and here is this test binary, so it is
## checked, not run.

import std/[os, osproc, sequtils, streams, strtabs, strutils, tables,
            tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_core/process_streams
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

const ModeBMarker = "mode-b-test-marker 31"

proc isolateFromAmbientCargo(root: string) =
  ## Clear every variable through which the caller's shell could steer
  ## cargo, and point ``CARGO_HOME`` at an empty directory, as
  ## ``test_rust_convention_lib_bin_and_path_deps`` does. The fixture has
  ## no registry dependency, so nothing needs the real one. Process-wide on
  ## purpose: the runner starts each case in its own process.
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

proc runCapture(exe: string; args: openArray[string]; workingDir: string):
    tuple[output: string; exitCode: int] =
  ## Run ``exe`` with the ambient environment, stderr folded into stdout.
  var envTab = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    envTab[k] = v
  let p = startProcess(exe, workingDir = workingDir, args = args,
    env = envTab, options = {poStdErrToStdOut})
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (output, code)

proc writeModeBTestFixture(root: string; exitCode = 0) =
  ## A package with a ``build.rs`` (Mode B) and a ``harness = false``
  ## integration test whose ``main`` prints ``ModeBMarker``. With
  ## ``harness = false`` cargo passes the test's stdout through, so the
  ## marker shows that cargo really ran it. The test's ``main`` exits with
  ## ``exitCode``.
  createDir(root / "src")
  createDir(root / "tests")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package modeb:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[package]\n" &
    "name = \"modeb\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" &
    "[[test]]\n" &
    "name = \"marker\"\n" &
    "harness = false\n")
  writeFile(root / "build.rs", "fn main() {}\n")
  writeFile(root / "src" / "lib.rs",
    "pub fn z() -> u32 { 31 }\n")
  writeFile(root / "tests" / "marker.rs",
    "fn main() {\n" &
    "    println!(\"mode-b-test-marker {}\", modeb::z());\n" &
    "    std::process::exit(" & $exitCode & ");\n" &
    "}\n")

type
  ModeBTest = object
    testArgv: seq[string]   ## the test run action's whole argv
    cargoArgv: seq[string]  ## the cargo command after the edge's ``--``

template modeBTestOf(root: string): ModeBTest {.dirty.} =
  ## Emit the fragment for the fixture at ``root`` and check the shape of
  ## its ``test`` target; return the test run's argv. A dirty template,
  ## not a proc: ``check`` and ``require`` mark the enclosing test failed
  ## only when they see that test's status variable, and outside a test
  ## ``require`` quits the process and ``check`` merely sets its exit code.
  block:
    var res: ModeBTest
    # Recognition and ``--locked`` need a Cargo.lock; the fixture has no
    # dependency to fetch.
    let (lockOut, lockExit) = runCapture(findExe("cargo"),
      ["generate-lockfile", "--offline"], root)
    checkpoint "cargo generate-lockfile output:\n" & lockOut
    require lockExit == 0

    let conv = rust_convention.rustConvention()
    let request = dummyRequest(root)
    require conv.recognize(root, request)
    let fragment = conv.emitFragment(root, request)
    var byId: Table[string, BuildActionDef]
    var targets: Table[string, BuildTargetDef]
    for node in fragment.nodes:
      if node.kind == gnkAction:
        let action = decodeBuildActionPayload(toBytes(node.payload))
        byId[action.id] = action
      elif node.kind == gnkMetadata and
          node.stableName == "reprobuild.build-target.v1":
        let t = decodeBuildTargetPayload(toBytes(node.payload))
        targets[t.name] = t
    checkpoint "targets: " & $toSeq(targets.keys)
    checkpoint "actions: " & $toSeq(byId.keys)

    # The build.rs sends the package to Mode B: one cargo delegation.
    var buildIds: seq[string] = @[]
    for id in byId.keys:
      if id.startsWith("crude-build-"):
        buildIds.add(id)
    require buildIds.len == 1
    let build = byId[buildIds[0]]

    # The test target exists, and one of its actions runs ``cargo test``
    # over the workspace, through the edge, once the build action is done.
    require "test" in targets
    var testRun = ""
    for id in targets["test"].actions:
      require id in byId
      let argv = inlineArgvOf(byId[id])
      checkpoint id & " argv: " & argv.join(" ")
      let sep = argv.find("--")
      if sep >= 0 and sep + 2 < argv.len and
          argv[sep + 1].extractFilename.startsWith("cargo") and
          argv[sep + 2] == "test":
        testRun = id
    require testRun.len > 0
    let run = byId[testRun]
    res.testArgv = inlineArgvOf(run)
    res.cargoArgv = res.testArgv[res.testArgv.find("--") + 1 .. ^1]
    check "--cargo-edge" in res.testArgv
    check "--workspace" in res.cargoArgv
    check "--release" in res.cargoArgv
    check "--locked" in res.cargoArgv
    check "--no-fail-fast" in res.cargoArgv
    check build.id in run.deps
    # Sized like the build: the engine leases a width and writes it after
    # ``-j``.
    check build.widthFlag == "-j"
    check run.widthFlag == "-j"
    check run.cpuMinMilli == build.cpuMinMilli

    # A stamp waits for the run and declares the target's output.
    check targets["test"].actions.len == 2
    var stamp = ""
    for id in targets["test"].actions:
      if id != testRun:
        stamp = id
    require stamp in byId
    check testRun in byId[stamp].deps
    check byId[stamp].outputs.len == 1

    # ``default`` still only builds.
    require "default" in targets
    check testRun notin targets["default"].actions
    check stamp notin targets["default"].actions
    res

suite "rust convention: Mode B test target":
  test "a Mode B workspace has a test target that runs cargo test":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_mode_b_test_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeModeBTestFixture(root)
      let modeB = modeBTestOf(root)
      # Running the action's cargo command runs the integration test.
      let (output, exitCode) = runCapture(modeB.cargoArgv[0],
        modeB.cargoArgv[1 .. ^1], root)
      checkpoint "cargo test output:\n" & output
      check exitCode == 0
      check ModeBMarker in output

  test "a failing test in a Mode B workspace fails the test action":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_mode_b_test_fail_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeModeBTestFixture(root, exitCode = 3)
      let modeB = modeBTestOf(root)
      let (output, exitCode) = runCapture(modeB.cargoArgv[0],
        modeB.cargoArgv[1 .. ^1], root)
      checkpoint "cargo test output:\n" & output
      # The test ran (its marker is there) and its failure reached cargo's
      # exit status, which is the action's.
      check ModeBMarker in output
      check exitCode != 0

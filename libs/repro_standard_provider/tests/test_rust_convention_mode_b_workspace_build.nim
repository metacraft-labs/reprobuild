## Rust convention (Mode B): the cargo build delegation builds every
## workspace member, not only cargo's default members.
##
## Language-Conventions/Rust.md, "Mode B — Crude fallback (cargo
## delegation)", gives the workspace build as
## ``cargo build --release --locked --workspace``. Without ``--workspace``,
## ``cargo build`` at the root of a workspace whose root manifest has a
## ``[package]`` table builds only that root package and what it depends on
## (Cargo reference, "Workspaces", "The `default-members` field":
## https://doc.rust-lang.org/cargo/reference/workspaces.html#the-default-members-field),
## so a member the root package does not depend on is never built, while
## Mode A builds every member.
##
## The fixture is that workspace: a root package ``rootpkg`` with a
## ``build.rs`` (which sends the workspace to Mode B, Rust.md
## §"Recognition", item 5) and ``[workspace] members = ["extra"]``, where
## ``extra`` is a binary crate ``rootpkg`` does not depend on. The test
## requires:
##
##   * one cargo build delegation (``crude-build-*``) in ``default``, so the
##     fixture really is in Mode B;
##   * its cargo command (after the edge's ``--``) carries ``--workspace``,
##     ``--release`` and ``--locked``;
##   * running that cargo command produces ``target/release/extra``, and
##     ``rootpkg``'s binary too.
##
## Written as the adversarial confirmation of reprobuild-pm issue
## ``issues/2026-11-19-rust-mode-b-runs-cargo-build-without-workspace.md``:
## before the fix the argv was ``cargo build --release --locked --offline``,
## and running it left ``extra`` unbuilt.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, and the cargo used is
## whichever is on ``PATH``. When cargo or rustc is missing the case is
## skipped with a reason, as the other Rust convention cases are. The engine
## is not involved: the test runs the part of the action's argv after the
## edge's ``--`` (the cargo command the edge runs) itself, in the action's
## working directory. The helper before ``--`` is the running executable
## (``getAppFilename``), which in production is ``repro-standard-provider``
## and here is this test binary, so it is not run.

import std/[os, osproc, sequtils, strtabs, strutils, tables,
            tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_core/process_streams
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

proc isolateFromAmbientCargo(root: string) =
  ## Clear every variable through which the caller's shell could steer
  ## cargo (a ``CARGO_TARGET_DIR`` would move the products this test looks
  ## for), and point ``CARGO_HOME`` at an empty directory, as
  ## ``test_rust_convention_mode_b_test_target`` does. The fixture has no
  ## registry dependency, so nothing needs the real one. Process-wide on
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

proc writeWorkspaceFixture(root: string) =
  ## A root package ``rootpkg`` (with a ``build.rs``, so Mode B) that is
  ## also a workspace root listing the member ``extra``. ``rootpkg`` does
  ## not depend on ``extra``, so ``extra`` is outside cargo's default
  ## members and only ``--workspace`` builds it.
  createDir(root / "src")
  createDir(root / "extra" / "src")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package rootpkg:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[package]\n" &
    "name = \"rootpkg\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" &
    "[workspace]\n" &
    "members = [\"extra\"]\n")
  writeFile(root / "build.rs", "fn main() {}\n")
  writeFile(root / "src" / "main.rs",
    "fn main() { println!(\"rootpkg\"); }\n")
  writeFile(root / "extra" / "Cargo.toml",
    "[package]\n" &
    "name = \"extra\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n")
  writeFile(root / "extra" / "src" / "main.rs",
    "fn main() { println!(\"extra\"); }\n")

suite "rust convention: Mode B workspace build":
  test "the Mode B build builds a member the root package does not depend on":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_mode_b_ws_build_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeWorkspaceFixture(root)
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

      # The build.rs sends the workspace to Mode B: one cargo delegation,
      # and it is what ``default`` builds.
      var buildIds: seq[string] = @[]
      for id in byId.keys:
        if id.startsWith("crude-build-"):
          buildIds.add(id)
      require buildIds.len == 1
      require "default" in targets
      check buildIds[0] in targets["default"].actions

      let argv = inlineArgvOf(byId[buildIds[0]])
      checkpoint "build argv: " & argv.join(" ")
      let sep = argv.find("--")
      require sep >= 0 and sep + 2 < argv.len
      let cargoArgv = argv[sep + 1 .. ^1]
      require cargoArgv[0].extractFilename.startsWith("cargo")
      require cargoArgv[1] == "build"
      check "--workspace" in cargoArgv
      check "--release" in cargoArgv
      check "--locked" in cargoArgv

      # Running the action's cargo command builds every member.
      let (output, exitCode) = runCapture(cargoArgv[0], cargoArgv[1 .. ^1],
        root)
      checkpoint "cargo build output:\n" & output
      require exitCode == 0
      let exeSuffix = when defined(windows): ".exe" else: ""
      check fileExists(root / "target" / "release" / ("rootpkg" & exeSuffix))
      check fileExists(root / "target" / "release" / ("extra" & exeSuffix))

## Rust convention: a package with a build script never builds in Mode A,
## wherever in the workspace it is and however its script is declared.
##
## A build script's output is part of how Cargo compiles the package:
## ``cargo:rustc-cfg`` and ``cargo:rustc-env`` lines become ``--cfg`` flags
## and environment variables of the package's ``rustc`` runs, and the script
## may write sources under ``OUT_DIR`` (Cargo reference, "Build Scripts",
## "Outputs of the Build Script":
## https://doc.rust-lang.org/cargo/reference/build-scripts.html#outputs-of-the-build-script).
## Mode A calls ``rustc`` itself and runs no build script, so a package that
## has one must be built by cargo (Mode B; Rust.md §"Recognition" item 5).
## Compiled in Mode A it either fails or, worse, compiles to code other than
## cargo's. ``cargo metadata`` reports a build script as a target of kind
## ``custom-build``, for the default ``build.rs`` beside the manifest and
## for a ``build = "<path>"`` key alike (Cargo reference, "The Manifest
## Format", "The ``build`` field":
## https://doc.rust-lang.org/cargo/reference/manifest.html#the-build-field).
##
## Five cases, each against the real toolchain:
##
## 1. **A member of a virtual workspace has a ``build.rs``.** The workspace
##    root has no ``build.rs`` of its own. Member ``b``'s script prints
##    ``cargo:rustc-cfg=from_build`` and ``b``'s only public function exists
##    under ``#[cfg(from_build)]``; member ``a``'s binary calls it.
## 2. **A package names its script with the ``build`` key.** The script is
##    ``gen/custom.rs``, so no file named ``build.rs`` exists anywhere. It
##    prints ``cargo:rustc-env=FROM_BUILD=4217`` and the binary prints
##    ``env!("FROM_BUILD")``.
## 3. **A build script added to a workspace Mode A already emitted.** The
##    convention caches ``cargo metadata``'s output between emits, keyed
##    by the manifests and ``.rs`` files it finds under the project root.
##    ``b``'s library here returns 4217 under ``from_build`` and 0
##    without, so it builds either way; the workspace is emitted once
##    without ``b/build.rs`` (Mode A) and again after the script, and
##    nothing else, is added.
## 4. **The added ``build.rs`` is a symbolic link** to a script outside
##    the workspace. Cargo follows the link; a walk over regular files
##    does not see it. Not on Windows, where creating a link needs a
##    privilege.
## 5. **The added ``build.rs`` belongs to a member outside the project
##    root** (``members = ["a", "../ext"]``, and ``workspace = "../ws"`` in
##    its manifest), where a walk of the root
##    never looks.
##
## Each case first checks with cargo that the fixture builds and its binary
## prints the build script's value (otherwise the fixture, not the
## convention, is wrong); cases 3 to 5 check it before and after the
## script is added (0, then 4217). It then requires of the emitted
## fragment:
##
##   * no ``rustc`` action compiles the crate that needs the script without
##     what the script provides;
##   * every ``rustc`` action the fragment does hold builds with the real
##     ``rustc``, in dependency order and with the environment it declares;
##   * the fragment delegates to cargo (one ``crude-build-*`` action whose
##     argv runs ``cargo build``).
##
## Reported in reprobuild-pm
## issues/2026-11-18-rust-mode-a-ignores-a-workspace-members-build-script.md.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, and the cargo and
## rustc used are whichever are on ``PATH``. When either is missing the case
## is skipped with a reason, as the other Rust convention cases are.
##
## Each case first clears what a developer shell may export for cargo (see
## ``isolateFromAmbientCargo``), the same isolation as
## ``test_rust_convention_lib_bin_and_path_deps``.

import std/[algorithm, os, osproc, streams, strtabs, strutils, tables,
            tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_core/process_streams
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

proc isolateFromAmbientCargo(root: string) =
  ## Clear, for this whole process, every variable through which the
  ## caller's shell could steer cargo, and move ``CARGO_HOME`` to an empty
  ## directory under ``root``. Process-wide on purpose: this file is its own
  ## process.
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
  for i, arg in argv:
    if arg == flag and i + 1 < argv.len:
      return argv[i + 1]
    if arg.startsWith(flag & "="):
      return arg[flag.len + 1 .. ^1]
  ""

proc hasCfg(argv: openArray[string]; cfg: string): bool =
  for i, arg in argv:
    if arg == "--cfg" and i + 1 < argv.len and argv[i + 1] == cfg:
      return true
    if arg == "--cfg=" & cfg:
      return true
  false

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
  # ``readAll`` stops at the first short read of the pipe; ``drainStream``
  # reads to end of file.
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (output, code)

proc cargoBuildAndRun(root, targetDir, binary: string): string =
  ## ``cargo build`` the workspace at ``root`` (which also writes the
  ## ``Cargo.lock`` recognition needs) and return what ``binary`` prints.
  let (output, exitCode) = runCapture(findExe("cargo"),
    ["build", "--workspace", "-v", "--offline", "--target-dir", targetDir],
    root)
  checkpoint "cargo build -v output:\n" & output
  doAssert exitCode == 0, "cargo build failed with exit " & $exitCode
  let run = runCapture(targetDir / "debug" / binary, [], root)
  doAssert run.exitCode == 0, binary & " built by cargo exited " &
    $run.exitCode
  run.output

type
  EmittedFragment = object
    byId: Table[string, BuildActionDef]
    actionIds: seq[string]   ## every action id, in fragment order
    rustcIds: seq[string]
      ## the ids of the actions that run ``rustc`` on a crate, sorted
    cargoBuildIds: seq[string]
      ## the ids of the cargo delegation (Mode B) actions

proc emittedFragment(root: string): EmittedFragment =
  let conv = rust_convention.rustConvention()
  let request = dummyRequest(root)
  doAssert conv.recognize(root, request), "fixture not recognised"
  let fragment = conv.emitFragment(root, request)
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    result.actionIds.add(action.id)
    result.byId[action.id] = action
    let argv = inlineArgvOf(action)
    if argv.len > 0 and argv[0].extractFilename.startsWith("rustc") and
        flagValue(argv, "--crate-name").len > 0:
      result.rustcIds.add(action.id)
    if action.id.startsWith("crude-build-"):
      var namesCargo = false
      for arg in argv:
        if arg.extractFilename == "cargo" or
            arg.extractFilename == "cargo.exe":
          namesCargo = true
      if namesCargo and "build" in argv:
        result.cargoBuildIds.add(action.id)
  result.rustcIds.sort()

proc rustcActionsOf(emitted: EmittedFragment; crateName: string): seq[string] =
  for id in emitted.rustcIds:
    if flagValue(inlineArgvOf(emitted.byId[id]), "--crate-name") == crateName:
      result.add(id)

proc declaresEnv(action: BuildActionDef; name: string): bool =
  for (key, _) in action.env:
    if key == name:
      return true
  false

proc runRustcActions(emitted: EmittedFragment; root: string): seq[string] =
  ## Run every ``rustc`` action of the fragment with the real ``rustc``,
  ## each after its dependencies and with the environment it declares.
  ## Returns the ids of those that failed.
  var pending = emitted.rustcIds
  var ran: seq[string] = @[]
  while pending.len > 0:
    var next: seq[string] = @[]
    for id in pending:
      var ready = true
      for dep in emitted.byId[id].deps:
        if dep in emitted.rustcIds and dep notin ran:
          ready = false
      if ready:
        let argv = inlineArgvOf(emitted.byId[id])
        let (output, exitCode) = runCapture(argv[0], argv[1 .. ^1], root,
          emitted.byId[id].env)
        checkpoint id & " rustc exit " & $exitCode & ", output:\n" & output
        if exitCode != 0:
          result.add(id)
        ran.add(id)
      else:
        next.add(id)
    doAssert next.len < pending.len, "rustc actions depend on each other " &
      "in a cycle: " & $pending
    pending = next

proc writeWorkspaceFixture(root: string) =
  ## A virtual workspace: binary ``a`` depends on library ``b``.
  ## ``b/build.rs`` sets the cfg ``from_build`` and ``b::value`` exists
  ## only under it.
  createDir(root / "a" / "src")
  createDir(root / "b" / "src")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package buildScriptMember:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[workspace]\n" &
    "resolver = \"2\"\n" &
    "members = [\"a\", \"b\"]\n")
  writeFile(root / "a" / "Cargo.toml",
    "[package]\n" &
    "name = \"a\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" &
    "[dependencies]\n" &
    "b = { path = \"../b\" }\n")
  writeFile(root / "a" / "src" / "main.rs",
    "fn main() {\n" &
    "    println!(\"b says {}\", b::value());\n" &
    "}\n")
  writeFile(root / "b" / "Cargo.toml",
    "[package]\n" &
    "name = \"b\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n")
  writeFile(root / "b" / "build.rs",
    "fn main() {\n" &
    "    println!(\"cargo:rustc-check-cfg=cfg(from_build)\");\n" &
    "    println!(\"cargo:rustc-cfg=from_build\");\n" &
    "}\n")
  writeFile(root / "b" / "src" / "lib.rs",
    "#[cfg(from_build)]\n" &
    "pub fn value() -> u32 {\n" &
    "    4217\n" &
    "}\n")

const BuildScriptSettingCfg =
  "fn main() {\n" &
  "    println!(\"cargo:rustc-check-cfg=cfg(from_build)\");\n" &
  "    println!(\"cargo:rustc-cfg=from_build\");\n" &
  "}\n"

proc writeAddedScriptFixture(root, libDir, libMember: string;
                             libWorkspace = "") =
  ## A virtual workspace at ``root``: binary ``a`` depends on library
  ## ``b``, whose package directory is ``libDir`` and whose ``members``
  ## entry is ``libMember``. ``b::value`` is 4217 under the cfg
  ## ``from_build`` and 0 without it. A ``libDir`` outside ``root`` must
  ## name its workspace (``libWorkspace``, the manifest's
  ## ``package.workspace`` key). No build script is written: the case
  ## adds ``libDir/build.rs`` later and changes nothing else.
  createDir(root / "a" / "src")
  createDir(libDir / "src")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package buildScriptAdded:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[workspace]\n" &
    "resolver = \"2\"\n" &
    "members = [\"a\", \"" & libMember & "\"]\n")
  writeFile(root / "a" / "Cargo.toml",
    "[package]\n" &
    "name = \"a\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "\n" &
    "[dependencies]\n" &
    "b = { path = \"../" & libMember & "\" }\n")
  writeFile(root / "a" / "src" / "main.rs",
    "fn main() {\n" &
    "    println!(\"b says {}\", b::value());\n" &
    "}\n")
  writeFile(libDir / "Cargo.toml",
    "[package]\n" &
    "name = \"b\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    (if libWorkspace.len > 0: "workspace = \"" & libWorkspace & "\"\n"
     else: ""))
  writeFile(libDir / "src" / "lib.rs",
    "#![allow(unexpected_cfgs)]\n" &
    "#[cfg(from_build)]\n" &
    "pub fn value() -> u32 {\n" &
    "    4217\n" &
    "}\n" &
    "#[cfg(not(from_build))]\n" &
    "pub fn value() -> u32 {\n" &
    "    0\n" &
    "}\n")

template checkScriptAddedAfterModeAEmit(parent, root: string;
                                        addScript: untyped) =
  ## The body of cases 3 to 5 (a template, so that ``check`` and
  ## ``require`` act on the calling test). ``root`` holds ``writeAddedScriptFixture``'s
  ## workspace and lies under ``parent``, which also takes cargo's target
  ## directory so that nothing but ``addScript`` changes under ``root``
  ## between the two emits.
  let cargoTarget = parent / "cargo-target"
  require cargoBuildAndRun(root, cargoTarget, "a") == "b says 0\n"
  # Without a build script this workspace is Mode A's: the emit below
  # also fills the convention's ``cargo metadata`` cache.
  let before = emittedFragment(root)
  checkpoint "actions before: " & $before.actionIds
  require before.rustcActionsOf("b").len > 0
  require before.cargoBuildIds.len == 0
  require before.runRustcActions(root).len == 0

  addScript
  # Cargo now runs the script: the fixture really has a build script.
  require cargoBuildAndRun(root, cargoTarget, "a") == "b says 4217\n"
  let after = emittedFragment(root)
  checkpoint "actions after: " & $after.actionIds
  # ``b`` builds without the cfg too, but to the wrong code (0): only a
  # compile that carries the script's cfg is cargo's ``b``.
  for id in after.rustcActionsOf("b"):
    let argv = inlineArgvOf(after.byId[id])
    checkpoint id & " argv: " & argv.join(" ")
    check hasCfg(argv, "from_build")
  check after.runRustcActions(root).len == 0
  check after.cargoBuildIds.len == 1

proc writeBuildKeyFixture(root: string) =
  ## One package whose build script is ``gen/custom.rs``, named by the
  ## manifest's ``build`` key. No file is called ``build.rs``.
  createDir(root / "src")
  createDir(root / "gen")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package buildKey:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  writeFile(root / "Cargo.toml",
    "[package]\n" &
    "name = \"keyed\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n" &
    "build = \"gen/custom.rs\"\n")
  writeFile(root / "gen" / "custom.rs",
    "fn main() {\n" &
    "    println!(\"cargo:rustc-env=FROM_BUILD=4217\");\n" &
    "}\n")
  writeFile(root / "src" / "main.rs",
    "fn main() {\n" &
    "    println!(\"build says {}\", env!(\"FROM_BUILD\"));\n" &
    "}\n")

suite "rust convention: packages with a build script":
  test "a workspace member's build.rs keeps the member out of Mode A":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_member_build_rs_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeWorkspaceFixture(root)
      require not fileExists(root / "build.rs")
      require cargoBuildAndRun(root, root / "cargo-target", "a") ==
        "b says 4217\n"

      let emitted = emittedFragment(root)
      checkpoint "emitted actions: " & $emitted.actionIds
      # ``b`` compiled by a bare rustc has no ``from_build`` cfg, hence no
      # ``value``: only a compile that carries the script's cfg is ``b``.
      for id in emitted.rustcActionsOf("b"):
        let argv = inlineArgvOf(emitted.byId[id])
        checkpoint id & " argv: " & argv.join(" ")
        check hasCfg(argv, "from_build")
      check emitted.runRustcActions(root).len == 0
      check emitted.cargoBuildIds.len == 1

  test "a build script named by the build key keeps the package out of Mode A":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let root = createTempDir("test_rust_convention_build_key_", "")
      defer:
        removeDir(root)
      isolateFromAmbientCargo(root)
      writeBuildKeyFixture(root)
      for entry in walkDirRec(root):
        require entry.extractFilename != "build.rs"
      require cargoBuildAndRun(root, root / "cargo-target", "keyed") ==
        "build says 4217\n"

      let emitted = emittedFragment(root)
      checkpoint "emitted actions: " & $emitted.actionIds
      # ``env!("FROM_BUILD")`` compiles only with the variable the script
      # asks cargo to set.
      for id in emitted.rustcActionsOf("keyed"):
        checkpoint id & " env: " & $emitted.byId[id].env
        check emitted.byId[id].declaresEnv("FROM_BUILD")
      check emitted.runRustcActions(root).len == 0
      check emitted.cargoBuildIds.len == 1

  test "a build.rs added to a member after a Mode A emit is seen by the next":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_convention_build_rs_added_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeAddedScriptFixture(root, root / "b", "b")
      checkScriptAddedAfterModeAEmit(parent, root):
        writeFile(root / "b" / "build.rs", BuildScriptSettingCfg)

  test "a build.rs added as a symbolic link is seen by the next emit":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    elif defined(windows):
      skip("creating a symbolic link needs a privilege on Windows")
    else:
      let parent = createTempDir("test_rust_convention_build_rs_link_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeAddedScriptFixture(root, root / "b", "b")
      createDir(parent / "scripts")
      writeFile(parent / "scripts" / "sets_cfg.rs", BuildScriptSettingCfg)
      checkScriptAddedAfterModeAEmit(parent, root):
        createSymlink(parent / "scripts" / "sets_cfg.rs",
          root / "b" / "build.rs")

  test "a build.rs added to a member outside the root is seen by the next emit":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_convention_build_rs_outside_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeAddedScriptFixture(root, parent / "ext", "../ext",
        libWorkspace = "../ws")
      checkScriptAddedAfterModeAEmit(parent, root):
        writeFile(parent / "ext" / "build.rs", BuildScriptSettingCfg)

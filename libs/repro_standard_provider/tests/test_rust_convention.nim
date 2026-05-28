## M4 + M13 + M22 verification: Rust language convention.
##
## Tests against the in-tree fixture at
## ``reprobuild-examples/rust/binary/`` for the positive recognise path
## and the two-action emit-fragment path. Library-only / workspace /
## multi-bin recognise are exercised against scratch fixtures under the
## test's temp dir (no need for the real ``rust/library`` / ``rust/workspace``
## fixtures here — the E2E validators cover those end-to-end).
##
## Coverage:
##   * ``recognize`` returns true for the canonical binary fixture
##   * ``recognize`` returns true when ``build.rs`` is present (M6 — the
##     convention now claims the project and ``emitFragment`` routes to
##     the Mode B crude fallback internally). Runs only when rustc/cargo
##     are on PATH; without them the toolchain probe returns false for
##     unrelated reasons and the positive-recognise assertion degrades to
##     a checkpoint.
##   * ``recognize`` returns true for library-only crates (``src/lib.rs``
##     present, no ``src/main.rs``) — M13 graduation.
##   * ``recognize`` returns true for workspace manifests (``[workspace]``
##     declared at root) — M13 graduation.
##   * ``recognize`` returns true for ``[[bin]]`` array entries (multi-bin
##     crates with no conventional ``src/main.rs``) — M13 graduation.
##   * ``recognize`` returns false when:
##       - ``Cargo.toml`` is absent (not a Cargo project)
##       - ``uses:`` lists ``python`` instead of ``rust`` / ``cargo``
##   * ``emitFragment`` against the canonical fixture produces:
##       - exactly one ``rustc-metadata-*`` action with ``--emit=metadata,dep-info``
##       - exactly one ``rustc-link-*`` action with ``--emit=link,dep-info``
##       - the link action declares the metadata action's id in ``deps``
##       - both actions carry a ``depfile`` and ``dependencyPolicy ==
##         bdpMakeDepfile``
##       - both are in the ``compile`` pool
##
## The fragment test depends on ``rustc`` AND ``cargo`` being on PATH
## because the convention invokes ``cargo metadata`` eagerly at emit time
## (``Standard-Provider-Implementation.milestones.org §M4, Option 1``).
## When either is missing we skip the emit assertions — the recognise
## assertions still run because they short-circuit to ``false`` on a
## missing toolchain.
##
## The negative-recognise cases are hermetic *except* that they also
## need ``rustc`` and ``cargo`` on PATH to assert the deeper rejection
## paths (workspace/build.rs/missing-source). When the toolchain is
## absent the recognise check exits ``false`` for unrelated reasons (no
## rustc on PATH) — that's still a valid ``false`` so the test passes,
## but the rejection-reason coverage degrades; the e2e validator picks up
## that gap by exercising the full path against a real toolchain.

import std/[os, strutils, tables, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

const
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_rust_convention.nim``
  ## lands at the ``reprobuild/`` repo root. The fixture lives in the
  ## sibling ``reprobuild-examples`` checkout under ``D:/metacraft/``,
  ## so we take one more parent.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  FixtureRoot = MetacraftRoot / "reprobuild-examples" / "rust" / "binary"
  FixtureCrateName = "rust_binary_example"
  TestFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "rust" / "library-with-tests"
  WorkspaceChainFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "rust" / "workspace-lib-chain"
  CdylibFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "rust" / "cdylib"
  CratesIoFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "rust" / "binary-with-crates-io"

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

suite "rust convention M4":

  test "recognize: positive — canonical fixture":
    let conv = rust_convention.rustConvention()
    check conv.name == "rust"
    if not fileExists(FixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & FixtureRoot
      fail()
    let request = dummyRequest(FixtureRoot)
    if not rustToolchainAvailable():
      checkpoint "rustc/cargo not on PATH — positive recognize will return false"
      check not conv.recognize(FixtureRoot, request)
    else:
      check conv.recognize(FixtureRoot, request)

  test "recognize: positive — build.rs is present (M6 relaxation)":
    # Prior to M6 the convention rejected build.rs projects so the
    # dispatch loop fell through to "no convention matched". M6 routes
    # build.rs through the Mode B crude fallback inside emitFragment, so
    # recognize now claims the project (provided rustc/cargo are on
    # PATH — same toolchain-probe gate as the positive M4 test).
    let scratch = getTempDir() / "test_rust_convention_build_rs"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeBuildRsExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  executable fake_build_rs:\n" &
      "    discard\n")
    writeFile(scratch / "Cargo.toml",
      "[package]\n" &
      "name = \"fake-build-rs\"\n" &
      "version = \"0.1.0\"\n" &
      "edition = \"2024\"\n" &
      "publish = false\n")
    writeFile(scratch / "src" / "main.rs",
      "fn main() { println!(\"unused\"); }\n")
    writeFile(scratch / "build.rs",
      "fn main() { println!(\"cargo:rerun-if-changed=build.rs\"); }\n")
    defer:
      removeDir(scratch)
    let conv = rust_convention.rustConvention()
    let request = dummyRequest(scratch)
    if not rustToolchainAvailable():
      checkpoint "rustc/cargo not on PATH — recognise will short-circuit to false"
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "recognize: positive — library-only crate (M13)":
    # M13: a crate with only ``src/lib.rs`` (no ``src/main.rs``) is now
    # recognised. The convention spec (Rust.md §"Mode A — Fine-grained
    # build graph") explicitly supports library targets via
    # ``--crate-type lib --emit=link,dep-info`` producing ``lib<n>.rlib``.
    let scratch = getTempDir() / "test_rust_convention_library_only"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeLibExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  library fake_lib\n")
    writeFile(scratch / "Cargo.toml",
      "[package]\n" &
      "name = \"fake-lib\"\n" &
      "version = \"0.1.0\"\n" &
      "edition = \"2024\"\n" &
      "publish = false\n")
    writeFile(scratch / "src" / "lib.rs",
      "pub fn unused() -> i32 { 42 }\n")
    defer:
      removeDir(scratch)
    let conv = rust_convention.rustConvention()
    let request = dummyRequest(scratch)
    if not rustToolchainAvailable():
      checkpoint "rustc/cargo not on PATH — library-only recognise will short-circuit to false"
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "recognize: positive — [workspace] in Cargo.toml (M13)":
    # M13: previously rejected ([workspace] was a hard-fail in recognize).
    # The convention now claims the project and ``cargo metadata``
    # enumerates workspace members at emit time. The scratch fixture
    # carries a single member to keep the test hermetic — the real
    # ``rust/workspace`` example covers the multi-member path end-to-end
    # via the E2E validator.
    let scratch = getTempDir() / "test_rust_convention_workspace"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "member-a" / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeWorkspaceExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  executable member_a:\n" &
      "    discard\n")
    writeFile(scratch / "Cargo.toml",
      "[workspace]\n" &
      "resolver = \"2\"\n" &
      "members = [\"member-a\"]\n")
    writeFile(scratch / "member-a" / "Cargo.toml",
      "[package]\n" &
      "name = \"member-a\"\n" &
      "version = \"0.1.0\"\n" &
      "edition = \"2024\"\n" &
      "publish = false\n" &
      "\n" &
      "[[bin]]\n" &
      "name = \"member_a\"\n" &
      "path = \"src/main.rs\"\n")
    writeFile(scratch / "member-a" / "src" / "main.rs",
      "fn main() { println!(\"unused\"); }\n")
    defer:
      removeDir(scratch)
    let conv = rust_convention.rustConvention()
    let request = dummyRequest(scratch)
    if not rustToolchainAvailable():
      checkpoint "rustc/cargo not on PATH — workspace recognise will short-circuit to false"
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "recognize: positive — [[bin]] array in Cargo.toml (M13)":
    # M13: explicit ``[[bin]]`` table entries (with non-default ``path =``)
    # are recognised. No ``src/main.rs`` exists at the root — the bin
    # source lives under ``bin/alpha.rs`` per the manifest.
    let scratch = getTempDir() / "test_rust_convention_multi_bin"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src" / "bins")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMultiBinExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  executable alpha:\n" &
      "    discard\n" &
      "  executable beta:\n" &
      "    discard\n")
    writeFile(scratch / "Cargo.toml",
      "[package]\n" &
      "name = \"fake-multi-bin\"\n" &
      "version = \"0.1.0\"\n" &
      "edition = \"2024\"\n" &
      "publish = false\n" &
      "\n" &
      "[[bin]]\n" &
      "name = \"alpha\"\n" &
      "path = \"src/bins/alpha.rs\"\n" &
      "\n" &
      "[[bin]]\n" &
      "name = \"beta\"\n" &
      "path = \"src/bins/beta.rs\"\n")
    writeFile(scratch / "src" / "bins" / "alpha.rs",
      "fn main() { println!(\"alpha\"); }\n")
    writeFile(scratch / "src" / "bins" / "beta.rs",
      "fn main() { println!(\"beta\"); }\n")
    defer:
      removeDir(scratch)
    let conv = rust_convention.rustConvention()
    let request = dummyRequest(scratch)
    if not rustToolchainAvailable():
      checkpoint "rustc/cargo not on PATH — multi-bin recognise will short-circuit to false"
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "recognize: negative — no Cargo.toml":
    let scratch = getTempDir() / "test_rust_convention_no_cargo"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeNoCargoExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  executable fake_no_cargo:\n" &
      "    discard\n")
    writeFile(scratch / "src" / "main.rs",
      "fn main() { println!(\"unused\"); }\n")
    defer:
      removeDir(scratch)
    let conv = rust_convention.rustConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lists python instead of rust/cargo":
    let scratch = getTempDir() / "test_rust_convention_python_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakePythonExample:\n" &
      "  uses:\n" &
      "    \"python >=3.10\"\n" &
      "\n" &
      "  executable fake_python:\n" &
      "    discard\n")
    writeFile(scratch / "Cargo.toml",
      "[package]\n" &
      "name = \"fake-python\"\n" &
      "version = \"0.1.0\"\n" &
      "edition = \"2024\"\n")
    writeFile(scratch / "src" / "main.rs",
      "fn main() { println!(\"unused\"); }\n")
    defer:
      removeDir(scratch)
    let conv = rust_convention.rustConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: two-action graph against canonical fixture":
    if not rustToolchainAvailable():
      skip()
    else:
      let conv = rust_convention.rustConvention()
      let request = dummyRequest(FixtureRoot)
      require conv.recognize(FixtureRoot, request)
      let fragment = conv.emitFragment(FixtureRoot, request)

      var metadataActions: seq[BuildActionDef] = @[]
      var linkActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        let argv = inlineArgvOf(action)
        if argv.len == 0:
          continue
        if action.id.startsWith("rustc-metadata-"):
          metadataActions.add(action)
        elif action.id.startsWith("rustc-link-"):
          linkActions.add(action)

      # Pass 1: exactly one rustc-metadata action; argv carries
      # --emit=metadata,dep-info plus --crate-name and -C metadata=.
      check metadataActions.len == 1
      let metadataAction = metadataActions[0]
      let metadataArgv = inlineArgvOf(metadataAction)
      check "--emit=metadata,dep-info" in metadataArgv
      check "--crate-name" in metadataArgv
      check FixtureCrateName in metadataArgv
      check "--edition" in metadataArgv
      check "--crate-type" in metadataArgv
      check "bin" in metadataArgv
      check metadataArgv[^1].endsWith("main.rs")
      check metadataAction.depfile.len > 0
      check metadataAction.dependencyPolicy.kind == bdpMakeDepfile
      check metadataAction.pool == "compile"

      # Pass 2: exactly one rustc-link action; argv carries
      # --emit=link,dep-info; deps include the metadata action's id;
      # output ends with the binary path.
      check linkActions.len == 1
      let linkAction = linkActions[0]
      let linkArgv = inlineArgvOf(linkAction)
      check "--emit=link,dep-info" in linkArgv
      check "--crate-name" in linkArgv
      check FixtureCrateName in linkArgv
      check "--edition" in linkArgv
      check "--crate-type" in linkArgv
      check "bin" in linkArgv
      check linkArgv[^1].endsWith("main.rs")
      check metadataAction.id in linkAction.deps
      check linkAction.depfile.len > 0
      check linkAction.dependencyPolicy.kind == bdpMakeDepfile
      check linkAction.pool == "compile"

      # Link output is the executable under <scratch>/<crate>/bin.
      let primaryOutput = linkAction.outputs[0]
      when defined(windows):
        check primaryOutput.endsWith(FixtureCrateName & ".exe")
      else:
        check primaryOutput.endsWith(FixtureCrateName)

      # The metadata action's rmeta is wired in as an input of the link
      # action — captures the pipelined edge in the action cache
      # fingerprint per Rust.md §"Cross-crate ordering edges".
      var sawRmetaInput = false
      for inp in linkAction.inputs:
        if inp.endsWith(".rmeta"):
          sawRmetaInput = true
          break
      check sawRmetaInput

  # --- M22: integration-test discovery -------------------------------------

  test "emitFragment M22: library-with-tests emits a non-default test target":
    # The library-with-tests fixture ships exactly one
    # ``tests/test_greet.rs`` integration test. The M22 surface asks
    # cargo metadata to surface the ``kind=["test"]`` target, then emits
    # a (compile, run, stamp) action triple per test under a
    # non-default ``test`` target. The default target stays bin/lib-only.
    if not rustToolchainAvailable():
      skip()
    elif not fileExists(TestFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & TestFixtureRoot
      fail()
    else:
      let conv = rust_convention.rustConvention()
      let request = dummyRequest(TestFixtureRoot)
      require conv.recognize(TestFixtureRoot, request)
      let fragment = conv.emitFragment(TestFixtureRoot, request)

      var compileActions: seq[BuildActionDef] = @[]
      var runActions: seq[BuildActionDef] = @[]
      var stampActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("rustc-test-compile-"):
          compileActions.add(action)
        elif action.id.startsWith("rustc-test-run-"):
          runActions.add(action)
        elif action.id.startsWith("rustc-test-stamp-"):
          stampActions.add(action)

      check compileActions.len == 1
      check runActions.len == 1
      check stampActions.len == 1

      let compileAction = compileActions[0]
      let compileArgv = inlineArgvOf(compileAction)
      check "--test" in compileArgv
      check "--crate-name" in compileArgv
      check "--edition" in compileArgv
      check "--emit=link" in compileArgv
      # The lib's rlib must be threaded as ``--extern <name>=<path>`` so
      # the test can ``use rust_library_with_tests_example::greet``.
      var sawExtern = false
      for arg in compileArgv:
        if arg.startsWith("rust_library_with_tests_example=") and
            arg.endsWith(".rlib"):
          sawExtern = true
          break
      check sawExtern
      check compileArgv[^1].endsWith("test_greet.rs")
      # Output is the test harness binary under ``<scratch>/<crate>/tests/``.
      check compileAction.outputs.len == 1
      let binaryOut = compileAction.outputs[0].replace('\\', '/')
      check "/tests/test_greet" in binaryOut
      when defined(windows):
        check binaryOut.endsWith(".exe")

      # Run action: depends on the compile, argv is just the binary.
      let runAction = runActions[0]
      check compileAction.id in runAction.deps
      let runArgv = inlineArgvOf(runAction)
      check runArgv.len == 1
      check runArgv[0] == compileAction.outputs[0]

      # Stamp action: depends on the run; output ends in .stamp.
      let stampAction = stampActions[0]
      check runAction.id in stampAction.deps
      check stampAction.outputs.len == 1
      let stampOut = stampAction.outputs[0].replace('\\', '/')
      check stampOut.endsWith("test_greet.stamp")
      check "/tests/" in stampOut

  test "emitFragment M22: rust/binary has no test actions":
    # Inverse cohort: the rust/binary fixture has no ``tests/`` directory
    # so the convention must not emit any ``rustc-test-*`` actions.
    if not rustToolchainAvailable():
      skip()
    else:
      let conv = rust_convention.rustConvention()
      let request = dummyRequest(FixtureRoot)
      require conv.recognize(FixtureRoot, request)
      let fragment = conv.emitFragment(FixtureRoot, request)
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        check not action.id.startsWith("rustc-test-compile-")
        check not action.id.startsWith("rustc-test-run-")
        check not action.id.startsWith("rustc-test-stamp-")

  # --- M23: workspace lib→lib chain ---------------------------------------

  test "emitFragment M23: workspace-lib-chain topological order":
    # M23 Part A: a workspace ``crate_a (lib) → crate_b (lib) → crate_c
    # (bin)`` must emit Pass A in topological order so crate_b's
    # metadata + link passes carry ``--extern crate_a=...`` flags
    # pointing at crate_a's already-emitted rmeta + rlib. Pass B's
    # crate_c bin similarly carries the full direct + transitive
    # ``--extern`` set (plus the transitive ``-L dependency`` paths).
    if not rustToolchainAvailable():
      skip()
    elif not fileExists(WorkspaceChainFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & WorkspaceChainFixtureRoot
      fail()
    else:
      let conv = rust_convention.rustConvention()
      let request = dummyRequest(WorkspaceChainFixtureRoot)
      require conv.recognize(WorkspaceChainFixtureRoot, request)
      let fragment = conv.emitFragment(WorkspaceChainFixtureRoot, request)

      # Collect actions keyed on crate name (strip the
      # ``rustc-metadata-`` / ``rustc-link-`` prefix + ``-umbrella``
      # suffix).
      var metadataByCrate = initTable[string, BuildActionDef]()
      var linkByCrate = initTable[string, BuildActionDef]()
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("rustc-metadata-") and
            action.id.endsWith("-umbrella"):
          let crate = action.id["rustc-metadata-".len ..^ "-umbrella".len + 1]
          metadataByCrate[crate] = action
        elif action.id.startsWith("rustc-link-") and
            action.id.endsWith("-umbrella"):
          let crate = action.id["rustc-link-".len ..^ "-umbrella".len + 1]
          linkByCrate[crate] = action

      # All three crates should have both passes emitted.
      check "crate_a" in metadataByCrate
      check "crate_a" in linkByCrate
      check "crate_b" in metadataByCrate
      check "crate_b" in linkByCrate
      check "crate_c" in metadataByCrate
      check "crate_c" in linkByCrate

      # M23 Part A: crate_b's metadata pass must reference crate_a's
      # rmeta via ``--extern crate_a=...`` AND declare crate_a's
      # metadata action id in its deps.
      let crateBMetaArgv = inlineArgvOf(metadataByCrate["crate_b"])
      var sawCrateAExternInB = false
      for arg in crateBMetaArgv:
        if arg.startsWith("crate_a=") and arg.endsWith(".rmeta"):
          sawCrateAExternInB = true
          break
      check sawCrateAExternInB
      check metadataByCrate["crate_a"].id in metadataByCrate["crate_b"].deps

      # M23 Part A: crate_b's link pass must reference crate_a's rlib
      # and depend on crate_a's link action.
      let crateBLinkArgv = inlineArgvOf(linkByCrate["crate_b"])
      var sawCrateAExternRlibInB = false
      for arg in crateBLinkArgv:
        if arg.startsWith("crate_a=") and arg.endsWith(".rlib"):
          sawCrateAExternRlibInB = true
          break
      check sawCrateAExternRlibInB
      check linkByCrate["crate_a"].id in linkByCrate["crate_b"].deps

      # M23 transitive deps: crate_c (bin) directly depends on crate_b
      # only; ``--extern crate_b=...`` must be present. The transitive
      # crate_a is reached via ``-L dependency=<crate_a bin/deps dir>``
      # so we check for a ``-L`` flag referencing crate_a's dirs.
      let crateCMetaArgv = inlineArgvOf(metadataByCrate["crate_c"])
      var sawCrateBExternInC = false
      var sawCrateASearchPathInC = false
      for arg in crateCMetaArgv:
        if arg.startsWith("crate_b=") and arg.endsWith(".rmeta"):
          sawCrateBExternInC = true
        if arg.startsWith("dependency=") and arg.contains("crate_a"):
          sawCrateASearchPathInC = true
      check sawCrateBExternInC
      check sawCrateASearchPathInC
      # crate_c's metadata pass must list crate_b's actions in deps so
      # the engine waits for crate_b before running rustc-metadata-crate_c.
      check metadataByCrate["crate_b"].id in metadataByCrate["crate_c"].deps
      check linkByCrate["crate_b"].id in metadataByCrate["crate_c"].deps

  # --- M23: cdylib variant ------------------------------------------------

  test "emitFragment M23: cdylib emits --crate-type cdylib link argv":
    # M23 Part C: a crate with ``crate-type = ["cdylib"]`` in Cargo.toml
    # must emit a rustc-link action whose argv carries ``--crate-type
    # cdylib`` and whose primary output is the platform-named dynamic
    # library (``<n>.dll`` on Windows, ``lib<n>.so/.dylib`` on POSIX).
    if not rustToolchainAvailable():
      skip()
    elif not fileExists(CdylibFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & CdylibFixtureRoot
      fail()
    else:
      let conv = rust_convention.rustConvention()
      let request = dummyRequest(CdylibFixtureRoot)
      require conv.recognize(CdylibFixtureRoot, request)
      let fragment = conv.emitFragment(CdylibFixtureRoot, request)

      var metadataAction: BuildActionDef
      var linkAction: BuildActionDef
      var sawMetadata = false
      var sawLink = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "rustc-metadata-rust_cdylib_example-umbrella":
          metadataAction = action
          sawMetadata = true
        elif action.id == "rustc-link-rust_cdylib_example-umbrella":
          linkAction = action
          sawLink = true

      check sawMetadata
      check sawLink

      # Both passes must carry ``--crate-type cdylib`` (M23: per-target
      # crate-type selection, not the M13-era ``lib`` lumping).
      let metaArgv = inlineArgvOf(metadataAction)
      let linkArgv = inlineArgvOf(linkAction)
      var sawCdylibMeta = false
      var sawCdylibLink = false
      for i in 0 ..< metaArgv.len:
        if metaArgv[i] == "--crate-type" and i + 1 < metaArgv.len and
            metaArgv[i + 1] == "cdylib":
          sawCdylibMeta = true
          break
      for i in 0 ..< linkArgv.len:
        if linkArgv[i] == "--crate-type" and i + 1 < linkArgv.len and
            linkArgv[i + 1] == "cdylib":
          sawCdylibLink = true
          break
      check sawCdylibMeta
      check sawCdylibLink

      # Link action's primary output must be the platform-named .dll /
      # .so / .dylib. We check basename rather than full path so the
      # test is host-agnostic.
      check linkAction.outputs.len >= 1
      let primaryOut = linkAction.outputs[0].extractFilename
      when defined(windows):
        check primaryOut == "rust_cdylib_example.dll"
      elif defined(macosx):
        check primaryOut == "librust_cdylib_example.dylib"
      else:
        check primaryOut == "librust_cdylib_example.so"

  # --- M23: external crates.io dep ----------------------------------------

  test "emitFragment M23: project with crates.io dep routes to Mode B":
    # M23 Part B (scoped-down): when a project pulls in a crates.io
    # registry dep, the convention currently routes the WHOLE project
    # through the Mode B crude fallback. The crude path emits exactly
    # one ``cargo build --release --locked --offline`` action under a
    # ``project:crude-rust_binary_with_crates_io`` (or similar) id. We
    # don't assert the exact id (crude action ids encode the package
    # name, which varies per fixture); we just check that NO
    # ``rustc-metadata-*`` / ``rustc-link-*`` actions are emitted
    # (those would mean the convention tried Mode A and would fail at
    # rustc-resolve time).
    if not rustToolchainAvailable():
      skip()
    elif not fileExists(CratesIoFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & CratesIoFixtureRoot
      fail()
    else:
      # ``cargo metadata --no-deps --offline`` needs the crates.io
      # registry index to resolve the version specifier. If the host's
      # CARGO_HOME is empty (cold dev box) the convention's metadata
      # call fails. Skip cleanly rather than fail loud so the test
      # remains hermetic.
      let conv = rust_convention.rustConvention()
      let request = dummyRequest(CratesIoFixtureRoot)
      if not conv.recognize(CratesIoFixtureRoot, request):
        skip()
      else:
        var fragmentOk = true
        var fragment: GraphFragment
        try:
          fragment = conv.emitFragment(CratesIoFixtureRoot, request)
        except CatchableError:
          # ``cargo metadata`` may fail offline if the crate isn't in
          # the host's CARGO_HOME registry — that's a host-env gap, not
          # a convention bug. Mark skip rather than fail loud.
          fragmentOk = false
        if not fragmentOk:
          skip()
        else:
          var sawMode = false
          for node in fragment.nodes:
            if node.kind != gnkAction:
              continue
            let action = decodeBuildActionPayload(toBytes(node.payload))
            # No Mode A rustc actions should be emitted.
            check not action.id.startsWith("rustc-metadata-")
            check not action.id.startsWith("rustc-link-")
            # The crude fallback id is ``crude-build-<sanitized-name>``
            # (per ``crudeActionIdFor`` in crude.nim).
            if action.id.startsWith("crude-build-"):
              sawMode = true
          check sawMode

## M4 verification: Rust language convention.
##
## Tests against the in-tree fixture at
## ``reprobuild-examples/rust/binary/`` for the positive recognise path
## and the two-action emit-fragment path. Negative recognise cases are
## materialised as tiny scratch projects under the test's temp directory
## so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for the canonical fixture
##   * ``recognize`` returns false when:
##       - ``build.rs`` is present (forces M6 crude fallback)
##       - ``Cargo.toml`` declares ``[workspace]`` (deferred to M4+1)
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

import std/[os, strutils, unittest]

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

  test "recognize: negative — build.rs is present":
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
    check not conv.recognize(scratch, request)

  test "recognize: negative — [workspace] in Cargo.toml":
    let scratch = getTempDir() / "test_rust_convention_workspace"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeWorkspaceExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  executable fake_workspace:\n" &
      "    discard\n")
    writeFile(scratch / "Cargo.toml",
      "[workspace]\n" &
      "members = [\"crates/a\", \"crates/b\"]\n" &
      "\n" &
      "[package]\n" &
      "name = \"fake-workspace\"\n" &
      "version = \"0.1.0\"\n" &
      "edition = \"2024\"\n")
    writeFile(scratch / "src" / "main.rs",
      "fn main() { println!(\"unused\"); }\n")
    defer:
      removeDir(scratch)
    let conv = rust_convention.rustConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

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

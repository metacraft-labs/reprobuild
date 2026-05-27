## M4 + M13 verification: Rust language convention.
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

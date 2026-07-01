## M6 verification: Mode B crude fallback emitter.
##
## Covers ``libs/repro_standard_provider/src/repro_standard_provider/crude.nim``
## end-to-end without depending on a specific language convention.
##
## Coverage:
##   * ``emitCrudeFragment`` against a synthetic scratch project produces
##     a single inline-exec action whose argv starts with the supplied
##     native-build-tool command, whose cwd is the project root, whose
##     ``dependencyPolicy.kind == bdpAutomaticMonitor``, whose ``outputs``
##     contain the supplied output directory, and which lives in the
##     ``compile`` pool with ``cacheable = true``.
##   * The Rust convention's ``recognize`` now returns ``true`` for the
##     in-tree ``reprobuild-examples/rust/binary-with-build-rs`` fixture
##     (M6 relaxation — ``build.rs`` is no longer a rejection signal).
##   * The Rust convention's ``recognize`` continues to return ``true``
##     for the canonical ``rust/binary`` fixture (the Mode A path still
##     fires when no ``build.rs`` is present).
##
## The convention-level tests run only when ``rustc`` and ``cargo`` are
## on PATH — same skip pattern as ``test_rust_convention.nim``.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/crude
import repro_standard_provider/conventions/rust as rust_convention

const
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_crude_fallback.nim``
  ## lands at the ``reprobuild/`` repo root. The fixtures live in the
  ## sibling ``reprobuild-examples`` checkout under ``D:/metacraft/``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  RustBinaryRoot = MetacraftRoot / "reprobuild-examples" / "rust" / "binary"
  RustBuildRsRoot = MetacraftRoot / "reprobuild-examples" / "rust" /
                    "binary-with-build-rs"

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

proc inlineCwdOf(action: BuildActionDef): string =
  for arg in action.call.arguments:
    if arg.name == "cwd":
      return arg.encodedValue
  ""

proc rustToolchainAvailable(): bool =
  findExe("rustc").len > 0 and findExe("cargo").len > 0

suite "crude fallback M6":

  test "test_crude_fallback_emits_monitored_action":
    # Hermetic scratch project — emitCrudeFragment only touches the
    # filesystem to enumerate inputs, so a tiny fixture is enough.
    let scratch = getTempDir() / "test_crude_fallback_emit"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.rs",
      "fn main() {}\n")
    writeFile(scratch / "Cargo.toml", "[package]\nname = \"fake\"\n")
    defer:
      removeDir(scratch)

    let request = dummyRequest(scratch)
    let fragment = emitCrudeFragment(
      projectRoot = scratch,
      request = request,
      packageName = "fakePkg",
      nativeBuildArgv = ["fake-tool", "build"],
      outputDirs = ["target"])

    # Decode every action node and assert there is exactly one.
    var actions: seq[BuildActionDef] = @[]
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      actions.add(decodeBuildActionPayload(toBytes(node.payload)))
    check actions.len == 1
    let action = actions[0]

    # Inline-exec call carries the supplied argv as the first
    # `argv` arg, encoded as \x1f-separated tokens.
    let argv = inlineArgvOf(action)
    check argv.len >= 2
    check argv[0] == "fake-tool"
    check argv[1] == "build"

    # cwd argument matches the project root verbatim.
    check inlineCwdOf(action) == scratch

    # M6 contract: dependencyPolicy is automaticMonitor (io-monitor
    # captures the real deps at runtime).
    check action.dependencyPolicy.kind == bdpAutomaticMonitor

    # Outputs include the conventional target dir (expanded to an
    # absolute path under the project root by emitCrudeFragment so
    # the engine's preserve-tree bookkeeping has a single canonical
    # location).
    let expectedTarget = scratch / "target"
    var sawTarget = false
    for o in action.outputs:
      if o == expectedTarget or o.endsWith("target") or
         o.endsWith("target" & $DirSep):
        sawTarget = true
        break
    check sawTarget

    # Compile pool + cacheable — both fixed by the M6 design.
    check action.pool == "compile"
    check action.cacheable

    # Inputs include the scratch source file we wrote. The exact list
    # depends on platform path separators, so check by basename.
    var sawMainRs = false
    var sawCargoToml = false
    for inp in action.inputs:
      let tail = inp.extractFilename
      if tail == "main.rs":
        sawMainRs = true
      elif tail == "Cargo.toml":
        sawCargoToml = true
    check sawMainRs
    check sawCargoToml

  test "rustConvention.recognize: positive — binary-with-build-rs fixture":
    # M6 relaxation — build.rs no longer rejects the project; the
    # convention claims it and routes to Mode B inside emitFragment.
    let conv = rust_convention.rustConvention()
    if not fileExists(RustBuildRsRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & RustBuildRsRoot
      fail()
    let request = dummyRequest(RustBuildRsRoot)
    if not rustToolchainAvailable():
      checkpoint "rustc/cargo not on PATH — positive recognize will return false"
      check not conv.recognize(RustBuildRsRoot, request)
    else:
      check conv.recognize(RustBuildRsRoot, request)
    # crudeFallback hook is wired up on the convention object.
    check conv.crudeFallback != nil

  test "rustConvention.recognize: still claims rust/binary (no build.rs)":
    # Regression — the M6 emitFragment change must not affect projects
    # without a build.rs. Same probe as test_rust_convention.nim's
    # positive case but kept here so the M6 suite stays self-contained.
    let conv = rust_convention.rustConvention()
    if not fileExists(RustBinaryRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & RustBinaryRoot
      fail()
    let request = dummyRequest(RustBinaryRoot)
    if not rustToolchainAvailable():
      checkpoint "rustc/cargo not on PATH — positive recognize will return false"
      check not conv.recognize(RustBinaryRoot, request)
    else:
      check conv.recognize(RustBinaryRoot, request)

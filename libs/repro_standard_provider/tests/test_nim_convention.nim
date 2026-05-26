## M3 verification: Nim language convention.
##
## Tests against the in-tree fixture at
## ``reprobuild-examples/nim/binary/`` for the positive path. For the
## negative cases (no executable, wrong language, missing source file)
## we materialise tiny scratch projects under the test's temp directory
## so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for the canonical fixture
##   * ``recognize`` returns false when:
##       - ``uses:`` doesn't include ``nim`` (e.g. ``rust >=1.0``)
##       - the declared ``executable``'s ``src/<name>.nim`` is missing
##       - no executable is declared
##   * ``emitFragment`` against the canonical fixture produces a graph
##     with exactly one Phase 1 ``nim c --compileOnly`` action, at least
##     one Phase 2 ``gcc -c -o`` action with a depfile, exactly one
##     Phase 3 ``gcc -o <exe>`` link action, and the deps wired up so
##     Phase 2 → Phase 1, Phase 3 → all Phase 2.
##
## The fragment test depends on ``nim`` being on PATH because the
## convention's Phase 1 invocation runs eagerly at emit time
## (``Standard-Provider-Implementation.milestones.org §M3, Option 1``).
## We assert ``recognize`` first, which short-circuits to ``false`` if
## ``nim`` is missing — so a sandbox without Nim simply skips the
## fragment assertions instead of failing them.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/nim as nim_convention

const
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_nim_convention.nim``
  ## lands at the ``reprobuild/`` repo root. The fixture lives in the
  ## sibling ``reprobuild-examples`` checkout under ``D:/metacraft/``,
  ## so we take one more parent.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  FixtureRoot = MetacraftRoot / "reprobuild-examples" / "nim" / "binary"
  FixtureEntry = "nim_binary_example"

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

suite "nim convention M3":

  test "recognize: positive — canonical fixture":
    let conv = nim_convention.nimConvention()
    check conv.name == "nim"
    if not fileExists(FixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & FixtureRoot
      fail()
    let request = dummyRequest(FixtureRoot)
    check conv.recognize(FixtureRoot, request)

  test "recognize: negative — uses lists rust instead of nim":
    let scratch = getTempDir() / "test_nim_convention_rust_neg"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRustExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.0\"\n" &
      "\n" &
      "  executable fake_rust\n")
    writeFile(scratch / "src" / "fake_rust.nim",
      "echo \"unused\"\n")
    defer:
      removeDir(scratch)
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — declared executable has no source file":
    let scratch = getTempDir() / "test_nim_convention_missing_source"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package missingSourceExample:\n" &
      "  uses:\n" &
      "    \"nim >=2.2\"\n" &
      "\n" &
      "  executable ghost_binary\n")
    # NO src/ghost_binary.nim AND no *.nimble file. recognize must
    # fall through to checking the src tree and find nothing.
    defer:
      removeDir(scratch)
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declarations":
    let scratch = getTempDir() / "test_nim_convention_metadata_only"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package metadataOnlyExample:\n" &
      "  uses:\n" &
      "    \"nim >=2.2\"\n")
    # No executable / library declared — the package is pure metadata.
    defer:
      removeDir(scratch)
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: three-phase graph against canonical fixture":
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(FixtureRoot)
    require conv.recognize(FixtureRoot, request)
    let fragment = conv.emitFragment(FixtureRoot, request)

    var phase1Actions: seq[BuildActionDef] = @[]
    var phase2Actions: seq[BuildActionDef] = @[]
    var phase3Actions: seq[BuildActionDef] = @[]
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      let argv = inlineArgvOf(action)
      if argv.len == 0:
        continue
      if action.id.startsWith("nim-c-compileonly-"):
        phase1Actions.add(action)
      elif action.id.startsWith("gcc-compile-"):
        phase2Actions.add(action)
      elif action.id.startsWith("gcc-link-"):
        phase3Actions.add(action)

    # Phase 1: exactly one nim-c-compileonly action whose argv has the
    # convention's hard-coded skip-config / compile-only / no-linking
    # toggles.
    check phase1Actions.len == 1
    let phase1 = phase1Actions[0]
    let phase1Argv = inlineArgvOf(phase1)
    check phase1Argv.len >= 6
    check phase1Argv[1] == "c"
    check "--compileOnly" in phase1Argv
    check "--noLinking" in phase1Argv
    check "--skipParentCfg" in phase1Argv
    check "--skipUserCfg" in phase1Argv
    check "--mm:orc" in phase1Argv
    check phase1Argv[^1].endsWith(FixtureEntry & ".nim")

    # Phase 2: at least one gcc-compile action; each carries a depfile,
    # explicit -c, an -o pair, and declares the phase-1 id in its deps.
    check phase2Actions.len >= 1
    for action in phase2Actions:
      let argv = inlineArgvOf(action)
      check "-c" in argv
      check "-o" in argv
      check "-MD" in argv
      check "-MF" in argv
      check action.depfile.len > 0
      check action.dependencyPolicy.kind == bdpMakeDepfile
      check phase1.id in action.deps

    # Phase 3: exactly one link action; depends on every phase-2 id;
    # argv carries -o <binary> and the binary path ends with the entry
    # name (with .exe on Windows).
    check phase3Actions.len == 1
    let phase3 = phase3Actions[0]
    let phase3Argv = inlineArgvOf(phase3)
    check "-o" in phase3Argv
    let phase2Ids = block:
      var ids: seq[string] = @[]
      for a in phase2Actions: ids.add(a.id)
      ids
    for id in phase2Ids:
      check id in phase3.deps
    let outputBinary = phase3.outputs[^1]
    when defined(windows):
      check outputBinary.endsWith(FixtureEntry & ".exe")
    else:
      check outputBinary.endsWith(FixtureEntry)

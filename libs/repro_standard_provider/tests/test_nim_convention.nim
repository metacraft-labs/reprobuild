## M3 + M22 verification: Nim language convention.
##
## Tests against the in-tree fixture at
## ``reprobuild-examples/nim/binary/`` for the positive path. For the
## negative cases (no executable, wrong language, missing source file)
## we materialise tiny scratch projects under the test's temp directory
## so each case is hermetic.
##
## **M22 additions**: emit-fragment coverage against
## ``reprobuild-examples/nim/library-with-tests/`` asserts that the
## convention emits a non-default ``test`` target with one ``nim c -r``
## verification action per discovered ``tests/test_*.nim`` file, each
## paired with a chained ``fs.stamp`` companion.
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
  TestFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "nim" / "library-with-tests"

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

  # --- M22: test discovery -------------------------------------------------

  test "emitFragment M22: library-with-tests emits a non-default test target":
    # The library-with-tests fixture ships exactly one
    # ``tests/test_greet.nim`` file. The Nim convention's M22 surface
    # walks ``tests/`` for ``test_*.nim`` files and emits a non-default
    # ``test`` target with a (nim c -r, fs.stamp) pair per file. The
    # default target still builds the library only — tests are opt-in
    # via ``repro build .#test``.
    let conv = nim_convention.nimConvention()
    if not fileExists(TestFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & TestFixtureRoot
      fail()
    let request = dummyRequest(TestFixtureRoot)
    require conv.recognize(TestFixtureRoot, request)
    let fragment = conv.emitFragment(TestFixtureRoot, request)

    var testRunActions: seq[BuildActionDef] = @[]
    var testStampActions: seq[BuildActionDef] = @[]
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      if action.id.startsWith("nim-test-run-"):
        testRunActions.add(action)
      elif action.id.startsWith("nim-test-stamp-"):
        testStampActions.add(action)

    check testRunActions.len == 1
    check testStampActions.len == 1
    let runAction = testRunActions[0]
    let runArgv = inlineArgvOf(runAction)
    # The run action's argv must invoke nim with ``c -r`` and the test
    # file as the final positional. ``--path:src`` exposes the library
    # source root to the test's imports.
    check runArgv.len >= 4
    check runArgv[1] == "c"
    check "-r" in runArgv
    check "--hints:off" in runArgv
    check "--warnings:off" in runArgv
    var sawPathFlag = false
    for arg in runArgv:
      if arg.startsWith("--path:") and arg.endsWith("src"):
        sawPathFlag = true
        break
    check sawPathFlag
    check runArgv[^1].endsWith("test_greet.nim")
    check runAction.outputs.len == 0
    check runAction.pool == "compile"

    # Stamp action: depends on the run; its output is the convention's
    # canonical stamp path under ``<scratch>/tests/``.
    let stampAction = testStampActions[0]
    check runAction.id in stampAction.deps
    check stampAction.outputs.len == 1
    let stampPath = stampAction.outputs[0].replace('\\', '/')
    check stampPath.endsWith("/tests/test_greet.stamp")
    check ".repro/build" in stampPath

  test "emitFragment M22: nim/binary has no test actions":
    # Inverse cohort: the nim/binary fixture has no ``tests/`` directory
    # so the convention must not emit a ``test`` target nor any
    # ``nim-test-*`` actions.
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(FixtureRoot)
    require conv.recognize(FixtureRoot, request)
    let fragment = conv.emitFragment(FixtureRoot, request)
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      check not action.id.startsWith("nim-test-run-")
      check not action.id.startsWith("nim-test-stamp-")

# ---------------------------------------------------------------------------
# Mode 3 ``depends_on`` engine-consumption suite.
#
# These tests pin the convention's response to the workspace-dep registry:
#   * the converted ``mode3-pilot`` fixture produces an executable link
#     action whose ``inputs``/``deps``/argv reference the dep library's
#     archive (the action graph carries the cross-package edge);
#   * a cycle in a hand-rolled scratch fixture is rejected with a clear
#     diagnostic;
#   * an ``depends_on <pkg>: <missing>`` referencing a non-declared
#     package is rejected with a clear diagnostic;
#   * single-package fixtures (no ``depends_on``) are unaffected.
# ---------------------------------------------------------------------------

const
  ## ``nim/mode3-pilot`` carries the canonical two-package shape: one
  ## library package (``mode3PilotGreet``), one executable package
  ## (``mode3PilotHello``), and a scanner-emitted ``depends_on`` edge.
  Mode3PilotRoot =
    MetacraftRoot / "reprobuild-examples" / "nim" / "mode3-pilot"

proc actionByPrefix(fragment: GraphFragment; prefix: string):
    seq[BuildActionDef] =
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    if action.id.startsWith(prefix):
      result.add(action)

suite "nim convention Mode 3 depends_on":

  test "emitFragment: mode3-pilot wires hello -> greet via dep library":
    let conv = nim_convention.nimConvention()
    if not fileExists(Mode3PilotRoot / "repro.nim"):
      checkpoint "fixture missing — looked at " & Mode3PilotRoot
      fail()
    let request = dummyRequest(Mode3PilotRoot)
    require conv.recognize(Mode3PilotRoot, request)
    let fragment = conv.emitFragment(Mode3PilotRoot, request)

    # The convention emits one ``ar`` archive action for the greet
    # library and one ``gcc -o hello.exe`` link action for the
    # executable. The hello link must declare both an ``inputs`` entry
    # for the archive and a ``deps`` entry for the archive's action id.
    var greetArchive: BuildActionDef
    var greetFound = false
    for action in actionByPrefix(fragment, "ar-archive-greet-"):
      greetArchive = action
      greetFound = true
      break
    check greetFound
    check greetArchive.outputs.len == 1
    let archivePath = greetArchive.outputs[0]
    check archivePath.replace('\\', '/').endsWith("libgreet.a")

    var helloLink: BuildActionDef
    var helloFound = false
    for action in actionByPrefix(fragment, "gcc-link-hello-"):
      helloLink = action
      helloFound = true
      break
    check helloFound

    # Build-sequencing: hello's link depends on greet's ar action id.
    check greetArchive.id in helloLink.deps
    # Link-input wiring: archive is declared as an input of the link.
    check archivePath in helloLink.inputs
    # Argv wiring: the archive appears as a positional on the link argv.
    let helloArgv = inlineArgvOf(helloLink)
    check archivePath in helloArgv

  test "emitFragment: cycle in depends_on is rejected":
    let scratch = getTempDir() / "test_nim_convention_cycle"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "alpha.nim", "## alpha library\n")
    writeFile(scratch / "src" / "beta.nim", "## beta library\n")
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package alphaPkg:\n" &
      "  uses:\n" &
      "    \"nim >=2.2 <3.0\"\n" &
      "  library alpha\n" &
      "\n" &
      "package betaPkg:\n" &
      "  uses:\n" &
      "    \"nim >=2.2 <3.0\"\n" &
      "  library beta\n" &
      "\n" &
      "depends_on alphaPkg: betaPkg\n" &
      "depends_on betaPkg: alphaPkg\n")
    defer:
      removeDir(scratch)
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(scratch)
    require conv.recognize(scratch, request)
    var raised = false
    var message = ""
    try:
      discard conv.emitFragment(scratch, request)
    except ValueError as err:
      raised = true
      message = err.msg
    check raised
    check "cycle" in message.toLowerAscii()

  test "emitFragment: depends_on referencing undeclared package is rejected":
    let scratch = getTempDir() / "test_nim_convention_undeclared"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "hello.nim",
      "echo \"hello from undeclared-test\"\n")
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package undeclaredHello:\n" &
      "  uses:\n" &
      "    \"nim >=2.2 <3.0\"\n" &
      "  executable hello:\n" &
      "    discard\n" &
      "\n" &
      "depends_on undeclaredHello: nonexistentPackage\n")
    defer:
      removeDir(scratch)
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(scratch)
    require conv.recognize(scratch, request)
    var raised = false
    var message = ""
    try:
      discard conv.emitFragment(scratch, request)
    except ValueError as err:
      raised = true
      message = err.msg
    check raised
    check "nonexistentPackage" in message

  test "emitFragment: nim/binary unaffected by Mode 3 wiring":
    # Regression check: a single-package fixture with NO ``depends_on``
    # at all must still emit the same link-action shape (no extra
    # archive inputs, no extra dep edges between targets).
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(FixtureRoot)
    require conv.recognize(FixtureRoot, request)
    let fragment = conv.emitFragment(FixtureRoot, request)
    var phase3: BuildActionDef
    var found = false
    for action in actionByPrefix(fragment, "gcc-link-"):
      phase3 = action
      found = true
      break
    check found
    # No archive inputs (the fixture declares no library).
    for input in phase3.inputs:
      check not input.endsWith(".a")
      check not input.endsWith(".so")
      check not input.endsWith(".dylib")

# ---------------------------------------------------------------------------
# Cross-language (Mode 3 mixed-workspace) emit-fragment suite.
#
# Pins the Nim convention's response when a single ``repro.nim`` declares
# packages from multiple toolchains:
#   * The Nim convention claims the WHOLE workspace because it's
#     registered first AND at least one package declares ``uses: nim``.
#   * Only ``uses: nim`` packages contribute to the Nim three-phase
#     pipeline; ``uses: gcc`` / ``uses: clang`` packages route through
#     the embedded C/C++ archive helper inside the same fragment.
#   * The Nim entrypoint's Phase 1 ``nim c`` argv carries
#     ``--passC:-I<dep-include>`` per upstream C package.
#   * The Nim entrypoint's Phase 3 link argv carries the C archive path
#     as a trailing positional, its inputs include the archive path,
#     and its deps include the archive action's id.
#   * The schema-by-convention archive path matches what
#     ``c_cpp_direct`` would emit if it had ownership instead, so a
#     downstream user who graduates a project from mixed to pure C/C++
#     observes no archive path change.
# ---------------------------------------------------------------------------

const
  MixedFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "nim-uses-cpp-lib"

suite "nim convention cross-language (Mode 3 mixed workspace)":

  test "extractPackageUses: separates Nim and gcc packages by uses token":
    let source = """
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package nimapp:
  uses:
    "nim >=2.2 <3.0"
  executable nimapp:
    discard
"""
    let entries = nim_convention.extractPackageUses(source)
    check entries.len == 2
    var mathlibTokens: seq[string] = @[]
    var nimappTokens: seq[string] = @[]
    for entry in entries:
      if entry.package == "mathlib":
        mathlibTokens = entry.tokens
      elif entry.package == "nimapp":
        nimappTokens = entry.tokens
    check "gcc" in mathlibTokens
    check "nim" notin mathlibTokens
    check "nim" in nimappTokens
    check "gcc" notin nimappTokens

  test "emitFragment: mixed fixture wires Nim app -> C archive end-to-end":
    let conv = nim_convention.nimConvention()
    if not fileExists(MixedFixtureRoot / "repro.nim"):
      checkpoint "fixture missing — looked at " & MixedFixtureRoot
      fail()
    elif not conv.recognize(MixedFixtureRoot, dummyRequest(MixedFixtureRoot)):
      # Missing nim/gcc on PATH — the convention's recognize check
      # short-circuits to false. Skip the assertions instead of failing
      # the test in a stripped-down sandbox.
      skip()
    else:
      let request = dummyRequest(MixedFixtureRoot)
      let fragment = conv.emitFragment(MixedFixtureRoot, request)

      # The convention must emit (a) the C archive action for the
      # mathlib package and (b) the Nim Phase 3 link action for the
      # nimapp package. Both live in the same fragment so file-path
      # dep inference can wire them together.
      var mathlibArchive: BuildActionDef
      var sawArchive = false
      for action in actionByPrefix(fragment, "nim-xlang-ccpp-archive-mathlib"):
        mathlibArchive = action
        sawArchive = true
        break
      check sawArchive
      check mathlibArchive.outputs.len == 1
      let archivePath = mathlibArchive.outputs[0]
      check archivePath.replace('\\', '/').endsWith("libmathlib.a")

      # The archive path schema must match what c_cpp_direct would
      # emit for a same-named library member:
      # ``.repro/build/mathlib/libmathlib.a``. This is the schema the
      # cross-convention story relies on so downstream users can
      # graduate to pure C/C++ without an archive-path migration.
      let normalised = archivePath.replace('\\', '/')
      check normalised.endsWith(".repro/build/mathlib/libmathlib.a")

      # Per-source compile action exists for the C source.
      var sawCCompile = false
      for action in actionByPrefix(fragment, "nim-xlang-ccpp-compile-mathlib-"):
        sawCCompile = true
        break
      check sawCCompile

      # The Nim Phase 1 action's argv carries --passC:-I<mathlib-include>.
      var nimPhase1: BuildActionDef
      var sawPhase1 = false
      for action in actionByPrefix(fragment, "nim-c-compileonly-nimapp-"):
        nimPhase1 = action
        sawPhase1 = true
        break
      check sawPhase1
      let phase1Argv = inlineArgvOf(nimPhase1)
      var sawPassCInclude = false
      for token in phase1Argv:
        let normTok = token.replace('\\', '/')
        if normTok.startsWith("--passC:-I") and
            normTok.endsWith("mathlib/include"):
          sawPassCInclude = true
          break
      check sawPassCInclude

      # The Nim Phase 3 link action's argv carries the C archive as a
      # trailing positional, inputs include the archive, deps include
      # the archive action's id.
      var nimLink: BuildActionDef
      var sawLink = false
      for action in actionByPrefix(fragment, "gcc-link-nimapp-"):
        nimLink = action
        sawLink = true
        break
      check sawLink
      let linkArgv = inlineArgvOf(nimLink)
      check archivePath in linkArgv
      check archivePath in nimLink.inputs
      check mathlibArchive.id in nimLink.deps

  test "emitFragment: pure-Nim fixture does NOT emit any cross-language archive":
    # Regression: a single-language Nim project must not trigger the
    # C/C++ emit path, otherwise the unit-test count for nim/binary
    # diverges from the baseline.
    let conv = nim_convention.nimConvention()
    let request = dummyRequest(FixtureRoot)
    require conv.recognize(FixtureRoot, request)
    let fragment = conv.emitFragment(FixtureRoot, request)
    for action in actionByPrefix(fragment, "nim-xlang-ccpp-"):
      checkpoint "unexpected cross-language action: " & action.id
      fail()

## Integration test for the ``repro.nim`` / ``reprobuild.nim`` alias on
## the standard-provider recognition + emit path.
##
## Wide-coverage unit tests for the resolver itself live in
## ``libs/repro_core/tests/t_project_file_alias.nim``. This file proves
## that a project carrying ONLY the canonical ``repro.nim`` (no legacy
## file) still walks through the standard provider's convention
## dispatch path successfully — the alias contract is end-to-end, not
## just at the resolver layer.
##
## Approach: take the canonical ``reprobuild-examples/nim/binary``
## fixture, materialise a COPY into a temp directory with the project
## file renamed to ``repro.nim``, and assert that:
##
## * The Nim convention's ``recognize`` still returns ``true``.
## * ``emitFragment`` still produces a non-empty fragment (the same
##   three-phase shape ``test_nim_convention.nim`` exercises against
##   the legacy-named fixture; we don't re-pin the action count here
##   because that's not the alias contract — we only need to know the
##   convention recognised the project and produced *some* graph).
##
## We also exercise the "ambiguous" case end-to-end by writing both
## files into the scratch fixture and asserting that the convention
## path raises ``ProjectFileAmbiguousError`` — having both files in
## the same directory is a HARD ERROR per the spec, not a warning.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/nim as nim_convention

const
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  CanonicalFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "nim" / "binary"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc copyTree(srcDir, dstDir: string) =
  ## Recursive directory copy. Nim's ``copyDir`` exists but is locale-
  ## sensitive on Windows; this loop is portable.
  createDir(dstDir)
  for kind, src in walkDir(srcDir):
    let rel = src.relativePath(srcDir)
    let dst = dstDir / rel
    case kind
    of pcFile, pcLinkToFile:
      copyFile(src, dst)
    of pcDir, pcLinkToDir:
      copyTree(src, dst)

proc materialiseCanonicalRename(scratchName: string): string =
  ## Copy the canonical-fixture tree to a scratch directory and rename
  ## its ``reprobuild.nim`` to ``repro.nim``. Returns the scratch root.
  result = getTempDir() / scratchName
  if dirExists(result):
    removeDir(result)
  copyTree(CanonicalFixtureRoot, result)
  let legacy = result / "reprobuild.nim"
  let canonical = result / "repro.nim"
  doAssert fileExists(legacy),
    "test fixture missing reprobuild.nim at " & legacy
  moveFile(legacy, canonical)

suite "standard-provider project-file alias integration":

  test "canonical repro.nim only: nim convention recognises + emits":
    # Take the canonical Nim binary fixture, copy it under a scratch
    # name, rename the project file to ``repro.nim``, and verify the
    # whole convention path (recognise + emit) still works. This is the
    # Mode-3 recommended shape — the convention MUST work without the
    # legacy filename present at all.
    if not fileExists(CanonicalFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & CanonicalFixtureRoot
      skip()
    else:
      let scratch = materialiseCanonicalRename(
        "test_project_file_alias_canonical_only")
      defer: removeDir(scratch)
      check fileExists(scratch / "repro.nim")
      check not fileExists(scratch / "reprobuild.nim")
      let conv = nim_convention.nimConvention()
      let request = dummyRequest(scratch)
      check conv.recognize(scratch, request)
      # Emit is gated on ``nim`` being on PATH (the Nim convention runs
      # an eager ``nim c --compileOnly`` from emitFragment). ``recognize``
      # already returned true above, which short-circuits to false when
      # ``nim`` is missing — so a green ``recognize`` plus a defensive
      # try around the emit is the right shape.
      var emitOk = false
      var fragment: GraphFragment
      try:
        fragment = conv.emitFragment(scratch, request)
        emitOk = true
      except CatchableError as err:
        checkpoint "emitFragment raised: " & err.msg
        fail()
      if emitOk:
        check fragment.nodes.len > 0
        # The engine's diagnostic surface ultimately surfaces the
        # ``PackageDef.sourceFile`` via the interface-artifact pipeline
        # (M2-and-beyond). The resolver's per-call test
        # (``test_project_file_alias.nim`` under ``libs/repro_core/``)
        # already pins that ``resolveProjectFile`` returns the canonical
        # name here, so we trust the convention's own
        # ``syntheticPackage`` to thread the right filename into the
        # ``PackageDef``. The integration concern at this layer is
        # simply that emit succeeded without the project file present
        # at the legacy name.

  test "both files: convention path raises ProjectFileAmbiguousError":
    # Materialise the same fixture with BOTH files present. The spec
    # (Three-Mode-Convention-System.md line 211) declares this a hard
    # error: the convention path MUST raise rather than silently pick
    # one of the two files. We assert the error surfaces at the
    # resolver layer AND propagates through the convention's
    # ``recognize`` entry point (which calls ``resolveProjectFile``
    # via ``readReprobuildSource``).
    if not fileExists(CanonicalFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & CanonicalFixtureRoot
      skip()
    else:
      let scratch = getTempDir() / "test_project_file_alias_both"
      if dirExists(scratch):
        removeDir(scratch)
      copyTree(CanonicalFixtureRoot, scratch)
      defer: removeDir(scratch)
      # Add the canonical name without removing the legacy one.
      copyFile(scratch / "reprobuild.nim", scratch / "repro.nim")
      check fileExists(scratch / "repro.nim")
      check fileExists(scratch / "reprobuild.nim")
      # Resolver-layer: raises.
      var resolverRaised = false
      var resolverMsg = ""
      try:
        discard resolveProjectFile(scratch)
      except ProjectFileAmbiguousError as err:
        resolverRaised = true
        resolverMsg = err.msg
      check resolverRaised
      check resolverMsg.contains(CanonicalProjectFileName)
      check resolverMsg.contains(LegacyProjectFileName)
      check resolverMsg.contains(scratch)
      # Convention path: ``recognize`` calls ``readReprobuildSource`` →
      # ``resolveProjectFile``; the error propagates up.
      let conv = nim_convention.nimConvention()
      let request = dummyRequest(scratch)
      var conventionRaised = false
      try:
        discard conv.recognize(scratch, request)
      except ProjectFileAmbiguousError:
        conventionRaised = true
      check conventionRaised

  test "legacy reprobuild.nim only: existing fixtures keep working":
    # The unchanged canonical fixture. This is the regression: the M0-M29
    # corpus uses ``reprobuild.nim`` exclusively; the alias must not
    # have broken any of those.
    if not fileExists(CanonicalFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & CanonicalFixtureRoot
      skip()
    else:
      let conv = nim_convention.nimConvention()
      let request = dummyRequest(CanonicalFixtureRoot)
      check conv.recognize(CanonicalFixtureRoot, request)

## M46 verification: OCaml + Dune (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/ocaml-dune/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - ocaml AND dune are on PATH
##   * ``recognize`` returns false when:
##     - no ``dune-project`` is at the root
##     - ``uses:`` doesn't list dune
##     - ``uses:`` doesn't list ocaml (only dune)
##     - no executable / library member is declared
##     - ocaml or dune is missing from PATH (toolchain probe failure)
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     ocaml/dune missing):
##     - the convention emits a single ``ocaml-dune-build`` action.
##     - the action's argv carries ``dune build --release -j 1``.
##     - the action's output is
##       ``_build/default/hello.exe`` under the project root.
##   * Output-path resolution:
##     - executable at root yields ``_build/default/<name>.exe``
##     - executable in ``src/`` yields ``_build/default/src/<name>.exe``
##     - library yields ``_build/default/<entry-rel>/<name>.cmxa``
##   * Entry-dir resolution: ``findDuneEntryDir`` finds the root
##     ``dune`` file first, then descends into subdirs.
##
## **Toolchain-gated SKIPs**: most tests SKIP cleanly when ``ocaml`` or
## ``dune`` is not on PATH (which is the M46 default on Windows — OCaml
## isn't in the standard dev shell). The recognition-negative tests
## that don't depend on the toolchain still exercise the convention's
## gate-only paths and run unconditionally.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/ocaml_dune as ocaml_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_ocaml_dune_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "ocaml-dune" / "hello-binary"

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

proc ocamlToolchainReady(): bool =
  ## True when BOTH ``ocaml`` and ``dune`` are on PATH. The convention's
  ## ``recognize`` enforces this jointly; tests gate on this and SKIP
  ## when either is missing.
  findExe("ocaml").len > 0 and findExe("dune").len > 0

suite "ocaml-dune convention M46":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = ocaml_convention.ocamlDuneConvention()
    check conv.name == "ocaml-dune"
    if not fileExists(HelloBinaryFixture / "dune-project"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "dune"):
      checkpoint "fixture missing root dune file"
      fail()
    if not fileExists(HelloBinaryFixture / "hello.ml"):
      checkpoint "fixture missing hello.ml"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if ocamlToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "ocaml/dune toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no dune-project at root":
    let scratch = getTempDir() / "test_ocaml_dune_convention_no_manifest"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "hello.ml",
      "let () = print_endline \"hi\"\n")
    writeFile(scratch / "dune",
      "(executable (name hello))\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeOcamlNoManifest:\n" &
      "  uses:\n" &
      "    \"ocaml >=4.14\"\n" &
      "    \"dune >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = ocaml_convention.ocamlDuneConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks dune (only ocaml)":
    let scratch = getTempDir() / "test_ocaml_dune_convention_no_dune_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "dune-project", "(lang dune 3.0)\n")
    writeFile(scratch / "dune",
      "(executable (name hello))\n")
    writeFile(scratch / "hello.ml",
      "let () = print_endline \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeOcamlNoDune:\n" &
      "  uses:\n" &
      "    \"ocaml >=4.14\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = ocaml_convention.ocamlDuneConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks ocaml (only dune)":
    let scratch = getTempDir() / "test_ocaml_dune_convention_no_ocaml_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "dune-project", "(lang dune 3.0)\n")
    writeFile(scratch / "dune",
      "(executable (name hello))\n")
    writeFile(scratch / "hello.ml",
      "let () = print_endline \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeOcamlNoOcaml:\n" &
      "  uses:\n" &
      "    \"dune >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = ocaml_convention.ocamlDuneConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_ocaml_dune_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "dune-project", "(lang dune 3.0)\n")
    writeFile(scratch / "dune",
      "(executable (name hello))\n")
    writeFile(scratch / "hello.ml",
      "let () = print_endline \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeOcamlNoMember:\n" &
      "  uses:\n" &
      "    \"ocaml >=4.14\"\n" &
      "    \"dune >=3.0\"\n")
    defer:
      removeDir(scratch)
    let conv = ocaml_convention.ocamlDuneConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — ocaml/dune not on PATH (toolchain probe)":
    ## When ``ocaml`` or ``dune`` is missing from PATH the convention's
    ## recognise must return false. This test asserts only when the
    ## toolchain is ACTUALLY missing — when both ARE installed, skip
    ## rather than hand-wave the gate.
    if ocamlToolchainReady():
      skip()
    else:
      let scratch = getTempDir() / "test_ocaml_dune_convention_no_toolchain"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      writeFile(scratch / "dune-project", "(lang dune 3.0)\n")
      writeFile(scratch / "dune",
        "(executable (name hello))\n")
      writeFile(scratch / "hello.ml",
        "let () = print_endline \"hi\"\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeOcamlNoToolchain:\n" &
        "  uses:\n" &
        "    \"ocaml >=4.14\"\n" &
        "    \"dune >=3.0\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = ocaml_convention.ocamlDuneConvention()
      let request = dummyRequest(scratch)
      check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces a single build action":
    if not ocamlToolchainReady():
      skip()
    else:
      let conv = ocaml_convention.ocamlDuneConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var buildActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ocaml-dune-build":
          buildActions.add(action)

      check buildActions.len == 1
      let buildAct = buildActions[0]
      check buildAct.pool == "compile"

      # argv carries: dune, "build", "--release", "-j", "1"
      let argv = inlineArgvOf(buildAct)
      var sawBuildVerb = false
      var sawReleaseFlag = false
      var sawJobOnePair = false
      for i, token in argv:
        if token == "build": sawBuildVerb = true
        elif token == "--release": sawReleaseFlag = true
        elif token == "1" and i > 0 and argv[i - 1] == "-j":
          sawJobOnePair = true
      check sawBuildVerb
      check sawReleaseFlag
      check sawJobOnePair

      # Output is _build/default/hello.exe under the fixture root.
      var sawExeOutput = false
      let expectedSuffix = "/_build/default/hello.exe"
      for outPath in buildAct.outputs:
        let unified = outPath.replace('\\', '/')
        if unified.endsWith(expectedSuffix):
          sawExeOutput = true
      check sawExeOutput

  test "output-path resolution: executable at root ⇒ _build/default/<name>.exe":
    ## Exercise the executable output-path predictor for the root-level
    ## dune-file case. This is a pure function — no toolchain needed.
    let projectRoot = "/some/project"
    let predicted = ocaml_convention.producedExecutablePath(
      projectRoot, "", "myexe")
    let unified = predicted.replace('\\', '/')
    check unified.endsWith("/_build/default/myexe.exe")

  test "output-path resolution: executable at src/ ⇒ _build/default/src/<name>.exe":
    ## Exercise the executable output-path predictor when the dune file
    ## lives under ``src/``. This validates the relative entry-dir
    ## threading through the output path.
    let projectRoot = "/some/project"
    let predicted = ocaml_convention.producedExecutablePath(
      projectRoot, "src", "myexe")
    let unified = predicted.replace('\\', '/')
    check unified.endsWith("/_build/default/src/myexe.exe")

  test "output-path resolution: library yields _build/default/<rel>/<name>.cmxa":
    ## Exercise the library output-path predictor — produces the OCaml
    ## native-code archive convention ``<name>.cmxa``.
    let projectRoot = "/some/project"
    let predictedRoot = ocaml_convention.producedLibraryPath(
      projectRoot, "", "mylib")
    check predictedRoot.replace('\\', '/').endsWith(
      "/_build/default/mylib.cmxa")
    let predictedSrc = ocaml_convention.producedLibraryPath(
      projectRoot, "src", "mylib")
    check predictedSrc.replace('\\', '/').endsWith(
      "/_build/default/src/mylib.cmxa")

  test "entry-dir resolution: root dune file ⇒ project root":
    ## ``findDuneEntryDir`` must return the project root itself when
    ## the dune file lives at the root.
    let scratch = getTempDir() / "test_ocaml_dune_entry_root"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "dune-project", "(lang dune 3.0)\n")
    writeFile(scratch / "dune", "(executable (name hello))\n")
    defer:
      removeDir(scratch)
    let entryDir = ocaml_convention.findDuneEntryDir(scratch)
    # Compare normalised paths (handle Windows backslashes + temp dir).
    check entryDir.replace('\\', '/').strip(chars = {'/'}) ==
      scratch.replace('\\', '/').strip(chars = {'/'})

  test "entry-dir resolution: src/ dune file ⇒ src/":
    ## ``findDuneEntryDir`` must descend into ``src/`` when no root
    ## dune file is present.
    let scratch = getTempDir() / "test_ocaml_dune_entry_src"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "dune-project", "(lang dune 3.0)\n")
    writeFile(scratch / "src" / "dune", "(executable (name hello))\n")
    defer:
      removeDir(scratch)
    let entryDir = ocaml_convention.findDuneEntryDir(scratch)
    let expected = scratch / "src"
    check entryDir.replace('\\', '/').strip(chars = {'/'}) ==
      expected.replace('\\', '/').strip(chars = {'/'})

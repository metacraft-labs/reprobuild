## M5 verification: Go language convention.
##
## Tests against the in-tree fixture at
## ``reprobuild-examples/go/binary/`` for the positive recognise path
## and the emit-fragment path. Negative recognise cases are materialised
## as tiny scratch projects under the test's temp directory so each case
## is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for the canonical fixture
##   * ``recognize`` returns false when:
##       - any ``.go`` file contains ``import "C"`` (cgo trigger)
##       - a ``_cgo_*.go`` file exists in the project tree
##       - ``go.work`` is present (workspaces deferred)
##       - ``go.mod`` is absent (not a Go module)
##       - ``uses:`` doesn't list ``go``
##   * ``emitFragment`` against the canonical fixture produces:
##       - at least one ``go-compile-*`` action with ``go tool compile``
##         in argv
##       - exactly one ``go-link-*`` action with ``go tool link`` in argv
##       - the link action's ``deps`` include the main package's compile
##         action id (transitively the importcfg.link writer is also a
##         dep — the link action depends on both)
##
## The fragment test depends on ``go`` being on PATH because the
## convention invokes ``go list -export -json -deps ./...`` eagerly at
## emit time (Standard-Provider-Implementation.milestones.org §M5,
## Option 1). When ``go`` is missing we skip the emit assertions — the
## recognise assertions still run because they short-circuit to ``false``
## on a missing toolchain.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/go as go_convention

const
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_go_convention.nim`` lands
  ## at the ``reprobuild/`` repo root. The fixture lives in the sibling
  ## ``reprobuild-examples`` checkout under ``D:/metacraft/``, so take
  ## one more parent.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  FixtureRoot = MetacraftRoot / "reprobuild-examples" / "go" / "binary"
  FixtureModulePath = "example.com/go-binary-example"

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

proc goToolchainAvailable(): bool =
  findExe("go").len > 0

proc writeMinimalFixture(scratch, mainGo: string;
                         reprobuildBody = "uses:\n    \"go >=1.22 <2.0\"\n\n  executable fake_go:\n    discard\n";
                         modulePath = "example.com/fake") =
  ## Build a minimal but conforming Go-fixture skeleton: ``go.mod`` +
  ## ``main.go`` + ``reprobuild.nim``. Returns nothing — caller defers
  ## removal of ``scratch`` itself.
  if dirExists(scratch):
    removeDir(scratch)
  createDir(scratch)
  writeFile(scratch / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package fakeGoExample:\n  " &
    reprobuildBody)
  writeFile(scratch / "go.mod",
    "module " & modulePath & "\n\ngo 1.22\n")
  writeFile(scratch / "main.go", mainGo)

suite "go convention M5":

  test "recognize: positive — canonical fixture":
    let conv = go_convention.goConvention()
    check conv.name == "go"
    if not fileExists(FixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & FixtureRoot
      fail()
    let request = dummyRequest(FixtureRoot)
    if not goToolchainAvailable():
      checkpoint "go not on PATH — positive recognize will return false"
      check not conv.recognize(FixtureRoot, request)
    else:
      check conv.recognize(FixtureRoot, request)

  test "recognize: negative — import \"C\" present (cgo)":
    let scratch = getTempDir() / "test_go_convention_cgo_import"
    writeMinimalFixture(scratch,
      mainGo = "package main\n\nimport \"C\"\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"cgo\") }\n")
    defer:
      removeDir(scratch)
    let conv = go_convention.goConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — _cgo_*.go present":
    let scratch = getTempDir() / "test_go_convention_cgo_file"
    writeMinimalFixture(scratch,
      mainGo = "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"no cgo here\") }\n")
    # Add a _cgo_*.go file alongside main.go — recognition must reject
    # purely on the filename.
    writeFile(scratch / "_cgo_gotypes.go",
      "package main\n\n// generated stub\n")
    defer:
      removeDir(scratch)
    let conv = go_convention.goConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — go.work present":
    let scratch = getTempDir() / "test_go_convention_go_work"
    writeMinimalFixture(scratch,
      mainGo = "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"workspaces\") }\n")
    # Add go.work — recognition must reject (single-module only for M5).
    writeFile(scratch / "go.work",
      "go 1.22\n\nuse ./\n")
    defer:
      removeDir(scratch)
    let conv = go_convention.goConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no go.mod":
    let scratch = getTempDir() / "test_go_convention_no_gomod"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeGoNoMod:\n" &
      "  uses:\n" &
      "    \"go >=1.22 <2.0\"\n" &
      "\n" &
      "  executable fake_no_mod:\n" &
      "    discard\n")
    writeFile(scratch / "main.go",
      "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"hi\") }\n")
    defer:
      removeDir(scratch)
    let conv = go_convention.goConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lists rust instead of go":
    let scratch = getTempDir() / "test_go_convention_rust_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRustyExample:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  executable fake_rusty:\n" &
      "    discard\n")
    writeFile(scratch / "go.mod",
      "module example.com/fake-rusty\n\ngo 1.22\n")
    writeFile(scratch / "main.go",
      "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"not me\") }\n")
    defer:
      removeDir(scratch)
    let conv = go_convention.goConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: graph shape against canonical fixture":
    if not goToolchainAvailable():
      skip()
    else:
      let conv = go_convention.goConvention()
      let request = dummyRequest(FixtureRoot)
      require conv.recognize(FixtureRoot, request)
      let fragment = conv.emitFragment(FixtureRoot, request)

      var compileActions: seq[BuildActionDef] = @[]
      var linkActions: seq[BuildActionDef] = @[]
      var mainCompileId = ""
      # The main package's compile action is identified by the action id
      # suffix containing the fixture's import path. ``-p`` itself is
      # ``main`` (Go's own convention for the main-package symbol-table
      # identifier), so we can't key off the argv's ``-p`` value alone.
      let sanitizedMainImportPath = block:
        var s = ""
        for ch in FixtureModulePath:
          if ch == '/':
            s.add("__")
          else:
            s.add(ch)
        s
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        let argv = inlineArgvOf(action)
        if argv.len == 0:
          continue
        if action.id.startsWith("go-compile-"):
          compileActions.add(action)
          if sanitizedMainImportPath in action.id:
            mainCompileId = action.id
        elif action.id.startsWith("go-link-"):
          linkActions.add(action)

      # At least one compile action (the main package) must be present —
      # any additional ones depend on whether the fixture pulls in
      # project-local sub-packages (the canonical fixture is single-pkg
      # so this is exactly one, but we don't hard-code that).
      check compileActions.len >= 1

      # The main compile must carry ``go tool compile`` + ``-pack`` + a
      # ``-p main`` flag (Go's convention for the main-package symbol-
      # table identifier — using the full import path triggers a
      # "function main is undeclared" link error).
      check mainCompileId.len > 0
      var sawMainArgv = false
      for action in compileActions:
        if action.id != mainCompileId:
          continue
        let argv = inlineArgvOf(action)
        check "tool" in argv
        check "compile" in argv
        check "-pack" in argv
        check "-importcfg" in argv
        let pIdx = argv.find("-p")
        check pIdx >= 0
        check argv[pIdx + 1] == "main"
        check action.pool == "compile"
        sawMainArgv = true
      check sawMainArgv

      # Exactly one link action with ``go tool link`` in argv.
      check linkActions.len == 1
      let linkAction = linkActions[0]
      let linkArgv = inlineArgvOf(linkAction)
      check "tool" in linkArgv
      check "link" in linkArgv
      check "-importcfg" in linkArgv
      check "-buildmode=exe" in linkArgv
      check linkAction.pool == "compile"

      # The link action's deps must include the main package's compile
      # action id (cross-package ordering edges from Go.md).
      check mainCompileId in linkAction.deps

      # The link output should be the executable under
      # <scratch>/<entry>/bin/ — the binary should at minimum carry the
      # snake-case form of the fixture's last path component.
      check linkAction.outputs.len == 1
      let outName = extractFilename(linkAction.outputs[0])
      when defined(windows):
        check outName.endsWith(".exe")
        check outName.startsWith("go_binary_example")
      else:
        check outName.startsWith("go_binary_example")

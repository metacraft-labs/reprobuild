## M5 + M14 + M22 verification: Go language convention.
##
## Tests against the in-tree fixtures under ``reprobuild-examples/go/``:
##
##   * ``go/binary``       — root ``main.go`` (M5 surface)
##   * ``go/multi-binary`` — ``cmd/alpha/main.go`` + ``cmd/beta/main.go``
##     (M14 surface)
##   * ``go/library``      — library-only module, no ``package main``
##     anywhere (M14 surface)
##
## Negative recognise cases are materialised as tiny scratch projects
## under the test's temp directory so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for:
##     - a ``go.work`` workspace root (Go.md §"Workspace and module mode",
##       amended 2026-11-16; this replaced a negative case that encoded the
##       old "workspaces deferred" rule)
##     - the canonical root-``main.go`` fixture (M5)
##     - the ``cmd/<name>/main.go`` multi-binary fixture (M14)
##     - the library-only fixture (M14)
##   * ``recognize`` returns false when:
##     - any ``.go`` file contains ``import "C"`` (cgo trigger)
##     - a ``_cgo_*.go`` file exists in the project tree
##     - ``go.mod`` is absent (not a Go module)
##     - ``uses:`` doesn't list ``go``
##   * ``emitFragment`` against the canonical M5 fixture produces:
##     - at least one ``go-compile-*`` action with ``go tool compile``
##       in argv
##     - exactly one ``go-link-*`` action with ``go tool link`` in argv
##     - the link action's ``deps`` include the main package's compile
##       action id (transitively the importcfg.link writer is also a
##       dep — the link action depends on both)
##   * ``emitFragment`` against the M14 multi-binary fixture produces:
##     - exactly TWO ``go-link-*`` actions (one per ``cmd/<name>/``)
##     - each link action's output basename matches the cmd's last
##       path segment (``alpha.exe`` / ``beta.exe``)
##   * ``emitFragment`` against the M14 library-only fixture produces:
##     - at least one ``go-compile-*`` action
##     - ZERO ``go-link-*`` actions
##
## The fragment tests depend on ``go`` being on PATH because the
## convention invokes ``go list -export -json -deps ./...`` eagerly at
## emit time (Standard-Provider-Implementation.milestones.org §M5,
## Option 1). When ``go`` is missing we skip the emit assertions — the
## recognise assertions still run because they short-circuit to ``false``
## on a missing toolchain.

import std/[json, os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/go as go_convention
import repro_standard_provider/conventions/go_embed

let
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_go_convention.nim`` lands
  ## at the ``reprobuild/`` repo root. The fixture lives in the sibling
  ## ``reprobuild-examples`` checkout under ``D:/metacraft/``, so take
  ## one more parent.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = workspaceRootForRepo(ReprobuildRoot)
  FixtureRoot = MetacraftRoot / "reprobuild-examples" / "go" / "binary"
  FixtureModulePath = "example.com/go-binary-example"
  MultiBinaryFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "go" / "multi-binary"
  LibraryFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "go" / "library"
  LibraryWithTestsFixtureRoot =
    MetacraftRoot / "reprobuild-examples" / "go" / "library-with-tests"

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

proc writeWorkspaceFixture(root: string) =
  ## A ``go.work`` root that is not itself a module: ``lib`` (``go 1.23.0``,
  ## the patch-release form ``go mod init`` writes; ranges over a function
  ## iterator, legal only at ``-lang=go1.23``+) and ``api`` (``go 1.22``)
  ## importing it.
  createDir(root / "lib")
  createDir(root / "api")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package fakeGoWork:\n" &
    "  uses:\n    \"go >=1.22 <2.0\"\n\n" &
    "  executable api:\n    discard\n")
  writeFile(root / "go.work", "go 1.23.0\n\nuse (\n\t./api\n\t./lib\n)\n")
  writeFile(root / "lib" / "go.mod", "module example.com/lib\n\ngo 1.23.0\n")
  writeFile(root / "lib" / "lib.go", "package lib\n\n" &
    "func seq(yield func(int) bool) {\n" &
    "\tfor i := 1; i <= 3; i++ {\n\t\tif !yield(i) {\n\t\t\treturn\n\t\t}\n\t}\n}\n\n" &
    "func Sum() int {\n\ts := 0\n\tfor v := range seq {\n\t\ts += v\n\t}\n\treturn s\n}\n")
  writeFile(root / "api" / "go.mod", "module example.com/api\n\ngo 1.22\n\n" &
    "require example.com/lib v0.0.0\n")
  writeFile(root / "api" / "main.go", "package main\n\nimport (\n\t\"fmt\"\n\n" &
    "\t\"example.com/lib\"\n)\n\nfunc main() { fmt.Println(lib.Sum()) }\n")

proc staticElfWithoutInterpreter(path: string): bool =
  ## True for an ELF64 executable with no ``PT_INTERP`` program header: an
  ## image the dynamic loader never runs, so ``LD_PRELOAD`` cannot inject the
  ## monitor into it.
  var data: string
  try:
    data = readFile(path)   # follows symlinks
  except CatchableError:
    return false
  if data.len < 64 or data[0 .. 3] != "\x7FELF" or data[4] != '\x02':
    return false
  proc u16(at: int): int = ord(data[at]) or (ord(data[at + 1]) shl 8)
  proc u64(at: int): int =
    for i in countdown(7, 0):
      result = (result shl 8) or ord(data[at + i])
  let phoff = u64(0x20)
  let phentsize = u16(0x36)
  let phnum = u16(0x38)
  for i in 0 ..< phnum:
    let at = phoff + i * phentsize
    if at + 4 > data.len:
      return false
    if ord(data[at]) == 3 and ord(data[at + 1]) == 0 and
        ord(data[at + 2]) == 0 and ord(data[at + 3]) == 0:
      return false
  true

proc writeTextOf(action: BuildActionDef): string =
  ## The text an ``fs.writeText`` action writes.
  for arg in action.call.arguments:
    if arg.name == "text":
      return arg.encodedValue
  ""

proc actionsOf(fragment: GraphFragment): seq[BuildActionDef] =
  for node in fragment.nodes:
    if node.kind == gnkAction:
      result.add(decodeBuildActionPayload(toBytes(node.payload)))

suite "go convention: Go's own path.Match and embed resolution":

  test "goPathMatch agrees with Go's path.Match test table":
    # The vectors are Go's own ``src/path/match_test.go`` (matchTests).
    const matches = [
      ("abc", "abc", true), ("*", "abc", true), ("*c", "abc", true),
      ("a*", "a", true), ("a*", "abc", true), ("a*", "ab/c", false),
      ("a*/b", "abc/b", true), ("a*/b", "a/c/b", false),
      ("a*b*c*d*e*/f", "axbxcxdxe/f", true),
      ("a*b*c*d*e*/f", "axbxcxdxexxx/f", true),
      ("a*b*c*d*e*/f", "axbxcxdxe/xxx/f", false),
      ("a*b*c*d*e*/f", "axbxcxdxexxx/fff", false),
      ("a*b?c*x", "abxbbxdbxebxczzx", true),
      ("a*b?c*x", "abxbbxdbxebxczzy", false),
      ("ab[c]", "abc", true), ("ab[b-d]", "abc", true),
      ("ab[e-g]", "abc", false), ("ab[^c]", "abc", false),
      ("ab[^b-d]", "abc", false), ("ab[^e-g]", "abc", true),
      ("a\\*b", "a*b", true), ("a\\*b", "ab", false),
      ("a?b", "a\u263Ab", true), ("a[^a]b", "a\u263Ab", true),
      ("a???b", "a\u263Ab", false), ("a[^a][^a][^a]b", "a\u263Ab", false),
      ("[a-\u03B6]*", "\u03B1", true), ("*[a-\u03B6]", "A", false),
      ("a?b", "a/b", false), ("a*b", "a/b", false),
      ("[\\]a]", "]", true), ("[\\-]", "-", true),
      ("[x\\-]", "x", true), ("[x\\-]", "-", true), ("[x\\-]", "z", false),
      ("[\\-x]", "x", true), ("[\\-x]", "-", true), ("[\\-x]", "a", false),
      ("*x", "xxx", true)]
    for (pattern, name, expected) in matches:
      checkpoint(pattern & " ~ " & name)
      check goPathMatch(pattern, name) == expected
    const bad = [("[]a]", "]"), ("[-]", "-"), ("[x-]", "x"), ("[x-]", "-"),
      ("[x-]", "z"), ("[-x]", "x"), ("[-x]", "-"), ("[-x]", "a"),
      ("\\", "a"), ("[a-b-c]", "a"), ("[", "a"), ("[^", "a"),
      ("[^bc", "a"), ("a[", "a"), ("a[", "ab"), ("a[", "x"), ("a/b[", "x")]
    for (pattern, name) in bad:
      checkpoint("bad pattern " & pattern & " ~ " & name)
      expect GoBadPattern:
        discard goPathMatch(pattern, name)

  test "embedFilesOfPattern applies cmd/go's directory-walk exclusions":
    let files = @["static/a.txt", "static/sub/b.txt", "static/.h.txt",
      "static/_u.txt", "static/sub/.s.txt", "other/c.txt", "static/.git/x"]
    # A directory pattern drops dot- and underscore-prefixed names below the
    # matched directory, and VCS directories always.
    check embedFilesOfPattern("static", files) ==
      @["static/a.txt", "static/sub/b.txt"]
    # ``all:`` keeps the hidden names, but never a VCS directory.
    check embedFilesOfPattern("all:static", files) == @["static/.h.txt",
      "static/_u.txt", "static/a.txt", "static/sub/.s.txt", "static/sub/b.txt"]
    # A glob naming a hidden file directly embeds it.
    check embedFilesOfPattern("static/.h.txt", files) == @["static/.h.txt"]
    check embedFilesOfPattern("static/*.txt", files) ==
      @["static/.h.txt", "static/_u.txt", "static/a.txt"]
    # A glob matching a directory embeds its tree, element by element.
    check embedFilesOfPattern("s*/sub", files) == @["static/sub/b.txt"]
    check embedFilesOfPattern("nomatch", files).len == 0

  test "goLanguageVersion agrees with cmd/go's gover.Lang":
    # The vectors are ``gover.Lang``'s (src/cmd/go/internal/gover): a ``go``
    # directive may name a patch release or a pre-release, and ``-lang``
    # takes only the language version.
    for (version, lang) in [("1.22", "1.22"), ("1.22.3", "1.22"),
        ("1.23.0", "1.23"), ("1.21rc1", "1.21"), ("1.16", "1.16"),
        ("1", "1"), ("1.0", "1"), ("1.0.0", "1"), ("2.1.4", "2.1")]:
      checkpoint(version)
      check go_convention.goLanguageVersion(version) == lang
    for bad in ["", "x1.22", "1.", "1-22"]:
      checkpoint("bad version " & bad.escape())
      expect ValueError:
        discard go_convention.goLanguageVersion(bad)

  test "renderEmbedcfg refuses a pattern that matches none of EmbedFiles":
    expect ValueError:
      discard renderEmbedcfg("/pkg", ["static"], ["other/c.txt"])

suite "go convention M5 + M14":

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

  test "recognize: positive — go.work workspace root without a go.mod":
    # Spec-driven change, not a weakening: this case used to assert that a
    # ``go.work`` made recognition FAIL ("workspaces deferred"). Go.md
    # §"Recognition" 1 and §"Workspace and module mode" (amended
    # 2026-11-16, reprobuild-pm issue
    # 2026-11-12-go-import-and-embed-resolution-is-hand-approximated-and-wrong)
    # now make a ``go.work`` root a workspace-mode project, so the case
    # asserts the opposite — and with no root ``go.mod`` at all, the shape
    # the old rule could not have accepted.
    let scratch = getTempDir() / "test_go_convention_go_work"
    if dirExists(scratch):
      removeDir(scratch)
    writeWorkspaceFixture(scratch)
    defer:
      removeDir(scratch)
    let conv = go_convention.goConvention()
    let request = dummyRequest(scratch)
    if not goToolchainAvailable():
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

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
      skip("go not on PATH")
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

  # --- M14: cmd/<name>/main.go layout ----------------------------------

  test "recognize: positive — cmd/<name>/main.go multi-binary fixture":
    let conv = go_convention.goConvention()
    if not fileExists(MultiBinaryFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & MultiBinaryFixtureRoot
      fail()
    let request = dummyRequest(MultiBinaryFixtureRoot)
    if not goToolchainAvailable():
      check not conv.recognize(MultiBinaryFixtureRoot, request)
    else:
      check conv.recognize(MultiBinaryFixtureRoot, request)

  test "emitFragment: multi-binary fixture produces one link per cmd":
    if not goToolchainAvailable():
      skip("go not on PATH")
    else:
      let conv = go_convention.goConvention()
      let request = dummyRequest(MultiBinaryFixtureRoot)
      require conv.recognize(MultiBinaryFixtureRoot, request)
      let fragment = conv.emitFragment(MultiBinaryFixtureRoot, request)
      var linkActions: seq[BuildActionDef] = @[]
      var compileActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("go-link-"):
          linkActions.add(action)
        elif action.id.startsWith("go-compile-"):
          compileActions.add(action)
      # Two main packages (alpha, beta) → exactly two link actions.
      check linkActions.len == 2
      # Two project packages → at least two compile actions.
      check compileActions.len >= 2
      # Each link action's output basename should match one of the
      # binaries declared in the fixture's ``cmd/<name>/`` layout.
      var sawAlpha = false
      var sawBeta = false
      for action in linkActions:
        check action.outputs.len == 1
        let outName = extractFilename(action.outputs[0])
        let stem = outName.toLowerAscii
        if stem.startsWith("alpha"):
          sawAlpha = true
        elif stem.startsWith("beta"):
          sawBeta = true
        let argv = inlineArgvOf(action)
        check "tool" in argv
        check "link" in argv
        check "-buildmode=exe" in argv
      check sawAlpha
      check sawBeta

  # --- M14: library-only module ----------------------------------------

  test "recognize: positive — library-only fixture":
    let conv = go_convention.goConvention()
    if not fileExists(LibraryFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & LibraryFixtureRoot
      fail()
    let request = dummyRequest(LibraryFixtureRoot)
    if not goToolchainAvailable():
      check not conv.recognize(LibraryFixtureRoot, request)
    else:
      check conv.recognize(LibraryFixtureRoot, request)

  test "emitFragment: library-only fixture emits no link actions":
    if not goToolchainAvailable():
      skip("go not on PATH")
    else:
      let conv = go_convention.goConvention()
      let request = dummyRequest(LibraryFixtureRoot)
      require conv.recognize(LibraryFixtureRoot, request)
      let fragment = conv.emitFragment(LibraryFixtureRoot, request)
      var compileActions: seq[BuildActionDef] = @[]
      var linkActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("go-compile-"):
          compileActions.add(action)
        elif action.id.startsWith("go-link-"):
          linkActions.add(action)
      # At least one compile action (the library package).
      check compileActions.len >= 1
      # Library-only modules emit no link actions and no link-importcfg
      # actions — the umbrella ``default`` target builds every package's
      # ``.a`` archive and stops there.
      check linkActions.len == 0
      # The compile output should be an ``.a`` archive under the
      # convention's scratch ``pkg/`` directory.
      var sawArchiveOutput = false
      for action in compileActions:
        for outPath in action.outputs:
          if outPath.endsWith(".a"):
            sawArchiveOutput = true
            break
        if sawArchiveOutput:
          break
      check sawArchiveOutput

  # --- M22: per-package test discovery -------------------------------------

  test "recognize: positive — library-with-tests fixture":
    let conv = go_convention.goConvention()
    if not fileExists(LibraryWithTestsFixtureRoot / "reprobuild.nim"):
      checkpoint "fixture missing — looked at " & LibraryWithTestsFixtureRoot
      fail()
    let request = dummyRequest(LibraryWithTestsFixtureRoot)
    if not goToolchainAvailable():
      check not conv.recognize(LibraryWithTestsFixtureRoot, request)
    else:
      check conv.recognize(LibraryWithTestsFixtureRoot, request)

  test "emitFragment M22: library-with-tests emits a non-default test target":
    # The library-with-tests fixture ships a single package with both
    # ``greet.go`` and ``greet_test.go``. The Go convention's M22
    # surface walks ``go list``'s ``TestGoFiles`` array and emits one
    # ``go test -count=1 <importPath>`` action per test-bearing
    # package, paired with an ``fs.stamp`` companion. Default target
    # stays compile-only; tests opt in via ``repro build .#test``.
    if not goToolchainAvailable():
      skip("go not on PATH")
    else:
      let conv = go_convention.goConvention()
      let request = dummyRequest(LibraryWithTestsFixtureRoot)
      require conv.recognize(LibraryWithTestsFixtureRoot, request)
      let fragment = conv.emitFragment(LibraryWithTestsFixtureRoot, request)

      var testRunActions: seq[BuildActionDef] = @[]
      var testStampActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("go-test-run-"):
          testRunActions.add(action)
        elif action.id.startsWith("go-test-stamp-"):
          testStampActions.add(action)

      check testRunActions.len == 1
      check testStampActions.len == 1
      let runAction = testRunActions[0]
      let runArgv = inlineArgvOf(runAction)
      # ``go test -count=1 <importPath>`` — three positional args
      # past argv[0] (the go driver). ``-count=1`` is the official knob
      # that disables go's per-process test cache (we want reprobuild's
      # action cache to be the source of truth).
      check runArgv.len >= 4
      check "test" in runArgv
      check "-count=1" in runArgv
      var sawImportPath = false
      for arg in runArgv:
        if arg == "example.com/go-library-with-tests-example":
          sawImportPath = true
          break
      check sawImportPath
      check runAction.outputs.len == 0
      check runAction.pool == "compile"

      # Stamp action: depends on the run; output ends in .stamp under
      # the convention's ``<scratch>/<entry>/tests/`` directory.
      let stampAction = testStampActions[0]
      check runAction.id in stampAction.deps
      check stampAction.outputs.len == 1
      let stampPath = stampAction.outputs[0].replace('\\', '/')
      check stampPath.endsWith(".stamp")
      check "/tests/" in stampPath

  test "emitFragment M22: go/library (no tests) emits no test actions":
    # Inverse cohort: the go/library fixture has no ``*_test.go`` files
    # so the convention must not emit any ``go-test-*`` actions.
    if not goToolchainAvailable():
      skip("go not on PATH")
    else:
      let conv = go_convention.goConvention()
      let request = dummyRequest(LibraryFixtureRoot)
      require conv.recognize(LibraryFixtureRoot, request)
      let fragment = conv.emitFragment(LibraryFixtureRoot, request)
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        check not action.id.startsWith("go-test-run-")
        check not action.id.startsWith("go-test-stamp-")

  # --- Go.md §"The embedcfg file" / §"Workspace and module mode" -----------

  test "emitFragment: embedcfg matches the document go build -n writes":
    if not goToolchainAvailable():
      skip("go not on PATH")
    else:
      let scratch = getTempDir() / "test_go_convention_embedcfg"
      if dirExists(scratch):
        removeDir(scratch)
      writeMinimalFixture(scratch, mainGo = "package main\n\n" &
        "import (\n\t\"embed\"\n\t\"fmt\"\n)\n\n" &
        "//go:embed static\nvar dirFS embed.FS\n\n" &
        "//go:embed static/a.txt\nvar single string\n\n" &
        "//go:embed all:static/sub\nvar allFS embed.FS\n\n" &
        "func main() { fmt.Println(single, dirFS, allFS) }\n",
        modulePath = "example.com/embedcfg")
      for (rel, text) in [("static/a.txt", "a\n"), ("static/.h.txt", "h\n"),
          ("static/_u.txt", "u\n"), ("static/sub/b.txt", "b\n"),
          ("static/sub/.s.txt", "s\n")]:
        createDir((scratch / rel).parentDir)
        writeFile(scratch / rel, text)
      defer:
        removeDir(scratch)
      let conv = go_convention.goConvention()
      let request = dummyRequest(scratch)
      require conv.recognize(scratch, request)
      let fragment = conv.emitFragment(scratch, request)
      var embedcfgText = ""
      var compileArgv: seq[string] = @[]
      for action in actionsOf(fragment):
        if action.id.startsWith("go-embedcfg-"):
          embedcfgText = writeTextOf(action)
        elif action.id.startsWith("go-compile-"):
          compileArgv = inlineArgvOf(action)
      checkpoint("embedcfg: " & embedcfgText)
      require embedcfgText.len > 0
      # The compile is handed the document.
      check "-embedcfg" in compileArgv
      # Go's own document for the same package, from ``go build -n``.
      # ``-a``: the convention's ``go list -export`` has just put this package
      # in GOCACHE, and without it ``-n`` would print only the link.
      let (dryRun, code) = execCmdEx(quoteShell(findExe("go")) &
        " build -a -n .", options = {poUsePath, poStdErrToStdOut},
        workingDir = scratch)
      checkpoint("go build -n: " & dryRun)
      require code == 0
      # The only package of the build with //go:embed is the main one, so the
      # one embedcfg heredoc in the plan is its.
      let marker = dryRun.find("embedcfg << 'EOF'")
      require marker >= 0
      let openIdx = dryRun.find('{', marker)
      let closeIdx = dryRun.find("EOF", openIdx)
      require openIdx >= 0 and closeIdx > openIdx
      let goDoc = parseJson(dryRun[openIdx ..< closeIdx])
      check parseJson(embedcfgText) == goDoc
      # The listing's reads key the fragment (Go.md §"Implicit-dependency
      # capture", item 3) — where the monitor can observe ``go``. A
      # statically linked ``go`` (every go.dev/nixpkgs build on Linux) cannot
      # be entered by the preload monitor, and then the fragment must carry
      # the never-matching ``unobserved`` input instead, so it is re-derived
      # on every refresh.
      var sawGoMod = false
      var sawStaticDir = false
      var sawUnobserved = false
      for input in fragment.evaluationInputs:
        if input.kind == gevFileRead and
            input.digest == UnobservedEvaluationDigest:
          sawUnobserved = true
        elif input.kind == gevFileRead and
            sameFile(input.identity, scratch / "go.mod"):
          sawGoMod = true
        if input.kind == gevDirectoryEnumeration and
            input.identity.endsWith(DirSep & "static"):
          sawStaticDir = true
      if staticElfWithoutInterpreter(findExe("go")):
        checkpoint("go is a static ELF: the capture must be graded incomplete")
        check sawUnobserved
      else:
        check not sawUnobserved
        check sawGoMod
        check sawStaticDir

  test "emitFragment: a workspace compiles each package at its module's go version":
    if not goToolchainAvailable():
      skip("go not on PATH")
    else:
      let scratch = getTempDir() / "test_go_convention_work_lang"
      if dirExists(scratch):
        removeDir(scratch)
      writeWorkspaceFixture(scratch)
      defer:
        removeDir(scratch)
      let conv = go_convention.goConvention()
      let request = dummyRequest(scratch)
      require conv.recognize(scratch, request)
      let fragment = conv.emitFragment(scratch, request)
      var langOf: seq[(string, string)] = @[]
      for action in actionsOf(fragment):
        if not action.id.startsWith("go-compile-"):
          continue
        var lang = ""
        for arg in inlineArgvOf(action):
          if arg.startsWith("-lang="):
            lang = arg
        langOf.add((action.id, lang))
      checkpoint($langOf)
      var sawLib, sawApi = false
      for (id, lang) in langOf:
        if "example.com__lib" in id:
          sawLib = true
          check lang == "-lang=go1.23"
        elif "example.com__api" in id:
          sawApi = true
          check lang == "-lang=go1.22"
      check sawLib
      check sawApi

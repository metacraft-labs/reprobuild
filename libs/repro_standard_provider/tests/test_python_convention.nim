## M15 verification: Python language convention.
##
## Tests against the in-tree fixtures under
## ``reprobuild-examples/python/``:
##
##   * ``python/library-pure``   — hatchling, ``library`` member only
##   * ``python/console-script`` — hatchling, ``executable`` member with
##                                  ``[project.scripts]`` entry point
##
## Negative recognise cases are materialised as tiny scratch projects
## under the test's temp directory so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for:
##     - the canonical ``library-pure`` fixture (hatchling library)
##     - the ``console-script`` fixture (hatchling + ``[project.scripts]``
##       + ``executable`` member)
##   * ``recognize`` returns false when:
##     - ``pyproject.toml`` is absent
##     - ``[build-system].build-backend`` is ``maturin`` (out-of-scope
##       backend that should route to Mode B in a future M)
##     - ``uses:`` doesn't list ``python3``/``python``
##     - no library or executable member is declared
##   * ``emitFragment`` against the ``library-pure`` fixture (skipped
##     cleanly when ``python3`` isn't on PATH):
##     - at least one ``python-build-wheel-*`` action exists
##     - the action's argv has ``python3``/``python`` as argv[0]
##     - the action declares at least one ``.whl`` output

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/python as python_convention

const
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_python_convention.nim``
  ## lands at the ``reprobuild/`` repo root. The fixture lives in the
  ## sibling ``reprobuild-examples`` checkout under ``D:/metacraft/``,
  ## so take one more parent.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  LibraryFixture =
    MetacraftRoot / "reprobuild-examples" / "python" / "library-pure"
  ConsoleScriptFixture =
    MetacraftRoot / "reprobuild-examples" / "python" / "console-script"

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

proc pythonOnPath(): bool =
  ## True when either ``python3`` or ``python`` resolves. The convention's
  ## ``recognize`` short-circuits to ``false`` when neither resolves, so
  ## the emit-fragment tests skip cleanly in environments without Python.
  findExe("python3").len > 0 or findExe("python").len > 0

suite "python convention M15":

  test "recognize: positive — library-pure fixture":
    let conv = python_convention.pythonConvention()
    check conv.name == "python"
    if not fileExists(LibraryFixture / "pyproject.toml"):
      checkpoint "fixture missing — looked at " & LibraryFixture
      fail()
    let request = dummyRequest(LibraryFixture)
    if not pythonOnPath():
      checkpoint "python not on PATH — positive recognize will return false"
      check not conv.recognize(LibraryFixture, request)
    else:
      check conv.recognize(LibraryFixture, request)

  test "recognize: positive — console-script fixture":
    let conv = python_convention.pythonConvention()
    if not fileExists(ConsoleScriptFixture / "pyproject.toml"):
      checkpoint "fixture missing — looked at " & ConsoleScriptFixture
      fail()
    let request = dummyRequest(ConsoleScriptFixture)
    if not pythonOnPath():
      check not conv.recognize(ConsoleScriptFixture, request)
    else:
      check conv.recognize(ConsoleScriptFixture, request)

  test "recognize: negative — pyproject.toml missing":
    let scratch = getTempDir() / "test_python_convention_no_pyproject"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakePythonExample:\n" &
      "  uses:\n" &
      "    \"python3 >=3.11\"\n" &
      "\n" &
      "  library fake_lib\n")
    defer:
      removeDir(scratch)
    let conv = python_convention.pythonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — maturin backend (unsupported)":
    let scratch = getTempDir() / "test_python_convention_maturin"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "pyproject.toml",
      "[project]\n" &
      "name = \"fake-maturin\"\n" &
      "version = \"0.1.0\"\n" &
      "\n" &
      "[build-system]\n" &
      "requires = [\"maturin\"]\n" &
      "build-backend = \"maturin\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMaturin:\n" &
      "  uses:\n" &
      "    \"python3 >=3.11\"\n" &
      "\n" &
      "  library fake_maturin\n")
    defer:
      removeDir(scratch)
    let conv = python_convention.pythonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks python":
    let scratch = getTempDir() / "test_python_convention_rust_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "pyproject.toml",
      "[project]\n" &
      "name = \"fake-rusty\"\n" &
      "version = \"0.1.0\"\n" &
      "\n" &
      "[build-system]\n" &
      "requires = [\"hatchling\"]\n" &
      "build-backend = \"hatchling.build\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRustyPython:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  library fake_rusty\n")
    defer:
      removeDir(scratch)
    let conv = python_convention.pythonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_python_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "pyproject.toml",
      "[project]\n" &
      "name = \"empty-pkg\"\n" &
      "version = \"0.1.0\"\n" &
      "\n" &
      "[build-system]\n" &
      "requires = [\"hatchling\"]\n" &
      "build-backend = \"hatchling.build\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package emptyPkg:\n" &
      "  uses:\n" &
      "    \"python3 >=3.11\"\n")
    defer:
      removeDir(scratch)
    let conv = python_convention.pythonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: library-pure produces a wheel-build action":
    if not pythonOnPath():
      skip()
    else:
      let conv = python_convention.pythonConvention()
      let request = dummyRequest(LibraryFixture)
      require conv.recognize(LibraryFixture, request)
      let fragment = conv.emitFragment(LibraryFixture, request)

      var wheelActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("python-build-wheel-"):
          wheelActions.add(action)

      # Exactly one wheel-build action (one library member).
      check wheelActions.len == 1
      let wheel = wheelActions[0]
      let argv = inlineArgvOf(wheel)
      check argv.len >= 2
      let arg0Base = extractFilename(argv[0]).toLowerAscii
      check arg0Base.startsWith("python3") or arg0Base.startsWith("python")
      check wheel.pool == "compile"

      # The action declares at least one ``.whl`` output, located under
      # the convention's ``<scratch>/<member>/dist/`` directory.
      var sawWheel = false
      for outPath in wheel.outputs:
        if outPath.toLowerAscii.endsWith(".whl"):
          sawWheel = true
          # The wheel must land under the convention's scratch dir, not
          # in the project root or somewhere outside ``.repro/build/``.
          check ".repro" in outPath.replace('\\', '/')
          check "/dist/" in outPath.replace('\\', '/')
      check sawWheel

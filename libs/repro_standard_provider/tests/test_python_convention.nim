## M15 + M20 verification: Python language convention.
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
## Coverage (M15):
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
##
## Coverage (M20 — A1/A4/A5 graduations):
##   * ``emitFragment`` library-pure also produces:
##     - one ``python-byte-compile-*`` action per ``.py`` under ``src/``
##     - one ``python-build-sdist-*`` action (parallel to the wheel)
##     - NO ``python-install-wheel-*`` action (no ``[project.scripts]``)
##   * ``emitFragment`` console-script additionally produces:
##     - one ``python-install-wheel-*`` action whose argv carries the
##       monkey-patched installer hook script, outputs declare the per-
##       entry ``Scripts/<name>.exe`` (Windows) launcher path, and
##       ``deps`` references the corresponding wheel-build action.

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

  test "emitFragment M20: library-pure emits byte-compile + sdist actions, no installer":
    if not pythonOnPath():
      skip()
    else:
      let conv = python_convention.pythonConvention()
      let request = dummyRequest(LibraryFixture)
      require conv.recognize(LibraryFixture, request)
      let fragment = conv.emitFragment(LibraryFixture, request)

      var byteCompiles: seq[BuildActionDef] = @[]
      var sdists: seq[BuildActionDef] = @[]
      var installers: seq[BuildActionDef] = @[]
      var wheels: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("python-byte-compile-"):
          byteCompiles.add(action)
        elif action.id.startsWith("python-build-wheel-"):
          wheels.add(action)
        elif action.id.startsWith("python-build-sdist-"):
          sdists.add(action)
        elif action.id.startsWith("python-install-wheel-"):
          installers.add(action)

      # The library-pure fixture ships exactly one ``.py`` under ``src/``
      # (``python_library_example/__init__.py``). M20 A1 emits one
      # ``python-byte-compile-*`` action per ``.py`` source.
      check byteCompiles.len == 1
      let byteCompile = byteCompiles[0]
      let bcArgv = inlineArgvOf(byteCompile)
      # Argv shape: ``python3 -m compileall -b -q -f <src>``.
      check bcArgv.len >= 5
      check bcArgv[1] == "-m"
      check bcArgv[2] == "compileall"
      check "-b" in bcArgv
      check "-f" in bcArgv
      # Output is the adjacent ``.pyc`` file (one entry, ``<src.py>c``).
      check byteCompile.outputs.len == 1
      check byteCompile.outputs[0].toLowerAscii.endsWith(".pyc")
      # Input is the source ``.py`` file (the byte-compile action carries
      # exactly its source — the cache fingerprint then invalidates only
      # when this file changes).
      check byteCompile.inputs.len == 1
      check byteCompile.inputs[0].toLowerAscii.endsWith(".py")
      check byteCompile.pool == "compile"

      # M20 A4: one ``python-build-sdist-*`` action per member. The
      # library-pure fixture has a single library member, so exactly one
      # sdist action. The sdist action's output is the predicted
      # ``<dist>-<ver>.tar.gz`` under the same ``<scratch>/<member>/dist/``
      # directory as the wheel.
      check sdists.len == 1
      let sdist = sdists[0]
      var sawSdist = false
      for outPath in sdist.outputs:
        if outPath.toLowerAscii.endsWith(".tar.gz"):
          sawSdist = true
          check ".repro" in outPath.replace('\\', '/')
          check "/dist/" in outPath.replace('\\', '/')
      check sawSdist
      check sdist.pool == "compile"

      # M20 A5: library-pure has NO ``[project.scripts]`` so the installer
      # sub-graph stays silent. (Library members are excluded from
      # installer emission regardless of the project's [project.scripts]
      # table.)
      check installers.len == 0

      # The wheel-build action depends on every byte-compile action via
      # ``deps`` so the engine orders them before the wheel.
      check wheels.len == 1
      for bc in byteCompiles:
        check bc.id in wheels[0].deps

  test "emitFragment M20: console-script emits installer action with shim outputs":
    if not pythonOnPath():
      skip()
    else:
      let conv = python_convention.pythonConvention()
      let request = dummyRequest(ConsoleScriptFixture)
      require conv.recognize(ConsoleScriptFixture, request)
      let fragment = conv.emitFragment(ConsoleScriptFixture, request)

      var byteCompiles: seq[BuildActionDef] = @[]
      var wheels: seq[BuildActionDef] = @[]
      var sdists: seq[BuildActionDef] = @[]
      var installers: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("python-byte-compile-"):
          byteCompiles.add(action)
        elif action.id.startsWith("python-build-wheel-"):
          wheels.add(action)
        elif action.id.startsWith("python-build-sdist-"):
          sdists.add(action)
        elif action.id.startsWith("python-install-wheel-"):
          installers.add(action)

      # console-script ships two ``.py`` files under ``src/`` —
      # ``python_console_script/__init__.py`` and ``cli.py``.
      check byteCompiles.len == 2
      check wheels.len == 1
      check sdists.len == 1
      # M20 A5: the executable member with ``[project.scripts]`` triggers
      # the installer sub-graph — exactly one ``python-install-wheel-*``
      # action whose outputs include the launcher path.
      check installers.len == 1
      let installer = installers[0]
      check installer.deps.len >= 1
      check wheels[0].id in installer.deps
      # The installer action's argv runs ``python3 <install_wheel.py>``.
      let instArgv = inlineArgvOf(installer)
      check instArgv.len == 2
      let arg0Base = extractFilename(instArgv[0]).toLowerAscii
      check arg0Base.startsWith("python3") or arg0Base.startsWith("python")
      # The launcher output path includes the platform's subdir
      # (Scripts/ on Windows, bin/ on POSIX) and the script name from
      # ``[project.scripts]``.
      var sawLauncher = false
      for outPath in installer.outputs:
        let normalised = outPath.replace('\\', '/')
        if "python-console-script" in normalised:
          sawLauncher = true
          when defined(windows):
            check "/Scripts/" in normalised
            check normalised.toLowerAscii.endsWith(".exe")
          else:
            check "/bin/" in normalised
      check sawLauncher

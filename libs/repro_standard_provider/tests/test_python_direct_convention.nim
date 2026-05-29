## Verification for the python-direct (Mode 3) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/python-mode3/binary-with-library`` plus a
## small set of scratch-directory negative cases.
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture (no
##     pyproject.toml, python on PATH).
##   * ``recognize`` returns false when a pyproject.toml is present
##     (the Mode 2 ``python`` convention's territory).
##   * ``recognize`` returns false when the ``uses:`` block lacks
##     ``python3`` / ``python``.
##   * ``recognize`` returns false when a setup.py is present (legacy
##     setuptools — also Mode 2 territory).
##   * ``emitFragment`` against the Mode 3 fixture:
##     - per-member stage actions for both ``mathlib`` (library) and
##       ``calc`` (executable);
##     - per-member byte-compile actions sequenced after stage;
##     - calc's wrapper-emit action carries mathlib's staging dir on
##       PYTHONPATH (via the wrapper script content);
##     - calc's wrapper-emit deps include mathlib's byte-compile
##       action id (sequencing).
##   * cycle detection: a scratch fixture with ``depends_on a: b``
##     AND ``depends_on b: a`` rejects emitFragment with ValueError.
##   * undeclared-dep detection: a scratch fixture with
##     ``depends_on a: c`` (where ``c`` is not a declared package)
##     rejects with ValueError.
##   * executable missing ``__main__.py``: rejects with ValueError.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/python_direct as python_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "python-mode3" /
      "binary-with-library"

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
  ## True when either ``python3`` or ``python`` resolves. The
  ## convention's ``recognize`` short-circuits to ``false`` when
  ## neither resolves, so the emit-fragment tests skip cleanly in
  ## environments without Python.
  findExe("python3").len > 0 or findExe("python").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-python-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "python-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no pyproject.toml, python available)":
    if not pythonOnPath():
      skip()
    else:
      let conv = python_direct_convention.pythonDirectConvention()
      check conv.name == "python-direct"
      if not fileExists(Mode3Fixture / "repro.nim"):
        checkpoint "fixture missing — looked at " & Mode3Fixture
        fail()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — pyproject.toml at the project root":
    let dir = makeScratch("with-pyproject")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "python3"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "hello")
    writeFile(dir / "hello" / "hello" / "__init__.py", "")
    writeFile(dir / "hello" / "hello" / "__main__.py",
      "print('hi')\n")
    writeFile(dir / "pyproject.toml", """
[project]
name = "x"
version = "0.0.1"
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
""")
    let conv = python_direct_convention.pythonDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks python3/python":
    let dir = makeScratch("no-python-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "hello")
    writeFile(dir / "hello" / "hello" / "__init__.py", "")
    writeFile(dir / "hello" / "hello" / "__main__.py",
      "print('hi')\n")
    let conv = python_direct_convention.pythonDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — setup.py at the project root":
    let dir = makeScratch("with-setup-py")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "python3"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "hello")
    writeFile(dir / "hello" / "hello" / "__init__.py", "")
    writeFile(dir / "hello" / "hello" / "__main__.py",
      "print('hi')\n")
    writeFile(dir / "setup.py", "from setuptools import setup\nsetup()\n")
    let conv = python_direct_convention.pythonDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

suite "python-direct convention emit (Mode 3 fixture)":

  test "emitFragment: produces per-member stage + byte-compile + wrapper":
    if not pythonOnPath():
      skip()
    else:
      let conv = python_direct_convention.pythonDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var stageActions: seq[BuildActionDef] = @[]
      var byteCompileActions: seq[BuildActionDef] = @[]
      var wrapperActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("python-direct-stage-"):
          stageActions.add(action)
        elif action.id.startsWith("python-direct-bytecompile-"):
          byteCompileActions.add(action)
        elif action.id.startsWith("python-direct-wrapper-"):
          wrapperActions.add(action)

      check stageActions.len == 2  # mathlib + calc
      check byteCompileActions.len == 2  # mathlib + calc
      check wrapperActions.len == 1  # calc only

      var mathlibByteCompile: BuildActionDef
      var calcByteCompile: BuildActionDef
      var sawMathlibByte = false
      var sawCalcByte = false
      for action in byteCompileActions:
        if action.id == "python-direct-bytecompile-mathlib":
          mathlibByteCompile = action
          sawMathlibByte = true
        elif action.id == "python-direct-bytecompile-calc":
          calcByteCompile = action
          sawCalcByte = true
      check sawMathlibByte
      check sawCalcByte

      let calcWrapper = wrapperActions[0]
      check calcWrapper.id == "python-direct-wrapper-calc"

      # The wrapper-emit action's deps should include mathlib's
      # byte-compile action id so the wrapper sequences after the
      # upstream's staged tree is populated.
      var sawMathlibDepInWrapper = false
      for dep in calcWrapper.deps:
        if dep == mathlibByteCompile.id:
          sawMathlibDepInWrapper = true
      check sawMathlibDepInWrapper

      # The wrapper-emit action's argv encodes the wrapper text via
      # fs.writeText — check the encoded text contains the mathlib
      # staging dir on the PYTHONPATH line.
      var sawMathlibStagingInWrapper = false
      for arg in calcWrapper.call.arguments:
        if arg.name == "text":
          if "mathlib" in arg.encodedValue and
              "PYTHONPATH" in arg.encodedValue:
            sawMathlibStagingInWrapper = true
      check sawMathlibStagingInWrapper

      # The wrapper's outputs declare the wrapper file under the
      # scratch dir.
      var sawWrapperOutput = false
      for outPath in calcWrapper.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        when defined(windows):
          if lower.endsWith("/.repro/build/calc/calc.cmd"):
            sawWrapperOutput = true
        else:
          if lower.endsWith("/.repro/build/calc/calc"):
            sawWrapperOutput = true
      check sawWrapperOutput

suite "python-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not pythonOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "python3"
  library alpha

package betaPkg:
  uses:
    "python3"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "alpha")
      writeFile(dir / "alpha" / "alpha" / "__init__.py",
        "def alpha_fn():\n    return 1\n")
      createDir(dir / "beta" / "beta")
      writeFile(dir / "beta" / "beta" / "__init__.py",
        "def beta_fn():\n    return 2\n")
      let conv = python_direct_convention.pythonDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not pythonOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "python3"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "hello" / "hello")
      writeFile(dir / "hello" / "hello" / "__init__.py", "")
      writeFile(dir / "hello" / "hello" / "__main__.py",
        "print('hi')\n")
      let conv = python_direct_convention.pythonDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "executable missing __main__.py is rejected with a clear ValueError":
    if not pythonOnPath():
      skip()
    else:
      let dir = makeScratch("no-main")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "python3"
  executable hello:
    discard
""")
      createDir(dir / "hello" / "hello")
      writeFile(dir / "hello" / "hello" / "__init__.py",
        "# package marker but no __main__.py\n")
      let conv = python_direct_convention.pythonDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# Layout recognition. Pins the convention's behaviour for the canonical
# Mode 3 Python layouts.
# ---------------------------------------------------------------------------

suite "python-direct convention layout recognition":

  test "layout B-flat: multi-package workspace with per-member <pkg>/<pkg>/__init__.py":
    if not pythonOnPath():
      skip()
    else:
      let dir = makeScratch("layout-b-flat-recognise")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package libPkg:
  uses:
    "python3"
  library mylib

package binPkg:
  uses:
    "python3"
  executable mybin:
    discard
""")
      createDir(dir / "mylib" / "mylib")
      writeFile(dir / "mylib" / "mylib" / "__init__.py",
        "def helper():\n    return 42\n")
      createDir(dir / "mybin" / "mybin")
      writeFile(dir / "mybin" / "mybin" / "__init__.py", "")
      writeFile(dir / "mybin" / "mybin" / "__main__.py",
        "print('hi')\n")
      let conv = python_direct_convention.pythonDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

  test "layout A: single-member workspace with src/<pkg>/__init__.py at root":
    if not pythonOnPath():
      skip()
    else:
      let dir = makeScratch("layout-a-bin")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package soloPkg:
  uses:
    "python3"
  executable solo:
    discard
""")
      createDir(dir / "src" / "solo")
      writeFile(dir / "src" / "solo" / "__init__.py", "")
      writeFile(dir / "src" / "solo" / "__main__.py",
        "print('hi')\n")
      let conv = python_direct_convention.pythonDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

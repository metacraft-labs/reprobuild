## Verification for the jsts-direct (Mode 3 JS/TS) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/jsts-mode3/binary-with-library`` plus a
## small set of scratch-directory negative cases.
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture (no
##     package.json / tsconfig.json / bundler config, node on PATH).
##   * ``recognize`` returns false when a package.json is present
##     (the Mode 2 ``javascript-typescript`` convention's territory).
##   * ``recognize`` returns false when a tsconfig.json is present.
##   * ``recognize`` returns false when a vite.config.* / webpack.config.*
##     is present.
##   * ``recognize`` returns false when the ``uses:`` block lacks
##     ``node`` / ``typescript``.
##   * ``emitFragment`` against the Mode 3 fixture:
##     - per-executable esbuild bundle action present;
##     - bundle action's argv carries ``--alias:mathlib=<src>`` for
##       the upstream library;
##     - bundle action's inputs list includes the mathlib source file
##       (so a change invalidates the cache);
##     - wrapper-emit action present with the bundle action id in deps
##       (sequencing).
##   * cycle detection: a scratch fixture with ``depends_on a: b``
##     AND ``depends_on b: a`` rejects emitFragment with ValueError.
##   * undeclared-dep detection: a scratch fixture with
##     ``depends_on a: c`` (where ``c`` is not a declared package)
##     rejects with ValueError.
##   * layout B-flat (per-member without ``src/``) is recognised.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/jsts_direct as jsts_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "jsts-mode3" /
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

proc nodeOnPath(): bool =
  ## True when ``node`` resolves. The convention's ``recognize``
  ## short-circuits to ``false`` when ``node`` is missing, so the
  ## emit-fragment tests skip cleanly in environments without it.
  findExe("node").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-jsts-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "jsts-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no package.json, node available)":
    if not nodeOnPath():
      skip()
    else:
      let conv = jsts_direct_convention.jsTsDirectConvention()
      check conv.name == "jsts-direct"
      if not fileExists(Mode3Fixture / "repro.nim"):
        checkpoint "fixture missing — looked at " & Mode3Fixture
        fail()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — package.json at the project root":
    let dir = makeScratch("with-package-json")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "typescript"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "src")
    writeFile(dir / "hello" / "src" / "main.ts", "console.log('hi');\n")
    writeFile(dir / "package.json", """{ "name": "x", "version": "0.0.1", "type": "module" }""")
    let conv = jsts_direct_convention.jsTsDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — tsconfig.json at the project root":
    let dir = makeScratch("with-tsconfig")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "typescript"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "src")
    writeFile(dir / "hello" / "src" / "main.ts", "console.log('hi');\n")
    writeFile(dir / "tsconfig.json", """{ "compilerOptions": {} }""")
    let conv = jsts_direct_convention.jsTsDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — vite.config.ts at the project root":
    let dir = makeScratch("with-vite-config")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "typescript"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "src")
    writeFile(dir / "hello" / "src" / "main.ts", "console.log('hi');\n")
    writeFile(dir / "vite.config.ts", "export default { };\n")
    let conv = jsts_direct_convention.jsTsDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — webpack.config.js at the project root":
    let dir = makeScratch("with-webpack-config")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "typescript"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "src")
    writeFile(dir / "hello" / "src" / "main.ts", "console.log('hi');\n")
    writeFile(dir / "webpack.config.js", "module.exports = {};\n")
    let conv = jsts_direct_convention.jsTsDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks node/typescript":
    let dir = makeScratch("no-jsts-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "src")
    writeFile(dir / "hello" / "src" / "main.ts", "console.log('hi');\n")
    let conv = jsts_direct_convention.jsTsDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

suite "jsts-direct convention emit (Mode 3 fixture)":

  test "emitFragment: produces per-executable bundle + wrapper":
    if not nodeOnPath():
      skip()
    else:
      let conv = jsts_direct_convention.jsTsDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var bundleActions: seq[BuildActionDef] = @[]
      var wrapperActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("jsts-direct-bundle-"):
          bundleActions.add(action)
        elif action.id.startsWith("jsts-direct-wrapper-"):
          wrapperActions.add(action)

      # Mode 3 JS/TS emits NO per-library action; only the
      # executable's bundle + wrapper.
      check bundleActions.len == 1  # calc only
      check wrapperActions.len == 1  # calc only

      let calcBundle = bundleActions[0]
      check calcBundle.id == "jsts-direct-bundle-calc"
      let calcWrapper = wrapperActions[0]
      check calcWrapper.id == "jsts-direct-wrapper-calc"

      # The wrapper-emit action's deps should include the calc bundle
      # action id so the wrapper sequences after the bundle output
      # exists.
      var sawBundleDepInWrapper = false
      for dep in calcWrapper.deps:
        if dep == calcBundle.id:
          sawBundleDepInWrapper = true
      check sawBundleDepInWrapper

      # The bundle action's argv must carry the --alias for mathlib
      # so the upstream library's bare import resolves at bundle time.
      let bundleArgv = inlineArgvOf(calcBundle)
      var sawMathlibAlias = false
      for arg in bundleArgv:
        if arg.startsWith("--alias:mathlib="):
          sawMathlibAlias = true
      check sawMathlibAlias

      # The bundle action's inputs must include the mathlib library's
      # source file so a change invalidates the cache.
      var sawMathlibInput = false
      for inputPath in calcBundle.inputs:
        let normalised = inputPath.replace('\\', '/')
        if normalised.contains("mathlib/src/index.ts"):
          sawMathlibInput = true
      check sawMathlibInput

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

suite "jsts-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not nodeOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "typescript"
  library alpha

package betaPkg:
  uses:
    "typescript"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "index.ts",
        "export function alphaFn(): number { return 1; }\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "index.ts",
        "export function betaFn(): number { return 2; }\n")
      let conv = jsts_direct_convention.jsTsDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not nodeOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "typescript"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "hello" / "src")
      writeFile(dir / "hello" / "src" / "main.ts", "console.log('hi');\n")
      let conv = jsts_direct_convention.jsTsDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# Layout recognition. Pins the convention's behaviour for the canonical
# Mode 3 JS/TS layouts.
# ---------------------------------------------------------------------------

suite "jsts-direct convention layout recognition":

  test "layout B-flat: per-member <pkg>/main.ts at root (no src/)":
    if not nodeOnPath():
      skip()
    else:
      let dir = makeScratch("layout-b-flat-recognise")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package binPkg:
  uses:
    "typescript"
  executable mybin:
    discard
""")
      createDir(dir / "mybin")
      writeFile(dir / "mybin" / "main.ts", "console.log('hi');\n")
      let conv = jsts_direct_convention.jsTsDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

  test "layout A: single-member workspace with src/<pkg>.ts at root":
    if not nodeOnPath():
      skip()
    else:
      let dir = makeScratch("layout-a-bin")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package soloPkg:
  uses:
    "typescript"
  executable solo:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "solo.ts", "console.log('hi');\n")
      let conv = jsts_direct_convention.jsTsDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

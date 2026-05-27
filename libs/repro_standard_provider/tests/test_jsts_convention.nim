## M16 verification: JavaScript / TypeScript language convention.
##
## Tests against the in-tree fixtures under
## ``reprobuild-examples/javascript-typescript/``:
##
##   * ``javascript-typescript/typescript-library`` — TS library, single
##     ``src/index.ts``
##   * ``javascript-typescript/typescript-cli``     — TS CLI, ``bin``
##     entry pointing at ``src/bin/cli.ts``
##   * ``javascript-typescript/node-server``        — pure JS, no
##     TypeScript, ``src/index.js`` entry
##
## Negative recognise cases are materialised as tiny scratch projects
## under the test's temp directory so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for each of the three fixtures (with
##     node on PATH).
##   * ``recognize`` returns false when:
##     - ``package.json`` is absent
##     - a Mode B config (``vite.config.*``) is present at the root
##     - ``uses:`` doesn't list ``node`` / ``typescript``
##     - no member is declared
##     - ``"type"`` is not ``"module"`` (CommonJS — out of M16 scope)
##   * ``emitFragment`` against ``typescript-library`` (skipped if node
##     isn't on PATH):
##     - at least one ``jsts-tsc-compile`` action exists
##     - the action's argv carries ``npx`` as argv[0] and ``tsc`` in the
##       argv
##     - at least one ``.js`` and one ``.d.ts`` appear in the action's
##       declared outputs
##   * ``emitFragment`` against ``node-server`` (skipped if node isn't on
##     PATH):
##     - at least one ``jsts-copy-js-*`` action exists
##     - the action's outputs land under ``.repro/build/dist/``

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/javascript_typescript as jsts_convention

const
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_jsts_convention.nim``
  ## lands at the ``reprobuild/`` repo root. The fixture lives in the
  ## sibling ``reprobuild-examples`` checkout under ``D:/metacraft/``,
  ## so take one more parent.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  LibraryFixture =
    MetacraftRoot / "reprobuild-examples" / "javascript-typescript" /
      "typescript-library"
  CliFixture =
    MetacraftRoot / "reprobuild-examples" / "javascript-typescript" /
      "typescript-cli"
  NodeServerFixture =
    MetacraftRoot / "reprobuild-examples" / "javascript-typescript" /
      "node-server"

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
  findExe("node").len > 0

suite "javascript/typescript convention M16":

  test "recognize: positive — typescript-library fixture":
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    check conv.name == "javascript-typescript"
    if not fileExists(LibraryFixture / "package.json"):
      checkpoint "fixture missing — looked at " & LibraryFixture
      fail()
    let request = dummyRequest(LibraryFixture)
    if not nodeOnPath():
      checkpoint "node not on PATH — positive recognize will return false"
      check not conv.recognize(LibraryFixture, request)
    else:
      check conv.recognize(LibraryFixture, request)

  test "recognize: positive — typescript-cli fixture":
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    if not fileExists(CliFixture / "package.json"):
      checkpoint "fixture missing — looked at " & CliFixture
      fail()
    let request = dummyRequest(CliFixture)
    if not nodeOnPath():
      check not conv.recognize(CliFixture, request)
    else:
      check conv.recognize(CliFixture, request)

  test "recognize: positive — node-server fixture":
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    if not fileExists(NodeServerFixture / "package.json"):
      checkpoint "fixture missing — looked at " & NodeServerFixture
      fail()
    let request = dummyRequest(NodeServerFixture)
    if not nodeOnPath():
      check not conv.recognize(NodeServerFixture, request)
    else:
      check conv.recognize(NodeServerFixture, request)

  test "recognize: negative — package.json missing":
    let scratch = getTempDir() / "test_jsts_convention_no_pkg_json"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeJsTs:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n" &
      "\n" &
      "  library fake_ts\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — vite.config.ts at root forces Mode B":
    let scratch = getTempDir() / "test_jsts_convention_vite"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\n" &
      "  \"name\": \"fake-vite\",\n" &
      "  \"version\": \"0.1.0\",\n" &
      "  \"type\": \"module\"\n" &
      "}\n")
    writeFile(scratch / "tsconfig.json",
      "{\n" &
      "  \"compilerOptions\": {\n" &
      "    \"module\": \"NodeNext\",\n" &
      "    \"moduleResolution\": \"NodeNext\",\n" &
      "    \"isolatedModules\": true,\n" &
      "    \"verbatimModuleSyntax\": true\n" &
      "  },\n" &
      "  \"include\": [\"src/**/*\"]\n" &
      "}\n")
    writeFile(scratch / "src" / "index.ts",
      "export const x = 1;\n")
    writeFile(scratch / "vite.config.ts", "export default {};\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeViteApp:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n" &
      "    \"typescript >=5\"\n" &
      "\n" &
      "  library fake_vite_app\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks node/typescript":
    let scratch = getTempDir() / "test_jsts_convention_rust_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\"name\":\"fake\",\"version\":\"0.1.0\",\"type\":\"module\"}\n")
    writeFile(scratch / "src" / "index.ts", "export const x = 1;\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRustyJs:\n" &
      "  uses:\n" &
      "    \"rust >=1.80\"\n" &
      "\n" &
      "  library fake_rusty_js\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — type is not module (CommonJS)":
    let scratch = getTempDir() / "test_jsts_convention_cjs"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\"name\":\"fake-cjs\",\"version\":\"0.1.0\"}\n")
    writeFile(scratch / "src" / "index.js", "module.exports = {};\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeCjs:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n" &
      "\n" &
      "  library fake_cjs\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_jsts_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\"name\":\"fake\",\"version\":\"0.1.0\",\"type\":\"module\"}\n")
    writeFile(scratch / "src" / "index.ts", "export const x = 1;\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package emptyJsPkg:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: typescript-library produces a tsc-compile action":
    if not nodeOnPath():
      skip()
    else:
      let conv = jsts_convention.javaScriptTypeScriptConvention()
      let request = dummyRequest(LibraryFixture)
      require conv.recognize(LibraryFixture, request)
      let fragment = conv.emitFragment(LibraryFixture, request)

      var tscActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "jsts-tsc-compile":
          tscActions.add(action)

      check tscActions.len == 1
      let tsc = tscActions[0]
      let argv = inlineArgvOf(tsc)
      check argv.len >= 2
      let arg0Base = extractFilename(argv[0]).toLowerAscii
      check arg0Base.startsWith("npx")
      var sawTsc = false
      for arg in argv:
        if arg == "tsc":
          sawTsc = true
          break
      check sawTsc
      check tsc.pool == "compile"

      var sawJs = false
      var sawDts = false
      for outPath in tsc.outputs:
        let lower = outPath.toLowerAscii
        if lower.endsWith(".d.ts"):
          sawDts = true
          check ".repro" in outPath.replace('\\', '/')
        elif lower.endsWith(".js"):
          sawJs = true
          check ".repro" in outPath.replace('\\', '/')
      check sawJs
      check sawDts

  test "emitFragment: node-server produces a JS-copy action":
    if not nodeOnPath():
      skip()
    else:
      let conv = jsts_convention.javaScriptTypeScriptConvention()
      let request = dummyRequest(NodeServerFixture)
      require conv.recognize(NodeServerFixture, request)
      let fragment = conv.emitFragment(NodeServerFixture, request)

      var copyActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("jsts-copy-js-"):
          copyActions.add(action)

      check copyActions.len >= 1
      var sawJs = false
      for action in copyActions:
        for outPath in action.outputs:
          if outPath.toLowerAscii.endsWith(".js"):
            sawJs = true
            check ".repro" in outPath.replace('\\', '/')
            check "/dist/" in outPath.replace('\\', '/')
      check sawJs

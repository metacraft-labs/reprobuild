## M16 + M21 verification: JavaScript / TypeScript language convention.
##
## Tests against the in-tree fixtures under
## ``reprobuild-examples/javascript-typescript/``:
##
##   * ``javascript-typescript/typescript-library`` — TS library, single
##     ``src/index.ts``
##   * ``javascript-typescript/typescript-cli``     — TS CLI, ``bin``
##     entry pointing at ``src/bin/cli.ts``, ``package-lock.json``
##     present (M21), test file under ``test/cli.test.ts`` (M21)
##   * ``javascript-typescript/node-server``        — pure JS, no
##     TypeScript, ``src/index.js`` entry
##
## Negative recognise cases are materialised as tiny scratch projects
## under the test's temp directory so each case is hermetic.
##
## Coverage (M16):
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
##
## Coverage (M21 — A1 / A5 / A6 / A7 graduations):
##   * ``emitFragment`` against ``typescript-cli`` (lockfile + test
##     fixture, skipped if node not on PATH):
##     - exactly one ``jsts-npm-ci`` action with ``npm ci`` in argv,
##       ``node_modules`` in outputs, ``package-lock.json`` in inputs
##     - exactly one ``jsts-esbuild-bundle-*`` action per bin entry;
##       argv carries ``esbuild`` + ``--bundle`` + ``--format=esm``;
##       outputs include the bundle ``.js`` + ``.meta.json`` metafile
##     - exactly one ``jsts-shim-*`` action per bin entry; output path
##       ends in ``.cmd`` (Windows) or has no extension (POSIX); the
##       shim's parent dir is the convention's ``<scratch>/bin/``
##     - a non-default ``test`` target exists with at least one
##       ``jsts-test-run`` action; argv carries ``--test`` + ``--import=tsx``
##   * ``emitFragment`` against ``typescript-library`` (no lockfile, no
##     tests): no ``jsts-npm-ci`` / ``jsts-esbuild-*`` / ``jsts-shim-*``
##     / ``jsts-test-run`` actions emitted.

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

  test "recognize: positive M24 — vite.config.ts at root routes to Mode B":
    # M24: a vite.config.* file at the project root now routes the
    # project to the crude fallback rather than declining recognition.
    # The fixture must additionally declare a non-empty
    # ``scripts.build`` so the convention knows what to invoke.
    let scratch = getTempDir() / "test_jsts_convention_vite"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\n" &
      "  \"name\": \"fake-vite\",\n" &
      "  \"version\": \"0.1.0\",\n" &
      "  \"type\": \"module\",\n" &
      "  \"scripts\": { \"build\": \"vite build\" }\n" &
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
    if not nodeOnPath():
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "recognize: negative M24 — Mode B project missing scripts.build":
    # Inverse: a Mode B-shaped project that ships no ``scripts.build``
    # has nothing for the crude fallback to invoke. The convention
    # declines so the diagnostic stays clean ("no convention matched")
    # rather than emitting a guaranteed-to-fail fragment.
    let scratch = getTempDir() / "test_jsts_convention_vite_no_build"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\n" &
      "  \"name\": \"fake-vite-nobuild\",\n" &
      "  \"version\": \"0.1.0\",\n" &
      "  \"type\": \"module\"\n" &
      "}\n")
    writeFile(scratch / "src" / "index.js", "export const x = 1;\n")
    writeFile(scratch / "vite.config.js", "export default {};\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeViteNoBuild:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n" &
      "\n" &
      "  library fake_vite_nobuild\n")
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

  test "emitFragment M21: typescript-cli emits npm-ci + esbuild + shim + test-run":
    # Verifies the M21 A1/A5/A6/A7 graduations against the canonical
    # typescript-cli fixture. The fixture ships a lockfile (so A1 fires),
    # one bin entry (so A5+A6 fire once), and one test file under
    # ``test/`` (so A7 fires).
    if not nodeOnPath():
      skip()
    elif not fileExists(CliFixture / "package-lock.json"):
      checkpoint "typescript-cli fixture missing package-lock.json — " &
        "M21 A1 won't fire; ensure 'npm install --package-lock-only' was " &
        "run on the fixture"
      skip()
    else:
      let conv = jsts_convention.javaScriptTypeScriptConvention()
      let request = dummyRequest(CliFixture)
      require conv.recognize(CliFixture, request)
      let fragment = conv.emitFragment(CliFixture, request)

      var npmCi: seq[BuildActionDef] = @[]
      var esbuild: seq[BuildActionDef] = @[]
      var shim: seq[BuildActionDef] = @[]
      var testRun: seq[BuildActionDef] = @[]
      var tsc: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "jsts-npm-ci":
          npmCi.add(action)
        elif action.id.startsWith("jsts-esbuild-bundle-"):
          esbuild.add(action)
        elif action.id.startsWith("jsts-shim-"):
          shim.add(action)
        elif action.id == "jsts-test-run":
          testRun.add(action)
        elif action.id == "jsts-tsc-compile":
          tsc.add(action)

      # M21 A1: exactly one npm-ci action with the expected argv shape
      # and node_modules + package-lock.json wired up.
      check npmCi.len == 1
      let ci = npmCi[0]
      let ciArgv = inlineArgvOf(ci)
      check ciArgv.len >= 2
      check ciArgv[1] == "ci"
      var sawNodeModules = false
      for o in ci.outputs:
        if extractFilename(o) == "node_modules":
          sawNodeModules = true
      check sawNodeModules
      var sawLockfileInput = false
      for i in ci.inputs:
        if extractFilename(i) == "package-lock.json":
          sawLockfileInput = true
      check sawLockfileInput

      # tsc still runs (whole-project type-check + .d.ts emit) and
      # carries the npm-ci action in its deps so the install lands
      # before tsc fires.
      check tsc.len == 1
      check "jsts-npm-ci" in tsc[0].deps

      # M21 A5: one esbuild action per bin entry. The typescript-cli
      # fixture declares exactly one bin ("typescript-cli-example").
      check esbuild.len == 1
      let bundle = esbuild[0]
      let bundleArgv = inlineArgvOf(bundle)
      check "--bundle" in bundleArgv
      var sawFormatEsm = false
      var sawPlatformNode = false
      var sawOutfile = false
      var sawMetafile = false
      for arg in bundleArgv:
        if arg == "--format=esm":
          sawFormatEsm = true
        elif arg == "--platform=node":
          sawPlatformNode = true
        elif arg.startsWith("--outfile="):
          sawOutfile = true
        elif arg.startsWith("--metafile="):
          sawMetafile = true
      check sawFormatEsm
      check sawPlatformNode
      check sawOutfile
      check sawMetafile
      # Bundle outputs include the .js + .meta.json.
      var sawBundleJs = false
      var sawBundleMeta = false
      for o in bundle.outputs:
        let lower = o.toLowerAscii
        if lower.endsWith(".meta.json"):
          sawBundleMeta = true
        elif lower.endsWith(".js"):
          sawBundleJs = true
      check sawBundleJs
      check sawBundleMeta
      # The esbuild action carries the npm-ci action in its deps so
      # local node_modules/.bin/esbuild is installed first.
      check "jsts-npm-ci" in bundle.deps

      # M21 A6: one shim action per bin entry. The shim writes a
      # platform-specific launcher under <scratch>/bin/. Output ends in
      # .cmd on Windows; no extension on POSIX.
      check shim.len == 1
      let sh = shim[0]
      check sh.outputs.len == 1
      let shimPath = sh.outputs[0].replace('\\', '/')
      check "/.repro/build/bin/" in shimPath
      when defined(windows):
        check shimPath.toLowerAscii.endsWith(".cmd")
      # The shim depends on the esbuild action so the bundle exists
      # when the launcher's text is materialised.
      check bundle.id in sh.deps

      # M21 A7: one test-runner action. Argv carries ``node --test``
      # + ``--import=tsx`` + the test file paths. The action declares
      # NO file outputs (it's a verification action).
      check testRun.len == 1
      let tr = testRun[0]
      let trArgv = inlineArgvOf(tr)
      check "--test" in trArgv
      check "--import=tsx" in trArgv
      check tr.outputs.len == 0
      var sawTestFile = false
      for i in tr.inputs:
        let lower = i.toLowerAscii
        if lower.endsWith(".test.ts") or lower.endsWith(".test.js"):
          sawTestFile = true
      check sawTestFile

  test "emitFragment M21: typescript-library has no npm-ci / esbuild / shim / test actions":
    # Inverse cohort: the typescript-library fixture has no lockfile
    # and no bins / tests, so M21's new sub-graphs must not fire.
    if not nodeOnPath():
      skip()
    else:
      let conv = jsts_convention.javaScriptTypeScriptConvention()
      let request = dummyRequest(LibraryFixture)
      require conv.recognize(LibraryFixture, request)
      let fragment = conv.emitFragment(LibraryFixture, request)
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        check action.id != "jsts-npm-ci"
        check not action.id.startsWith("jsts-esbuild-bundle-")
        check not action.id.startsWith("jsts-shim-")
        check action.id != "jsts-test-run"

  test "recognize: positive M24 — webpack.config.cjs routes to Mode B":
    let scratch = getTempDir() / "test_jsts_convention_webpack"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\n" &
      "  \"name\": \"fake-webpack\",\n" &
      "  \"version\": \"0.1.0\",\n" &
      "  \"type\": \"module\",\n" &
      "  \"scripts\": { \"build\": \"webpack --mode production\" }\n" &
      "}\n")
    writeFile(scratch / "src" / "index.js", "export const x = 1;\n")
    writeFile(scratch / "webpack.config.cjs",
      "module.exports = { entry: './src/index.js' };\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeWebpack:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n" &
      "\n" &
      "  library fake_webpack\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    if not nodeOnPath():
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "recognize: positive M24 — workspaces field forces Mode B":
    # ``workspaces`` is one of the Mode B triggers — even when no
    # bundler config is present. The fixture ships a build script so
    # recognition succeeds.
    let scratch = getTempDir() / "test_jsts_convention_workspaces"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "packages")
    writeFile(scratch / "package.json",
      "{\n" &
      "  \"name\": \"fake-monorepo\",\n" &
      "  \"version\": \"0.1.0\",\n" &
      "  \"private\": true,\n" &
      "  \"workspaces\": [\"packages/*\"],\n" &
      "  \"scripts\": { \"build\": \"echo monorepo build\" }\n" &
      "}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMonorepo:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n" &
      "\n" &
      "  library fake_monorepo\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    if not nodeOnPath():
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "recognize: positive M24 — scripts.build invoking vite without config":
    # Vite can run without a ``vite.config.*`` file (it picks
    # convention-based defaults). The ``scripts.build`` detection covers
    # this case independently of the root-config check.
    let scratch = getTempDir() / "test_jsts_convention_vite_no_config"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "package.json",
      "{\n" &
      "  \"name\": \"fake-vite-no-config\",\n" &
      "  \"version\": \"0.1.0\",\n" &
      "  \"type\": \"module\",\n" &
      "  \"scripts\": { \"build\": \"vite build\" }\n" &
      "}\n")
    writeFile(scratch / "src" / "index.js", "export const x = 1;\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeViteNoConfig:\n" &
      "  uses:\n" &
      "    \"node >=20\"\n" &
      "\n" &
      "  library fake_vite_no_config\n")
    defer:
      removeDir(scratch)
    let conv = jsts_convention.javaScriptTypeScriptConvention()
    let request = dummyRequest(scratch)
    if not nodeOnPath():
      check not conv.recognize(scratch, request)
    else:
      check conv.recognize(scratch, request)

  test "emitFragment M24: vite scratch project emits a single crude action":
    # Materialise a tiny scratch vite-shaped project and verify the
    # emitted fragment carries exactly one ``crude-build-*`` action
    # whose argv invokes the platform shell with
    # ``npm install && npm run build`` (no lockfile present, so
    # ``install`` not ``ci``).
    if not nodeOnPath():
      skip()
    else:
      let scratch = getTempDir() / "test_jsts_convention_vite_emit"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "src")
      writeFile(scratch / "package.json",
        "{\n" &
        "  \"name\": \"fake-vite-emit\",\n" &
        "  \"version\": \"0.1.0\",\n" &
        "  \"type\": \"module\",\n" &
        "  \"scripts\": { \"build\": \"vite build\" }\n" &
        "}\n")
      writeFile(scratch / "src" / "index.js", "export const x = 1;\n")
      writeFile(scratch / "vite.config.js", "export default {};\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeViteEmit:\n" &
        "  uses:\n" &
        "    \"node >=20\"\n" &
        "\n" &
        "  library fake_vite_emit\n")
      defer:
        removeDir(scratch)
      let conv = jsts_convention.javaScriptTypeScriptConvention()
      let request = dummyRequest(scratch)
      require conv.recognize(scratch, request)
      let fragment = conv.emitFragment(scratch, request)

      var crudeActions: seq[BuildActionDef] = @[]
      var tscActions: seq[BuildActionDef] = @[]
      var copyActions: seq[BuildActionDef] = @[]
      var npmCiActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("crude-build-"):
          crudeActions.add(action)
        elif action.id == "jsts-tsc-compile":
          tscActions.add(action)
        elif action.id.startsWith("jsts-copy-js-"):
          copyActions.add(action)
        elif action.id == "jsts-npm-ci":
          npmCiActions.add(action)

      # Exactly one crude action and zero Mode A actions — the M24
      # routing must replace the entire Mode A sub-graph.
      check crudeActions.len == 1
      check tscActions.len == 0
      check copyActions.len == 0
      check npmCiActions.len == 0

      let crude = crudeActions[0]
      let argv = inlineArgvOf(crude)
      # Windows: ``cmd.exe /d /s /c "npm install && npm run build"``.
      # POSIX:   ``sh -c "npm install && npm run build"``.
      check argv.len >= 3
      let arg0Base = extractFilename(argv[0]).toLowerAscii
      when defined(windows):
        check arg0Base.startsWith("cmd")
      else:
        check arg0Base == "sh"
      # The full shell command lands in the last argv entry. ``npm`` is
      # interpolated as an absolute path (``findExe`` result) so we look
      # for the resolved executable basename + the install verb tokens.
      let shellLine = argv[^1]
      let shellLower = shellLine.toLowerAscii
      check "npm" in shellLower  # matches "npm.cmd" / "npm" basename
      check " install " in shellLine
      check "run build" in shellLine
      check "&&" in shellLine
      check crude.pool == "compile"

      # ``dist`` declared as an opaque output dir.
      var sawDist = false
      for outPath in crude.outputs:
        let normalised = outPath.replace('\\', '/')
        if normalised.endsWith("/dist") or normalised.endsWith("\\dist"):
          sawDist = true
      check sawDist

  test "emitFragment M24: vite scratch project with lockfile uses npm ci":
    # Same vite fixture as above but with a ``package-lock.json``
    # present — the install verb must flip from ``install`` to ``ci``.
    if not nodeOnPath():
      skip()
    else:
      let scratch = getTempDir() / "test_jsts_convention_vite_emit_ci"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "src")
      writeFile(scratch / "package.json",
        "{\n" &
        "  \"name\": \"fake-vite-emit-ci\",\n" &
        "  \"version\": \"0.1.0\",\n" &
        "  \"type\": \"module\",\n" &
        "  \"scripts\": { \"build\": \"vite build\" }\n" &
        "}\n")
      writeFile(scratch / "package-lock.json",
        "{ \"name\": \"fake-vite-emit-ci\", \"lockfileVersion\": 3, \"requires\": true, \"packages\": {} }\n")
      writeFile(scratch / "src" / "index.js", "export const x = 1;\n")
      writeFile(scratch / "vite.config.js", "export default {};\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeViteEmitCi:\n" &
        "  uses:\n" &
        "    \"node >=20\"\n" &
        "\n" &
        "  library fake_vite_emit_ci\n")
      defer:
        removeDir(scratch)
      let conv = jsts_convention.javaScriptTypeScriptConvention()
      let request = dummyRequest(scratch)
      require conv.recognize(scratch, request)
      let fragment = conv.emitFragment(scratch, request)

      var crudeActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("crude-build-"):
          crudeActions.add(action)
      check crudeActions.len == 1
      let argv = inlineArgvOf(crudeActions[0])
      let shellLine = argv[^1]
      # ``npm`` is interpolated as an absolute path (``findExe`` result).
      # We assert the install verb is ``ci`` (not ``install``) by
      # checking for the space-separated verb sentinel ``" ci "``.
      check " ci " in shellLine
      check " install " notin shellLine

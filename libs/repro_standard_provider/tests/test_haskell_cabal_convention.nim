## M55 verification: Haskell + Cabal (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/haskell-cabal/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - ghc AND cabal are on PATH
##   * ``recognize`` returns false when:
##     - no ``*.cabal`` file is at the root
##     - ``uses:`` doesn't list cabal
##     - ``uses:`` doesn't list haskell / ghc
##     - no executable member is declared
##     - ``stack.yaml`` is present at the root (defer to a future
##       haskell-stack sibling)
##     - ghc or cabal is missing from PATH (toolchain probe failure)
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     ghc/cabal missing):
##     - the convention emits a ``haskell-cabal-outputs`` discovery
##       action and a single ``haskell-cabal-build`` action.
##     - the build action's argv carries ``cabal v2-build --offline -j1
##       --builddir=<root>/dist-newstyle``, with ``--enable-relocatable``
##       on Linux and macOS only: Cabal refuses a relocatable build on any
##       other OS (``Cabal-3339``, measured on Windows).
##     - the build action declares no outputs of its own: it loads the
##       discovery fragment, which is one of its inputs.
##   * Where cabal puts each executable (default layout, an
##     ``optimization`` override) is checked by real builds in
##     ``test_delegated_build_outputs.nim``.
##
## **Toolchain-gated SKIPs**: most tests SKIP cleanly when ``ghc`` or
## ``cabal`` is not on PATH (which is the M55 default on Windows —
## Haskell isn't in the standard dev shell). The recognition-negative
## tests that don't depend on the toolchain still exercise the
## convention's gate-only paths and run unconditionally.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/haskell_cabal as haskell_convention

let
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_haskell_cabal_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = workspaceRootForRepo(ReprobuildRoot)
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "haskell-cabal" / "hello-binary"

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

proc haskellToolchainReady(): bool =
  ## True when BOTH ``ghc`` and ``cabal`` are on PATH. The convention's
  ## ``recognize`` enforces this jointly; tests gate on this and SKIP
  ## when either is missing.
  findExe("ghc").len > 0 and findExe("cabal").len > 0

suite "haskell-cabal convention M55":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = haskell_convention.haskellCabalConvention()
    check conv.name == "haskell-cabal"
    if not fileExists(HelloBinaryFixture / "hello.cabal"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "app" / "Main.hs"):
      checkpoint "fixture missing app/Main.hs"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if haskellToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "ghc/cabal toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no *.cabal at root":
    let scratch = getTempDir() / "test_haskell_cabal_no_manifest"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "app")
    writeFile(scratch / "app" / "Main.hs",
      "module Main where\nmain :: IO ()\nmain = putStrLn \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeHaskellNoManifest:\n" &
      "  uses:\n" &
      "    \"haskell >=9.10\"\n" &
      "    \"cabal >=3.12\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = haskell_convention.haskellCabalConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks cabal (only haskell)":
    let scratch = getTempDir() / "test_haskell_cabal_no_cabal_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "app")
    writeFile(scratch / "hello.cabal",
      "cabal-version: 2.0\nname: hello\nversion: 1.0\n" &
      "executable hello\n  main-is: Main.hs\n  hs-source-dirs: app\n" &
      "  build-depends: base\n  default-language: Haskell2010\n")
    writeFile(scratch / "app" / "Main.hs",
      "module Main where\nmain :: IO ()\nmain = putStrLn \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeHaskellNoCabal:\n" &
      "  uses:\n" &
      "    \"haskell >=9.10\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = haskell_convention.haskellCabalConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks haskell/ghc (only cabal)":
    let scratch = getTempDir() / "test_haskell_cabal_no_haskell_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "app")
    writeFile(scratch / "hello.cabal",
      "cabal-version: 2.0\nname: hello\nversion: 1.0\n" &
      "executable hello\n  main-is: Main.hs\n  hs-source-dirs: app\n" &
      "  build-depends: base\n  default-language: Haskell2010\n")
    writeFile(scratch / "app" / "Main.hs",
      "module Main where\nmain :: IO ()\nmain = putStrLn \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeHaskellNoHaskellToken:\n" &
      "  uses:\n" &
      "    \"cabal >=3.12\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = haskell_convention.haskellCabalConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no executable member declared":
    let scratch = getTempDir() / "test_haskell_cabal_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "hello.cabal",
      "cabal-version: 2.0\nname: hello\nversion: 1.0\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeHaskellNoMember:\n" &
      "  uses:\n" &
      "    \"haskell >=9.10\"\n" &
      "    \"cabal >=3.12\"\n")
    defer:
      removeDir(scratch)
    let conv = haskell_convention.haskellCabalConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — stack.yaml present (defer to future haskell-stack)":
    let scratch = getTempDir() / "test_haskell_cabal_stack_yaml"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "app")
    writeFile(scratch / "hello.cabal",
      "cabal-version: 2.0\nname: hello\nversion: 1.0\n" &
      "executable hello\n  main-is: Main.hs\n  hs-source-dirs: app\n" &
      "  build-depends: base\n  default-language: Haskell2010\n")
    writeFile(scratch / "stack.yaml",
      "resolver: lts-22.0\npackages:\n  - .\n")
    writeFile(scratch / "app" / "Main.hs",
      "module Main where\nmain :: IO ()\nmain = putStrLn \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeHaskellStack:\n" &
      "  uses:\n" &
      "    \"haskell >=9.10\"\n" &
      "    \"cabal >=3.12\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = haskell_convention.haskellCabalConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — ghc/cabal not on PATH (toolchain probe)":
    ## When ``ghc`` or ``cabal`` is missing from PATH the convention's
    ## recognise must return false. This test asserts only when the
    ## toolchain is ACTUALLY missing — when both ARE installed, skip
    ## rather than hand-wave the gate.
    if haskellToolchainReady():
      skip("ghc or cabal not on PATH")
    else:
      let scratch = getTempDir() / "test_haskell_cabal_no_toolchain"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "app")
      writeFile(scratch / "hello.cabal",
        "cabal-version: 2.0\nname: hello\nversion: 1.0\n" &
        "executable hello\n  main-is: Main.hs\n  hs-source-dirs: app\n" &
        "  build-depends: base\n  default-language: Haskell2010\n")
      writeFile(scratch / "app" / "Main.hs",
        "module Main where\nmain :: IO ()\nmain = putStrLn \"hi\"\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeHaskellNoToolchain:\n" &
        "  uses:\n" &
        "    \"haskell >=9.10\"\n" &
        "    \"cabal >=3.12\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = haskell_convention.haskellCabalConvention()
      let request = dummyRequest(scratch)
      check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces a single build action":
    if not haskellToolchainReady():
      skip("ghc or cabal not on PATH")
    else:
      let conv = haskell_convention.haskellCabalConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var buildActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "haskell-cabal-build":
          buildActions.add(action)

      check buildActions.len == 1
      let buildAct = buildActions[0]
      check buildAct.pool == "compile"

      # argv carries: cabal, "v2-build", "--offline", "-j1",
      # "--enable-relocatable"
      let argv = inlineArgvOf(buildAct)
      var sawV2BuildVerb = false
      var sawOfflineFlag = false
      var sawJ1Flag = false
      var sawRelocatableFlag = false
      for token in argv:
        if token == "v2-build": sawV2BuildVerb = true
        elif token == "--offline": sawOfflineFlag = true
        elif token == "-j1": sawJ1Flag = true
        elif token == "--enable-relocatable": sawRelocatableFlag = true
      check sawV2BuildVerb
      check sawOfflineFlag
      check sawJ1Flag
      when defined(linux) or defined(macosx):
        check sawRelocatableFlag
      else:
        check not sawRelocatableFlag

      check "--builddir=" & (HelloBinaryFixture / "dist-newstyle") in argv
      # The build edge's outputs are discovered, not predicted
      # (Build-Engine-And-Scheduler.md §"Outputs a delegated build
      # decides"): it declares none itself, loads the fragment its
      # discovery edge writes, and is keyed on it. Real builds of the
      # default layout and of the overrides are in
      # test_delegated_build_outputs.nim.
      check buildAct.outputs.len == 0
      check buildAct.dynamicDepsFile.replace('\\', '/').endsWith(
        "/.repro/build/haskell-cabal-outputs.dyndep")
      check buildAct.dynamicDepsFile in buildAct.inputs
      check "haskell-cabal-outputs" in buildAct.deps
      var sawDiscovery = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "haskell-cabal-outputs":
          sawDiscovery = true
          check action.outputs == @[buildAct.dynamicDepsFile]
          check "--delegated-outputs" in inlineArgvOf(action)
      check sawDiscovery

## M43 verification: Swift / SwiftPM (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/swift-swiftpm/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - swift is on PATH
##   * ``recognize`` returns false when:
##     - no ``Package.swift`` is at the root
##     - ``uses:`` doesn't list swift
##     - no executable / library member is declared
##     - swift is missing from PATH (toolchain probe failure)
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     swift is missing):
##     - the convention emits a single ``swift-swiftpm-build`` action.
##     - the action's argv carries ``swift build -c release --quiet``.
##     - an output discovery edge asks SwiftPM for the actual release
##       directory; the build consumes it as a dynamic directory output.
##   * Legacy static output-name helpers: executable yields ``.build/release/<name>``
##     (with ``.exe`` on Windows); library yields
##     ``.build/release/lib<name>.a``.
##
## **Toolchain-gated SKIPs**: most tests SKIP cleanly when ``swift`` is
## not on PATH (which is the M43 default on Windows — Swift Windows
## isn't in the standard dev shell). The recognition-negative tests
## that don't depend on the toolchain still exercise the convention's
## gate-only paths and run unconditionally.

import std/[os, osproc, streams, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/swift_swiftpm as swift_convention
from repro_standard_provider/conventions/output_discovery import readToEnd

let
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_swift_swiftpm_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = workspaceRootForRepo(ReprobuildRoot)
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "swift-swiftpm" / "hello-binary"
  ## The built standard provider the real-build case runs. Spelled as the
  ## one literal ``build/bin/repro-standard-provider``: the suite inventory
  ## recognises a case that needs the built binaries by that spelling, and
  ## schedules it after them.
  StandardProviderBinary =
    addFileExt(ReprobuildRoot / "build/bin/repro-standard-provider", ExeExt)

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

proc swiftToolchainReady(): bool =
  ## True when ``swift`` is on PATH. The convention's ``recognize``
  ## enforces this; tests gate on this and SKIP when missing.
  findExe("swift").len > 0

# --- real SwiftPM builds ------------------------------------------------------
#
# The real-build case runs the emitted argv the way the engine does: each
# edge's own argv, in its own working directory, with no shell in between
# (a POSIX ``cd <dir> && ...`` line is not a command on Windows, where
# ``execCmdEx`` hands the string to ``CreateProcessW``). Its body lives in
# these procs rather than in the ``test`` block: unittest inlines a top-level
# ``test`` into module scope, which made its locals module globals, and the
# loop variable of the ``for token in argv.mitems`` the case used to carry
# was reset through its still-nil global pointer before the loop bound it
# (SIGSEGV at the ``emitFragment`` line on eli-pc, Nim 2.2.8; issue
# 2026-10-27-swift-convention-real-build-test-crashes-on-windows.md).
#
# The procs fail with ``doAssert``, not ``check`` / ``require``: outside a
# ``test`` body ``unittest.check`` cannot see the ``testStatusIMPL`` the
# ``test`` template injects and only sets the program result, so the case
# would still report ``[OK]``. ``doAssert`` raises, and the ``test``
# template's own ``except`` reports the case as failed.

proc runInDir(argv: seq[string]; cwd: string): tuple[output: string; code: int] =
  let process = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  # Not ``readAll``, which stops at a pipe's first short read on Windows.
  result.output = process.outputStream.readToEnd()
  result.code = process.waitForExit()

proc writeSwiftLibraryPackage(project, mode: string) =
  createDir(project / "Sources" / "Internal")
  writeFile(project / "Sources" / "Internal" / "Lib.swift",
    "public func answer() -> Int { 42 }\n")
  let productType = if mode == "automatic": "" else: ", type: ." & mode
  writeFile(project / "Package.swift", "// swift-tools-version: 5.9\n" &
    "import PackageDescription\nlet package = Package(name: \"OutputTest\", " &
    "products: [.library(name: \"Public\"" & productType &
    ", targets: [\"Internal\"])], targets: [.target(name: \"Internal\")])\n")
  writeFile(project / "reprobuild.nim", "import repro_project_dsl\n" &
    "package swiftOutputTest:\n  uses:\n    \"swift >=5.9\"\n" &
    "  library Public:\n    discard\n")

proc swiftBuildProbe(swiftExe, project: string): string =
  ## "" when ``swift build`` builds a trivial package here, else why not
  ## (eli-pc's Swift 5.10.1 lacks the SDK module maps; nixpkgs' needs its
  ## stdenv). The case is about the convention, not the toolchain.
  writeSwiftLibraryPackage(project, "automatic")
  let probe = runInDir(@[swiftExe, "build", "-c", "release"], project)
  if probe.code != 0:
    let text = probe.output.strip()
    result = "exit " & $probe.code & ": " &
      text[max(0, text.len - 400) .. ^1]

proc checkSwiftLibraryMode(root, mode: string) =
  let project = root / mode
  writeSwiftLibraryPackage(project, mode)
  let fragment = swift_convention.swiftSwiftpmConvention().emitFragment(
    project, dummyRequest(project))
  # The discovery edge names this process as the standard provider; run
  # the built one instead.
  let provider = StandardProviderBinary
  for node in fragment.nodes:
    if node.kind != gnkAction: continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    var argv: seq[string] = @[]
    for token in inlineArgvOf(action):
      argv.add(token.replace(getAppFilename(), provider))
    if "build" in argv: argv.add(@["--jobs", "2"])
    let outcome = runInDir(argv, project)
    doAssert outcome.code == 0, mode & ": " & argv.quoteShellCommand() &
      " exited " & $outcome.code & "\n" & outcome.output
    for output in action.outputs:
      doAssert fileExists(output) or dirExists(output),
        mode & ": declared output not written: " & output
    if action.dynamicDepsFile.len > 0:
      for line in readFile(action.dynamicDepsFile).splitLines():
        # The release directory is an opaque output tree
        # (Build-Engine-And-Scheduler.md §"Opaque output directories").
        if line.startsWith("opaque-output\t"):
          let tree = line.split('\t')[2]
          doAssert dirExists(tree), mode & ": opaque output not written: " & tree
  let directory = project / ".build" / "release"
  if mode == "static":
    # ``lib<name>.a`` for every triple, Windows included
    # (``Triple.staticLibraryExtension``).
    doAssert fileExists(directory / "libPublic.a"), "no libPublic.a in " & directory
  elif mode == "dynamic":
    let library = when defined(windows): "Public.dll"
                  elif defined(macosx): "libPublic.dylib"
                  else: "libPublic.so"
    doAssert fileExists(directory / library), "no " & library & " in " & directory
  else:
    doAssert not fileExists(directory / "libPublic.a"),
      "an automatic product built a static archive in " & directory
    var sawModule = false
    for file in walkDirRec(directory):
      if file.endsWith("Internal.swiftmodule"): sawModule = true
    doAssert sawModule, "no Internal.swiftmodule under " & directory

suite "swift-swiftpm convention M43":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = swift_convention.swiftSwiftpmConvention()
    check conv.name == "swift-swiftpm"
    if not fileExists(HelloBinaryFixture / "Package.swift"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "Sources" / "hello" / "main.swift"):
      checkpoint "fixture missing Sources/hello/main.swift"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if swiftToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "swift toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no Package.swift at root":
    let scratch = getTempDir() / "test_swift_swiftpm_convention_no_pkg"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "Sources" / "hello")
    writeFile(scratch / "Sources" / "hello" / "main.swift",
      "print(\"hi\")\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeSwiftNoPkg:\n" &
      "  uses:\n" &
      "    \"swift >=5.5\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = swift_convention.swiftSwiftpmConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks swift":
    let scratch = getTempDir() / "test_swift_swiftpm_convention_no_swift_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Package.swift",
      "// swift-tools-version:5.5\n" &
      "import PackageDescription\n" &
      "let package = Package(name: \"hello\",\n" &
      "  targets: [.executableTarget(name: \"hello\")])\n")
    createDir(scratch / "Sources" / "hello")
    writeFile(scratch / "Sources" / "hello" / "main.swift",
      "print(\"hi\")\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeSwiftNoUses:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = swift_convention.swiftSwiftpmConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_swift_swiftpm_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Package.swift",
      "// swift-tools-version:5.5\n" &
      "import PackageDescription\n" &
      "let package = Package(name: \"hello\",\n" &
      "  targets: [.executableTarget(name: \"hello\")])\n")
    createDir(scratch / "Sources" / "hello")
    writeFile(scratch / "Sources" / "hello" / "main.swift",
      "print(\"hi\")\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeSwiftNoMember:\n" &
      "  uses:\n" &
      "    \"swift >=5.5\"\n")
    defer:
      removeDir(scratch)
    let conv = swift_convention.swiftSwiftpmConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — swift not on PATH (toolchain probe)":
    ## When ``swift`` is missing from PATH the convention's recognise
    ## must return false. This test asserts only when the toolchain is
    ## ACTUALLY missing — when swift IS installed, skip rather than
    ## hand-wave the gate.
    if swiftToolchainReady():
      skip("swift not on PATH")
    else:
      let scratch = getTempDir() / "test_swift_swiftpm_convention_no_toolchain"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      writeFile(scratch / "Package.swift",
        "// swift-tools-version:5.5\n" &
        "import PackageDescription\n" &
        "let package = Package(name: \"hello\",\n" &
        "  targets: [.executableTarget(name: \"hello\")])\n")
      createDir(scratch / "Sources" / "hello")
      writeFile(scratch / "Sources" / "hello" / "main.swift",
        "print(\"hi\")\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeSwiftNoToolchain:\n" &
        "  uses:\n" &
        "    \"swift >=5.5\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = swift_convention.swiftSwiftpmConvention()
      let request = dummyRequest(scratch)
      check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces a single build action":
    if not swiftToolchainReady():
      skip("swift not on PATH")
    else:
      let conv = swift_convention.swiftSwiftpmConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var buildActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "swift-swiftpm-build":
          buildActions.add(action)

      check buildActions.len == 1
      let buildAct = buildActions[0]
      check buildAct.pool == "compile"

      # argv carries: swift, "build", "-c", "release", "--quiet"
      let argv = inlineArgvOf(buildAct)
      var sawBuildVerb = false
      var sawReleaseConfig = false
      var sawQuietFlag = false
      for i, token in argv:
        if token == "build": sawBuildVerb = true
        elif token == "release" and i > 0 and argv[i - 1] == "-c":
          sawReleaseConfig = true
        elif token == "--quiet": sawQuietFlag = true
      check sawBuildVerb
      check sawReleaseConfig
      check sawQuietFlag

      check buildAct.outputs.len == 0
      check buildAct.dynamicDepsFile.endsWith("swift-outputs.dyndep")
      check "swift-swiftpm-outputs" in buildAct.deps

  test "output-path resolution: executable target ⇒ .build/release/<name>[.exe]":
    ## Exercise the executable output-path predictor. This is a pure
    ## function (``producedExecutablePath``) — no toolchain needed.
    let projectRoot = "/some/project"
    let predicted = swift_convention.producedExecutablePath(projectRoot, "myexe")
    let unified = predicted.replace('\\', '/')
    when defined(windows):
      check unified.endsWith("/.build/release/myexe.exe")
    else:
      check unified.endsWith("/.build/release/myexe")

  test "output-path resolution: library target ⇒ .build/release/lib<name>.a":
    ## Exercise the library output-path predictor — produces the
    ## SwiftPM static-archive convention ``lib<name>.a``.
    let projectRoot = "/some/project"
    let predicted = swift_convention.producedLibraryPath(projectRoot, "mylib")
    let unified = predicted.replace('\\', '/')
    # ``lib<name>.a`` on Windows too: SwiftPM's static-library extension
    # is ``.a`` for every triple (``Triple.staticLibraryExtension``).
    check unified.endsWith("/.build/release/libmylib.a")

  test "real static dynamic and automatic libraries fulfill declared outputs":
    let swiftExe = findExe("swift", followSymlinks = false)
    let provider = StandardProviderBinary
    if swiftExe.len == 0:
      skip("swift not on PATH")
    else:
      # The discovery edge runs the built standard provider. Without it the
      # case cannot run, and that is an unbuilt checkout, not a missing
      # toolchain, so it fails rather than skips.
      checkpoint "standard provider: " & provider
      require fileExists(provider)
      let root = getTempDir() / "repro-swift-library-output-obligation"
      if dirExists(root): removeDir(root)
      createDir(root)
      defer: removeDir(root)
      let why = swiftBuildProbe(swiftExe, root / "probe")
      if why.len > 0:
        skip("swift build cannot build a trivial package here: " & why)
      else:
        for mode in ["static", "dynamic", "automatic"]:
          checkSwiftLibraryMode(root, mode)

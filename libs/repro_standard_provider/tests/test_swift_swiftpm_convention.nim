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
##     - the action's output is
##       ``.build/release/hello[.exe]`` under the project root.
##   * Output-path resolution: executable yields ``.build/release/<name>``
##     (with ``.exe`` on Windows); library yields
##     ``.build/release/lib<name>.a``.
##
## **Toolchain-gated SKIPs**: most tests SKIP cleanly when ``swift`` is
## not on PATH (which is the M43 default on Windows — Swift Windows
## isn't in the standard dev shell). The recognition-negative tests
## that don't depend on the toolchain still exercise the convention's
## gate-only paths and run unconditionally.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/swift_swiftpm as swift_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_swift_swiftpm_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "swift-swiftpm" / "hello-binary"

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
      skip()
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
      skip()
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

      # Output is .build/release/hello[.exe] under the fixture root.
      var sawExeOutput = false
      let expectedSuffix =
        when defined(windows): "/.build/release/hello.exe"
        else: "/.build/release/hello"
      for outPath in buildAct.outputs:
        let unified = outPath.replace('\\', '/')
        if unified.endsWith(expectedSuffix):
          sawExeOutput = true
      check sawExeOutput

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
    check unified.endsWith("/.build/release/libmylib.a")

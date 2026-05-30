## M61 verification: Erlang + rebar3 (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/erlang-rebar3/hello-binary/`` plus scratch
## projects materialised in the test's temp directory. Mirrors the
## test shape of M55 (haskell-cabal), M56 (ruby-bundler), M57
## (php-composer), and M60 (crystal).
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - erl AND rebar3 are on PATH
##   * ``recognize`` returns false when:
##     - no ``rebar.config`` is at the root
##     - no ``rebar.lock`` is at the root (HARD precondition)
##     - ``uses:`` doesn't list erlang / erl / rebar3
##     - no executable member is declared
##     - erl or rebar3 is missing from PATH (toolchain probe failure)
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     erl/rebar3 missing):
##     - the convention emits a single
##       ``erlang-rebar3-escriptize-<name>`` action per declared
##       executable.
##     - the escriptize action's argv carries ``rebar3`` and
##       ``escriptize`` tokens.
##     - the convention also emits one ``erlang-rebar3-wrapper-<name>``
##       action per declared executable.
##     - the wrapper action's output ends with ``hello.cmd`` (Windows)
##       under ``.repro/build/hello/``.
##   * Output-path resolution:
##     - the predicted wrapper path matches
##       ``<root>/.repro/build/<name>/<name>.cmd`` (Windows) /
##       ``<root>/.repro/build/<name>/<name>`` (POSIX).
##     - the predicted escript path matches
##       ``<root>/_build/default/bin/<name>``.
##   * ``hasRebarConfig`` / ``hasRebarLock`` helpers correctly detect
##     manifest + lockfile presence.
##
## **Toolchain-gated SKIPs**: tests that require the live convention's
## ``recognize`` to fire SKIP cleanly when ``erl`` or ``rebar3`` is
## not on PATH. The recognition-negative tests that don't depend on
## the toolchain still exercise the convention's gate-only paths and
## run unconditionally.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/erlang_rebar3 as erlang_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_erlang_rebar3_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "erlang-rebar3" / "hello-binary"

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

proc erlangToolchainReady(): bool =
  ## True when BOTH ``erl`` and ``rebar3`` are on PATH. The
  ## convention's ``recognize`` enforces this jointly; tests gate on
  ## this and SKIP when either is missing.
  findExe("erl").len > 0 and findExe("rebar3").len > 0

suite "erlang-rebar3 convention M61":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = erlang_convention.erlangRebar3Convention()
    check conv.name == "erlang-rebar3"
    if not fileExists(HelloBinaryFixture / "rebar.config"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "rebar.lock"):
      checkpoint "fixture missing rebar.lock"
      fail()
    if not fileExists(HelloBinaryFixture / "src" / "hello.erl"):
      checkpoint "fixture missing src/hello.erl"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if erlangToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "erl/rebar3 toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no rebar.config at root":
    let scratch = getTempDir() / "test_erlang_rebar3_no_manifest"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "hello.erl",
      "-module(hello).\n-export([main/1]).\nmain(_) -> ok.\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeErlangNoManifest:\n" &
      "  uses:\n" &
      "    \"erlang\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = erlang_convention.erlangRebar3Convention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — rebar.config present but rebar.lock missing (HARD precondition)":
    ## M61 spec: ``rebar.lock`` is a HARD precondition. The convention
    ## refuses to recognise a project missing it; rebar3's
    ## reproducibility guarantee depends on the lockfile.
    let scratch = getTempDir() / "test_erlang_rebar3_no_lockfile"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "rebar.config",
      "{erl_opts, [debug_info]}.\n{deps, []}.\n" &
      "{escript_main_app, hello}.\n")
    # NOTE: deliberately no rebar.lock.
    writeFile(scratch / "src" / "hello.erl",
      "-module(hello).\n-export([main/1]).\nmain(_) -> ok.\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeErlangNoLockfile:\n" &
      "  uses:\n" &
      "    \"erlang\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = erlang_convention.erlangRebar3Convention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks erlang/erl/rebar3":
    let scratch = getTempDir() / "test_erlang_rebar3_no_erlang_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "rebar.config",
      "{erl_opts, [debug_info]}.\n{deps, []}.\n")
    writeFile(scratch / "rebar.lock", "[].\n")
    writeFile(scratch / "src" / "hello.erl",
      "-module(hello).\n-export([main/1]).\nmain(_) -> ok.\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeErlangNoToken:\n" &
      "  uses:\n" &
      "    \"python >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = erlang_convention.erlangRebar3Convention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no executable member declared":
    let scratch = getTempDir() / "test_erlang_rebar3_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "rebar.config",
      "{erl_opts, [debug_info]}.\n{deps, []}.\n")
    writeFile(scratch / "rebar.lock", "[].\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeErlangNoMember:\n" &
      "  uses:\n" &
      "    \"erlang\"\n")
    defer:
      removeDir(scratch)
    let conv = erlang_convention.erlangRebar3Convention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — erl/rebar3 not on PATH (toolchain probe)":
    ## When ``erl`` or ``rebar3`` is missing from PATH the convention's
    ## recognise must return false. This test asserts only when the
    ## toolchain is ACTUALLY missing — when both ARE installed, skip
    ## rather than hand-wave the gate.
    if erlangToolchainReady():
      skip()
    else:
      let scratch = getTempDir() / "test_erlang_rebar3_no_toolchain"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "src")
      writeFile(scratch / "rebar.config",
        "{erl_opts, [debug_info]}.\n{deps, []}.\n")
      writeFile(scratch / "rebar.lock", "[].\n")
      writeFile(scratch / "src" / "hello.erl",
        "-module(hello).\n-export([main/1]).\nmain(_) -> ok.\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeErlangNoToolchain:\n" &
        "  uses:\n" &
        "    \"erlang\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = erlang_convention.erlangRebar3Convention()
      let request = dummyRequest(scratch)
      check not conv.recognize(scratch, request)

  test "recognize: positive — accepts ``rebar3`` token in uses":
    ## The convention accepts ``erlang`` / ``erl`` / ``rebar3`` as
    ## equivalent ``uses:`` tokens (single-token accept pattern, mirroring
    ## M30 / M56 / M57 / M60).
    if not erlangToolchainReady():
      skip()
    else:
      let scratch = getTempDir() / "test_erlang_rebar3_token_rebar3"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "src")
      writeFile(scratch / "rebar.config",
        "{erl_opts, [debug_info]}.\n{deps, []}.\n" &
        "{escript_main_app, hello}.\n")
      writeFile(scratch / "rebar.lock", "[].\n")
      writeFile(scratch / "src" / "hello.app.src",
        "{application, hello, [{vsn, \"1.0.0\"}]}.\n")
      writeFile(scratch / "src" / "hello.erl",
        "-module(hello).\n-export([main/1]).\nmain(_) -> ok.\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeErlangRebar3Token:\n" &
        "  uses:\n" &
        "    \"rebar3\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = erlang_convention.erlangRebar3Convention()
      let request = dummyRequest(scratch)
      check conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces escriptize + wrapper actions":
    if not erlangToolchainReady():
      skip()
    elif not fileExists(HelloBinaryFixture / "rebar.config"):
      skip()
    else:
      let conv = erlang_convention.erlangRebar3Convention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var escriptizeActions: seq[BuildActionDef] = @[]
      var wrapperActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("erlang-rebar3-escriptize-"):
          escriptizeActions.add(action)
        elif action.id.startsWith("erlang-rebar3-wrapper-"):
          wrapperActions.add(action)

      check escriptizeActions.len >= 1
      check wrapperActions.len >= 1
      let escriptizeAct = escriptizeActions[0]
      check escriptizeAct.pool == "compile"

      # The escriptize argv must carry the rebar3 + escriptize tokens.
      let argv = inlineArgvOf(escriptizeAct)
      let joined = argv.join(" ")
      check joined.contains("rebar3") or joined.contains("rebar3.cmd") or
        joined.contains("rebar3.exe")
      check joined.contains("escriptize")

      # The wrapper action's output ends with hello.cmd (Windows) or
      # hello (POSIX) under .repro/build/hello/.
      var sawWrapperOutput = false
      let expectedName =
        when defined(windows): "hello.cmd"
        else: "hello"
      for wrapper in wrapperActions:
        for outPath in wrapper.outputs:
          let unified = outPath.replace('\\', '/')
          if unified.contains("/.repro/build/hello/") and
              unified.endsWith("/" & expectedName):
            sawWrapperOutput = true
      check sawWrapperOutput

      # The escriptize action's outputs include the produced escript.
      var sawEscriptOutput = false
      for outPath in escriptizeAct.outputs:
        let unified = outPath.replace('\\', '/')
        if unified.contains("/_build/default/bin/hello"):
          sawEscriptOutput = true
      check sawEscriptOutput

  test "emitFragment: wrapper depends on escriptize action (chained ordering)":
    if not erlangToolchainReady():
      skip()
    elif not fileExists(HelloBinaryFixture / "rebar.config"):
      skip()
    else:
      let conv = erlang_convention.erlangRebar3Convention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var escriptizeActionId = ""
      var wrapperAction: BuildActionDef
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("erlang-rebar3-escriptize-"):
          escriptizeActionId = action.id
        elif action.id.startsWith("erlang-rebar3-wrapper-"):
          wrapperAction = action

      check escriptizeActionId.len > 0

      # The wrapper must list the escriptize action in its deps so the
      # produced escript exists by the time the launcher fires.
      var sawEscriptizeDep = false
      for dep in wrapperAction.deps:
        if dep == escriptizeActionId:
          sawEscriptizeDep = true
      check sawEscriptizeDep

  test "output-path resolution: predicted wrapper layout":
    ## Exercise the wrapper-path predictor against a fixed project
    ## root. This is a pure function — no toolchain needed.
    let projectRoot = "/some/project"
    let predicted = erlang_convention.producedWrapperPath(projectRoot,
      exeName = "hello")
    let unified = predicted.replace('\\', '/')
    let expectedSuffix =
      when defined(windows):
        "/some/project/.repro/build/hello/hello.cmd"
      else:
        "/some/project/.repro/build/hello/hello"
    check unified == expectedSuffix

  test "output-path resolution: predicted escript layout":
    let projectRoot = "/some/project"
    let escript = erlang_convention.producedEscriptPath(projectRoot, "hello")
    check escript.replace('\\', '/') ==
      "/some/project/_build/default/bin/hello"
    let escriptCmd = erlang_convention.producedEscriptCmdPath(projectRoot,
      "hello")
    check escriptCmd.replace('\\', '/') ==
      "/some/project/_build/default/bin/hello.cmd"

  test "rebar.config + rebar.lock detection helpers":
    let scratch = getTempDir() / "test_erlang_rebar3_helpers"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      removeDir(scratch)
    check not erlang_convention.hasRebarConfig(scratch)
    check not erlang_convention.hasRebarLock(scratch)
    writeFile(scratch / "rebar.config", "{erl_opts, []}.\n")
    check erlang_convention.hasRebarConfig(scratch)
    check not erlang_convention.hasRebarLock(scratch)
    writeFile(scratch / "rebar.lock", "[].\n")
    check erlang_convention.hasRebarLock(scratch)

  test "usesIncludesErlang: accepts erlang / erl / rebar3 tokens":
    ## Direct test of the ``uses:`` parser — no toolchain needed.
    let withErlang = """
import repro_project_dsl

package x:
  uses:
    "erlang"
  executable hello:
    discard
"""
    check erlang_convention.usesIncludesErlang(withErlang)
    let withErl = """
import repro_project_dsl

package x:
  uses:
    "erl"
  executable hello:
    discard
"""
    check erlang_convention.usesIncludesErlang(withErl)
    let withRebar3 = """
import repro_project_dsl

package x:
  uses:
    "rebar3"
  executable hello:
    discard
"""
    check erlang_convention.usesIncludesErlang(withRebar3)
    let withoutErlang = """
import repro_project_dsl

package x:
  uses:
    "python"
  executable hello:
    discard
"""
    check not erlang_convention.usesIncludesErlang(withoutErlang)

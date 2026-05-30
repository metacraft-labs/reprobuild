## M62 verification: Elixir + mix (Tier 2b) language convention.
##
## **Campaign-closing milestone** (M49-M62). Tests against the
## in-tree fixture under
## ``reprobuild-examples/elixir-mix/hello-binary/`` plus scratch
## projects materialised in the test's temp directory. Mirrors the
## test shape of M55 (haskell-cabal), M56 (ruby-bundler), M57
## (php-composer), M60 (crystal), and M61 (erlang-rebar3).
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - elixir AND mix are on PATH
##   * ``recognize`` returns false when:
##     - no ``mix.exs`` is at the root
##     - no ``mix.lock`` is at the root (HARD precondition)
##     - ``rebar.config`` is also at the root (defer to M61
##       erlang-rebar3 convention's territory)
##     - ``uses:`` doesn't list elixir / mix
##     - no executable member is declared
##     - elixir or mix is missing from PATH (toolchain probe failure)
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     elixir/mix missing):
##     - the convention emits a single
##       ``elixir-mix-escript-build-<name>`` action per declared
##       executable.
##     - the escript-build action's argv carries ``mix`` and
##       ``escript.build`` tokens.
##     - the convention also emits one ``elixir-mix-wrapper-<name>``
##       action per declared executable.
##     - the wrapper action's output ends with ``hello.cmd`` (Windows)
##       under ``.repro/build/hello/``.
##   * Output-path resolution:
##     - the predicted wrapper path matches
##       ``<root>/.repro/build/<name>/<name>.cmd`` (Windows) /
##       ``<root>/.repro/build/<name>/<name>`` (POSIX).
##     - the predicted escript path matches
##       ``<root>/<name>`` (mix escript.build emits at the project
##       root, NOT under ``_build/`` like rebar3).
##   * ``hasMixExs`` / ``hasMixLock`` / ``hasRebarConfigForDefer``
##     helpers correctly detect manifest + lockfile + defer condition.
##
## **Toolchain-gated SKIPs**: tests that require the live convention's
## ``recognize`` to fire SKIP cleanly when ``elixir`` or ``mix`` is
## not on PATH. The recognition-negative tests that don't depend on
## the toolchain still exercise the convention's gate-only paths and
## run unconditionally.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/elixir_mix as elixir_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_elixir_mix_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "elixir-mix" / "hello-binary"

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

proc elixirToolchainReady(): bool =
  ## True when BOTH ``elixir`` and ``mix`` are on PATH. The
  ## convention's ``recognize`` enforces this jointly; tests gate on
  ## this and SKIP when either is missing.
  findExe("elixir").len > 0 and findExe("mix").len > 0

suite "elixir-mix convention M62":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = elixir_convention.elixirMixConvention()
    check conv.name == "elixir-mix"
    if not fileExists(HelloBinaryFixture / "mix.exs"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "mix.lock"):
      checkpoint "fixture missing mix.lock"
      fail()
    if not fileExists(HelloBinaryFixture / "lib" / "hello.ex"):
      checkpoint "fixture missing lib/hello.ex"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if elixirToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "elixir/mix toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no mix.exs at root":
    let scratch = getTempDir() / "test_elixir_mix_no_manifest"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "lib")
    writeFile(scratch / "lib" / "hello.ex",
      "defmodule Hello do\n  def main(_), do: :ok\nend\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeElixirNoManifest:\n" &
      "  uses:\n" &
      "    \"elixir\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = elixir_convention.elixirMixConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — mix.exs present but mix.lock missing (HARD precondition)":
    ## M62 spec: ``mix.lock`` is a HARD precondition. The convention
    ## refuses to recognise a project missing it; mix's reproducibility
    ## guarantee depends on the lockfile.
    let scratch = getTempDir() / "test_elixir_mix_no_lockfile"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "lib")
    writeFile(scratch / "mix.exs",
      "defmodule Hello.MixProject do\n  use Mix.Project\n" &
      "  def project, do: [app: :hello, version: \"1.0.0\"]\nend\n")
    # NOTE: deliberately no mix.lock.
    writeFile(scratch / "lib" / "hello.ex",
      "defmodule Hello do\n  def main(_), do: :ok\nend\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeElixirNoLockfile:\n" &
      "  uses:\n" &
      "    \"elixir\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = elixir_convention.elixirMixConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — defers when rebar.config also present (M61's territory)":
    ## M62 defers to M61's erlang-rebar3 convention when rebar.config
    ## is also at the project root. mix can compile rebar deps but a
    ## top-level rebar.config means the project is primarily an
    ## Erlang/rebar3 project.
    let scratch = getTempDir() / "test_elixir_mix_defers_rebar"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "lib")
    writeFile(scratch / "mix.exs",
      "defmodule Hello.MixProject do\n  use Mix.Project\n" &
      "  def project, do: [app: :hello, version: \"1.0.0\"]\nend\n")
    writeFile(scratch / "mix.lock", "%{}\n")
    writeFile(scratch / "rebar.config",
      "{erl_opts, [debug_info]}.\n{deps, []}.\n")
    writeFile(scratch / "lib" / "hello.ex",
      "defmodule Hello do\n  def main(_), do: :ok\nend\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeElixirDefersRebar:\n" &
      "  uses:\n" &
      "    \"elixir\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = elixir_convention.elixirMixConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks elixir/mix":
    let scratch = getTempDir() / "test_elixir_mix_no_elixir_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "lib")
    writeFile(scratch / "mix.exs",
      "defmodule Hello.MixProject do\n  use Mix.Project\n" &
      "  def project, do: [app: :hello, version: \"1.0.0\"]\nend\n")
    writeFile(scratch / "mix.lock", "%{}\n")
    writeFile(scratch / "lib" / "hello.ex",
      "defmodule Hello do\n  def main(_), do: :ok\nend\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeElixirNoToken:\n" &
      "  uses:\n" &
      "    \"python >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = elixir_convention.elixirMixConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no executable member declared":
    let scratch = getTempDir() / "test_elixir_mix_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "mix.exs",
      "defmodule Hello.MixProject do\n  use Mix.Project\n" &
      "  def project, do: [app: :hello, version: \"1.0.0\"]\nend\n")
    writeFile(scratch / "mix.lock", "%{}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeElixirNoMember:\n" &
      "  uses:\n" &
      "    \"elixir\"\n")
    defer:
      removeDir(scratch)
    let conv = elixir_convention.elixirMixConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — elixir/mix not on PATH (toolchain probe)":
    ## When ``elixir`` or ``mix`` is missing from PATH the convention's
    ## recognise must return false. This test asserts only when the
    ## toolchain is ACTUALLY missing — when both ARE installed, skip
    ## rather than hand-wave the gate.
    if elixirToolchainReady():
      skip()
    else:
      let scratch = getTempDir() / "test_elixir_mix_no_toolchain"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "lib")
      writeFile(scratch / "mix.exs",
        "defmodule Hello.MixProject do\n  use Mix.Project\n" &
        "  def project, do: [app: :hello, version: \"1.0.0\"]\nend\n")
      writeFile(scratch / "mix.lock", "%{}\n")
      writeFile(scratch / "lib" / "hello.ex",
        "defmodule Hello do\n  def main(_), do: :ok\nend\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeElixirNoToolchain:\n" &
        "  uses:\n" &
        "    \"elixir\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = elixir_convention.elixirMixConvention()
      let request = dummyRequest(scratch)
      check not conv.recognize(scratch, request)

  test "recognize: positive — accepts ``mix`` token in uses":
    ## The convention accepts ``elixir`` / ``mix`` as equivalent
    ## ``uses:`` tokens (single-token accept pattern, mirroring
    ## M30 / M56 / M57 / M60 / M61).
    if not elixirToolchainReady():
      skip()
    else:
      let scratch = getTempDir() / "test_elixir_mix_token_mix"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "lib")
      writeFile(scratch / "mix.exs",
        "defmodule Hello.MixProject do\n  use Mix.Project\n" &
        "  def project, do: [app: :hello, version: \"1.0.0\", " &
        "escript: [main_module: Hello]]\nend\n")
      writeFile(scratch / "mix.lock", "%{}\n")
      writeFile(scratch / "lib" / "hello.ex",
        "defmodule Hello do\n  def main(_), do: :ok\nend\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeElixirMixToken:\n" &
        "  uses:\n" &
        "    \"mix\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = elixir_convention.elixirMixConvention()
      let request = dummyRequest(scratch)
      check conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces escript-build + wrapper actions":
    if not elixirToolchainReady():
      skip()
    elif not fileExists(HelloBinaryFixture / "mix.exs"):
      skip()
    else:
      let conv = elixir_convention.elixirMixConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var buildActions: seq[BuildActionDef] = @[]
      var wrapperActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("elixir-mix-escript-build-"):
          buildActions.add(action)
        elif action.id.startsWith("elixir-mix-wrapper-"):
          wrapperActions.add(action)

      check buildActions.len >= 1
      check wrapperActions.len >= 1
      let buildAct = buildActions[0]
      check buildAct.pool == "compile"

      # The escript-build argv must carry the mix + escript.build
      # tokens.
      let argv = inlineArgvOf(buildAct)
      let joined = argv.join(" ")
      check joined.contains("mix") or joined.contains("mix.bat") or
        joined.contains("mix.exe")
      check joined.contains("escript.build")

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

      # The escript-build action's outputs include the produced
      # escript (at the project root, NOT under _build/).
      var sawEscriptOutput = false
      for outPath in buildAct.outputs:
        let unified = outPath.replace('\\', '/')
        if unified.endsWith("/hello"):
          sawEscriptOutput = true
      check sawEscriptOutput

  test "emitFragment: wrapper depends on escript-build action (chained ordering)":
    if not elixirToolchainReady():
      skip()
    elif not fileExists(HelloBinaryFixture / "mix.exs"):
      skip()
    else:
      let conv = elixir_convention.elixirMixConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var buildActionId = ""
      var wrapperAction: BuildActionDef
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("elixir-mix-escript-build-"):
          buildActionId = action.id
        elif action.id.startsWith("elixir-mix-wrapper-"):
          wrapperAction = action

      check buildActionId.len > 0

      # The wrapper must list the escript-build action in its deps
      # so the produced escript exists by the time the launcher fires.
      var sawBuildDep = false
      for dep in wrapperAction.deps:
        if dep == buildActionId:
          sawBuildDep = true
      check sawBuildDep

  test "output-path resolution: predicted wrapper layout":
    ## Exercise the wrapper-path predictor against a fixed project
    ## root. This is a pure function — no toolchain needed.
    let projectRoot = "/some/project"
    let predicted = elixir_convention.producedWrapperPath(projectRoot,
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
    let escript = elixir_convention.producedEscriptPath(projectRoot, "hello")
    check escript.replace('\\', '/') == "/some/project/hello"

  test "mix.exs + mix.lock + rebar.config detection helpers":
    let scratch = getTempDir() / "test_elixir_mix_helpers"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      removeDir(scratch)
    check not elixir_convention.hasMixExs(scratch)
    check not elixir_convention.hasMixLock(scratch)
    check not elixir_convention.hasRebarConfigForDefer(scratch)
    writeFile(scratch / "mix.exs",
      "defmodule X.MixProject do\n  use Mix.Project\nend\n")
    check elixir_convention.hasMixExs(scratch)
    check not elixir_convention.hasMixLock(scratch)
    writeFile(scratch / "mix.lock", "%{}\n")
    check elixir_convention.hasMixLock(scratch)
    check not elixir_convention.hasRebarConfigForDefer(scratch)
    writeFile(scratch / "rebar.config", "{erl_opts, []}.\n")
    check elixir_convention.hasRebarConfigForDefer(scratch)

  test "usesIncludesElixir: accepts elixir / mix tokens":
    ## Direct test of the ``uses:`` parser — no toolchain needed.
    let withElixir = """
import repro_project_dsl

package x:
  uses:
    "elixir"
  executable hello:
    discard
"""
    check elixir_convention.usesIncludesElixir(withElixir)
    let withMix = """
import repro_project_dsl

package x:
  uses:
    "mix"
  executable hello:
    discard
"""
    check elixir_convention.usesIncludesElixir(withMix)
    let withoutElixir = """
import repro_project_dsl

package x:
  uses:
    "python"
  executable hello:
    discard
"""
    check not elixir_convention.usesIncludesElixir(withoutElixir)

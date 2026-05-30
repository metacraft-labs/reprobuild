## M56 verification: Ruby + Bundler (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/ruby-bundler/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - ruby AND bundle are on PATH
##   * ``recognize`` returns false when:
##     - no ``Gemfile`` is at the root
##     - no ``Gemfile.lock`` is at the root (HARD precondition)
##     - ``uses:`` doesn't list ruby / bundler
##     - no executable member is declared
##     - ruby or bundle is missing from PATH (toolchain probe failure)
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     ruby/bundle missing):
##     - the convention emits a single ``ruby-bundler-install`` action.
##     - the install action's argv carries ``bundle install
##       --deployment --local --quiet --path vendor/bundle`` tokens.
##     - the convention also emits one ``ruby-bundler-wrapper-<name>``
##       action per declared executable.
##     - the wrapper action's output ends with ``hello.cmd`` (Windows)
##       under ``.repro/build/hello/`` plus the project root prefix.
##   * Output-path resolution:
##     - the predicted wrapper path matches
##       ``<root>/.repro/build/<name>/<name>.cmd``.
##     - the predicted sentinel path matches
##       ``<root>/vendor/bundle/.repro-bundle-stamp``.
##     - the predicted entry script path matches
##       ``<root>/bin/<name>.rb``.
##
## **Toolchain-gated SKIPs**: tests that require the live convention's
## ``recognize`` to fire SKIP cleanly when ``ruby`` or ``bundle`` is
## not on PATH (which is the M56 default on Windows — Ruby isn't in
## the standard dev shell). The recognition-negative tests that don't
## depend on the toolchain still exercise the convention's gate-only
## paths and run unconditionally.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/ruby_bundler as ruby_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_ruby_bundler_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "ruby-bundler" / "hello-binary"

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

proc rubyToolchainReady(): bool =
  ## True when BOTH ``ruby`` and ``bundle`` are on PATH. The
  ## convention's ``recognize`` enforces this jointly; tests gate on
  ## this and SKIP when either is missing.
  findExe("ruby").len > 0 and findExe("bundle").len > 0

suite "ruby-bundler convention M56":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = ruby_convention.rubyBundlerConvention()
    check conv.name == "ruby-bundler"
    if not fileExists(HelloBinaryFixture / "Gemfile"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "Gemfile.lock"):
      checkpoint "fixture missing Gemfile.lock"
      fail()
    if not fileExists(HelloBinaryFixture / "bin" / "hello.rb"):
      checkpoint "fixture missing bin/hello.rb"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if rubyToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "ruby/bundle toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no Gemfile at root":
    let scratch = getTempDir() / "test_ruby_bundler_no_manifest"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "bin")
    writeFile(scratch / "bin" / "hello.rb",
      "#!/usr/bin/env ruby\nputs \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRubyNoManifest:\n" &
      "  uses:\n" &
      "    \"ruby >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = ruby_convention.rubyBundlerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — Gemfile present but Gemfile.lock missing (HARD precondition)":
    ## M56 spec: ``Gemfile.lock`` is a HARD precondition. The
    ## convention refuses to recognise a project missing it; the
    ## ``--deployment`` mode's strict-lockfile guarantee depends on
    ## the lockfile.
    let scratch = getTempDir() / "test_ruby_bundler_no_lockfile"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "bin")
    writeFile(scratch / "Gemfile",
      "source 'https://rubygems.org'\nruby '>= 3.0'\n")
    # NOTE: deliberately no Gemfile.lock.
    writeFile(scratch / "bin" / "hello.rb",
      "#!/usr/bin/env ruby\nputs \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRubyNoLockfile:\n" &
      "  uses:\n" &
      "    \"ruby >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = ruby_convention.rubyBundlerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks ruby/bundler":
    let scratch = getTempDir() / "test_ruby_bundler_no_ruby_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "bin")
    writeFile(scratch / "Gemfile",
      "source 'https://rubygems.org'\nruby '>= 3.0'\n")
    writeFile(scratch / "Gemfile.lock",
      "GEM\nPLATFORMS\n  ruby\nDEPENDENCIES\nBUNDLED WITH\n   2.5.18\n")
    writeFile(scratch / "bin" / "hello.rb",
      "#!/usr/bin/env ruby\nputs \"hi\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRubyNoToken:\n" &
      "  uses:\n" &
      "    \"python >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = ruby_convention.rubyBundlerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no executable member declared":
    let scratch = getTempDir() / "test_ruby_bundler_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Gemfile",
      "source 'https://rubygems.org'\nruby '>= 3.0'\n")
    writeFile(scratch / "Gemfile.lock",
      "GEM\nPLATFORMS\n  ruby\nDEPENDENCIES\nBUNDLED WITH\n   2.5.18\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeRubyNoMember:\n" &
      "  uses:\n" &
      "    \"ruby >=3.0\"\n")
    defer:
      removeDir(scratch)
    let conv = ruby_convention.rubyBundlerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — ruby/bundle not on PATH (toolchain probe)":
    ## When ``ruby`` or ``bundle`` is missing from PATH the
    ## convention's recognise must return false. This test asserts
    ## only when the toolchain is ACTUALLY missing — when both ARE
    ## installed, skip rather than hand-wave the gate.
    if rubyToolchainReady():
      skip()
    else:
      let scratch = getTempDir() / "test_ruby_bundler_no_toolchain"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "bin")
      writeFile(scratch / "Gemfile",
        "source 'https://rubygems.org'\nruby '>= 3.0'\n")
      writeFile(scratch / "Gemfile.lock",
        "GEM\nPLATFORMS\n  ruby\nDEPENDENCIES\nBUNDLED WITH\n   2.5.18\n")
      writeFile(scratch / "bin" / "hello.rb",
        "#!/usr/bin/env ruby\nputs \"hi\"\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeRubyNoToolchain:\n" &
        "  uses:\n" &
        "    \"ruby >=3.0\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = ruby_convention.rubyBundlerConvention()
      let request = dummyRequest(scratch)
      check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces install + wrapper actions":
    if not rubyToolchainReady():
      skip()
    else:
      let conv = ruby_convention.rubyBundlerConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var installActions: seq[BuildActionDef] = @[]
      var wrapperActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ruby-bundler-install":
          installActions.add(action)
        elif action.id.startsWith("ruby-bundler-wrapper-"):
          wrapperActions.add(action)

      check installActions.len == 1
      check wrapperActions.len >= 1
      let installAct = installActions[0]
      check installAct.pool == "compile"

      # The install action's argv (wrapped in cmd /c or sh -c) must
      # carry the bundle install + --deployment + --local tokens.
      let argv = inlineArgvOf(installAct)
      let joined = argv.join(" ")
      check joined.contains("bundle")
      check joined.contains("install")
      check joined.contains("--deployment")
      check joined.contains("--local")

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

  test "output-path resolution: predicted wrapper layout":
    ## Exercise the wrapper-path predictor against a fixed project
    ## root. This is a pure function — no toolchain needed.
    let projectRoot = "/some/project"
    let predicted = ruby_convention.producedWrapperPath(projectRoot,
      exeName = "hello")
    let unified = predicted.replace('\\', '/')
    let expectedSuffix =
      when defined(windows):
        "/some/project/.repro/build/hello/hello.cmd"
      else:
        "/some/project/.repro/build/hello/hello"
    check unified == expectedSuffix

  test "output-path resolution: sentinel + entry-script paths":
    let projectRoot = "/some/project"
    let sentinel = ruby_convention.producedSentinelPath(projectRoot)
    let entry = ruby_convention.entryScriptPath(projectRoot, "hello")
    check sentinel.replace('\\', '/') ==
      "/some/project/vendor/bundle/.repro-bundle-stamp"
    check entry.replace('\\', '/') ==
      "/some/project/bin/hello.rb"

  test "Gemfile + Gemfile.lock detection helpers":
    let scratch = getTempDir() / "test_ruby_bundler_helpers"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      removeDir(scratch)
    check not ruby_convention.hasGemfile(scratch)
    check not ruby_convention.hasGemfileLock(scratch)
    writeFile(scratch / "Gemfile", "source 'https://rubygems.org'\n")
    check ruby_convention.hasGemfile(scratch)
    check not ruby_convention.hasGemfileLock(scratch)
    writeFile(scratch / "Gemfile.lock", "GEM\n")
    check ruby_convention.hasGemfileLock(scratch)

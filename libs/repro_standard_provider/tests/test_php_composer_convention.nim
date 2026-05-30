## M57 verification: PHP + Composer (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/php-composer/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - php AND composer are on PATH
##   * ``recognize`` returns false when:
##     - no ``composer.json`` is at the root
##     - no ``composer.lock`` is at the root (HARD precondition)
##     - ``uses:`` doesn't list php / composer
##     - no executable member is declared
##     - php or composer is missing from PATH (toolchain probe failure)
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     php/composer missing):
##     - the convention emits a single ``php-composer-install`` action.
##     - the install action's argv carries ``composer install --no-dev
##       --optimize-autoloader --no-progress --quiet`` tokens.
##     - the convention also emits one ``php-composer-wrapper-<name>``
##       action per declared executable.
##     - the wrapper action's output ends with ``hello.cmd`` (Windows)
##       under ``.repro/build/hello/`` plus the project root prefix.
##   * Output-path resolution:
##     - the predicted wrapper path matches
##       ``<root>/.repro/build/<name>/<name>.cmd``.
##     - the predicted sentinel path matches
##       ``<root>/vendor/.repro-composer-stamp``.
##     - the predicted entry script path matches
##       ``<root>/bin/<name>.php``.
##
## **Toolchain-gated SKIPs**: tests that require the live convention's
## ``recognize`` to fire SKIP cleanly when ``php`` or ``composer`` is
## not on PATH (which is the M57 default on Windows — PHP isn't in
## the standard dev shell). The recognition-negative tests that don't
## depend on the toolchain still exercise the convention's gate-only
## paths and run unconditionally.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/php_composer as php_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_php_composer_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to
  ## the sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "php-composer" / "hello-binary"

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

proc phpToolchainReady(): bool =
  ## True when BOTH ``php`` and ``composer`` are on PATH. The
  ## convention's ``recognize`` enforces this jointly; tests gate on
  ## this and SKIP when either is missing.
  findExe("php").len > 0 and findExe("composer").len > 0

suite "php-composer convention M57":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = php_convention.phpComposerConvention()
    check conv.name == "php-composer"
    if not fileExists(HelloBinaryFixture / "composer.json"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "composer.lock"):
      checkpoint "fixture missing composer.lock"
      fail()
    if not fileExists(HelloBinaryFixture / "bin" / "hello.php"):
      checkpoint "fixture missing bin/hello.php"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if phpToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "php/composer toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no composer.json at root":
    let scratch = getTempDir() / "test_php_composer_no_manifest"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "bin")
    writeFile(scratch / "bin" / "hello.php",
      "<?php\necho \"hi\\n\";\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakePhpNoManifest:\n" &
      "  uses:\n" &
      "    \"php >=8.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = php_convention.phpComposerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — composer.json present but composer.lock missing (HARD precondition)":
    ## M57 spec: ``composer.lock`` is a HARD precondition. The
    ## convention refuses to recognise a project missing it; Composer's
    ## strict-lockfile reproducibility guarantee depends on the
    ## lockfile.
    let scratch = getTempDir() / "test_php_composer_no_lockfile"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "bin")
    writeFile(scratch / "composer.json",
      "{\"name\":\"hello/hello\",\"type\":\"project\"}\n")
    # NOTE: deliberately no composer.lock.
    writeFile(scratch / "bin" / "hello.php",
      "<?php\necho \"hi\\n\";\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakePhpNoLockfile:\n" &
      "  uses:\n" &
      "    \"php >=8.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = php_convention.phpComposerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks php/composer":
    let scratch = getTempDir() / "test_php_composer_no_php_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "bin")
    writeFile(scratch / "composer.json",
      "{\"name\":\"hello/hello\",\"type\":\"project\"}\n")
    writeFile(scratch / "composer.lock",
      "{\"_readme\":[],\"packages\":[],\"packages-dev\":[]}\n")
    writeFile(scratch / "bin" / "hello.php",
      "<?php\necho \"hi\\n\";\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakePhpNoToken:\n" &
      "  uses:\n" &
      "    \"python >=3.0\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = php_convention.phpComposerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no executable member declared":
    let scratch = getTempDir() / "test_php_composer_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "composer.json",
      "{\"name\":\"hello/hello\",\"type\":\"project\"}\n")
    writeFile(scratch / "composer.lock",
      "{\"_readme\":[],\"packages\":[],\"packages-dev\":[]}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakePhpNoMember:\n" &
      "  uses:\n" &
      "    \"php >=8.0\"\n")
    defer:
      removeDir(scratch)
    let conv = php_convention.phpComposerConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — php/composer not on PATH (toolchain probe)":
    ## When ``php`` or ``composer`` is missing from PATH the
    ## convention's recognise must return false. This test asserts
    ## only when the toolchain is ACTUALLY missing — when both ARE
    ## installed, skip rather than hand-wave the gate.
    if phpToolchainReady():
      skip()
    else:
      let scratch = getTempDir() / "test_php_composer_no_toolchain"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "bin")
      writeFile(scratch / "composer.json",
        "{\"name\":\"hello/hello\",\"type\":\"project\"}\n")
      writeFile(scratch / "composer.lock",
        "{\"_readme\":[],\"packages\":[],\"packages-dev\":[]}\n")
      writeFile(scratch / "bin" / "hello.php",
        "<?php\necho \"hi\\n\";\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakePhpNoToolchain:\n" &
        "  uses:\n" &
        "    \"php >=8.0\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = php_convention.phpComposerConvention()
      let request = dummyRequest(scratch)
      check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces install + wrapper actions":
    if not phpToolchainReady():
      skip()
    else:
      let conv = php_convention.phpComposerConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var installActions: seq[BuildActionDef] = @[]
      var wrapperActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "php-composer-install":
          installActions.add(action)
        elif action.id.startsWith("php-composer-wrapper-"):
          wrapperActions.add(action)

      check installActions.len == 1
      check wrapperActions.len >= 1
      let installAct = installActions[0]
      check installAct.pool == "compile"

      # The install action's argv (wrapped in cmd /c or sh -c) must
      # carry the composer install + --no-dev + --optimize-autoloader
      # tokens.
      let argv = inlineArgvOf(installAct)
      let joined = argv.join(" ")
      check joined.contains("composer")
      check joined.contains("install")
      check joined.contains("--no-dev")
      check joined.contains("--optimize-autoloader")

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
    let predicted = php_convention.producedWrapperPath(projectRoot,
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
    let sentinel = php_convention.producedSentinelPath(projectRoot)
    let entry = php_convention.entryScriptPath(projectRoot, "hello")
    check sentinel.replace('\\', '/') ==
      "/some/project/vendor/.repro-composer-stamp"
    check entry.replace('\\', '/') ==
      "/some/project/bin/hello.php"

  test "composer.json + composer.lock detection helpers":
    let scratch = getTempDir() / "test_php_composer_helpers"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      removeDir(scratch)
    check not php_convention.hasComposerJson(scratch)
    check not php_convention.hasComposerLock(scratch)
    writeFile(scratch / "composer.json", "{}\n")
    check php_convention.hasComposerJson(scratch)
    check not php_convention.hasComposerLock(scratch)
    writeFile(scratch / "composer.lock", "{}\n")
    check php_convention.hasComposerLock(scratch)

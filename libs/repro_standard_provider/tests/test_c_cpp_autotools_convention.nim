## M17 / M28 verification: C/C++ Autotools language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/c-cpp-autotools/``:
##
##   * ``c-cpp-autotools/hello-binary`` — single ``executable hello``
##                                        built via the M28 per-source
##                                        lift (per-source ``gcc -c`` +
##                                        ``gcc -o`` link, configure
##                                        action retained as a
##                                        prerequisite).
##
## Negative recognise cases are materialised as tiny scratch projects
## under the test's temp directory so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - autoreconf / autoconf / automake are on PATH (or a checked-in
##       ``configure`` script is present)
##     - ``make`` (or ``mingw32-make`` on Windows) is on PATH
##     - ``sh`` is on PATH
##     - a C compiler is on PATH
##   * ``recognize`` returns false when:
##     - ``configure.ac`` is absent
##     - ``Makefile.am`` is absent
##     - ``uses:`` doesn't list autoconf + compiler + make
##     - no executable / library member is declared
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     any required tool is missing):
##     - the convention emits a ``ccpp-autotools-configure`` action.
##     - M28: at least one ``ccpp-autotools-compile-*`` per-source
##       action is present.
##     - M28: a ``ccpp-autotools-link-hello`` link action is present,
##       its ``deps`` list contains every compile action id, and the
##       compile actions depend on the configure action.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/c_cpp_autotools as autotools_convention

const
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "c-cpp-autotools" / "hello-binary"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc findExeAnyExt(exe: string): string =
  ## Mirror of the convention's findExeAnyExt: stock findExe with a
  ## fallback extensionless probe so MSYS2's POSIX shell scripts
  ## (autoreconf, automake) resolve on Windows.
  if exe.len == 0:
    return ""
  let stock = findExe(exe)
  if stock.len > 0:
    return stock
  when defined(windows):
    for candidate in getEnv("PATH").split(';'):
      let stripped = candidate.strip(chars = {' ', '"'})
      if stripped.len == 0:
        continue
      let probe = stripped / exe
      if fileExists(probe):
        return probe
  return ""

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc autotoolsAvailable(projectRoot: string): bool =
  ## True when every tool the convention demands at recognise time is
  ## present. ``autoreconf`` is only required when no ``configure`` is
  ## checked in.
  if findExe("gcc").len == 0 and findExe("clang").len == 0:
    return false
  let makeExe = findExe("make")
  let mingwMake = when defined(windows): findExe("mingw32-make") else: ""
  if makeExe.len == 0 and mingwMake.len == 0:
    return false
  if findExe("sh").len == 0:
    return false
  if not fileExists(projectRoot / "configure"):
    if findExeAnyExt("autoreconf").len == 0:
      return false
  true

suite "c-cpp-autotools convention M17":

  test "recognize: positive — hello-binary fixture (declaration-only)":
    # M9.N: recognise claims a recipe based on DECLARATION (configure.ac
    # + Makefile.am at projectRoot + uses: autotools tokens +
    # executable/library member + per-source resolution), NOT host PATH
    # availability. Tool identity is resolved AFTER recognise by the
    # engine.
    let conv = autotools_convention.cCppAutotoolsConvention()
    check conv.name == "c-cpp-autotools"
    if not fileExists(HelloBinaryFixture / "configure.ac"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    check conv.recognize(HelloBinaryFixture, request)

  test "recognize: returns true even without autotools on PATH (M9.N)":
    # M9.N architectural correction: explicit assertion that the
    # host-PATH gate has been dropped from recognise — the convention
    # claims the recipe regardless of whether gcc/make/sh/autoreconf
    # resolve.
    let conv = autotools_convention.cCppAutotoolsConvention()
    if not fileExists(HelloBinaryFixture / "configure.ac"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    let gccOnPath = findExe("gcc").len > 0
    let makeOnPath = findExe("make").len > 0
    let autoreconfOnPath = findExeAnyExt("autoreconf").len > 0
    checkpoint "gcc on PATH: " & $gccOnPath &
      ", make on PATH: " & $makeOnPath &
      ", autoreconf on PATH: " & $autoreconfOnPath
    check conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — configure.ac missing":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_configure_ac"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsNoAc:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — Makefile.am missing":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_makefile_am"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-pkg], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsNoAm:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks autoconf":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_autoconf_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-pkg], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsNoAuto:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-pkg], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am", "\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package emptyAutotools:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "    \"make >=4\"\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: M28 per-source lift (configure + compile(s) + link)":
    if not autotoolsAvailable(HelloBinaryFixture):
      skip()
    else:
      let conv = autotools_convention.cCppAutotoolsConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var configureAction: BuildActionDef
      var linkAction: BuildActionDef
      var compileActions: seq[BuildActionDef] = @[]
      var sawConfigure = false
      var sawLink = false
      var sawCoarseMake = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ccpp-autotools-configure":
          configureAction = action
          sawConfigure = true
        elif action.id.startsWith("ccpp-autotools-compile-"):
          compileActions.add(action)
        elif action.id.startsWith("ccpp-autotools-link-"):
          linkAction = action
          sawLink = true
        elif action.id == "ccpp-autotools-build":
          # M28 retires the coarse ``ccpp-autotools-build`` action.
          # Catching it here fails the test loudly so a regression is
          # easy to spot.
          sawCoarseMake = true

      check sawConfigure
      check compileActions.len >= 1
      check sawLink
      check not sawCoarseMake
      check configureAction.pool == "compile"
      check linkAction.pool == "compile"
      # Every compile action must depend on configure (so a stale
      # configure forces a recompile) and the link action must depend on
      # every compile action (full per-source DAG).
      for compileAction in compileActions:
        check configureAction.id in compileAction.deps
        check compileAction.id in linkAction.deps
      # The hello-binary fixture's Makefile.am declares
      # ``hello_SOURCES = src/main.c`` — exactly one .c source. The
      # convention should produce exactly one compile action.
      check compileActions.len == 1

  test "M9.K: configureFlags appear in ./configure invocation":
    # DSL-port M9.K: when the M9.I registry holds configureFlags for
    # the DSL package, ``emitFragment`` must inject them into the
    # ``./configure ...`` invocation inside the sh -c wrapper.
    if not autotoolsAvailable(HelloBinaryFixture):
      skip()
    else:
      # Read the fixture's recipe to pull the DSL package name so the
      # M9.K lookup key matches.
      let recipePath = HelloBinaryFixture / "reprobuild.nim"
      let recipeSrc = if fileExists(recipePath): readFile(recipePath) else: ""
      var pkgName = ""
      for rawLine in recipeSrc.splitLines():
        let stripped = rawLine.strip()
        if stripped.startsWith("package"):
          let rest = stripped[len("package") .. ^1].strip()
          for ch in rest:
            if ch in {' ', '\t', ':', ','}: break
            pkgName.add(ch)
          if pkgName.len > 0:
            break
      check pkgName.len > 0
      resetDslPortBuildFlagState()
      registerBuildFlag(pkgName, "", "configure", "--with-foo")
      registerBuildFlag(pkgName, "", "configure", "--enable-bar")
      defer:
        resetDslPortBuildFlagState()
      let conv = autotools_convention.cCppAutotoolsConvention()
      let request = dummyRequest(HelloBinaryFixture)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)
      var sawWithFoo = false
      var sawEnableBar = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id != "ccpp-autotools-configure":
          continue
        let argvJoined = inlineArgvOf(action).join(" ")
        if argvJoined.contains("--with-foo"):
          sawWithFoo = true
        if argvJoined.contains("--enable-bar"):
          sawEnableBar = true
      check sawWithFoo
      check sawEnableBar

  test "emitFragment: build actions carry toolIdentityRefs (M9.N Batch B)":
    # M9.N Batch B: every action stamps the catalog tool refs the
    # engine resolves at fork time. The assertion runs regardless of
    # whether the host has autotools / gcc installed because the
    # convention's new ``toolIdentityRefs`` are pure compile-time
    # tags. The configure action references autoreconf+make+gcc+sh;
    # compile actions reference gcc; link references gcc; archive
    # references ar.
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(HelloBinaryFixture)
    require conv.recognize(HelloBinaryFixture, request)
    let fragment = conv.emitFragment(HelloBinaryFixture, request)
    var sawConfigureRefs = false
    var sawCompileRefs = false
    var sawLinkRefs = false
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      if action.id == "ccpp-autotools-configure":
        check "autoreconf" in action.toolIdentityRefs
        check "make" in action.toolIdentityRefs
        check "gcc" in action.toolIdentityRefs
        check "sh" in action.toolIdentityRefs
        sawConfigureRefs = true
      elif action.id.startsWith("ccpp-autotools-compile-"):
        check "gcc" in action.toolIdentityRefs
        sawCompileRefs = true
      elif action.id.startsWith("ccpp-autotools-link-"):
        check "gcc" in action.toolIdentityRefs
        sawLinkRefs = true
    check sawConfigureRefs
    check sawCompileRefs
    check sawLinkRefs

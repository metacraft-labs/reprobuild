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

  test "M9.K: configureFlags injection retired (M9.R.6.1)":
    # M9.R.6.1 (2026-06-19): the ``registeredBuildFlags`` runtime
    # registry + the ``configureFlags:`` parser arm were retired.
    # Recipes route per-tool options through their explicit ``build:``
    # body calling ``autotools_package(...)`` directly. This assertion
    # documents the retirement at compile time.
    check not compiles((proc (): seq[string] =
      result = registeredBuildFlags("autotoolsPkg", "", "configure"))())

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

# ---------------------------------------------------------------------------
# Mode B — crude fallback (delegation)
#
# Grounded in C-Cpp-Autotools.md §"Triggers that escape to Mode B"
# (lines ~113-120) and §"Mode B — Crude fallback (delegation)"
# (lines ~121-137).
# ---------------------------------------------------------------------------

proc actionById(fragment: GraphFragment; id: string):
    tuple[found: bool; action: BuildActionDef] =
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    if action.id == id:
      return (true, action)
  (false, BuildActionDef())

proc writeGnulibProject(scratch, packageName: string) =
  ## Materialise a tiny gnulib-shaped autotools project: a checked-in
  ## ``configure`` script (released-tarball shape) + a ``Makefile.am``
  ## whose constructs (recursive SUBDIRS, noinst_LIBRARIES helper
  ## archive pulled in via _LDADD, automake conditional, custom recipe
  ## rule + ``*-hook`` target) all fire the Mode-B escape triggers per
  ## spec §lines 113-120. This is the shape coreutils / gzip / tar hit.
  if dirExists(scratch):
    removeDir(scratch)
  createDir(scratch)
  createDir(scratch / "src")
  writeFile(scratch / "src" / "main.c",
    "#include <stdio.h>\nint main(void){return 0;}\n")
  # A checked-in (released-tarball) configure script so the convention
  # picks the released shape and Mode B's ``needAutoreconf`` is false.
  writeFile(scratch / "configure",
    "#!/bin/sh\n# fake configure\nexit 0\n")
  setFilePermissions(scratch / "configure",
    {fpUserExec, fpUserRead, fpUserWrite, fpGroupExec, fpGroupRead,
     fpOthersExec, fpOthersRead})
  writeFile(scratch / "configure.ac",
    "AC_INIT([" & packageName & "], [1.0])\nAC_OUTPUT\n")
  writeFile(scratch / "Makefile.am", """
# gnulib-shaped Makefile.am — every block below is a Mode-A escape
# trigger per C-Cpp-Autotools.md §lines 113-120.
SUBDIRS = lib doc . tests
AM_CPPFLAGS = -I$(top_srcdir)/lib

noinst_LIBRARIES = libver.a
nodist_libver_a_SOURCES = version.c

if LESS
ZLESS_PROG = zless
else
ZLESS_PROG =
endif

bin_PROGRAMS = hello
hello_SOURCES = src/main.c
hello_LDADD = libver.a lib/libgnu.a

# Custom recipe rule — Mode A cannot model this.
version.c: Makefile
	printf 'char const *V = "1";\n' > $@

# *-hook target — explicit escape trigger (spec line 116).
install-exec-hook:
	@echo installed
""")
  writeFile(scratch / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package " & packageName & ":\n" &
    "  uses:\n" &
    "    \"gcc >=11\"\n" &
    "    \"autoconf >=2.71\"\n" &
    "    \"automake >=1.16\"\n" &
    "    \"make >=4\"\n" &
    "\n" &
    "  executable hello:\n" &
    "    discard\n")

suite "c-cpp-autotools convention — Mode B (crude fallback)":

  test "detectModeBTrigger: gnulib SUBDIRS fires (spec §line 115-116)":
    # A recursive ``SUBDIRS`` naming a real sub-dir is the gnulib
    # sub-archive signature: ``lib/libgnu.a`` is built in a sub-dir Mode
    # A never descends into.
    check autotools_convention.detectModeBTrigger(
      "SUBDIRS = lib doc . tests\nbin_PROGRAMS = hello\n")
    # A bare ``SUBDIRS = .`` (current dir only) is NOT recursive.
    check not autotools_convention.detectModeBTrigger(
      "SUBDIRS = .\nbin_PROGRAMS = hello\nhello_SOURCES = a.c\n")

  test "detectModeBTrigger: helper-archive _LDADD fires (spec §line 113-120)":
    check autotools_convention.detectModeBTrigger(
      "bin_PROGRAMS = hello\nhello_SOURCES = a.c\n" &
      "hello_LDADD = lib/libgnu.a\n")
    check autotools_convention.detectModeBTrigger(
      "noinst_LIBRARIES = libver.a\nbin_PROGRAMS = hello\n")

  test "detectModeBTrigger: automake conditional fires (spec §line 118)":
    check autotools_convention.detectModeBTrigger(
      "bin_PROGRAMS = hello\nhello_SOURCES = a.c\n" &
      "if LESS\nZLESS = z\nelse\nZLESS =\nendif\n")

  test "detectModeBTrigger: custom recipe + *-hook fire (spec §line 115-116)":
    check autotools_convention.detectModeBTrigger(
      "bin_PROGRAMS = hello\nhello_SOURCES = a.c\n" &
      "version.c: Makefile\n\tprintf x > $@\n")
    check autotools_convention.detectModeBTrigger(
      "bin_PROGRAMS = hello\nhello_SOURCES = a.c\n" &
      "install-exec-hook:\n\t@echo hi\n")
    check autotools_convention.detectModeBTrigger(
      "bin_PROGRAMS = hello\nhello_SOURCES = a.c\n" &
      "SUFFIXES = .in\n.in:\n\tcp $< $@\n")

  test "detectModeBTrigger: plain Mode-A Makefile.am does NOT fire":
    # The hello-binary fixture's shape — a straightforward
    # ``<target>_SOURCES`` declaration — must stay on Mode A so Mode B
    # never weakens the per-source path.
    check not autotools_convention.detectModeBTrigger(
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    check not autotools_convention.detectModeBTrigger(
      "lib_LIBRARIES = libgreet.a\nlibgreet_a_SOURCES = src/greet.c\n")

  test "recognize: a gnulib-shaped project is accepted (routes to Mode B)":
    let scratch = getTempDir() / "test_c_cpp_autotools_modeb_recognize"
    writeGnulibProject(scratch, "gnulibPkg")
    defer: removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    # Recognition must accept even though the gnulib ``Makefile.am``
    # would defeat Mode A's strict per-source resolution.
    check conv.recognize(scratch, request)

  test "emitFragment: Mode B emits configure/make/make-install per spec":
    let scratch = getTempDir() / "test_c_cpp_autotools_modeb_emit"
    writeGnulibProject(scratch, "gnulibEmitPkg")
    defer: removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    require conv.recognize(scratch, request)
    let fragment = conv.emitFragment(scratch, request)

    # The three Mode-B actions are present and the Mode-A per-source
    # actions are NOT (delegation replaces the fine-grained DAG).
    let configure = actionById(fragment, "ccpp-autotools-modeb-configure")
    let make = actionById(fragment, "ccpp-autotools-modeb-make")
    let install = actionById(fragment, "ccpp-autotools-modeb-install")
    check configure.found
    check make.found
    check install.found
    # Mode A actions must be absent.
    check not actionById(fragment, "ccpp-autotools-configure").found
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      check not action.id.startsWith("ccpp-autotools-compile-")
      check not action.id.startsWith("ccpp-autotools-link-")

    # Configure argv — ``<pkg>/configure --prefix=/
    # --disable-dependency-tracking`` (spec §lines 127-129), out-of-tree
    # (``mkdir -p _build && cd _build``, spec line 37).
    let configureArgv = inlineArgvOf(configure.action)
    check configureArgv.len == 3
    check configureArgv[0].endsWith("sh") or configureArgv[0] == "sh"
    check configureArgv[1] == "-c"
    let configureScript = configureArgv[2]
    check "--prefix=/" in configureScript
    check "--disable-dependency-tracking" in configureScript
    check "/configure" in configureScript
    check "mkdir -p" in configureScript
    check "_build" in configureScript

    # make argv — ``make -C <build> -j<n>`` (spec line 130).
    let makeArgv = inlineArgvOf(make.action)
    check makeArgv.len >= 3
    check makeArgv[0].endsWith("make") or makeArgv[0] == "make"
    check "-C" in makeArgv
    var sawJobs = false
    for a in makeArgv:
      if a.startsWith("-j"):
        sawJobs = true
    check sawJobs

    # install argv — ``make DESTDIR=<stage> install`` (spec line 131).
    let installArgv = inlineArgvOf(install.action)
    check installArgv[0].endsWith("make") or installArgv[0] == "make"
    check "install" in installArgv
    var sawDestdir = false
    var stageRoot = ""
    for a in installArgv:
      if a.startsWith("DESTDIR="):
        sawDestdir = true
        stageRoot = a["DESTDIR=".len .. ^1]
    check sawDestdir

    # Sequencing: configure → make → install.
    check configure.action.id in make.action.deps
    check make.action.id in install.action.deps

  test "emitFragment: Mode B lifts artifacts from <stage>/{bin,lib,include,share}":
    # Spec §lines 136-137: "Artifacts lifted from
    # ``<stage>/{bin,lib,include,share}/``." The install action declares
    # exactly those four sub-trees as outputs so they become the
    # package's artifacts.
    let scratch = getTempDir() / "test_c_cpp_autotools_modeb_stage"
    writeGnulibProject(scratch, "gnulibStagePkg")
    defer: removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    require conv.recognize(scratch, request)
    let fragment = conv.emitFragment(scratch, request)
    let install = actionById(fragment, "ccpp-autotools-modeb-install")
    require install.found
    var sawBin = false
    var sawLib = false
    var sawInclude = false
    var sawShare = false
    for output in install.action.outputs:
      if output.endsWith("/bin") or output.endsWith("\\bin"): sawBin = true
      if output.endsWith("/lib") or output.endsWith("\\lib"): sawLib = true
      if output.endsWith("/include") or output.endsWith("\\include"):
        sawInclude = true
      if output.endsWith("/share") or output.endsWith("\\share"):
        sawShare = true
    check sawBin
    check sawLib
    check sawInclude
    check sawShare
    # Every staged sub-tree lives under the same ``stage`` root.
    for output in install.action.outputs:
      check ("stage" in output) or ("Stage" in output)

  test "emitFragment: Mode B actions are monitored (real dep capture)":
    # Spec line 135: "io-monitor extends." Each Mode-B action runs under
    # the engine monitor (automatic-monitor policy) so the real
    # dependency set is captured rather than degraded to declared-only.
    let scratch = getTempDir() / "test_c_cpp_autotools_modeb_monitor"
    writeGnulibProject(scratch, "gnulibMonPkg")
    defer: removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    require conv.recognize(scratch, request)
    let fragment = conv.emitFragment(scratch, request)
    for id in ["ccpp-autotools-modeb-configure",
               "ccpp-autotools-modeb-make",
               "ccpp-autotools-modeb-install"]:
      let entry = actionById(fragment, id)
      require entry.found
      check entry.action.dependencyPolicy.kind == bdpAutomaticMonitor
      # The build tools are stamped for fork-time PATH resolution.
      check "make" in entry.action.toolIdentityRefs

  test "force Mode B via REPRO_AUTOTOOLS_MODE=B on a plain Mode-A project":
    # The hello-binary fixture is a plain Mode-A shape; setting the
    # force env var must route it to Mode B regardless. This proves the
    # explicit escape hatch (noted for spec clarification) works.
    if not fileExists(HelloBinaryFixture / "configure.ac"):
      skip()
    else:
      putEnv("REPRO_AUTOTOOLS_MODE", "B")
      defer: delEnv("REPRO_AUTOTOOLS_MODE")
      let conv = autotools_convention.cCppAutotoolsConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)
      check actionById(fragment, "ccpp-autotools-modeb-configure").found
      check actionById(fragment, "ccpp-autotools-modeb-make").found
      check actionById(fragment, "ccpp-autotools-modeb-install").found
      # Mode A actions must NOT be present under the force.
      check not actionById(fragment, "ccpp-autotools-configure").found

  test "Mode A still selected for a plain Makefile.am project (no regression)":
    # Without the force env var + with a plain ``<target>_SOURCES``
    # Makefile.am, the project stays on Mode A — Mode B must not
    # cannibalise the fine-grained path. We materialise a hermetic
    # released-tarball-shape project (committed ``configure``) so the
    # emit path runs without needing autoreconf/gcc on the host (the
    # emit only inspects the fragment, it does not run the build).
    delEnv("REPRO_AUTOTOOLS_MODE")
    let scratch = getTempDir() / "test_c_cpp_autotools_modea_noregress"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "configure",
      "#!/bin/sh\nexit 0\n")
    setFilePermissions(scratch / "configure",
      {fpUserExec, fpUserRead, fpUserWrite, fpGroupExec, fpGroupRead,
       fpOthersExec, fpOthersRead})
    writeFile(scratch / "configure.ac",
      "AC_INIT([plainpkg], [1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package plainModeAPkg:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer: removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    require conv.recognize(scratch, request)
    let fragment = conv.emitFragment(scratch, request)
    # Mode A actions present, Mode B actions absent.
    check actionById(fragment, "ccpp-autotools-configure").found
    check actionById(fragment, "ccpp-autotools-link-hello").found
    check not actionById(fragment, "ccpp-autotools-modeb-configure").found
    check not actionById(fragment, "ccpp-autotools-modeb-make").found

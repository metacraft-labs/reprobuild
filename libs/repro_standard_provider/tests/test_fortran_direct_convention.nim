## Verification for the fortran-direct (Mode 3) language convention
## (M37).
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture (gfortran on
##     PATH, ``uses: gfortran``, members resolve).
##   * ``recognize`` returns false when ``uses:`` lacks ``gfortran`` /
##     ``fortran``.
##   * ``emitFragment`` against the pure-Fortran fixture emits per-
##     source ``gfortran -c`` compile actions, an ``ar rcs`` archive
##     action for the library, and a ``gfortran -o`` link action for
##     the executable with the archive on inputs/argv/deps.
##   * Forward cross-language: a Fortran binary depends on a C library
##     — the convention emits both directions' actions and threads the
##     C archive onto the gfortran link.
##   * Reverse cross-language: a C++ binary depends on a Fortran
##     library — the convention emits the Fortran archive AND the C++
##     binary's per-source compile + terminal link with
##     ``-lgfortran``-and-friends runtime injection.
##   * cycle detection: a scratch fixture with cross-package cycles
##     rejects with a descriptive ValueError.
##   * undeclared-dep detection: a depends_on references an undeclared
##     package — rejected.
##   * cConsumable toggle: the Fortran library member is flagged
##     ``cConsumable`` when (and only when) a C/C++ executable in the
##     workspace depends on its package — verified by checking the
##     runtime-libs presence on the C++ link line in the reverse
##     fixture vs absence in the pure-Fortran fixture's link line.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fortran_direct as fortran_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "fortran-mode3" /
      "binary-with-library"
  Mode3MixedForwardFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "fortran-uses-cpp-lib"
  Mode3MixedReverseFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "cpp-uses-fortran-lib"

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

proc gfortranOnPath(): bool =
  findExe("gfortran").len > 0

proc gccOnPath(): bool =
  findExe("gcc").len > 0 or findExe("clang").len > 0

proc gppOnPath(): bool =
  findExe("g++").len > 0 or findExe("clang++").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-fortran-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "fortran-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (gfortran on PATH)":
    if not gfortranOnPath():
      skip()
    else:
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — uses lacks gfortran/fortran":
    let dir = makeScratch("no-fortran-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.f90",
      "program p\nend program\n")
    let conv = fortran_direct_convention.fortranDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — no Fortran members declared":
    if not gfortranOnPath():
      skip()
    else:
      let dir = makeScratch("no-members")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "gfortran"
""")
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(dir)
      check not conv.recognize(dir, request)
      removeDir(dir)

suite "fortran-direct convention emit (Mode 3 fixture)":

  test "emitFragment: per-source compile + archive + link actions":
    if not gfortranOnPath():
      skip()
    else:
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var sawCompileFortlib = false
      var sawArchiveFortlib = false
      var sawLinkFortcalc = false
      var fortlibArchiveAction: BuildActionDef
      var fortcalcLinkAction: BuildActionDef
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("fortran-direct-compile-fortlib"):
          sawCompileFortlib = true
        elif action.id == "fortran-direct-archive-fortlib":
          fortlibArchiveAction = action
          sawArchiveFortlib = true
        elif action.id == "fortran-direct-link-fortcalc":
          fortcalcLinkAction = action
          sawLinkFortcalc = true
      check sawCompileFortlib
      check sawArchiveFortlib
      check sawLinkFortcalc

      # The archive output lands at .repro/build/fortlib/libfortlib.a.
      var archiveOutput = ""
      for outPath in fortlibArchiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libfortlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The link action's deps include the archive action id.
      var sawArchiveDep = false
      for dep in fortcalcLinkAction.deps:
        if dep == fortlibArchiveAction.id:
          sawArchiveDep = true
      check sawArchiveDep

      # The link action's inputs include the upstream archive.
      var sawArchiveInput = false
      for inp in fortcalcLinkAction.inputs:
        if inp == archiveOutput:
          sawArchiveInput = true
      check sawArchiveInput

      # The link argv carries the archive as a trailing positional.
      let linkArgv = inlineArgvOf(fortcalcLinkAction)
      var sawArchivePositional = false
      for token in linkArgv:
        if token == archiveOutput:
          sawArchivePositional = true
      check sawArchivePositional

      # The link argv goes through gfortran (NOT gcc).
      check linkArgv.len > 0
      let driver = linkArgv[0].toLowerAscii.replace('\\', '/')
      check driver.endsWith("gfortran") or
        driver.endsWith("gfortran.exe")

      # The pure-Fortran link argv does NOT carry the C++ runtime
      # injection (no -lgfortran) — gfortran's driver pulls them in
      # automatically. cConsumable toggle verification: in the pure-
      # Fortran workspace nothing's cConsumable so we should NOT see
      # the explicit -lgfortran injection. (We DO emit the link
      # through gfortran so the driver handles runtime resolution
      # implicitly.)
      var sawExplicitGfortranLib = false
      for token in linkArgv:
        if token == "-lgfortran":
          sawExplicitGfortranLib = true
      check not sawExplicitGfortranLib

suite "fortran-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not gfortranOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "gfortran"
  library alpha

package betaPkg:
  uses:
    "gfortran"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "lib.f90",
        "function alpha() result(r)\n  integer :: r\n  r = 1\nend function\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "lib.f90",
        "function beta() result(r)\n  integer :: r\n  r = 2\nend function\n")
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not gfortranOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "gfortran"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.f90",
        "program p\n  print *, \"hi\"\nend program\n")
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# M37 cross-language Fortran ↔ C/C++ verification.
# ---------------------------------------------------------------------------

suite "fortran-direct convention M37 cross-language (forward direction)":

  test "forward: Fortran binary picks up C archive on link argv":
    if not gfortranOnPath() or not gccOnPath():
      skip()
    else:
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(Mode3MixedForwardFixture)
      require conv.recognize(Mode3MixedForwardFixture, request)
      let fragment = conv.emitFragment(Mode3MixedForwardFixture, request)

      var archiveAction: BuildActionDef
      var calcLinkAction: BuildActionDef
      var sawArchive = false
      var sawCalcLink = false
      var sawCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "fortran-xlang-ccpp-archive-mathlib":
          archiveAction = action
          sawArchive = true
        elif action.id == "fortran-direct-link-fortcalc":
          calcLinkAction = action
          sawCalcLink = true
        elif action.id.startsWith("fortran-xlang-ccpp-compile-mathlib"):
          sawCompile = true

      check sawArchive
      check sawCalcLink
      check sawCompile

      # The archive output lands at .repro/build/mathlib/libmathlib.a.
      var archiveOutput = ""
      for outPath in archiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The fortcalc link action's deps include the archive action id.
      var sawArchiveDep = false
      for dep in calcLinkAction.deps:
        if dep == archiveAction.id:
          sawArchiveDep = true
      check sawArchiveDep

      # The link argv carries the C archive as a trailing positional.
      let linkArgv = inlineArgvOf(calcLinkAction)
      var sawArchivePositional = false
      for token in linkArgv:
        if token == archiveOutput:
          sawArchivePositional = true
      check sawArchivePositional

suite "fortran-direct convention M37 cross-language (reverse direction)":

  test "reverse: C++ binary picks up Fortran archive + runtime libs":
    if not gfortranOnPath() or not gppOnPath():
      skip()
    else:
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(Mode3MixedReverseFixture)
      require conv.recognize(Mode3MixedReverseFixture, request)
      let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)

      var fortaddlibArchive: BuildActionDef
      var cppappLinkAction: BuildActionDef
      var sawFortaddlibArchive = false
      var sawCppLink = false
      var sawCppCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "fortran-direct-archive-fortaddlib":
          fortaddlibArchive = action
          sawFortaddlibArchive = true
        elif action.id == "fortran-xlang-ccpp-exec-link-cppapp":
          cppappLinkAction = action
          sawCppLink = true
        elif action.id.startsWith("fortran-xlang-ccpp-exec-compile-cppapp"):
          sawCppCompile = true
      check sawFortaddlibArchive
      check sawCppLink
      check sawCppCompile

      # The fortaddlib archive output lands at the canonical path.
      var fortaddlibOutput = ""
      for outPath in fortaddlibArchive.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libfortaddlib.a"):
          fortaddlibOutput = outPath
      check fortaddlibOutput.len > 0

      # The cppapp link action's deps include the fortaddlib archive
      # action id.
      var sawFortaddlibDep = false
      for dep in cppappLinkAction.deps:
        if dep == fortaddlibArchive.id:
          sawFortaddlibDep = true
      check sawFortaddlibDep

      # The cppapp link action's inputs include the upstream archive.
      var sawFortaddlibInput = false
      for inp in cppappLinkAction.inputs:
        if inp == fortaddlibOutput:
          sawFortaddlibInput = true
      check sawFortaddlibInput

      # The cppapp link argv carries the Fortran archive as a trailing
      # positional AND the Fortran runtime libs.
      let cppappArgv = inlineArgvOf(cppappLinkAction)
      var sawArchive = false
      var sawGfortran = false
      var sawQuadmath = false
      var sawM = false
      for token in cppappArgv:
        if token == fortaddlibOutput: sawArchive = true
        if token == "-lgfortran": sawGfortran = true
        if token == "-lquadmath": sawQuadmath = true
        if token == "-lm": sawM = true
      check sawArchive
      check sawGfortran
      check sawQuadmath
      check sawM

suite "fortran-direct convention cConsumable toggle":

  test "cConsumable=false when no C/C++ downstream (pure Fortran)":
    # The pure Fortran fixture has no C/C++ executables — so the
    # convention should NOT flag the fortlib library as cConsumable,
    # and the cConsumable runtime injection (via fortranRuntimeLinkLibs)
    # only fires on cross-language C++ binaries. The pure Fortran link
    # is gfortran-driven so libgfortran is pulled in by the driver
    # automatically; no explicit -lgfortran on the link argv.
    if not gfortranOnPath():
      skip()
    else:
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)
      var fortcalcLinkAction: BuildActionDef
      var sawFortcalcLink = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "fortran-direct-link-fortcalc":
          fortcalcLinkAction = action
          sawFortcalcLink = true
      check sawFortcalcLink
      # Driver = gfortran (pulls in libgfortran/libquadmath
      # automatically — no explicit -l on the line).
      let linkArgv = inlineArgvOf(fortcalcLinkAction)
      var sawExplicitRuntimeLib = false
      for token in linkArgv:
        if token == "-lgfortran" or token == "-lquadmath":
          sawExplicitRuntimeLib = true
      check not sawExplicitRuntimeLib

  test "cConsumable=true when C/C++ executable depends on Fortran lib":
    # The reverse fixture has a C++ executable depending on a Fortran
    # library — so the convention SHOULD inject -lgfortran (and the
    # rest of the runtime) onto the C++ link argv via the
    # cConsumable-driven runtime injection.
    if not gfortranOnPath() or not gppOnPath():
      skip()
    else:
      let conv = fortran_direct_convention.fortranDirectConvention()
      let request = dummyRequest(Mode3MixedReverseFixture)
      require conv.recognize(Mode3MixedReverseFixture, request)
      let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)
      var cppappLinkAction: BuildActionDef
      var sawCppLink = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "fortran-xlang-ccpp-exec-link-cppapp":
          cppappLinkAction = action
          sawCppLink = true
      check sawCppLink
      let cppappArgv = inlineArgvOf(cppappLinkAction)
      var sawGfortran = false
      for token in cppappArgv:
        if token == "-lgfortran":
          sawGfortran = true
      check sawGfortran

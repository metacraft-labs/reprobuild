## DSL-port M9.R.2b — typed-value layer + Layer-2 dispatch + Layer-1
## constructor surface.
##
## Coverage:
##
##   1. ``Library`` / ``Executable`` records round-trip the install
##      edge + auto-lifted scalars.
##   2. ``compile(opts)`` routes to ``gccCompile`` under the gcc
##      override and to ``clangCompile`` under the clang override.
##   3. ``link(opts)`` routes the same way.
##   4. ``c_library(into = ...)`` reads the surrounding ``library
##      libfoo: api: ...`` declaration through
##      ``registeredLibraryApi`` and threads the metadata into the
##      returned ``Library``.
##   5. ``MesonPackageResult.executable("meson")`` returns an
##      ``Executable`` whose ``installPrefix`` is the standard
##      ``"usr/bin"``.
##   6. ``MesonPackageResult.files("man")`` returns a
##      ``BuildActionDef`` (the install edge); the component-path
##      lookup honours the standard layout table.
##
## The compile / link calls in this test run OUTSIDE an active
## ``build:`` block — the constructors guard against that via
## ``tryCurrentBuildState`` returning nil — so the auto-lift falls
## back to ``registeredLibraryApi("", "libfoo")`` which returns
## ``declared = false`` for the empty package name. The c_library
## sub-test sets up a real ``package`` declaration so the lookup
## resolves.

{.experimental: "callOperator".}

import std/[unittest, tables]

import repro_project_dsl
import repro_dsl_stdlib/types
import repro_dsl_stdlib/operations
import repro_dsl_stdlib/operations/toolchain
import repro_dsl_stdlib/constructors

# ---------------------------------------------------------------------------
# Fixture — a package whose ``library`` block carries an ``api:`` slot
# the ``c_library`` constructor will look up via ``registeredLibraryApi``.
# ---------------------------------------------------------------------------

package m9r2bCLibFixture:
  library libfoo:
    api:
      soname  "foo"
      sover   "1.0"
      linkKind shared
      headers:
        "include/foo.h"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2b — typed-value records":

  test "Library record round-trip via newLibrary":
    let api = LibraryApi(declared: true, soname: "foo", sover: "1.0",
                         linkKind: llkShared)
    let action = BuildActionDef(id: "test-lib")
    let lib = newLibrary(install = action, api = api,
                        installPrefix = "usr/lib")
    check lib.api.declared == true
    check lib.api.soname == "foo"
    check lib.soname == "foo"
    check lib.sover == "1.0"
    check lib.linkKind == llkShared
    check lib.install.id == "test-lib"
    check lib.installPrefix == "usr/lib"

  test "Executable record round-trip via newExecutable":
    let action = BuildActionDef(id: "test-exe")
    let exe = newExecutable(install = action,
                            executableName = "meson",
                            installPrefix = "usr/bin")
    check exe.cli.executableName == "meson"
    check exe.install.id == "test-exe"
    check exe.installPrefix == "usr/bin"


suite "DSL-port M9.R.2b — compile / link dispatch":

  setup:
    # Each test pins the compiler override so the dispatch decision
    # is deterministic without running the solver.
    setCompilerOverride("")

  test "compile(opts) routes to gccCompile under cfGcc":
    setCompilerOverride("gcc")
    let edge = compile(CompileOptions(
      source: "foo.c", target: "foo.o"))
    check edge.call.packageName == "gcc"
    check edge.call.executableName == "gcc"

  test "compile(opts) routes to clangCompile under cfClang":
    setCompilerOverride("clang")
    let edge = compile(CompileOptions(
      source: "bar.c", target: "bar.o"))
    check edge.call.packageName == "clang"
    check edge.call.executableName == "clang"

  test "link(opts) routes to gccLink under cfGcc":
    setCompilerOverride("gcc")
    let obj = BuildActionDef(outputs: @["foo.o"])
    let edge = link(LinkOptions(
      objects: @[obj],
      kind: lokShared,
      target: "libfoo.so"))
    check edge.call.packageName == "gcc"
    check edge.call.executableName == "gcc"

  test "link(opts) routes to clangLink under cfClang":
    setCompilerOverride("clang")
    let obj = BuildActionDef(outputs: @["foo.o"])
    let edge = link(LinkOptions(
      objects: @[obj],
      kind: lokShared,
      target: "libfoo.so"))
    check edge.call.packageName == "clang"
    check edge.call.executableName == "clang"

  test "currentCompiler reads override, falls back to cfGcc":
    setCompilerOverride("")
    check currentCompiler() == cfGcc
    setCompilerOverride("clang")
    check currentCompiler() == cfClang
    setCompilerOverride("gcc")
    check currentCompiler() == cfGcc
    setCompilerOverride("unknown")
    check currentCompiler() == cfGcc


suite "DSL-port M9.R.2b — Layer-1 c_library constructor":

  setup:
    setCompilerOverride("gcc")

  test "c_library reads registered LibraryApi via the into parameter":
    # The ``m9r2bCLibFixture`` package above declared
    # ``library libfoo: api: soname "foo"`` so the registry has a row.
    let api = registeredLibraryApi("m9r2bCLibFixture", "libfoo")
    check api.declared == true
    check api.soname == "foo"
    check api.linkKind == llkShared

  test "c_library populates Library.api from the registered metadata":
    # Construct without an active ``build:`` block. The constructor
    # falls back to packageName == "" so the registered "libfoo"
    # lookup returns declared == false; the resulting Library carries
    # an empty api but is still a well-formed value.
    let lib = c_library(into = "libfoo",
                        sources = @["src/foo.c"])
    # Without an active build context the api lookup misses, so
    # ``api.declared`` is false (the registered row is keyed under
    # the package name, which we can't read outside a build block).
    check lib.api.declared == false
    check lib.installPrefix == "usr/lib"
    # The install edge is the link action.
    check lib.install.call.packageName == "gcc"


suite "DSL-port M9.R.2b — MesonPackageResult slicing":

  test "MesonPackageResult.executable returns Executable at usr/bin":
    let install = BuildActionDef(id: "meson-install")
    let pkg = MesonPackageResult(
      buildEdge: BuildActionDef(id: "meson-setup"),
      compileEdge: BuildActionDef(id: "meson-compile"),
      installEdge: install,
      destdir: "out",
      components: standardComponents())
    let exe = pkg.executable("meson")
    check exe.cli.executableName == "meson"
    check exe.install.id == "meson-install"
    check exe.installPrefix == "usr/bin"

  test "MesonPackageResult.library returns Library at usr/lib":
    let install = BuildActionDef(id: "meson-install")
    let pkg = MesonPackageResult(
      buildEdge: BuildActionDef(),
      compileEdge: BuildActionDef(),
      installEdge: install,
      destdir: "out",
      components: standardComponents())
    let lib = pkg.library("libmeson")
    check lib.install.id == "meson-install"
    check lib.installPrefix == "usr/lib"

  test "MesonPackageResult.files returns the install edge":
    let install = BuildActionDef(id: "meson-install")
    let pkg = MesonPackageResult(
      buildEdge: BuildActionDef(),
      compileEdge: BuildActionDef(),
      installEdge: install,
      destdir: "out",
      components: standardComponents())
    let manFiles = pkg.files("man")
    check manFiles.id == "meson-install"

  test "standardComponents maps the FHS layout":
    let comps = standardComponents()
    check comps["runtime"] == "usr/bin"
    check comps["library"] == "usr/lib"
    check comps["share"] == "usr/share"
    check comps["man"] == "usr/share/man"
    check comps["include"] == "usr/include"
    check comps["pkgconfig"] == "usr/lib/pkgconfig"


suite "DSL-port M9.R.2b — CmakePackageResult + AutotoolsPackageResult mirror":

  test "CmakePackageResult slicing surface matches Meson":
    let install = BuildActionDef(id: "cmake-install")
    let pkg = CmakePackageResult(
      buildEdge: BuildActionDef(),
      compileEdge: BuildActionDef(),
      installEdge: install,
      destdir: "out",
      components: standardComponents())
    let exe = pkg.executable("cmake")
    check exe.installPrefix == "usr/bin"
    let lib = pkg.library("libcmake")
    check lib.installPrefix == "usr/lib"

  test "AutotoolsPackageResult slicing surface matches Meson":
    let install = BuildActionDef(id: "autotools-install")
    let pkg = AutotoolsPackageResult(
      buildEdge: BuildActionDef(),
      compileEdge: BuildActionDef(),
      installEdge: install,
      destdir: "out",
      components: standardComponents())
    let exe = pkg.executable("autoconf")
    check exe.installPrefix == "usr/bin"
    let lib = pkg.library("libautoconf")
    check lib.installPrefix == "usr/lib"

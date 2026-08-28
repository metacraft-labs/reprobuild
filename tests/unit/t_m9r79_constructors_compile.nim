## M9.R.79 Phase D verification — the three high-level from-source
## constructors (meson_package / autotools_package / cmake_package)
## still compile cleanly after M9.R.79.2 / .3 / .4 threaded
## declaredOutputs + readOnlyRoots onto their emitted edges.
##
## This is a shallow import + presence check.  End-to-end graph
## emission is exercised by the recipe-corpus smoke suites at a
## higher level; here we just want a fast tripwire that a future
## refactor doesn't accidentally break the M9.R.79 threading.

import std/[os, tempfiles, unittest]

import repro_dsl_stdlib/constructors/meson_package
import repro_dsl_stdlib/constructors/autotools_package
import repro_dsl_stdlib/constructors/cmake_package

# ``repro_project_dsl`` exports the registry mutators the constructor
# modules use.
import repro_project_dsl

suite "t_m9r79_constructors_compile":

  test "meson_package + autotools_package + cmake_package importable":
    # ``check true`` could not fail, so "the imports above are the assertion"
    # was the whole of it -- and an import that resolves says nothing about
    # whether the constructor is still CALLABLE at its documented arity.
    # ``compiles`` says exactly that, and is false the moment a required
    # parameter appears or the symbol stops being exported.
    check compiles(meson_package(srcDir = "./src"))
    check compiles(cmake_package(srcDir = "./src"))
    check compiles(autotools_package(srcDir = "./src"))

  test "cmake runtime paths exclude propagated Nix glibc":
    let glibcLib = "/nix/store/0123456789abcdefghijklmnopqrstuv-glibc-2.40/lib"
    let dependencyLib = "/nix/store/vutsrqponmlkjihgfedcba9876543210-libfoo-1.0/lib"
    check cmakeRuntimeLibraryDirs(@[glibcLib, dependencyLib]) ==
      @[dependencyLib]

  test "cmake runtime paths exclude federated compiler bootstrap libc":
    let scratch = createTempDir("repro-cmake-bootstrap-libc-", "")
    defer: removeDir(scratch)
    writeFile(scratch / "libc.so.6", "synthetic bootstrap libc")
    let dependencyLib = scratch & "-dependency"
    check cmakeRuntimeLibraryDirs(@[scratch, dependencyLib]) ==
      @[dependencyLib]

  test "registry mutators are exported":
    # Compile-time gate: registry mutators must be
    # reachable from downstream constructor modules.  Call each proc
    # with a fake action id so ``dynOrStatic`` mode-lowered symbols get
    # actually referenced (a bare reference to the proc value trips
    # ``illegal discard proc``).  The mutators no-op when the id is not
    # present in the registry (defensive — same shape as the rest of
    # the ``setRegisteredAction*`` family) so calling them with a fake
    # id is safe.
    setRegisteredActionDeclaredOutputs("m9r79-fake-id", @["/tmp/x"])
    setRegisteredActionReadOnlyRoots("m9r79-fake-id", @["/tmp/y"])
    setRegisteredActionCwd("m9r84-fake-id", acwdBuild, "/tmp/build")
    # ``check true`` could not fail, so it did not record the property this
    # case is named for. ``compiles`` does: it goes false the moment a mutator
    # stops being exported or changes arity, which is the regression the
    # "compile-time gate" wording was reaching for.
    check compiles(setRegisteredActionDeclaredOutputs("id", @["/tmp/x"]))
    check compiles(setRegisteredActionReadOnlyRoots("id", @["/tmp/y"]))
    check compiles(setRegisteredActionCwd("id", acwdBuild, "/tmp/build"))

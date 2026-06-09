## Spec-Implementation M3 — ``Toolchain`` interface integration test.
##
## Asserts:
##   1. ``gccToolchain()`` returns a fully populated ``Toolchain``
##      whose canonical methods emit the documented argv shape.
##   2. ``clangToolchain()`` is a distinct adapter with its own
##      identity and binary path.
##   3. ``compile`` and ``link`` populate ``BuildAction.inputs`` /
##      ``outputs`` consistent with the requested source/object/output
##      paths.
##   4. ``ToolchainFlags`` defaults carry the spec-documented
##      properties (``optimization == "O2"``).

import std/[strutils, unittest]

import repro_dsl_stdlib/interfaces/toolchain
import repro_dsl_stdlib/adapters/gcc_toolchain
import repro_dsl_stdlib/adapters/clang_toolchain

suite "Spec-Implementation M3: Toolchain interface":

  test "gccToolchain is fully populated":
    let tc = gccToolchain()
    validate(tc)
    check tc.name == "gcc-toolchain"
    check tc.cCompilerPath == "gcc"
    check tc.cxxCompilerPath == "g++"
    check tc.defaultFlags.optimization == "O2"
    check tc.defaultFlags.languageStandard == "c11"

  test "clangToolchain is a distinct adapter":
    let tc = clangToolchain()
    validate(tc)
    check tc.name == "clang-toolchain"
    check tc.cCompilerPath == "clang"
    check tc.cxxCompilerPath == "clang++"
    # The two adapters produce distinct compile actions for the same
    # input — the action-id encodes the toolchain family.
    let gccAction = gccToolchain().compile("a.c", "a.o", @[])
    let clangAction = tc.compile("a.c", "a.o", @[])
    check gccAction.actionId.startsWith("gcc-")
    check clangAction.actionId.startsWith("clang-")
    check gccAction.argv[0] == "gcc"
    check clangAction.argv[0] == "clang"

  test "compile and link populate inputs/outputs":
    let tc = gccToolchain()
    let compileAction = tc.compile("src/foo.c", "build/foo.o",
                                    @["-O0", "-g"])
    check compileAction.inputs == @["src/foo.c"]
    check compileAction.outputs == @["build/foo.o"]
    check "-O0" in compileAction.argv
    check "-g" in compileAction.argv
    check "-c" in compileAction.argv
    let linkAction = tc.link(@["build/foo.o", "build/bar.o"],
                              "build/app", @["-lpthread"])
    check linkAction.inputs == @["build/foo.o", "build/bar.o"]
    check linkAction.outputs == @["build/app"]
    check "-lpthread" in linkAction.argv

  test "archiveExecutable produces a cp action by default":
    let tc = gccToolchain()
    let arch = tc.archiveExecutable("build/app", "dist/app.tar")
    check arch.inputs == @["build/app"]
    check arch.outputs == @["dist/app.tar"]
    check arch.argv == @["cp", "build/app", "dist/app.tar"]

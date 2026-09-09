import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_cli_support
import repro_project_dsl
import repro_tool_profiles
import repro_dsl_stdlib/packages/cmake as cmake_module

proc configure(root: string; fresh: bool): tuple[output: string, exitCode: int] =
  resetTargetExportRegistry()
  let action = cmake.configure(srcDir = root / "src", buildDir = root / "build",
    generator = "Ninja", cacheVars = @["RECIPE_VALUE=kept"], fresh = fresh)
  let argv = argvForCall(action.call,
    PathOnlyToolProfile(resolvedExecutablePath: findExe("cmake")))
  let process = startProcess(argv[0], args = argv[1 .. ^1],
    options = {poStdErrToStdOut})
  defer: process.close()
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()

suite "CMake fresh configuration":
  test "retry drops failed cached probes but preserves unrelated build files":
    require findExe("cmake").len > 0
    require findExe("ninja").len > 0
    let root = createTempDir("repro-cmake-fresh-", "")
    defer: removeDir(root)
    createDir(root / "src")
    writeFile(root / "src/CMakeLists.txt", """
cmake_minimum_required(VERSION 3.24)
project(CachedProbe NONE)
if(NOT DEFINED HAVE_DEPENDENCY)
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/dependency.txt" available)
  set(HAVE_DEPENDENCY "${available}" CACHE INTERNAL "Dependency probe")
endif()
if(NOT HAVE_DEPENDENCY)
  message(FATAL_ERROR "dependency probe failed")
endif()
if(NOT RECIPE_VALUE STREQUAL "kept")
  message(FATAL_ERROR "recipe cache variable lost")
endif()
""")
    writeFile(root / "src/dependency.txt", "OFF")
    let failed = configure(root, false)
    check failed.exitCode != 0
    check "dependency probe failed" in failed.output

    writeFile(root / "src/dependency.txt", "ON")
    writeFile(root / "build/compiled-artifact", "preserved")
    # The same dependency path is now ready, but CMake retains the old result.
    let stale = configure(root, false)
    check stale.exitCode != 0
    check "dependency probe failed" in stale.output

    let recovered = configure(root, true)
    checkpoint recovered.output
    check recovered.exitCode == 0
    check "HAVE_DEPENDENCY:INTERNAL=ON" in readFile(root / "build/CMakeCache.txt")
    check readFile(root / "build/compiled-artifact") == "preserved"

## The engine names itself to the build: every `repro build` writes the
## engine's revision and version to `<project>/.repro/build/engine-build-info`
## (reprobuild-pm Distribution-And-Packaging.md §5.3, the build record's
## `engine=` line, as Zahary Karadjov decided on 2026-11-03: the engine
## passes its build-info revision into the edge as a declared input, so it is
## part of the action key and not ambient).
##
## An edge that records the engine (`.#prefix`) declares the file as an input,
## so another engine is another key. The file is rewritten only when its text
## changes: an unchanged engine leaves the edge a cache hit.
##
## Real files in a temp dir; no mocks.

import std/[os, strutils, tempfiles, times, unittest]

import repro_core
import repro_core/engine_build_info

suite "engine-build-info":
  test "names the engine's revision and version":
    let text = engineBuildInfoText()
    check text.startsWith("engine=")
    check ("\nengine_version=" & versionString() & "\n") in text
    if ReprobuildSourceRevision.len > 0:
      check ("engine=" & ReprobuildSourceRevision & "\n") in text
    else:
      check "engine=unknown\n" in text

  test "is written under the project and left alone when unchanged":
    let root = createTempDir("engine-build-info-", "")
    defer: removeDir(root)
    writeEngineBuildInfo(root)
    let path = root / EngineBuildInfoSubpath
    check readFile(path) == engineBuildInfoText()
    let first = getLastModificationTime(path)
    sleep(1100)
    writeEngineBuildInfo(root)
    check getLastModificationTime(path) == first

  test "a file another engine wrote is replaced":
    let root = createTempDir("engine-build-info-old-", "")
    defer: removeDir(root)
    createDir((root / EngineBuildInfoSubpath).parentDir)
    writeFile(root / EngineBuildInfoSubpath, "engine=0000\nengine_version=0.0.1\n")
    writeEngineBuildInfo(root)
    check readFile(root / EngineBuildInfoSubpath) == engineBuildInfoText()

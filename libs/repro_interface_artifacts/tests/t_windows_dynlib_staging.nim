## ``stageHostDynlibsBesideBinary`` — the Windows self-containment step for
## binaries reprobuild compiles for ITSELF into scratch trees (the
## interface-extract runner and the project provider).
##
## Why this exists: every non-system library reprobuild uses on Windows is
## dlopen'd by leaf name, and ``repro_solver``'s clingo binding resolves at
## MODULE INIT — before ``main``. Win32's LoadLibrary searches the running
## .exe's own directory first and PATH last, so a helper sitting in ``%TEMP%``
## or ``.repro/build/provider`` with no DLLs beside it starts only on hosts
## that happen to carry clingo on PATH. On every other host it aborts with
## ``could not load: clingo.dll`` before running a line of its own code.
##
## Historically only the interface-extract path staged these DLLs, and it did
## so with an inline ``walkDir`` loop; the provider-compile path had no
## equivalent at all. The regressions worth pinning here are therefore:
##
##   1. DLLs beside the app get copied into the destination (the whole point).
##   2. Non-DLL files are NOT copied — the staging step must not turn a scratch
##      dir into a mirror of reprobuild's bin.
##   3. ``destDir == appDir`` is a no-op. ``copyFile`` onto itself truncates
##      the source, so a caller that passes the app's own directory (e.g. an
##      installed layout where the provider is written next to repro.exe) must
##      not destroy reprobuild's own clingo.dll.
##   4. An already-staged DLL of the same size is not recopied — the provider
##      scratch dir persists across builds and these files are ~12 MB total.
##   5. On POSIX the proc is inert: DT_RUNPATH / LC_RPATH baked in by
##      ``runtimeRpathCompilerFlags`` already resolve these libraries.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts

suite "stageHostDynlibsBesideBinary":

  test "copies dlls beside the running binary and skips other files":
    let appDir = parentDir(getAppFilename())
    let dest = createTempDir("repro-dynlib-staging-", "")
    defer: removeDir(dest)

    # Seed a marker DLL and a decoy in the app dir so the assertions do not
    # depend on which DLLs this particular test binary happens to sit next to.
    let markerDll = appDir / "t_windows_dynlib_staging_marker.dll"
    let decoyTxt = appDir / "t_windows_dynlib_staging_marker.txt"
    writeFile(markerDll, "not a real dll, just bytes")
    writeFile(decoyTxt, "should not be staged")
    defer:
      removeFile(markerDll)
      removeFile(decoyTxt)

    let staged = stageHostDynlibsBesideBinary(dest)

    when defined(windows):
      check "t_windows_dynlib_staging_marker.dll" in staged
      check fileExists(dest / "t_windows_dynlib_staging_marker.dll")
      check readFile(dest / "t_windows_dynlib_staging_marker.dll") ==
        "not a real dll, just bytes"
      # A non-DLL sibling must be left behind.
      check "t_windows_dynlib_staging_marker.txt" notin staged
      check not fileExists(dest / "t_windows_dynlib_staging_marker.txt")
    else:
      # POSIX: rpath handles resolution, so the proc stages nothing at all.
      check staged.len == 0
      check not fileExists(dest / "t_windows_dynlib_staging_marker.dll")

  test "staging into the app dir itself is a no-op and preserves contents":
    # Guards the copyFile-onto-itself truncation hazard: if a caller ever
    # passes the app's own directory, reprobuild's real clingo.dll must survive.
    let appDir = parentDir(getAppFilename())
    let markerDll = appDir / "t_windows_dynlib_selfcopy_marker.dll"
    let contents = "original bytes that must survive"
    writeFile(markerDll, contents)
    defer: removeFile(markerDll)

    let staged = stageHostDynlibsBesideBinary(appDir)

    check staged.len == 0
    check fileExists(markerDll)
    check readFile(markerDll) == contents

  test "does not recopy a dll already staged at the same size":
    let appDir = parentDir(getAppFilename())
    let dest = createTempDir("repro-dynlib-restage-", "")
    defer: removeDir(dest)

    let markerDll = appDir / "t_windows_dynlib_restage_marker.dll"
    writeFile(markerDll, "0123456789")
    defer: removeFile(markerDll)

    # Pre-stage a same-size but DIFFERENT-content file. The size guard should
    # leave it untouched, which is what makes the skip observable.
    let preStaged = dest / "t_windows_dynlib_restage_marker.dll"
    writeFile(preStaged, "abcdefghij")

    let staged = stageHostDynlibsBesideBinary(dest)

    when defined(windows):
      check "t_windows_dynlib_restage_marker.dll" in staged
      check readFile(preStaged) == "abcdefghij"
    else:
      check staged.len == 0

  test "an empty destination is rejected rather than staging into cwd":
    check stageHostDynlibsBesideBinary("").len == 0

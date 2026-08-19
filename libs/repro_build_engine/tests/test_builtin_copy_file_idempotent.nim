import std/[os, times, unittest]

when defined(windows):
  import std/dynlib

import repro_build_engine

suite "built-in copyFile idempotence":
  test "an identical destination is not replaced":
    let scratch = getTempDir() / "repro-copy-file-idempotent"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)

    when defined(windows):
      let source = getEnv("SystemRoot") / "System32" / "version.dll"
    else:
      let source = scratch / "source.bin"
      writeFile(source, "identical payload")
    let destination = scratch / "destination.bin"
    copyFileWithPermissions(source, destination)
    setLastModificationTime(destination, fromUnix(1_000_000))
    let originalMtime = getLastModificationTime(destination)

    when defined(windows):
      let loadedDestination = loadLib(destination)
      require loadedDestination != nil
      defer:
        unloadLib(loadedDestination)
        if dirExists(scratch):
          removeDir(scratch)
    else:
      defer:
        if dirExists(scratch):
          removeDir(scratch)

    let action = BuildAction(
      kind: bakCopyFile,
      id: "copy-identical-file",
      inputs: @[source],
      outputs: @[destination],
      cacheable: false)
    let actionResult = executeBuiltinAction(action)

    check actionResult.status == asSucceeded
    check sameFileContent(source, destination)
    check getLastModificationTime(destination) == originalMtime

import std/[os, strutils, times, unittest]

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
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakCopyFile,
      id: "copy-identical-file",
      inputs: @[source],
      outputs: @[destination],
      cacheable: false)
    let actionResult = executeBuiltinAction(action)

    check actionResult.status == asSucceeded
    check sameFileContent(source, destination)
    check getLastModificationTime(destination) == originalMtime

  test "a busy destination whose content differs is still replaced":
    ## The idempotence guard above hides the Windows self-conflict for as long
    ## as the staged bytes happen to match. This pins what happens when they do
    ## NOT -- an OpenSSL bump, a re-provisioned toolchain -- which is the case
    ## that used to wedge ``repro build .#apps`` permanently: reprobuild stages
    ## its runtime DLLs into the very ``build/bin`` its driver and workers run
    ## from and dlopen by leaf name, so the destination is mapped by the process
    ## executing the graph. No amount of retrying or daemon-stopping clears it.
    let scratch = getTempDir() / "repro-copy-file-busy-destination"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)

    let source = scratch / "source.bin"
    writeFile(source, "the payload that must reach the destination")

    # The destination needs a name no system module already owns: LoadLibrary
    # resolves an already-loaded module by BASE NAME even when handed a full
    # path, so seeding this as e.g. ``version.dll`` would hand back the system
    # copy and never map our file -- leaving the test vacuously green.
    let destination = scratch / "repro_busy_destination_marker.dll"
    when defined(windows):
      copyFileWithPermissions(getEnv("SystemRoot") / "System32" / "version.dll",
        destination)
    else:
      writeFile(destination, "stale bytes that must be replaced")
    require not sameFileContent(source, destination)

    when defined(windows):
      let loadedDestination = loadLib(destination)
      require loadedDestination != nil
      # Self-validation: assert the destination really IS unwritable before
      # claiming the engine copes with it. Without this the test would keep
      # passing if the lock ever stopped happening.
      var directCopyRefused = false
      try:
        copyFileWithPermissions(source, destination)
      except OSError:
        directCopyRefused = true
      check directCopyRefused

    let action = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakCopyFile,
      id: "copy-busy-destination",
      inputs: @[source],
      outputs: @[destination],
      cacheable: false)
    let actionResult = executeBuiltinAction(action)

    check actionResult.status == asSucceeded
    check sameFileContent(source, destination)

    when defined(windows):
      # Counted with walkDir + prefix, never a ``walkFiles`` glob: a pattern
      # like ``*.dll.repro-replaced-*`` matches NOTHING on Windows (see
      # ``sweepBusyReplacedLeftovers``), which would make both checks below
      # pass vacuously and hide a sweep that never reaps anything.
      proc leftoverCount(): int =
        let dir = destination.splitPath.head
        let prefix = destination.extractFilename & ".repro-replaced-"
        for kind, entry in walkDir(dir, relative = true):
          if kind == pcFile and entry.startsWith(prefix):
            inc result

      # The displaced file cannot be unlinked while it is still mapped, so a
      # leftover MUST exist at this point. Asserting its presence is what makes
      # the sweep assertion below meaningful rather than trivially true.
      check leftoverCount() == 1

      # Reaping it on a later build is the other half of the fix. Release the
      # mapping, then re-run the action: it now takes the identical-destination
      # no-op path, which is where the sweep runs.
      unloadLib(loadedDestination)
      discard executeBuiltinAction(action)
      check leftoverCount() == 0

    if dirExists(scratch):
      removeDir(scratch)

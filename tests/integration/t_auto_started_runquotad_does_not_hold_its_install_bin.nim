## The `runquotad` that `repro` starts on its own does not run in its install's
## `bin` directory, so an upgrade can rename that directory aside while the
## daemon lives.
##
## THE DEFECT THIS PINS. On Windows `spawnDetachedRunQuotaDaemon` started the daemon with
## `workingDir = parentDir(exe)`. A running image does not pin its directory
## (the loader maps it with `FILE_SHARE_DELETE`), but a process's current
## directory does: its handle is opened without `FILE_SHARE_DELETE`, so
## Windows refuses to rename the directory. The bundle upgrade renames
## `%LOCALAPPDATA%\repro\bin` aside first, and failed with "The process cannot
## access the file because it is being used by another process" for as long
## as such a daemon lived. The upgrade has to work with the old daemon alive:
## the old image is renamed aside, not deleted, and the daemon is not killed,
## because killing it would end the leases it holds.
##
## THE SHAPE OF THE CASE. A real `runquotad` image is copied into a scratch
## install, `<root>/install/bin/`. The test process changes into that `bin`
## and starts the daemon the product's way, then changes back out:
##
## * WINDOWS: through `spawnDetachedRunQuotaDaemon`, the very call the
##   auto-start makes, on a private pipe. The auto-start itself
##   (`startAutoRunQuotaIfNeeded`) reaches the fixed host-wide pipe, which the
##   host's own daemon serves; driving it would ask that daemon to retire.
## * POSIX: through `startAutoRunQuotaIfNeeded` itself, on a scratch per-user
##   endpoint (`isolateUserRunQuota`), with `RUNQUOTAD_BIN` naming the copy.
##
## Starting from inside `bin` means a daemon that inherited its starter's
## directory fails the case as surely as one started in its image's directory.
## Then, while the daemon is alive and still answering:
##
## 1. its current directory, READ FROM THE KERNEL'S RECORD OF THE PROCESS
##    (`/proc/<pid>/cwd` on Linux, the PEB's `CurrentDirectory` on Windows;
##    `repro_test_support/process_working_directory`), is neither the
##    scratch install nor anything beneath it, and is the neutral directory
##    `detachedDaemonWorkingDirectory` names (`/`, or the Windows system
##    directory);
## 2. `bin` is renamed aside, as the upgrade does, and the rename succeeds;
## 3. the daemon still runs and still answers after the rename.
##
## Step 2 is the incident itself on Windows. POSIX allows the rename whatever
## the daemon's directory is, so there step 1 carries the property and step 2
## only shows the daemon survives the rename.
##
## A second case runs the same three steps against the development store
## daemon, started through `startDevDaemon` (what `repro store daemon start
## --dev` calls) from a copy of the `repro` engine in a scratch install's
## `bin`, from inside that `bin`, with a RELATIVE store root. Besides the
## directory, it checks the store root the daemon serves is the one the
## caller named, resolved against the caller's directory: the daemon no
## longer runs there, so a path it resolved itself would land elsewhere.
##
## A third case grades the shared rule (`detachedDaemonWorkingDirectory`)
## that every detached daemon `repro` starts goes through: the per-user
## `repro-daemon` (its state directory), this `runquotad`, and the
## development store daemon.
##
## FALSIFIABILITY. Put `workingDir = parentDir(exe)` back into
## `spawnDetachedRunQuotaDaemon` and the Windows case fails at step 1 (the
## daemon's directory is `<root>\install\bin\`) and at step 2 (the rename is
## refused). Point the POSIX launch (`spawnDetachedUserDaemon`) at
## `parentDir(resolved)` and the Linux case fails at step 1. Drop the `chdir`
## from `startDevDaemon`'s POSIX arm and the store-daemon case fails at step 1
## (its directory is the starter's, `bin`); drop `anchoredDevDaemonConfig`
## and it fails on the store root. Make the shared rule accept a state
## directory inside the image's directory and the last case fails.
##
## NO MOCKS. A real `runquotad`, the product's own spawn, the kernel's record
## of the process, a real rename. The only arrangement is the private
## endpoint and, on Windows, the host-isolating daemon flags the other
## runquota spawn tests pass (`t_runquota_auto_spawned_daemon_follows_host_config`).

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support
import repro_runquota
import repro_store_daemon
import repro_daemon_core/detached_working_directory
import repro_test_support
import repro_test_support/process_fixtures
import repro_test_support/process_working_directory
when defined(posix):
  from std/posix import Pid, WNOHANG, waitpid
  import repro_test_support/per_user_runquota

proc scratchInstall(image, root: string): string =
  ## `<root>/install/bin/<runquotad>`, a byte-for-byte copy of `image`, with
  ## the libraries beside `image` copied too (a Windows build may load DLLs
  ## from its own directory). Returns the copy's path.
  let bin = root / "install" / "bin"
  createDir(bin)
  result = bin / extractFilename(image)
  copyFileWithPermissions(image, result)
  when defined(windows):
    for kind, path in walkDir(parentDir(image)):
      if kind == pcFile and path.toLowerAscii().endsWith(".dll"):
        copyFile(path, bin / extractFilename(path))

proc waitReachable(timeoutMs: int): bool =
  var waited = 0
  while waited <= timeoutMs:
    if isRunQuotaDaemonReachable():
      return true
    sleep(25)
    waited += 25
  false

proc alive(pid: int): bool =
  when defined(posix):
    pidAlive(pid)
  else:
    try:
      discard processWorkingDirectory(pid)
      true
    except OSError:
      false

suite "an auto-started runquotad does not hold its install's bin":
  let repoRoot = getCurrentDir()
  let image = requireRunQuotaDaemonBin(repoRoot)

  test "it runs outside bin, and bin can be renamed aside while it lives":
    let root = createTempDir("repro-rq-cwd-", "")
    releaseDirAtProcessExit(root)
    let installed = scratchInstall(image, root)
    let bin = parentDir(installed)
    let install = parentDir(bin)
    let starterDir = getCurrentDir()
    let savedSocket = getEnv("RUNQUOTA_SOCKET")
    let hadSocket = existsEnv("RUNQUOTA_SOCKET")
    var daemon: owned(Process) = nil
    var pid = 0
    when defined(posix):
      let isolated = isolateUserRunQuota()
      let savedBin = getEnv("RUNQUOTAD_BIN")
      let hadBin = existsEnv("RUNQUOTAD_BIN")
      let savedAuto = getEnv("REPROBUILD_AUTO_RUNQUOTA")
      let hadAuto = existsEnv("REPROBUILD_AUTO_RUNQUOTA")
    defer:
      setCurrentDir(starterDir)
      when defined(posix):
        releaseAutoRunQuotaProcess(daemon)
        isolated.release(pid)
        if hadBin: putEnv("RUNQUOTAD_BIN", savedBin)
        else: delEnv("RUNQUOTAD_BIN")
        if hadAuto: putEnv("REPROBUILD_AUTO_RUNQUOTA", savedAuto)
        else: delEnv("REPROBUILD_AUTO_RUNQUOTA")
      else:
        # Our own daemon on our own private pipe: nothing else adopted it.
        if daemon != nil:
          if daemon.running:
            daemon.terminate()
            discard daemon.waitForExit(10_000)
          daemon.close()
      if hadSocket: putEnv("RUNQUOTA_SOCKET", savedSocket)
      else: delEnv("RUNQUOTA_SOCKET")
      removeDir(root)

    # THE START, from inside `bin`.
    setCurrentDir(bin)
    try:
      when defined(posix):
        createDir(isolated.dir)
        setFilePermissions(isolated.dir,
          {fpUserRead, fpUserWrite, fpUserExec})
        putEnv("RUNQUOTA_SOCKET", isolated.socket)
        putEnv("RUNQUOTAD_BIN", installed)
        putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
        resetInvocationRunQuotaDaemonBin()
        daemon = startAutoRunQuotaIfNeeded(false)
      else:
        let socket = runquotaSocketEndpoint("repro-rq-cwd-" &
          $getCurrentProcessId())
        putEnv("RUNQUOTA_SOCKET", socket)
        daemon = spawnDetachedRunQuotaDaemon(installed, @[
          "--socket", socket,
          "--host-config", root / "runquotad.toml",
          "--host-identity-file", root / "host-id",
          "--no-write-stats", "--ambient-sample-interval-millis", "0",
          "--memory-pressure-source", "unavailable"])
    finally:
      setCurrentDir(starterDir)
    require daemon != nil
    pid = processID(daemon)
    require pid > 0
    require waitReachable(60_000)

    # 1. ITS CURRENT DIRECTORY, as the kernel records it.
    let cwd = processWorkingDirectory(pid)
    checkpoint("daemon pid " & $pid & " cwd: " & cwd & "; install: " & install)
    check cwd.len > 0
    check not isSameOrInside(cwd, install)
    check not isSameOrInside(cwd, bin)
    check not isSameOrInside(cwd, root)
    check isSameOrInside(cwd, neutralDaemonWorkingDirectory()) and
      isSameOrInside(neutralDaemonWorkingDirectory(), cwd)

    # 2. THE UPGRADE'S RENAME, while the daemon lives.
    let aside = install / "bin.old"
    var renameError = ""
    try:
      moveDir(bin, aside)
    except OSError as error:
      renameError = error.msg
    checkpoint("rename of " & bin & ": " &
      (if renameError.len == 0: "ok" else: renameError))
    check renameError.len == 0
    check dirExists(aside) and not dirExists(bin)

    # 3. The daemon outlived the rename, and still answers.
    check alive(pid)
    check isRunQuotaDaemonReachable()

  test "the development store daemon runs outside bin, and bin can be renamed aside while it lives":
    # The engine is the store daemon's image (`repro store serve --dev`); a
    # copy keeps the rename below away from this checkout's `build/bin`.
    let engine = repoRoot / "build" / "bin" / addFileExt("reprobuild", ExeExt)
    require fileExists(engine)
    let root = createTempDir("repro-sd-cwd-", "")
    releaseDirAtProcessExit(root)
    let installed = scratchInstall(engine, root)
    let bin = parentDir(installed)
    let install = parentDir(bin)
    let starterDir = getCurrentDir()
    let endpoint = daemonSocketEndpoint("repro-sd-cwd-" &
      $getCurrentProcessId())
    var started = false
    var pid = 0
    defer:
      setCurrentDir(starterDir)
      if started:
        try: stopDevDaemon(endpoint) except CatchableError: discard
        # The shutdown request returns before the daemon has exited. On
        # Windows its image and DLLs (`bin.old/clingo.dll`) stay mapped until
        # it has, and removing the scratch root before then is refused, so
        # wait for the exit. On POSIX `startDevDaemon` forks the daemon as
        # OUR child, so it is reaped here; until then a zombie still answers
        # `alive`. A daemon that ignores the request is a defect of its own
        # and fails the case.
        if pid > 0:
          var waited = 0
          while waited < 30_000:
            when defined(posix):
              var waitStatus: cint
              discard waitpid(Pid(pid), waitStatus, WNOHANG)
            if not alive(pid):
              break
            sleep(50)
            waited += 50
          check not alive(pid)
      removeDir(root)

    # THE START, from inside `bin`, naming the store root relative to it.
    # The root is `install/store`, outside `bin`: the daemon holds its index
    # open, and Windows refuses to rename a directory with an open file
    # beneath it whoever's current directory it is.
    var status: StoreDaemonStatus
    setCurrentDir(bin)
    try:
      status = startDevDaemon(installed,
        DevDaemonConfig(endpoint: endpoint, storeRoot: ".." / "store"))
      started = true
    finally:
      setCurrentDir(starterDir)
    require status.running
    pid = int(status.pid)
    require pid > 0

    # The store root is the caller's `../store`, made absolute where it was
    # typed, and the daemon created it there.
    let storeRoot = install / "store"
    checkpoint("store daemon pid " & $pid & " store root: " &
      status.storeRoot)
    check isAbsolute(status.storeRoot)
    check isSameOrInside(status.storeRoot, storeRoot) and
      isSameOrInside(storeRoot, status.storeRoot)
    check dirExists(storeRoot)

    # 1. ITS CURRENT DIRECTORY, as the kernel records it.
    let cwd = processWorkingDirectory(pid)
    checkpoint("store daemon cwd: " & cwd & "; install: " & install)
    check cwd.len > 0
    check not isSameOrInside(cwd, install)
    check not isSameOrInside(cwd, root)
    check isSameOrInside(cwd, neutralDaemonWorkingDirectory()) and
      isSameOrInside(neutralDaemonWorkingDirectory(), cwd)

    # 2. THE UPGRADE'S RENAME, while the daemon lives.
    let aside = install / "bin.old"
    var renameError = ""
    try:
      moveDir(bin, aside)
    except OSError as error:
      renameError = error.msg
    checkpoint("rename of " & bin & ": " &
      (if renameError.len == 0: "ok" else: renameError))
    check renameError.len == 0
    check dirExists(aside) and not dirExists(bin)

    # 3. The daemon outlived the rename, and still answers.
    check alive(pid)
    check queryDevStatus(endpoint).running

  test "the shared rule never answers the image's directory":
    let root = createTempDir("repro-detached-cwd-", "")
    defer: removeDir(root)
    let bin = root / "install" / "bin"
    let image = bin / addFileExt("daemon", ExeExt)
    let neutral = neutralDaemonWorkingDirectory()
    check neutral.len > 0
    check dirExists(neutral)
    check not isSameOrInside(neutral, root)
    # No state directory of its own: the neutral directory.
    check detachedDaemonWorkingDirectory(image) == neutral
    # A state directory outside the image's directory is the daemon's own.
    let state = root / "state" / "daemon"
    check detachedDaemonWorkingDirectory(image, state) == state
    # One that IS the image's directory, or lies beneath it, is refused.
    check detachedDaemonWorkingDirectory(image, bin) == neutral
    check detachedDaemonWorkingDirectory(image, bin / "daemon-state") == neutral
    check detachedDaemonWorkingDirectory(image, bin & DirSep) == neutral
    # A sibling whose name merely starts with the image directory's is not
    # beneath it.
    check detachedDaemonWorkingDirectory(image, bin & "-state") ==
      bin & "-state"
    when defined(windows):
      # NTFS names are case-insensitive, and so is the comparison.
      check detachedDaemonWorkingDirectory(image, bin.toUpperAscii()) == neutral
      check isSameOrInside(neutral & r"\drivers", neutral.toLowerAscii())

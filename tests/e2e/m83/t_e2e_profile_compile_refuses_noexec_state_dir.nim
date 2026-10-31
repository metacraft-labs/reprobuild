## A profile compile whose state directory is on a `noexec` mount is refused
## up front, naming the mount, instead of failing after the compile with the
## io monitor's bare "Permission denied".
##
## WHY. The profile compile is two edges: the compile edge links the profile
## binary under `<state-dir>/profile-cache/bin/<key>/`, and the run edge
## executes it from there under the io monitor. On a `noexec` mount that
## `execve` fails with `EACCES` whatever the file's mode, so the run edge
## failed with `repro internal io monitor: error: Permission denied` after a
## full Nim and C compile, and nothing said why. Measured on Debian 13
## (systemd 257): a transient unit with `DynamicUser=yes` and
## `StateDirectory=x` gets `/var/lib/private/x` bind-mounted
## `rw,nosuid,nodev,noexec`, so `deploy-agent compile-profile --state-dir`
## under it failed exactly this way, while the same command under the unit's
## private `/tmp` (exec-capable) succeeded.
##
## Primary assertion -- `e2e_profile_compile_refuses_noexec_state_dir`: with
## the state directory a real `noexec` tmpfs, `compileProfileToRbpi` raises a
## `ProfileCompileError` that names `noexec` and the directory, and no profile
## binary was produced (the refusal precedes the compile edge).
##
## Vacuity guard: before the compile is attempted, a copy of a real program
## placed on the mount is executed and must fail -- so the mount genuinely
## forbids execution -- and `isNoExecMount` must answer true for it and false
## for the exec-capable directory beside it.
##
## Falsifying mutation: remove the `refuseNoExecBinaryDir` call from
## `compileProfileToRbpi`. The compile edge then runs, the run edge fails on
## `execve`, and the error says "Permission denied" without "noexec": the
## primary case goes red (measured when this gate was written).
##
## HOW THE MOUNT IS MADE, WITHOUT ROOT. At start-up, while the process is
## still single-threaded, it enters a new user namespace and mount namespace
## (`unshare(CLONE_NEWUSER | CLONE_NEWNS)`), maps its own uid and gid onto
## themselves, makes the mount tree private, and mounts a `noexec` tmpfs over
## the sandbox's state directory. The process keeps its own uid, so the
## compiler and the io monitor run as the invoking user without capabilities,
## exactly like a dynamic user in a systemd unit; only the mount differs. The
## mount and the namespace end with the process and are never visible on the
## host. Linux only (the mount flag is a Linux concept here and the check is
## Linux-only); on a Linux host that forbids unprivileged user namespaces the
## case reports a SKIP with the reason rather than passing.
##
## No mocks: real `build/bin/repro`, real Nim and C toolchain, real io-mon,
## real kernel mount flags.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_profile_compile
import repro_test_support/reasoned_skip
from repro_elevation/store_view import isNoExecMount

const ProjectRoot = currentSourcePath().parentDir().parentDir().
  parentDir().parentDir()

const TrivialProfile = """
import repro_profile

profile "noexecStateDir":
  resources:
    fsUserFile(hostFile = "~/noexec-state-dir.txt", content = "x\n")
"""

proc reproBinary(): string =
  result = ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; run `just build` first"

when defined(linux):
  import std/posix

  var
    CloneNewUser {.importc: "CLONE_NEWUSER", header: "<sched.h>".}: cint
    CloneNewNs {.importc: "CLONE_NEWNS", header: "<sched.h>".}: cint
    MsRec {.importc: "MS_REC", header: "<sys/mount.h>".}: culong
    MsPrivate {.importc: "MS_PRIVATE", header: "<sys/mount.h>".}: culong
    MsNoExec {.importc: "MS_NOEXEC", header: "<sys/mount.h>".}: culong
    MsNoSuid {.importc: "MS_NOSUID", header: "<sys/mount.h>".}: culong
    MsNoDev {.importc: "MS_NODEV", header: "<sys/mount.h>".}: culong

  proc c_unshare(flags: cint): cint {.importc: "unshare",
    header: "<sched.h>".}
  proc c_mount(source, target, fstype: cstring; flags: culong;
               data: pointer): cint {.importc: "mount",
                                      header: "<sys/mount.h>".}

  proc enterNoExecNamespace(): string =
    ## Enter a private user + mount namespace that keeps this process's
    ## uid/gid (see the header). Returns "" on success, else why not.
    ## Must run before the process starts any thread: the kernel refuses
    ## `CLONE_NEWUSER` to a multi-threaded process.
    let uid = getuid()
    let gid = getgid()
    if c_unshare(CloneNewUser or CloneNewNs) != 0:
      return "unshare(CLONE_NEWUSER|CLONE_NEWNS): " &
        osErrorMsg(osLastError())
    try:
      # An unprivileged process must deny setgroups before writing gid_map
      # (user_namespaces(7), "Interaction with system calls that change
      # process UIDs or GIDs").
      writeFile("/proc/self/setgroups", "deny")
      writeFile("/proc/self/uid_map", $uid & " " & $uid & " 1\n")
      writeFile("/proc/self/gid_map", $gid & " " & $gid & " 1\n")
    except IOError as err:
      return "writing the namespace id maps: " & err.msg
    if c_mount(nil, "/", nil, MsRec or MsPrivate, nil) != 0:
      return "making / private: " & osErrorMsg(osLastError())
    ""

  proc mountNoExecTmpfs(dir: string): string =
    if c_mount("tmpfs", dir.cstring, "tmpfs",
               MsNoExec or MsNoSuid or MsNoDev, nil) != 0:
      return "mount tmpfs noexec on " & dir & ": " & osErrorMsg(osLastError())
    ""

  proc canExec(dir: string): bool =
    ## Whether an executable (mode 0755) script written to `dir` can be
    ## started directly, by `execve` and not through a shell.
    let probe = dir / "exec-probe"
    writeFile(probe, "#!/bin/sh\nexit 0\n")
    setFilePermissions(probe, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    defer: removeFile(probe)
    try:
      let p = startProcess(probe, args = [], options = {})
      result = p.waitForExit() == 0
      p.close()
    except OSError as err:
      checkpoint("exec " & probe & ": " & err.msg)
      result = false

  # Done at module initialisation, before `unittest` or anything else could
  # have started a thread.
  let namespaceError = enterNoExecNamespace()

suite "profile compile: noexec state directory":

  test "e2e_profile_compile_refuses_noexec_state_dir":
    when not defined(linux):
      skip("the noexec pre-flight check and the unprivileged mount are " &
        "Linux-only")
    else:
      if namespaceError.len > 0:
        skip("unprivileged user namespaces unavailable: " & namespaceError)
      else:
        let root = createTempDir("repro-profile-state-", "")
        let stateDir = root / "state"
        let profilePath = root / "profile" / "home.nim"
        createDir(stateDir)
        createDir(profilePath.parentDir)
        writeFile(profilePath, TrivialProfile)
        let mountError = mountNoExecTmpfs(stateDir)
        require mountError.len == 0
        # The tmpfs and the namespace vanish with the process; the files
        # under `root` outside the mount are removed here.
        defer:
          try: removeDir(root / "profile") except OSError: discard

        # Vacuity guard: the mount really forbids execution, and the
        # query tells the two directories apart. The same executable script
        # runs from the exec-capable directory (positive control) and is
        # refused by the kernel on the mount.
        check canExec(root / "profile")
        check not canExec(stateDir)
        check isNoExecMount(stateDir)
        check not isNoExecMount(root / "profile")

        let opts = ProfileCompileOptions(stateDir: stateDir,
          publicCliPath: reproBinary(), repoRoot: ProjectRoot)
        var message = ""
        try:
          discard compileProfileToRbpi(profilePath, opts)
        except ProfileCompileError as err:
          message = err.msg
        checkpoint("compileProfileToRbpi: " & message)
        check message.len > 0
        # "mounted noexec" is the refusal's own wording; the run edge's
        # bare io-monitor failure ("Permission denied") does not carry it.
        check "mounted noexec" in message
        check stateDir in message
        check "Permission denied" notin message
        # Refused before the compile edge: nothing was linked.
        let binaryPath = cachedProfileBinaryPath(stateDir,
          profileCompileKey(profilePath))
        check not fileExists(binaryPath)

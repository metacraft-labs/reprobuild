## Reap fixture descendants on macOS using their current working directory.
##
## A recorded pid alone is not authority to signal a process: it may have
## exited and its number may already belong to another test. libproc supplies
## the live cwd witness, including descendants that no session recorded.
## Call before removing the fixture tree so its canonical path is available.

when defined(macosx):
  import std/[os, posix, strutils]

  {.passL: "-lproc".}
  {.emit: """
#include <libproc.h>
#include <sys/proc_info.h>
#include <string.h>

/* Keep the SDK-owned structure layout in C rather than duplicating its ABI. */
static int repro_test_fixture_cwd(int pid, char *path, int capacity) {
  struct proc_vnodepathinfo info;
  if (capacity <= 0 ||
      proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info))
        != sizeof(info)) return 0;
  size_t length = strnlen(info.pvi_cdir.vip_path,
                         sizeof(info.pvi_cdir.vip_path));
  if (length == 0 || length >= (size_t)capacity) return 0;
  memcpy(path, info.pvi_cdir.vip_path, length);
  path[length] = '\0';
  return 1;
}
""".}

  proc procListAllPids(buffer: pointer; bufferSize: cint): cint
      {.importc: "proc_listallpids", header: "<libproc.h>".}
  proc fixtureCwd(pid: cint; buffer: cstring; capacity: cint): cint
      {.importc: "repro_test_fixture_cwd", nodecl.}

  proc canonicalFixtureRoot(root: string): string =
    # expandFilename uses realpath on POSIX, so /var and /private/var name
    # one fixture. A missing tree cannot provide the required witness.
    if not dirExists(root):
      return ""
    result = expandFilename(root)
    if result == $DirSep:
      raise newException(ValueError, "A fixture process root cannot be /")

  proc belongsToFixture(pid: int; root: string): bool =
    if pid <= 0 or pid == getCurrentProcessId() or root.len == 0:
      return false
    var path: array[4096, char]
    if fixtureCwd(cint(pid), cast[cstring](addr path[0]), cint(path.len)) != 1:
      return false                 # unknown identity is never permission
    let cwd = $cast[cstring](addr path[0])
    cwd == root or cwd.startsWith(root & DirSep)

  proc fixturePids(root: string): seq[int] =
    if root.len == 0:
      return @[]
    var capacity = int(procListAllPids(nil, 0))
    if capacity <= 0:
      raiseOSError(osLastError(), "Cannot enumerate fixture processes")
    while true:
      # Allow growth between the size query and the actual enumeration;
      # retry a full buffer rather than silently missing its tail.
      capacity += 128
      var pids = newSeq[cint](capacity)
      let count = int(procListAllPids(addr pids[0],
        cint(pids.len * sizeof(cint))))
      if count <= 0:
        raiseOSError(osLastError(), "Cannot enumerate fixture processes")
      if count >= pids.len:
        capacity = count
        continue
      for i in 0 ..< count:
        let pid = int(pids[i])
        if belongsToFixture(pid, root):
          result.add(pid)
      return

  proc darwinFixtureProcessIds*(root: string): seq[int] =
    ## Live processes whose cwd is this fixture or a directory below it.
    ## Missing roots return no matches; callers must inspect/reap before
    ## removing the tree. Unqueryable processes and this process are excluded.
    fixturePids(canonicalFixtureRoot(root))

  proc reapDarwinFixtureProcesses*(root: string) =
    ## Stop only processes that still have this fixture's cwd immediately
    ## before each signal. Re-enumerate before escalating, so exited or
    ## recycled pids never inherit an earlier process's authority.
    let canonicalRoot = canonicalFixtureRoot(root)
    for signal in [SIGTERM, SIGKILL]:
      for pid in fixturePids(canonicalRoot):
        if belongsToFixture(pid, canonicalRoot):
          if posix.kill(Pid(pid), signal) != 0 and errno != ESRCH:
            raiseOSError(osLastError(), "Cannot stop fixture process " & $pid)
      for attempt in 0 ..< 20:
        if fixturePids(canonicalRoot).len == 0:
          return
        sleep(50)
    let remaining = fixturePids(canonicalRoot)
    if remaining.len > 0:
      raise newException(OSError,
        "Fixture processes remain under " & canonicalRoot & ": " & $remaining)

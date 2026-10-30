## The private writable view of a read-only store (ReproOS Add-On Mode spec
## §10.2, "Store integrity").
##
## On an add-on host ``/repro/store`` is a read-only bind mount over itself
## (generation 0's ``repro-store.mount``). A process that has to write the
## store -- bootstrap realising a prefix, an apply registering a generation
## root, the privileged driver realising a ``package(apt, ...)`` closure --
## first moves into a private mount namespace in which that bind is
## writable. No other process on the host ever sees a writable store, and
## the view ends with the process.
##
## The namespace belongs to the calling thread: ``unshare(CLONE_NEWNS)``
## implies ``CLONE_FS``, which a multi-threaded process may unshare only for
## the calling thread. Call it on the thread that writes, and read the mount
## table through ``/proc/thread-self``, which is that thread's view.
##
## Call it immediately before EVERY write, not once per process. The store's
## read-only bind can appear in the middle of a process: bootstrap writes the
## store while it is a plain directory, then starts generation 0's
## ``repro-store.mount``, then writes again (registering the generation
## root). A call made before the mount existed had nothing to do, so the
## call after it must do the remount. That is why the check is "is the store
## a read-only mount NOW", and why nothing is cached except the namespace.
##
## A store on a filesystem that is itself read-only (its superblock is
## ``ro``: a read-only root, an ``iso9660`` or ``erofs`` image) is not a
## read-only bind, and remounting the bind cannot make it writable. That is
## refused with a message saying so, before anything is unshared.

import std/[os, strutils]
when defined(linux):
  import std/posix

when defined(linux):
  var
    CloneNewNs {.importc: "CLONE_NEWNS", header: "<sched.h>".}: cint
    MsRec {.importc: "MS_REC", header: "<sys/mount.h>".}: culong
    MsPrivate {.importc: "MS_PRIVATE", header: "<sys/mount.h>".}: culong
    MsRemount {.importc: "MS_REMOUNT", header: "<sys/mount.h>".}: culong
    MsBind {.importc: "MS_BIND", header: "<sys/mount.h>".}: culong
    MsNoSuid {.importc: "MS_NOSUID", header: "<sys/mount.h>".}: culong
    MsNoDev {.importc: "MS_NODEV", header: "<sys/mount.h>".}: culong
    MsNoExec {.importc: "MS_NOEXEC", header: "<sys/mount.h>".}: culong
    MsNoAtime {.importc: "MS_NOATIME", header: "<sys/mount.h>".}: culong
    MsNoDirAtime {.importc: "MS_NODIRATIME", header: "<sys/mount.h>".}: culong
    MsRelAtime {.importc: "MS_RELATIME", header: "<sys/mount.h>".}: culong
    StRdOnly {.importc: "ST_RDONLY", header: "<sys/statvfs.h>".}: culong
    StNoSuid {.importc: "ST_NOSUID", header: "<sys/statvfs.h>".}: culong
    StNoDev {.importc: "ST_NODEV", header: "<sys/statvfs.h>".}: culong
    StNoExec {.importc: "ST_NOEXEC", header: "<sys/statvfs.h>".}: culong
    StNoAtime {.importc: "ST_NOATIME", header: "<sys/statvfs.h>".}: culong
    StNoDirAtime {.importc: "ST_NODIRATIME", header: "<sys/statvfs.h>".}: culong
    StRelAtime {.importc: "ST_RELATIME", header: "<sys/statvfs.h>".}: culong

  proc c_unshare(flags: cint): cint {.importc: "unshare", header: "<sched.h>".}
  proc c_mount(source, target, fstype: cstring; flags: culong;
               data: pointer): cint {.importc: "mount",
                                      header: "<sys/mount.h>".}

proc isMountPoint*(path: string): bool =
  ## True when ``path`` is the mount point of some entry in the calling
  ## thread's mount table.
  when defined(linux):
    for line in readFile("/proc/thread-self/mountinfo").splitLines():
      let f = line.splitWhitespace()
      if f.len > 4 and f[4] == path:
        return true
  false

proc superblockReadOnly*(path: string): bool =
  ## True when the filesystem mounted at mount point ``path`` is read-only
  ## in its superblock options (after the `` - `` separator of
  ## ``mountinfo``), as opposed to a read-only per-mount flag on a bind.
  ## The last matching entry wins: it is the one on top.
  when defined(linux):
    for line in readFile("/proc/thread-self/mountinfo").splitLines():
      let f = line.splitWhitespace()
      if f.len > 4 and f[4] == path:
        let sep = f.find("-")
        result = sep >= 0 and sep + 3 < f.len and
          "ro" in f[sep + 3].split(',')
  else:
    discard path

proc isReadOnlyMount*(path: string): bool =
  ## True when the filesystem view at ``path`` is mounted read-only.
  when defined(linux):
    var st: Statvfs
    if statvfs(path.cstring, st) != 0:
      raiseOSError(osLastError(), "statvfs " & path)
    (culong(st.f_flag) and StRdOnly) != 0
  else:
    false

when defined(linux):
  var privateNamespaceEntered {.threadvar.}: bool

  proc keptMountFlags(path: string): culong =
    ## The per-mount flags of ``path`` other than read-only. A bind
    ## remount replaces them all, and an unprivileged user namespace
    ## refuses to clear one it inherited locked, so they are carried over.
    var st: Statvfs
    if statvfs(path.cstring, st) != 0:
      raiseOSError(osLastError(), "statvfs " & path)
    let f = culong(st.f_flag)
    if (f and StNoSuid) != 0: result = result or MsNoSuid
    if (f and StNoDev) != 0: result = result or MsNoDev
    if (f and StNoExec) != 0: result = result or MsNoExec
    if (f and StNoAtime) != 0: result = result or MsNoAtime
    if (f and StNoDirAtime) != 0: result = result or MsNoDirAtime
    if (f and StRelAtime) != 0: result = result or MsRelAtime

proc enterWritableStoreView*(storeRoot: string) =
  ## Make ``storeRoot`` writable for the calling thread and nothing else.
  ##
  ## When ``storeRoot`` is not a read-only mount point there is nothing to
  ## do and nothing is unshared: a store that is a plain directory (a test
  ## root, a host before bootstrap) is written in place. Otherwise the
  ## thread enters a private mount namespace (once; ``/`` made private so
  ## no mount event leaks out of it) and the bind is remounted without
  ## ``MS_RDONLY`` there, keeping its other flags. Idempotent.
  when defined(linux):
    if not dirExists(storeRoot) or not isReadOnlyMount(storeRoot):
      return
    if not isMountPoint(storeRoot) or superblockReadOnly(storeRoot):
      raise newException(OSError, storeRoot & " is on a read-only " &
        "filesystem, not a read-only bind of itself; a private remount " &
        "cannot make it writable. The add-on store needs a writable " &
        "filesystem under the read-only bind (spec §5.1, §10.2)")
    if not privateNamespaceEntered:
      if c_unshare(CloneNewNs) != 0:
        raiseOSError(osLastError(), "unshare(CLONE_NEWNS) to write " &
          storeRoot)
      # Stop mount events propagating out of (or into) this namespace
      # before changing anything in it. Until this succeeds the thread is
      # in a namespace that still shares propagation with the host, so the
      # view is not recorded as entered and no remount is attempted.
      if c_mount(nil, "/", nil, MsRec or MsPrivate, nil) != 0:
        raiseOSError(osLastError(), "make / private in the store view")
      privateNamespaceEntered = true
    if c_mount(nil, storeRoot.cstring, nil,
        MsRemount or MsBind or keptMountFlags(storeRoot), nil) != 0:
      raiseOSError(osLastError(), "remount " & storeRoot & " writable")
  else:
    discard storeRoot

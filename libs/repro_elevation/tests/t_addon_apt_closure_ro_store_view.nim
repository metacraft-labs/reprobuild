## The privileged driver realises a ``package(apt, ...)`` closure into a
## store that is mounted read-only (ReproOS Add-On Mode spec §10.2, "Store
## integrity"; §8.3 item 4).
##
## On a bootstrapped add-on host ``/repro/store`` is a read-only bind mount
## over itself. rpi2, 2026-10-30, reprobuild d7c86107b: the first
## deploy-agent tick after bootstrap failed 33 times with "realising its
## package(apt) closure failed: Read-only file system", because the driver
## wrote the store without entering the private writable view the spec
## gives the apply process. This test reproduces that mount: a scratch store
## bound read-only over itself in a mount namespace, and checks that
##
## * ``realiseAddOnAptClosure`` realises the closure into it, and
## * a sibling process in the same namespace still sees the store
##   read-only afterwards (the view is private to the realiser).
##
## MOCK JUSTIFICATION. The mount is real (an unprivileged user namespace
## maps the test's user to root so it may bind-mount; this is the only way a
## test can create a read-only bind without being root). The store, the
## realiser and the driver entry point are the production ones. Only the
## transport is substituted: the ``.deb`` is built by this file and served
## by a fetcher that copies it, because the case under test is the write,
## not the download. The test is skipped, with a printed reason, on a
## kernel that refuses unprivileged user namespaces; it never passes there.

import std/[os, strutils, tables, unittest]
when defined(linux):
  import std/posix

import repro_test_support/reasoned_skip

import repro_dsl_stdlib/packages/apt_closure
import repro_dsl_stdlib/packages/apt_jammy
import repro_elevation/posix_system_driver
import repro_elevation/store_view

when defined(linux):
  var
    CloneNewUser {.importc: "CLONE_NEWUSER", header: "<sched.h>".}: cint
    CloneNewNs {.importc: "CLONE_NEWNS", header: "<sched.h>".}: cint
    MsRec {.importc: "MS_REC", header: "<sys/mount.h>".}: culong
    MsPrivate {.importc: "MS_PRIVATE", header: "<sys/mount.h>".}: culong
    MsRemount {.importc: "MS_REMOUNT", header: "<sys/mount.h>".}: culong
    MsBind {.importc: "MS_BIND", header: "<sys/mount.h>".}: culong
    MsRdOnly {.importc: "MS_RDONLY", header: "<sys/mount.h>".}: culong
    MsNoSuid {.importc: "MS_NOSUID", header: "<sys/mount.h>".}: culong
    MsNoDev {.importc: "MS_NODEV", header: "<sys/mount.h>".}: culong
    MsNoExec {.importc: "MS_NOEXEC", header: "<sys/mount.h>".}: culong
    StNoSuid {.importc: "ST_NOSUID", header: "<sys/statvfs.h>".}: culong
    StNoDev {.importc: "ST_NODEV", header: "<sys/statvfs.h>".}: culong
    StNoExec {.importc: "ST_NOEXEC", header: "<sys/statvfs.h>".}: culong
  proc c_unshare(flags: cint): cint {.importc: "unshare", header: "<sched.h>".}
  proc c_mount(source, target, fstype: cstring; flags: culong;
               data: pointer): cint {.importc: "mount",
                                      header: "<sys/mount.h>".}

proc octal(v: int64; width: int): string = toOct(v, width - 1) & "\0"

proc tarFile(name, content: string; typeflag = '0'; mode = 0o644): string =
  var h = newString(512)
  for i in 0 ..< 512: h[i] = '\0'
  h[0 ..< name.len] = name
  h[100 ..< 108] = octal(mode, 8)
  h[108 ..< 116] = octal(0, 8)
  h[116 ..< 124] = octal(0, 8)
  h[124 ..< 136] = octal(content.len, 12)
  h[136 ..< 148] = octal(0, 12)
  h[156] = typeflag
  h[257 ..< 263] = "ustar\0"
  h[263 ..< 265] = "00"
  for i in 148 ..< 156: h[i] = ' '
  var sum = 0
  for c in h: sum += ord(c)
  h[148 ..< 155] = toOct(sum, 6) & "\0"
  h[155] = ' '
  result = h & content & "\0".repeat((512 - content.len mod 512) mod 512)

proc arMember(name, payload: string): string =
  var header = name & "/"
  header.add(" ".repeat(16 - header.len))
  header.add("0".alignLeft(12) & "0".alignLeft(6) & "0".alignLeft(6) &
    "100644".alignLeft(8) & ($payload.len).alignLeft(10) & "`\n")
  result = header & payload
  if (payload.len and 1) == 1: result.add('\n')

proc hostDebianArchitecture(): string =
  case hostMachineName()
  of "x86_64": "amd64"
  of "aarch64": "arm64"
  of "armv7l": "armhf"
  else: ""

proc fixture(root: string): (AptClosureLock, AptDebFetcher) =
  let tarStream = tarFile("./", "", '5', 0o755) &
    tarFile("./usr/", "", '5', 0o755) &
    tarFile("./usr/bin/", "", '5', 0o755) &
    tarFile("./usr/bin/svc", "svc-binary", '0', 0o755) &
    "\0".repeat(1024)
  let deb = root / "svc.deb"
  writeFile(deb, "!<arch>\n" & arMember("debian-binary", "2.0\n") &
    arMember("data.tar", tarStream))
  let lock = AptClosureLock(
    archive: "http://deb.example.invalid/debian", suite: "trixie",
    components: @["main"], architecture: hostDebianArchitecture(),
    snapshot: "", inReleaseSha256: "c".repeat(64),
    indexes: @[AptIndexDigest(path: "main/binary-x/Packages.xz",
                              sha256: "d".repeat(64))],
    roots: @["svc"],
    debs: @[AptLockedDeb(name: "svc", version: "1.0", architecture: "all",
      filename: "pool/main/s/svc/svc_1.0_all.deb", size: getFileSize(deb),
      sha256: sha256OfFile(deb))])
  let fetch: AptDebFetcher = proc (url: string; dest: string;
                                   expectedSize: int64) =
    copyFile(deb, dest)
  (lock, fetch)

when defined(linux):
  proc lockedFlags(path: string): culong =
    var st: Statvfs
    doAssert statvfs(path.cstring, st) == 0
    let f = culong(st.f_flag)
    if (f and StNoSuid) != 0: result = result or MsNoSuid
    if (f and StNoDev) != 0: result = result or MsNoDev
    if (f and StNoExec) != 0: result = result or MsNoExec

  proc enterTestNamespace(): bool =
    ## Become root of a fresh user + mount namespace. False when the
    ## kernel refuses unprivileged user namespaces.
    let uid = getuid()
    let gid = getgid()
    if c_unshare(CloneNewUser or CloneNewNs) != 0:
      return false
    writeFile("/proc/self/setgroups", "deny")
    writeFile("/proc/self/uid_map", "0 " & $uid & " 1")
    writeFile("/proc/self/gid_map", "0 " & $gid & " 1")
    doAssert c_mount(nil, "/", nil, MsRec or MsPrivate, nil) == 0
    true

  proc bindReadOnly(path: string) =
    ## What generation 0's ``repro-store.mount`` does: ``bind,ro`` over
    ## itself.
    doAssert c_mount(path.cstring, path.cstring, nil, MsBind, nil) == 0
    doAssert c_mount(nil, path.cstring, nil,
      MsRemount or MsBind or MsRdOnly or lockedFlags(path), nil) == 0

suite "Add-On apt closure: realised into a read-only store (spec §10.2)":
  test "the driver writes through a private view; others still see it read-only":
    when not defined(linux):
      skip("the read-only bind and mount namespaces are Linux-only")
    else:
      let root = getTempDir() / ("t-addon-ro-store-" & $getCurrentProcessId())
      if dirExists(root): removeDir(root)
      createDir(root / "store")
      let (lock, fetch) = fixture(root)
      check lock.architecture.len > 0
      var toObserver: array[2, cint]
      var fromObserver: array[2, cint]
      doAssert pipe(toObserver) == 0 and pipe(fromObserver) == 0
      let realiser = fork()
      doAssert realiser >= 0
      if realiser == 0:
        # Realiser: owns the namespace and the read-only store.
        var code = 0
        try:
          if not enterTestNamespace():
            code = 77
          else:
            bindReadOnly(root / "store")
            doAssert isReadOnlyMount(root / "store")
            let observer = fork()
            doAssert observer >= 0
            if observer == 0:
              # Observer: same namespace, never enters the private view.
              var b: char
              discard posix.read(toObserver[0], addr b, 1)
              var verdict = 'w'
              try:
                writeFile(root / "store" / "observer-write", "x")
              except IOError, OSError:
                if isReadOnlyMount(root / "store"): verdict = 'r'
              discard posix.write(fromObserver[1], addr verdict, 1)
              exitnow(0)
            let prefix = realiseAddOnAptClosure(lock, root / "store",
              root / "cache", fetch)
            if readFile(prefix / "usr/bin/svc") != "svc-binary": code = 2
            var go = 'g'
            discard posix.write(toObserver[1], addr go, 1)
            var verdict: char
            discard posix.read(fromObserver[0], addr verdict, 1)
            var st: cint
            discard waitpid(observer, st, 0)
            if verdict != 'r': code = 3
        except CatchableError as ex:
          stderr.writeLine("realiser failed: " & ex.msg)
          code = 1
        exitnow(cint(code))
      var status: cint
      doAssert waitpid(realiser, status, 0) == realiser
      let code = if WIFEXITED(status): int(WEXITSTATUS(status)) else: 128
      if code == 77:
        skip("unprivileged user namespaces are disabled on this kernel; " &
          "the read-only bind cannot be made without root")
      else:
        # 1: the realisation failed (the d7c86107b symptom: EROFS);
        # 2: wrong content; 3: the store was writable outside the view.
        check code == 0
        check aptClosureRealised(root / "store", lock)
      removeDir(root)

when defined(linux):
  proc inNamespaceChild(body: proc (): int): int =
    ## Run ``body`` in a forked child that is root of its own user + mount
    ## namespace; its return value is the child's exit code (77: no userns).
    let pid = fork()
    doAssert pid >= 0
    if pid == 0:
      var code = 0
      try:
        code = if enterTestNamespace(): body() else: 77
      except CatchableError as ex:
        stderr.writeLine("child failed: " & ex.msg)
        code = 1
      exitnow(cint(code))
    var status: cint
    doAssert waitpid(pid, status, 0) == pid
    if WIFEXITED(status): int(WEXITSTATUS(status)) else: 128

suite "Add-On store view: ordering and refusals (spec §10.2)":
  test "a write after generation 0's read-only mount appears still succeeds":
    # Bootstrap writes the store while it is a plain directory, then
    # generation 0 mounts it read-only over itself, then bootstrap writes
    # again. The second write must remount, not trust the first call.
    when not defined(linux):
      skip("the read-only bind and mount namespaces are Linux-only")
    else:
      let store = getTempDir() / ("t-addon-ro-order-" &
        $getCurrentProcessId()) / "store"
      createDir(store)
      let code = inNamespaceChild(proc (): int =
        enterWritableStoreView(store)          # plain directory: nothing to do
        writeFile(store / "before-mount", "x")
        bindReadOnly(store)                    # generation 0's mount
        try:
          writeFile(store / "unviewed", "x")
          return 2                             # the bind was not read-only
        except IOError, OSError: discard
        enterWritableStoreView(store)
        writeFile(store / "after-mount", "x")
        0)
      if code == 77:
        skip("unprivileged user namespaces are disabled on this kernel")
      else:
        check code == 0
        check fileExists(store / "after-mount")
      removeDir(parentDir(store))

  test "a store on a read-only filesystem (not a bind) is refused by name":
    when not defined(linux):
      skip("the read-only bind and mount namespaces are Linux-only")
    else:
      let store = getTempDir() / ("t-addon-ro-fs-" &
        $getCurrentProcessId()) / "store"
      createDir(store)
      let code = inNamespaceChild(proc (): int =
        # A filesystem whose superblock is read-only: what a store on an
        # iso9660 or erofs image, or a read-only root, looks like.
        doAssert c_mount("tmpfs", store.cstring, "tmpfs", MsRdOnly, nil) == 0
        try:
          enterWritableStoreView(store)
          return 2
        except OSError as e:
          if "read-only filesystem, not a read-only bind" notin e.msg:
            stderr.writeLine("wrong refusal: " & e.msg)
            return 3
        0)
      if code == 77:
        skip("unprivileged user namespaces are disabled on this kernel")
      else:
        check code == 0
      removeDir(parentDir(store))

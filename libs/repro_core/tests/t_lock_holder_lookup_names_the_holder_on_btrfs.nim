## A deadline-bounded lock that times out names the process holding it, on
## btrfs as on every other Linux filesystem.
##
## reprobuild-pm issue 2026-11-15-lock-holder-lookup-names-nobody-on-btrfs.
## `file_lock.flockHolderPids` finds a lock's holder in `/proc/locks`, whose
## lines name the locked file as `<major>:<minor>:<inode>`. It used to match
## that device against `fstat(fd).st_dev`. On btrfs the two differ: `stat`
## reports the subvolume's anonymous device (a fresh `0:N` per subvolume),
## while `/proc/locks` prints the superblock's `s_dev`, which is also the
## device `/proc/self/mountinfo` gives for the mount. So no line ever
## matched, every `ELockTimeout` said "a process /proc/locks does not name",
## and the realiser lock of ReproOS-Add-On-Mode.md §8.3 item 4 could not name
## its holder on the root filesystem of many NixOS hosts.
##
## Two kinds of case:
##
## * The text-matching procedures, fed the exact `/proc/self/fdinfo`,
##   `/proc/self/mountinfo` and `/proc/locks` text captured on a btrfs
##   subvolume (Linux 6.18, `stat` device 0:66, mount device 0:50 = hex 32;
##   only the mount path is replaced by a generic one). These are real
##   kernel output, not an invented format, and they run on every host, so
##   the btrfs shape is pinned even where no btrfs is mounted.
## * Live cases with no mocks: a forked child really holds the `flock`, and
##   the lookup reads the real `/proc` files. One runs in the ordinary
##   temporary directory (any filesystem). The other needs a directory on a
##   btrfs subvolume whose `stat` device differs from its mount's: the
##   temporary directory when it is one (as on a btrfs-rooted host), or the
##   directory named by `REPRO_TEST_BTRFS_DIR`. Creating a btrfs mount needs
##   root, so where neither exists the case skips with that reason. The test
##   never writes into a btrfs mount it merely finds on the host: that
##   directory belongs to someone else.

import std/[os, strutils, tempfiles, unittest]

import repro_core/file_lock
import repro_test_support/reasoned_skip

when defined(linux):
  import std/posix

  const BtrfsDirEnvVar = "REPRO_TEST_BTRFS_DIR"

  proc exitCodeOf(pid: Pid): int =
    var status: cint
    doAssert waitpid(pid, status, 0) == pid
    if WIFEXITED(status): int(WEXITSTATUS(status)) else: 128

  proc unescapeMountField(s: string): string =
    ## mountinfo escapes space, tab, newline and backslash as `\ooo`.
    var i = 0
    while i < s.len:
      if s[i] == '\\' and i + 3 <= s.high and
          s[i+1] in {'0'..'7'} and s[i+2] in {'0'..'7'} and
          s[i+3] in {'0'..'7'}:
        result.add(char(parseOctInt(s[i+1..i+3])))
        i += 4
      else:
        result.add(s[i])
        inc i

  proc mountOf(dir: string): tuple[fstype: string; major, minor: int] =
    ## The filesystem type and mountinfo device of the mount `dir` is on:
    ## the longest mount point that is a prefix of it. Written here
    ## independently of the code under test, so choosing the fixture does
    ## not depend on what is being tested.
    let target = expandFilename(dir)
    var best = -1
    for line in readFile("/proc/self/mountinfo").splitLines():
      let sep = line.find(" - ")
      if sep < 0: continue
      let f = line[0 ..< sep].splitWhitespace()
      let tail = line[sep + 3 .. ^1].splitWhitespace()
      if f.len < 5 or tail.len < 1: continue
      let mp = unescapeMountField(f[4])
      let under = target == mp or mp == "/" or
        target.startsWith(mp & "/")
      if not under or mp.len < best: continue
      let mm = f[2].split(':')
      if mm.len != 2: continue
      best = mp.len
      result = (tail[0], parseInt(mm[0]), parseInt(mm[1]))

  proc statDevice(path: string): tuple[major, minor: int] =
    var st: Stat
    doAssert stat(path.cstring, st) == 0
    let d = deviceOfStDev(uint64(st.st_dev))
    (int(d.major), int(d.minor))

  proc isMismatchedBtrfs(dir: string): bool =
    ## A btrfs directory whose `stat` device is not its mount's: exactly
    ## the condition the issue describes.
    if not dirExists(dir): return false
    let m = mountOf(dir)
    m.fstype == "btrfs" and statDevice(dir) != (m.major, m.minor)

  proc btrfsSubvolumeDir(): string =
    let named = getEnv(BtrfsDirEnvVar)
    if named.len > 0:
      # Named on purpose: a directory that cannot exercise the defect is a
      # configuration error, not a reason to pass quietly.
      doAssert isMismatchedBtrfs(named), BtrfsDirEnvVar & "=" & named &
        " is not a btrfs directory whose stat device differs from its " &
        "mount's device"
      return named
    if isMismatchedBtrfs(getTempDir()): return getTempDir()
    ""

  proc holdInChild(path: string): tuple[pid: Pid; release: cint] =
    ## Fork a child that takes an exclusive flock on `path`, says so on a
    ## pipe, and keeps it until the parent closes the other pipe.
    var ready, hold: array[2, cint]
    doAssert pipe(ready) == 0 and pipe(hold) == 0
    let pid = fork()
    doAssert pid >= 0
    if pid == 0:
      discard posix.close(ready[0])
      discard posix.close(hold[1])
      var code = 0
      try:
        var l = acquireExclusiveFileLock(path)
        var b = 'r'
        discard posix.write(ready[1], addr b, 1)
        discard posix.read(hold[0], addr b, 1)
        releaseExclusiveFileLock(l)
      except CatchableError:
        code = 1
      exitnow(cint(code))
    discard posix.close(ready[1])
    discard posix.close(hold[0])
    var b: char
    doAssert posix.read(ready[0], addr b, 1) == 1
    discard posix.close(ready[0])
    (pid, hold[1])

  type HolderReport = object
    holder: int           ## the pid that really holds the lock
    lookedUp: seq[int]    ## what flockHolderPids named
    refusedBy: seq[int]   ## ELockTimeout.holderPids
    refusal: string       ## ELockTimeout's message
    childExit: int

  proc lockHeldByAChild(dir: string): HolderReport =
    ## Lock a file in `dir` from a forked child, then ask who holds it both
    ## ways a caller can: `flockHolderPids` and a timed-out acquisition.
    let tmp = createTempDir("lock-holder-", "", dir)
    defer: removeDir(tmp)
    let path = tmp / "held.lock"
    let (pid, release) = holdInChild(path)
    result.holder = int(pid)
    let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC)
    doAssert fd >= 0
    result.lookedUp = flockHolderPids(fd)
    discard posix.close(fd)
    try:
      var l = acquireExclusiveLockWithin(path, 0)
      releaseExclusiveFileLock(l)
    except ELockTimeout as e:
      result.refusedBy = e.holderPids
      result.refusal = e.msg
    discard posix.close(release)
    result.childExit = exitCodeOf(pid)

  suite "the holder of a timed-out lock is named (live, Linux)":
    test "in the temporary directory":
      let r = lockHeldByAChild(getTempDir())
      checkpoint("refusal: " & r.refusal)
      check r.lookedUp == @[r.holder]
      check r.refusedBy == @[r.holder]
      check ("pid " & $r.holder) in r.refusal
      check r.childExit == 0

    test "on a btrfs subvolume, whose stat device is not its mount's":
      let dir = btrfsSubvolumeDir()
      if dir.len == 0:
        skip("no btrfs subvolume to lock in: the temporary directory is " &
          "not one and " & BtrfsDirEnvVar & " is unset (mounting btrfs " &
          "needs root)")
      else:
        let r = lockHeldByAChild(dir)
        checkpoint("btrfs directory: " & dir & "; refusal: " & r.refusal)
        check r.lookedUp == @[r.holder]
        check r.refusedBy == @[r.holder]
        check ("pid " & $r.holder) in r.refusal
        check r.childExit == 0

# Captured on a btrfs subvolume (Linux 6.18) while pid 164658 held an
# exclusive flock on inode 258: `stat` said 0:66, the mount is 0:50 (hex 32).
# Only the mount point and source path are generic stand-ins.
const
  CapturedFdinfo = "pos:\t0\nflags:\t02100002\nmnt_id:\t389\nino:\t258\n" &
    "lock:\t1: FLOCK  ADVISORY  WRITE 164658 00:32:258 0 EOF\n"
  CapturedMountinfo =
    "23 1 0:21 / / rw,relatime shared:1 - zfs pool/root rw,xattr\n" &
    "389 183 0:50 / /mnt/btrfs rw,relatime shared:418 - btrfs /dev/loop9 " &
      "rw,ssd,discard=async,space_cache=v2,user_subvol_rm_allowed," &
      "subvolid=5,subvol=/\n"
  CapturedLocks =
    "258: FLOCK  ADVISORY  READ 4108063 00:35:9328513 0 EOF\n" &
    "303: FLOCK  ADVISORY  WRITE 164658 00:32:258 0 EOF\n"
  StatDevice: LockDevice = (0'u64, 66'u64)

suite "the /proc texts a holder lookup reads":
  test "a btrfs lock is matched through the fd's mount, not stat's device":
    let mountId = fdinfoMountId(CapturedFdinfo)
    check mountId == 389
    var mount: LockDevice
    check mountinfoDevice(CapturedMountinfo, mountId, mount)
    check mount == (0'u64, 50'u64)
    # stat's device alone names nobody: the defect.
    check procLocksFlockHolders(CapturedLocks, [StatDevice], 258, 1).len == 0
    check procLocksFlockHolders(CapturedLocks, [StatDevice, mount], 258,
      1) == @[164658]

  test "st_dev splits into the major and minor /proc prints":
    check deviceOfStDev(66'u64) == (0'u64, 66'u64)
    check deviceOfStDev(0x0803'u64) == (8'u64, 3'u64)
    # makedev(0x1234, 0x5678) in glibc's encoding.
    check deviceOfStDev(0x0000_1000_0562_3478'u64) ==
      (0x1234'u64, 0x5678'u64)

  test "a missing or malformed mnt_id is no mount":
    check fdinfoMountId("pos:\t0\nflags:\t02\n") == -1
    check fdinfoMountId("mnt_id:\tx\n") == -1
    check fdinfoMountId("") == -1
    var mount: LockDevice
    check not mountinfoDevice(CapturedMountinfo, 390, mount)
    check not mountinfoDevice(CapturedMountinfo, -1, mount)
    check not mountinfoDevice("389 183 garbage / /x - btrfs\n", 389, mount)
    check not mountinfoDevice("", 389, mount)

  test "only granted FLOCK holders of that inode, other than us, are named":
    let mount: LockDevice = (0'u64, 50'u64)
    let locks =
      "1: FLOCK  ADVISORY  WRITE 100 00:32:258 0 EOF\n" &
      "1: -> FLOCK  ADVISORY  WRITE 101 00:32:258 0 EOF\n" & # a waiter
      "2: POSIX  ADVISORY  WRITE 102 00:32:258 0 EOF\n" &   # not a flock
      "3: FLOCK  ADVISORY  WRITE 103 00:32:259 0 EOF\n" &   # other inode
      "4: FLOCK  ADVISORY  WRITE 104 00:33:258 0 EOF\n" &   # other device
      "5: FLOCK  ADVISORY  READ  105 0:032:258 0 EOF\n" &   # other widths
      "6: FLOCK  ADVISORY  READ  100 00:32:258 0 EOF\n" &   # a repeat
      "7: FLOCK  ADVISORY  READ  999 00:32:258 0 EOF\n" &   # ourselves
      "8: FLOCK  ADVISORY  READ  zz 00:32:258 0 EOF\n" &    # malformed pid
      "9: FLOCK  ADVISORY  READ  106 00:32 0 EOF\n" &       # malformed id
      "truncated\n"
    check procLocksFlockHolders(locks, [mount], 258, 999) == @[100, 105]
    check procLocksFlockHolders(locks, [], 258, 999).len == 0
    check procLocksFlockHolders("", [mount], 258, 999).len == 0

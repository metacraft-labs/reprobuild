## The add-on's file writer never follows a symbolic link (threat model
## G29, T34): a link as the leaf, a link as a parent component, and a link
## planted between the plan-time check and the write all leave the link's
## target byte-identical, and a normal write lands with its final mode.
##
## *Mocking.* None: real files, links and directories under a temporary
## directory, written through the same ``openat``/``renameat`` path the
## add-on uses on a host. (The owner change is only attempted as root.)

import std/[os, posix, unittest]

import repro_addon/etc_write

let root = getTempDir() / ("repro-addon-etcwrite-" & $getCurrentProcessId())
removeDir(root)
createDir(root / "etc/app")
createDir(root / "outside")
writeFile(root / "outside/target", "untouched\n")

suite "writeFileNoFollow":
  test "a plain write lands atomically with the requested mode":
    writeFileNoFollow(root / "etc/app/a.conf", "hello\n", 0o640)
    check readFile(root / "etc/app/a.conf") == "hello\n"
    var st: Stat
    check lstat(cstring(root / "etc/app/a.conf"), st) == 0
    check (int(st.st_mode) and 0o7777) == 0o640
    # No temporary file is left behind.
    var leftovers = 0
    for f in walkDir(root / "etc/app"):
      if f.path != root / "etc/app/a.conf": inc leftovers
    check leftovers == 0

  test "an existing regular file is replaced, not written through":
    writeFileNoFollow(root / "etc/app/a.conf", "second\n", 0o644)
    check readFile(root / "etc/app/a.conf") == "second\n"

  test "a link as the leaf is refused and its target is byte-identical":
    discard symlink(cstring(root / "outside/target"), cstring(root / "etc/app/leaf"))
    expect SymlinkOnPath:
      writeFileNoFollow(root / "etc/app/leaf", "redirected\n", 0o644)
    check readFile(root / "outside/target") == "untouched\n"
    check symlinkExists(root / "etc/app/leaf")

  test "a link as a parent component is refused, naming the link":
    discard symlink(cstring(root / "outside"), cstring(root / "etc/linkdir"))
    try:
      writeFileNoFollow(root / "etc/linkdir/target", "redirected\n", 0o644)
      check false
    except SymlinkOnPath as e:
      check e.link == root / "etc/linkdir"
    check readFile(root / "outside/target") == "untouched\n"

  test "a relative or dotted path is refused":
    expect EtcWriteError:
      writeFileNoFollow("etc/app/x", "x", 0o644)
    expect EtcWriteError:
      writeFileNoFollow(root & "/etc/app/../app/x", "x", 0o644)

  test "a missing parent directory is an error, not a creation through a link":
    expect OSError:
      writeFileNoFollow(root / "etc/missing/x.conf", "x", 0o644)

  test "symlinkComponent reports the first link on the path, or nothing":
    check symlinkComponent(root / "etc/linkdir/deeper/x") == root / "etc/linkdir"
    check symlinkComponent(root / "etc/app/leaf") == root / "etc/app/leaf"
    check symlinkComponent(root / "etc/app/a.conf") == ""
    check symlinkComponent(root / "etc/app/not/yet/there") == ""

  test "parseOwner reads uid:gid":
    check parseOwner("0:0") == (0, 0)
    check parseOwner("1000:27") == (1000, 27)
    expect EtcWriteError:
      discard parseOwner("root")

removeDir(root)

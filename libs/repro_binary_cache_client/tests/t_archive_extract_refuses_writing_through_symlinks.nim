## A substituted prefix archive must never write outside the directory it is
## extracted into.
##
## `extractPrefix` already refuses entry paths that are absolute or contain
## `..`. That is not enough on its own: `rbcarc-v2` carries symbolic links, and
## a link entry followed by an entry *beneath* or *at* the link's path makes
## the extractor write wherever the link points. Substituted prefixes are
## materialised by `repro infra apply`, which runs as root, so a crafted entry
## such as `d -> /etc` followed by `d/cron.d/job` would plant a root cron job.
##
## Each case below hand-builds the archive bytes (the documented wire format:
## magic, version, entry count, then per entry path length, path, kind, mode,
## body length, body), points the hostile link at a real directory OUTSIDE the
## extraction root inside the test's own temporary tree, and asserts that the
## extractor raises and that nothing appeared outside. A positive control
## checks that ordinary relative links -- which real prefixes carry, such as
## `libfoo.so -> libfoo.so.1` -- still extract byte-identically.
##
## No mocks: real files, real symlinks, the real extractor.

import std/[os, unittest]

import ../src/repro_binary_cache_client

const
  KindFile = 0'u8
  KindDirectory = 1'u8
  KindSymlink = 2'u8

type Entry = tuple[path: string, kind: uint8, mode: uint32, body: string]

proc u32(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff))

proc u64(buf: var seq[byte]; v: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((v shr uint64(shift)) and 0xff))

proc archive(entries: openArray[Entry]): seq[byte] =
  for ch in "RBCA": result.add(byte(ch))
  u32(result, 2'u32)
  u32(result, uint32(entries.len))
  for e in entries:
    u32(result, uint32(e.path.len))
    for ch in e.path: result.add(byte(ch))
    result.add(e.kind)
    u32(result, e.mode)
    u64(result, uint64(e.body.len))
    for ch in e.body: result.add(byte(ch))

proc freshTree(name: string): tuple[root, outDir, outside: string] =
  let root = getTempDir() / ("rbcarc-symlink-" & name & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root / "out")
  createDir(root / "outside")
  (root, root / "out", root / "outside")

proc entriesUnder(dir: string): seq[string] =
  for p in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
    result.add(p.relativePath(dir))

suite "rbcarc extraction never writes through a symlink":
  test "a file beneath a link entry is refused":
    let t = freshTree("beneath")
    defer: removeDir(t.root)
    let bytes = archive([
      (path: "d", kind: KindSymlink, mode: 0'u32, body: t.outside),
      (path: "d/cron.d/job", kind: KindFile, mode: 0o644'u32, body: "pwned\n")])
    expect IOError:
      extractPrefix(bytes, t.outDir)
    check entriesUnder(t.outside).len == 0

  test "a file at the path of an earlier link entry is refused":
    let t = freshTree("at")
    defer: removeDir(t.root)
    writeFile(t.outside / "target", "original\n")
    let bytes = archive([
      (path: "f", kind: KindSymlink, mode: 0'u32, body: t.outside / "target"),
      (path: "f", kind: KindFile, mode: 0o644'u32, body: "pwned\n")])
    expect IOError:
      extractPrefix(bytes, t.outDir)
    check readFile(t.outside / "target") == "original\n"

  test "a directory beneath a link entry is refused":
    let t = freshTree("dir")
    defer: removeDir(t.root)
    let bytes = archive([
      (path: "d", kind: KindSymlink, mode: 0'u32, body: t.outside),
      (path: "d/sub", kind: KindDirectory, mode: 0o755'u32, body: "")])
    expect IOError:
      extractPrefix(bytes, t.outDir)
    check entriesUnder(t.outside).len == 0

  test "a link beneath a relative link that climbs out is refused":
    let t = freshTree("relative")
    defer: removeDir(t.root)
    let bytes = archive([
      (path: "up", kind: KindSymlink, mode: 0'u32, body: "../outside"),
      (path: "up/planted", kind: KindSymlink, mode: 0'u32, body: "/bin/sh")])
    expect IOError:
      extractPrefix(bytes, t.outDir)
    check entriesUnder(t.outside).len == 0

  test "positive control: ordinary relative links still extract":
    let t = freshTree("ok")
    defer: removeDir(t.root)
    let bytes = archive([
      (path: "lib", kind: KindDirectory, mode: 0o755'u32, body: ""),
      (path: "lib/libfoo.so.1", kind: KindFile, mode: 0o644'u32, body: "ELF\0lib"),
      (path: "lib/libfoo.so", kind: KindSymlink, mode: 0'u32, body: "libfoo.so.1"),
      (path: "bin/tool", kind: KindFile, mode: 0o755'u32, body: "#!/bin/sh\n")])
    extractPrefix(bytes, t.outDir)
    check readFile(t.outDir / "lib/libfoo.so.1") == "ELF\0lib"
    check symlinkExists(t.outDir / "lib/libfoo.so")
    check expandSymlink(t.outDir / "lib/libfoo.so") == "libfoo.so.1"
    check readFile(t.outDir / "lib/libfoo.so") == "ELF\0lib"
    check readFile(t.outDir / "bin/tool") == "#!/bin/sh\n"

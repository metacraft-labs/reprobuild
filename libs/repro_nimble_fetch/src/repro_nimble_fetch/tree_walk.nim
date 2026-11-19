## The canonical tree of a directory on disk, read without following a link.
##
## The client side of the source digest (NPC-AREQ12): what the generator
## computes from git objects (`repro_nimble_generator/source_tree`), this
## computes from an extracted tree, with the same typed serialization
## (`repro_multihash.canonicalTreeMultihash`): every regular file with its
## path, content and owner executable bit, every symbolic link with its path
## and target text. Directories carry no entry of their own (git records
## none), so an empty directory is not part of a tree.
##
## Every entry is classified with `lstat(2)`, so a link is read as a link
## (`readlink(2)`) and never followed, whatever it points at. Anything that
## is neither a regular file, a directory nor a link (a FIFO, a socket, a
## device) cannot come from a git tree and is refused, as is a path holding
## a byte the serialization cannot frame.

import std/[algorithm, os, strutils]
when defined(posix):
  import std/posix

import repro_multihash

type
  TreeWalkError* = object of IOError

proc walkError(msg: string) {.noreturn.} =
  raise newException(TreeWalkError, msg)

when defined(posix):
  proc readLinkText(path: string): string =
    var buf = newString(4096)
    let n = readlink(path.cstring, addr buf[0], buf.len)
    if n < 0:
      walkError("cannot read link " & path & ": " & osErrorMsg(osLastError()))
    if n >= buf.len:
      walkError("link target of " & path & " is longer than 4095 bytes")
    buf.setLen(n)
    buf

proc canonicalEntriesOf*(dir: string): seq[CanonicalTreeEntry] =
  ## The typed entries of the tree under ``dir``, sorted by path. Raises
  ## `TreeWalkError` for an entry no source tree can hold.
  when not defined(posix):
    walkError("reading a source tree's modes and links needs a POSIX host")
  else:
    var stack = @[""]
    while stack.len > 0:
      let rel = stack.pop()
      let abs = if rel.len == 0: dir else: dir / rel
      for kind, child in walkDir(abs, relative = true, checkDir = true):
        let childRel = if rel.len == 0: child else: rel & "/" & child
        let childAbs = dir / childRel
        var st: Stat
        if lstat(childAbs.cstring, st) != 0:
          walkError("cannot stat " & childAbs & ": " &
            osErrorMsg(osLastError()))
        if '\0' in childRel:
          walkError("a path holds NUL: " & childRel.escape())
        if S_ISDIR(st.st_mode):
          stack.add childRel
        elif S_ISLNK(st.st_mode):
          result.add CanonicalTreeEntry(path: childRel, kind: cekSymlink,
            content: readLinkText(childAbs))
        elif S_ISREG(st.st_mode):
          let exec = (int(st.st_mode) and int(S_IXUSR)) != 0
          result.add CanonicalTreeEntry(path: childRel,
            kind: (if exec: cekExecutable else: cekRegular),
            content: readFile(childAbs))
        else:
          walkError(childAbs & " is neither a file, a directory nor a " &
            "symbolic link")
    result.sort(proc (a, b: CanonicalTreeEntry): int = cmp(a.path, b.path))

proc treeDigestOf*(dir: string): string =
  ## Lower-case hex of the canonical tree digest of ``dir`` (no `blake3:`).
  let mh = canonicalTreeMultihash(canonicalEntriesOf(dir))
  mh["blake3:".len .. ^1]

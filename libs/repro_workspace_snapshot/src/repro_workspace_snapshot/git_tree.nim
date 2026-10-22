## A native git tree-object hash over a directory, restricted to a tracked
## path set — Distributed-Execution M7.
##
## `treeIdOf(root, tracked)` computes the id `git write-tree` would produce
## for an index holding exactly the `tracked` paths with the content and mode
## they have ON DISK under `root` (a tracked path that is missing is left
## out, exactly as a temporary-index content id leaves a deleted file out).
## That is the TC-8 `git-tree-sha1` of the state, computed without a `.git`
## directory and without consulting anything else under `root`: build
## outputs the goal wrote next to the sources are not tracked and do not
## participate, while ANY change to a tracked file does.
##
## Git object formats (https://git-scm.com/book/en/v2/Git-Internals-Git-Objects):
##   blob  = "blob <len>\0" || content
##   tree  = "tree <len>\0" || { "<mode> <name>\0" || 20-byte object id }*
## Tree entries are sorted by name, a subtree comparing as `name + "/"`;
## modes are 100644, 100755, 120000 (symlink, content = target) and 40000.

import std/[algorithm, os, strutils, tables]
when defined(posix):
  import std/posix

import nimcrypto/[hash, sha]

type
  Sha1Bytes* = array[20, byte]

  TreeIdResult* = object
    ok*: bool
    treeHex*: string
    reason*: string
    missing*: seq[string]
      ## Tracked paths absent on disk (left out of the tree).

proc hexOf*(b: openArray[byte]): string =
  const H = "0123456789abcdef"
  result = newString(b.len * 2)
  for i, x in b:
    result[2 * i] = H[int(x) shr 4]
    result[2 * i + 1] = H[int(x) and 0xf]

proc sha1Of(data: openArray[byte]): Sha1Bytes =
  let d = sha1.digest(data)
  for i in 0 ..< 20: result[i] = d.data[i]

proc gitObjectId*(kind: string; content: openArray[byte]): Sha1Bytes =
  var buf: seq[byte] = @[]
  for ch in kind & " " & $content.len: buf.add(byte(ord(ch)))
  buf.add(0'u8)
  buf.add(content)
  sha1Of(buf)

proc gitBlobOid*(content: openArray[byte]): string =
  hexOf(gitObjectId("blob", content))

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc diskEntry*(path: string): tuple[present: bool; mode: string;
                                     oid: Sha1Bytes] =
  ## Mode and blob id of what stands at `path`, as git would record it.
  when defined(posix):
    var st: Stat
    if lstat(path.cstring, st) != 0:
      return (false, "", default(Sha1Bytes))
    if S_ISLNK(st.st_mode):
      return (true, "120000", gitObjectId("blob", toBytes(expandSymlink(path))))
    if not S_ISREG(st.st_mode):
      return (false, "", default(Sha1Bytes))
    let exec = (st.st_mode.int and 0o100) != 0
    (true, (if exec: "100755" else: "100644"),
     gitObjectId("blob", toBytes(readFile(path))))
  else:
    if not fileExists(path):
      return (false, "", default(Sha1Bytes))
    (true, "100644", gitObjectId("blob", toBytes(readFile(path))))

type
  Node = ref object
    files: seq[tuple[name, mode: string; oid: Sha1Bytes]]
    dirs: OrderedTable[string, Node]

proc treeOid(n: Node): Sha1Bytes =
  var entries: seq[tuple[key, name, mode: string; oid: Sha1Bytes]] = @[]
  for f in n.files:
    entries.add((f.name, f.name, f.mode, f.oid))
  for name, child in n.dirs.pairs:
    entries.add((name & "/", name, "40000", treeOid(child)))
  entries.sort(proc(a, b: auto): int = cmp(a.key, b.key))
  var content: seq[byte] = @[]
  for e in entries:
    for ch in e.mode & " " & e.name: content.add(byte(ord(ch)))
    content.add(0'u8)
    content.add(e.oid)
  gitObjectId("tree", content)

proc parseSha1Hex*(hex: string): Sha1Bytes =
  if hex.len != 40:
    raise newException(ValueError, "not a 40-hex object id: " & hex)
  for i in 0 ..< 20:
    result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc treeIdOf*(root: string; tracked: openArray[string];
               gitlinks: openArray[(string, string)] = []): TreeIdResult =
  ## See the module doc. `tracked` are worktree-relative `/`-separated paths.
  ## `gitlinks` are submodule entries (path, 40-hex commit id): mode 160000,
  ## taken from the manifest and the base tree, never from disk (a worktree
  ## holds no submodule content; threat model G32).
  let top = Node(dirs: initOrderedTable[string, Node]())
  proc place(rel, mode: string; oid: Sha1Bytes) =
    let parts = rel.split('/')
    var cur = top
    for i in 0 ..< parts.high:
      if not cur.dirs.hasKey(parts[i]):
        cur.dirs[parts[i]] = Node(dirs: initOrderedTable[string, Node]())
      cur = cur.dirs[parts[i]]
    cur.files.add((parts[^1], mode, oid))
  for rel in tracked:
    let entry = diskEntry(root / rel)
    if not entry.present:
      result.missing.add(rel)
      continue
    place(rel, entry.mode, entry.oid)
  for (rel, commit) in gitlinks:
    try:
      place(rel, "160000", parseSha1Hex(commit))
    except ValueError as err:
      return TreeIdResult(reason: err.msg)
  result.ok = true
  result.treeHex = hexOf(treeOid(top))

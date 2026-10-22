## Library-local tests for `repro_workspace_snapshot` (Distributed-Execution
## M7; threat model G32).
##
##   * `validateManifest` refuses every shape that could steer a write outside
##     the materialized tree (absolute, `..`, `.git`, backslash, unsorted or
##     duplicate entries, modified-and-deleted), and a submodule entry that
##     claims a blob;
##   * the strict codec round-trips and refuses trailing bytes;
##   * `treeIdOf` equals `git write-tree` — for a plain tree, and for a tree
##     with a SUBMODULE: the gitlink is part of the tree id, so a repository
##     with submodules verifies (positive control) and the same computation
##     without the gitlink does not (the defect it fixes: gitlinks used to be
##     left out, and such a repository never verified);
##   * `materializeRepoSnapshot` of that repository verifies its tree, with a
##     submodule moved to another commit in the snapshot;
##   * the base checkout writes BLOB BYTES, untouched by any git conversion:
##     a tree whose `.gitattributes` asks for `eol=crlf`, `ident` and a smudge
##     filter, in a cache that also sets `core.autocrlf` and an
##     `info/attributes` rule, materializes byte for byte as `git cat-file`
##     returns it and verifies its tree (the defect it fixes: a converted
##     checkout hashed to another tree id and every such snapshot was
##     refused), next to a modified entry written from the manifest; a
##     replace ref in the cache does not substitute a blob's bytes, and a
##     base tree with a `.GIT` component is refused as git refuses it.
##
## MOCK POLICY — none: a real git repository with a real submodule; tree ids
## are computed by git itself and by the library, and compared.

import std/[options, os, osproc, strutils, tables, tempfiles, unittest]

import blake3

import repro_workspace_snapshot

proc git(dir: string; args: varargs[string]): string =
  let res = execCmdEx(quoteShellCommand(@["git", "-C", dir] & @args))
  doAssert res.exitCode == 0, "git " & args.join(" ") & ": " & res.output
  res.output.strip()

proc gitRepo(dir: string) =
  createDir(dir)
  discard git(dir, "init", "-q", "-b", "main")
  discard git(dir, "config", "user.email", "m7@example.invalid")
  discard git(dir, "config", "user.name", "M7")
  discard git(dir, "config", "protocol.file.allow", "always")

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc entry(rel: string; content = "x"): ModifiedFileEntry =
  let b = toBytes(content)
  ModifiedFileEntry(relPath: rel, mode: ModeRegular, gitOid: gitBlobOid(b),
    blake3Digest: blake3.digest(b), size: uint64(b.len))

proc manifestWith(modified: seq[ModifiedFileEntry];
                  deleted: seq[string] = @[]): WorkspaceSnapshotManifest =
  WorkspaceSnapshotManifest(schema: ManifestSchema, primaryRepo: RepoSnapshot(
    repoId: "r", baseCommitSha: repeat('a', 40), gitTreeSha1: repeat('b', 40),
    modified: modified, deleted: deleted))

suite "repro_workspace_snapshot: manifests and tree ids":

  test "validation refuses unsafe paths and malformed entries":
    check validateManifest(manifestWith(@[entry("src/a.c")])) == ""
    for bad in ["/etc/passwd", "../x", "a/../b", "a/.git/config", ".git",
                "a\\b", "a//b", "./a"]:
      check validateManifest(manifestWith(@[entry(bad)])) != ""
    check validateManifest(manifestWith(@[entry("b"), entry("a")])) != ""
    check validateManifest(manifestWith(@[entry("a"), entry("a")])) != ""
    check validateManifest(manifestWith(@[entry("a")], @["a"])) != ""
    var link = entry("sub")
    link.mode = ModeGitlink
    link.gitOid = repeat('c', 40)
    check validateManifest(manifestWith(@[link])) != ""   # claims a blob
    link.size = 0
    link.blake3Digest = default(Blake3Digest)
    check validateManifest(manifestWith(@[link])) == ""   # metadata only
    var weird = entry("a")
    weird.mode = 0o100600'u32
    check validateManifest(manifestWith(@[weird])) != ""

  test "the codec round-trips and is strict":
    let m = manifestWith(@[entry("src/a.c", "int main(){}")], @["old.txt"])
    let bytes = encodeManifest(m)
    check decodeManifest(bytes) == m
    expect ManifestError:
      discard decodeManifest(bytes & @[0'u8])
    expect ManifestError:
      discard decodeManifest(bytes[0 ..< bytes.len - 3])

  test "a repository with a submodule verifies, gitlink included":
    let base = createTempDir("m7-snapshot-", "")
    defer: removeDir(base)
    let sub = base / "sub"
    gitRepo(sub)
    writeFile(sub / "lib.c", "int lib(void){return 1;}\n")
    discard git(sub, "add", "-A")
    discard git(sub, "commit", "-q", "-m", "sub")
    let subCommit = git(sub, "rev-parse", "HEAD")
    let repo = base / "repo"
    gitRepo(repo)
    writeFile(repo / "main.c", "int main(void){return 0;}\n")
    discard git(repo, "-c", "protocol.file.allow=always", "submodule", "add",
      "-q", sub, "vendor/sub")
    discard git(repo, "add", "-A")
    discard git(repo, "commit", "-q", "-m", "base")
    let head = git(repo, "rev-parse", "HEAD")
    let tree = git(repo, "rev-parse", "HEAD^{tree}")
    let cache = base / "cache.git"
    discard execCmdEx(quoteShellCommand(["git", "clone", "-q", "--bare", repo,
      cache]))
    let paths = trackedPathsAt(cache, head)
    check paths.ok
    check paths.gitlinks == @[("vendor/sub", subCommit)]
    # The library's tree id over a checkout equals git's — WITH the gitlink.
    let checkout = base / "checkout"
    discard execCmdEx(quoteShellCommand(["git", "clone", "-q", repo, checkout]))
    let withLink = treeIdOf(checkout, paths.paths, paths.gitlinks)
    check withLink.ok
    check withLink.treeHex == tree
    # Without it — what the worker computed before — it never matches.
    check treeIdOf(checkout, paths.paths).treeHex != tree
    # Materializing a snapshot that moves the submodule to another commit
    # verifies against the tree git computes for that state.
    writeFile(sub / "lib.c", "int lib(void){return 2;}\n")
    discard git(sub, "commit", "-q", "-am", "sub v2")
    let subCommit2 = git(sub, "rev-parse", "HEAD")
    discard git(repo / "vendor" / "sub", "fetch", "-q", "origin")
    discard git(repo / "vendor" / "sub", "checkout", "-q", subCommit2)
    discard git(repo, "add", "vendor/sub")
    let index = base / "idx"
    let env = "GIT_INDEX_FILE=" & quoteShell(index) & " "
    discard execCmdEx(env & "git -C " & quoteShell(repo) & " read-tree HEAD")
    discard execCmdEx(env & "git -C " & quoteShell(repo) & " add -A")
    let dirtyTree = execCmdEx(env & "git -C " & quoteShell(repo) &
      " write-tree").output.strip()
    check dirtyTree != tree
    var snap = RepoSnapshot(repoId: "r", baseCommitSha: head,
      gitTreeSha1: dirtyTree, modified: @[ModifiedFileEntry(
        relPath: "vendor/sub", mode: ModeGitlink, gitOid: subCommit2)])
    check validateManifest(WorkspaceSnapshotManifest(schema: ManifestSchema,
      primaryRepo: snap)) == ""
    let reader = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
      none(seq[byte])
    let mat = materializeRepoSnapshot(cache, snap, base / "wt", reader)
    checkpoint("materialize: " & mat.reason)
    check mat.ok
    check mat.observedTree == dirtyTree
    check reverifyTree(base / "wt", mat.tracked, dirtyTree, mat.gitlinks).ok

  test "the base checkout writes blob bytes, with no git conversion":
    let base = createTempDir("m7-snapshot-attrs-", "")
    defer: removeDir(base)
    let repo = base / "repo"
    gitRepo(repo)
    writeFile(repo / ".gitattributes",
      "*.txt text eol=crlf\n*.id ident\n*.up filter=upper\n")
    writeFile(repo / "f.txt", "a\nb\n")
    writeFile(repo / "v.id", "$Id$\n")
    writeFile(repo / "u.up", "hello\n")
    writeFile(repo / "m.c", "int main(void){return 0;}\n")
    createDir(repo / "src")
    writeFile(repo / "src" / "keep.txt", "unchanged\n")
    writeFile(repo / "src" / "edit.txt", "before\n")
    discard git(repo, "add", "-A")
    discard git(repo, "commit", "-q", "-m", "base")
    let head = git(repo, "rev-parse", "HEAD")
    let tree = git(repo, "rev-parse", "HEAD^{tree}")
    let cache = base / "cache.git"
    discard execCmdEx(quoteShellCommand(["git", "clone", "-q", "--bare", repo,
      cache]))
    # Every conversion git would apply on checkout, configured in the CACHE
    # the worker reads (its config and its info/attributes), on top of the
    # committed `.gitattributes`.
    discard git(cache, "config", "filter.upper.smudge", "tr a-z A-Z")
    discard git(cache, "config", "filter.upper.clean", "cat")
    discard git(cache, "config", "core.autocrlf", "true")
    createDir(cache / "info")
    writeFile(cache / "info" / "attributes", "*.c text eol=crlf\n")
    let reader = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
      none(seq[byte])
    # No modifications: the snapshot IS the base tree.
    let clean = RepoSnapshot(repoId: "r", baseCommitSha: head,
      gitTreeSha1: tree)
    let mat = materializeRepoSnapshot(cache, clean, base / "wt", reader)
    checkpoint("materialize: " & mat.reason)
    check mat.ok
    check mat.observedTree == tree
    for rel in [".gitattributes", "f.txt", "v.id", "u.up", "m.c",
                "src/keep.txt", "src/edit.txt"]:
      checkpoint(rel)
      check readFile(base / "wt" / rel) ==
        execCmdEx(quoteShellCommand(["git", "--git-dir=" & cache, "cat-file",
          "blob", head & ":" & rel])).output
    check reverifyTree(base / "wt", mat.tracked, tree, mat.gitlinks).ok
    # A modified entry and the base files under conversion attributes
    # coexist: the tree git computes for that state verifies.
    let edited = "after\n"
    let editedBytes = toBytes(edited)
    writeFile(repo / "src" / "edit.txt", edited)
    let index = base / "idx"
    let env = "GIT_INDEX_FILE=" & quoteShell(index) & " "
    discard execCmdEx(env & "git -C " & quoteShell(repo) & " read-tree HEAD")
    discard execCmdEx(env & "git -C " & quoteShell(repo) &
      " update-index --add src/edit.txt")
    let dirtyTree = execCmdEx(env & "git -C " & quoteShell(repo) &
      " write-tree").output.strip()
    check dirtyTree != tree
    let dirty = RepoSnapshot(repoId: "r", baseCommitSha: head,
      gitTreeSha1: dirtyTree, modified: @[entry("src/edit.txt", edited)])
    check validateManifest(WorkspaceSnapshotManifest(schema: ManifestSchema,
      primaryRepo: dirty)) == ""
    let blobs = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
      if d == blake3.digest(editedBytes): some(editedBytes)
      else: none(seq[byte])
    let mat2 = materializeRepoSnapshot(cache, dirty, base / "wt2", blobs)
    checkpoint("materialize (modified): " & mat2.reason)
    check mat2.ok
    check mat2.observedTree == dirtyTree
    check readFile(base / "wt2" / "src" / "edit.txt") == edited
    check readFile(base / "wt2" / "f.txt") == "a\nb\n"
    check readFile(base / "wt2" / "u.up") == "hello\n"
    check reverifyTree(base / "wt2", mat2.tracked, dirtyTree,
      mat2.gitlinks).ok
    # A replace ref in the cache substitutes nothing: the bytes written are
    # those of the blob the tree names (git itself would read the
    # replacement, and the blob would then fail its id check).
    let keepOid = git(cache, "rev-parse", head & ":src/keep.txt")
    let editOid = git(cache, "rev-parse", head & ":src/edit.txt")
    discard git(cache, "replace", keepOid, editOid)
    let mat3 = materializeRepoSnapshot(cache, clean, base / "wt3", reader)
    checkpoint("materialize (replace ref): " & mat3.reason)
    check mat3.ok
    check readFile(base / "wt3" / "src" / "keep.txt") == "unchanged\n"
    # A base tree git itself would not check out — a `.GIT` component, which
    # a case-insensitive filesystem resolves as `.git` — is refused, not
    # written. `mktree` builds it; `git add` would refuse the path.
    let hiOid = execCmdEx("printf 'hi\\n' | git --git-dir=" & quoteShell(cache) &
      " hash-object -w --stdin").output.strip()
    let inner = execCmdEx("printf '100644 blob " & hiOid & "\\tconfig\\n' | " &
      "git --git-dir=" & quoteShell(cache) & " mktree").output.strip()
    let outer = execCmdEx("printf '040000 tree " & inner & "\\t.GIT\\n' | " &
      "git --git-dir=" & quoteShell(cache) & " mktree").output.strip()
    let evil = git(cache, "-c", "user.name=M7", "-c",
      "user.email=m7@example.invalid", "commit-tree", "-m", "evil", outer)
    let mat4 = materializeRepoSnapshot(cache, RepoSnapshot(repoId: "r",
      baseCommitSha: evil, gitTreeSha1: outer), base / "wt4", reader)
    check not mat4.ok
    check ".git component" in mat4.reason
    check not fileExists(base / "wt4" / ".GIT" / "config")

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
##     submodule moved to another commit in the snapshot.
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

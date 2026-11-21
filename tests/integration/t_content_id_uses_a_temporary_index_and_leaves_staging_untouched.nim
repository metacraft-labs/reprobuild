## TC-8a — a working tree's content id is computed in a temporary index, and
## the user's staging area is neither read as the tested state nor modified.
##
## Content-Id §2 identifies the tracked files as they are IN THE WORKING
## TREE: a modified file contributes its modified bytes, a deleted one
## contributes nothing, a newly added one counts, and untracked or ignored
## files do not. That is exactly the tree ``git commit -a`` records, so that
## is the oracle: the fixture holds a partly staged change, an unstaged
## modification, a newly added file and a deleted tracked file, and the id
## must equal the tree the subsequent ``git commit -a`` writes, while
## ``.git/index`` stays byte-identical across the computation.
##
## The other cases pin the defects a temporary index invites, each with a
## deterministic fixture (explicit timestamps, an explicit monitor) rather
## than a timing race:
##
## * racy git: a copy of the index with a fresh modification time trusts stat
##   data the user's index would have re-checked, and a copy that preserves
##   the original's time still trusts a rewrite that kept size and mtime.
##   The premise of each is asserted first (the trap really is armed), then
##   the id must name the NEW content;
## * a filesystem monitor that has not reported a change hides it from git
##   entirely; the id must name the new content regardless;
## * under ``core.splitIndex`` a write to the temporary index must not leave a
##   ``sharedindex.*`` file in the user's git directory;
## * a repository with no index yet tracks nothing: the empty tree.
##
## Every case also asserts that the library's temporary directory is gone.

import std/[os, strutils, times, unittest]

import repro_cli_support/content_id
import content_id_fixture

proc treeOf(entries: openArray[ContentEntry]): string =
  gitTreeIdOfEntries(entries, caGitTreeSha1).id

proc setMtime(path: string; seconds: int64) =
  setLastModificationTime(path, fromUnix(seconds))

suite "content ids use a temporary index":

  test "t_content_id_uses_a_temporary_index_and_leaves_staging_untouched":
    let scratch = enterHermeticGit()
    let repo = newRepo(scratch, "work")
    writeEntryFile(repo, ".gitignore", "*.log\n")
    writeEntryFile(repo, "partly.txt", "one\n")
    writeEntryFile(repo, "unstaged.txt", "two\n")
    writeEntryFile(repo, "deleted.txt", "three\n")
    writeEntryFile(repo, "same.txt", "four\n")
    commitAll(repo, "base")

    # A partly staged change: one edit staged, a second one not.
    writeEntryFile(repo, "partly.txt", "one\nstaged\n")
    discard git(repo, "add", "partly.txt")
    writeEntryFile(repo, "partly.txt", "one\nstaged\nunstaged\n")
    # An unstaged modification, a newly added file, a deleted tracked file.
    writeEntryFile(repo, "unstaged.txt", "two, edited\n")
    writeEntryFile(repo, "added.txt", "new\n")
    discard git(repo, "add", "added.txt")
    removeFile(repo / "deleted.txt")
    # Untracked and ignored files.
    writeEntryFile(repo, "untracked.txt", "not tracked\n")
    writeEntryFile(repo, "build.log", "ignored\n")

    let before = indexBytes(repo)
    let id = computeContentId(repo, workingTreeState(), caGitTreeSha1)
    checkpoint(id.reason)
    check id.outcome == cioComputed
    check indexBytes(repo) == before

    # The staged state is a different tree, and the index-being-committed
    # state computes exactly that one, also without touching the index.
    let staged = computeContentId(repo, indexState(), caGitTreeSha1)
    check staged.outcome == cioComputed
    check staged.id != id.id
    check indexBytes(repo) == before

    # Untracked and ignored files do not move the id; nor does a second
    # computation.
    writeEntryFile(repo, "another-untracked.txt", "x\n")
    writeEntryFile(repo, "dir/nested.log", "ignored too\n")
    check computeContentId(repo, workingTreeState(), caGitTreeSha1).id == id.id
    check indexBytes(repo) == before

    # The same answer in the manifest algorithm, from the same files.
    let manifest = computeContentId(repo, workingTreeState(), caManifestV1Sha256)
    check manifest.outcome == cioComputed
    check indexBytes(repo) == before

    # The oracle: what `git commit -a` records.
    discard git(repo, "commit", "-q", "-a", "-m", "commit -a")
    check "git-tree-sha1:" & gitLine(repo, "rev-parse", "HEAD^{tree}") == id.id
    check computeContentId(repo, commitState("HEAD"), caManifestV1Sha256).id ==
      manifest.id
    # And the index-state id was the tree of what had been staged.
    check computeContentId(repo, commitState("HEAD"), caGitTreeSha1).id != staged.id
    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)

  test "the temporary index is dated so stat data is never trusted":
    let scratch = enterHermeticGit()
    let base = 1_000_000_000'i64
    let repo = newRepo(scratch, "racy")
    # Compare as little stat data as git allows, so that only content can
    # reveal the edits below.
    discard git(repo, "config", "core.trustctime", "false")
    discard git(repo, "config", "core.checkStat", "minimal")
    writeEntryFile(repo, "a.txt", "aaaa\n")
    setMtime(repo / "a.txt", base)
    commitAll(repo, "base")

    # 1. A same-size edit in the second the index was last written. In the
    #    user's index the entry is racily clean, so git re-reads it; a fresh
    #    copy of that index is newer than the entry, so it does not.
    writeEntryFile(repo, "a.txt", "bbbb\n")
    setMtime(repo / "a.txt", base)
    setMtime(repo / ".git" / "index", base)
    let changed = treeOf([ContentEntry(path: "a.txt", mode: "100644",
                                       content: "bbbb\n")])
    let original = treeOf([ContentEntry(path: "a.txt", mode: "100644",
                                        content: "aaaa\n")])
    block premise:
      let copy = scratch / "fresh-copy-index"
      copyFile(repo / ".git" / "index", copy)
      setMtime(copy, base + 100)
      discard runGitIn(repo, ["add", "--update"],
                       env = [("GIT_INDEX_FILE", copy)])
      check "git-tree-sha1:" & runGitIn(repo, ["write-tree"],
        env = [("GIT_INDEX_FILE", copy)]).stdout.strip() == original
    let before = indexBytes(repo)
    let sameSecond = computeContentId(repo, workingTreeState(), caGitTreeSha1)
    checkpoint(sameSecond.reason)
    check sameSecond.id == changed
    check indexBytes(repo) == before

    # 2. A rewrite that kept size and mtime, long after the index was
    #    written. git itself trusts the stat data here (its status is clean),
    #    and so would a copy that preserved the index's own mtime.
    discard git(repo, "add", "a.txt")
    discard git(repo, "commit", "-q", "-m", "bbbb")
    setMtime(repo / ".git" / "index", base + 100)
    writeEntryFile(repo, "a.txt", "cccc\n")
    setMtime(repo / "a.txt", base)
    check runGitIn(repo, ["status", "--porcelain"],
                   env = [("GIT_OPTIONAL_LOCKS", "0")]).stdout == ""
    let rewritten = treeOf([ContentEntry(path: "a.txt", mode: "100644",
                                         content: "cccc\n")])
    let before2 = indexBytes(repo)
    let preserved = computeContentId(repo, workingTreeState(), caGitTreeSha1)
    checkpoint(preserved.reason)
    check preserved.id == rewritten
    check indexBytes(repo) == before2
    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)

  test "a filesystem monitor that has not reported a change does not hide it":
    let scratch = enterHermeticGit()
    let repo = newRepo(scratch, "monitored")
    writeEntryFile(repo, "a.txt", "aaaa\n")
    commitAll(repo, "base")
    # A monitor hook that always answers "nothing changed".
    let hook = scratch / "fsmonitor-says-nothing-changed"
    writeFile(hook, "#!/bin/sh\nprintf 'token\\0'\n")
    setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})
    discard git(repo, "config", "core.fsmonitor", hook)
    discard git(repo, "update-index", "--fsmonitor")
    discard git(repo, "status", "--porcelain")
    # A change of a different size: stat data alone would reveal it, the
    # monitor's "valid" mark hides it.
    writeEntryFile(repo, "a.txt", "a longer content\n")
    check git(repo, "status", "--porcelain") == ""
    let before = indexBytes(repo)
    let id = computeContentId(repo, workingTreeState(), caGitTreeSha1)
    checkpoint(id.reason)
    check id.id == treeOf([ContentEntry(path: "a.txt", mode: "100644",
                                        content: "a longer content\n")])
    check indexBytes(repo) == before
    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)

  test "a split index gains no shared index file":
    let scratch = enterHermeticGit()
    let repo = newRepo(scratch, "split")
    discard git(repo, "config", "core.splitIndex", "true")
    discard git(repo, "config", "splitIndex.maxPercentChange", "100")
    writeEntryFile(repo, "a.txt", "a\n")
    writeEntryFile(repo, "b.txt", "b\n")
    commitAll(repo, "base")
    discard git(repo, "update-index", "--split-index")
    proc sharedIndexFiles(): seq[string] =
      for kind, path in walkDir(repo / ".git"):
        if path.extractFilename.startsWith("sharedindex."):
          result.add path.extractFilename
    let sharedBefore = sharedIndexFiles()
    check sharedBefore.len > 0
    writeEntryFile(repo, "a.txt", "a, edited\n")
    writeEntryFile(repo, "c.txt", "c\n")
    discard git(repo, "add", "c.txt")
    let before = indexBytes(repo)
    for state in [workingTreeState(), indexState()]:
      let id = computeContentId(repo, state, caGitTreeSha1)
      checkpoint(id.reason)
      check id.outcome == cioComputed
    check computeContentId(repo, workingTreeState(), caGitTreeSha1,
                           ["a.txt"]).outcome == cioComputed
    check sharedIndexFiles() == sharedBefore
    check indexBytes(repo) == before
    check computeContentId(repo, workingTreeState(), caGitTreeSha1).id ==
      treeOf([ContentEntry(path: "a.txt", mode: "100644", content: "a, edited\n"),
              ContentEntry(path: "b.txt", mode: "100644", content: "b\n"),
              ContentEntry(path: "c.txt", mode: "100644", content: "c\n")])
    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)

  test "a repository with no index tracks nothing":
    let scratch = enterHermeticGit()
    for format in [("sha1", caGitTreeSha1), ("sha256", caGitTreeSha256)]:
      let repo = newRepo(scratch, "fresh-" & format[0], format[0])
      writeEntryFile(repo, "untracked.txt", "x\n")
      check not fileExists(repo / ".git" / "index")
      let id = computeContentId(repo, workingTreeState(), format[1])
      checkpoint(id.reason)
      check id.outcome == cioComputed
      check id.id == emptyTree(format[1])
      check not fileExists(repo / ".git" / "index")
    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)

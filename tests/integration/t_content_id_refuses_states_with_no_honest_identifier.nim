## TC-8a — states with no honest content id are refused, by name, with a
## remedy, and never given an id.
##
## Content-Id §3: a content id that silently omits what the tests read makes
## a certificate formally valid and substantively false. So for each state
## below the computation must return ``cioNoContentId`` with the named reason
## and the affected paths, an empty id, and a remedy; ``probeNoContentId``
## must name the same state; and the user's index must be untouched:
##
## * unmerged entries (a real merge conflict);
## * an entry marked ``assume-unchanged`` (whose file then changes);
## * an entry marked ``skip-worktree`` while its file is present, including a
##   file written back into a sparse checkout that uses a sparse index;
## * a nested repository with modified content;
## * a path containing NUL, for ``manifest-v1-sha256`` (an entry list: git
##   itself cannot record such a path).
##
## The controls matter as much as the refusals, because a probe that refused
## everything would pass the list above: a ``skip-worktree`` entry whose file
## is absent (a sparse checkout), a nested repository with only untracked
## files or at a new clean commit, a refusal outside the requested scope, and
## the index being committed, where only unmerged entries count, all compute.

import std/[os, strutils, unittest]

import repro_cli_support/content_id
import content_id_fixture

# Templates, not procs: a `check` must expand inside the `test` body to be
# attributed to the test case it fails.
template expectRefusal(repo: string; expectedReason: NoContentIdReason;
                       expectedPaths: seq[string]; scope: seq[string] = @[]) =
  block:
    let before = indexBytes(repo)
    for algorithm in [caGitTreeSha1, caManifestV1Sha256]:
      let refused = computeContentId(repo, workingTreeState(), algorithm, scope)
      checkpoint($algorithm & ": " & refused.reason)
      check refused.outcome == cioNoContentId
      check refused.id == ""
      check refused.findings.len == 1
      if refused.findings.len == 1:
        check refused.findings[0].reason == expectedReason
        check refused.findings[0].paths == expectedPaths
        check refused.findings[0].remedy().len > 0
      check $expectedReason in refused.reason
    let probe = probeNoContentId(repo, scope)
    check probe.ok
    check probe.findings.len == 1
    if probe.findings.len == 1:
      check probe.findings[0].reason == expectedReason
      check probe.findings[0].paths == expectedPaths
    check indexBytes(repo) == before

template expectComputed(repo: string; state = workingTreeState();
                        scope: seq[string] = @[]): string =
  block:
    let before = indexBytes(repo)
    let computedId = computeContentId(repo, state, caGitTreeSha1, scope)
    checkpoint(computedId.reason)
    check computedId.outcome == cioComputed
    check indexBytes(repo) == before
    computedId.id

suite "content ids refuse states with no honest identifier":

  test "t_content_id_refuses_states_with_no_honest_identifier":
    let scratch = enterHermeticGit()

    # --- unmerged entries ---------------------------------------------------
    let conflict = newRepo(scratch, "conflict")
    writeEntryFile(conflict, "shared.txt", "base\n")
    writeEntryFile(conflict, "other/file.txt", "untouched\n")
    commitAll(conflict, "base")
    discard git(conflict, "checkout", "-q", "-b", "side")
    writeEntryFile(conflict, "shared.txt", "side\n")
    commitAll(conflict, "side")
    discard git(conflict, "checkout", "-q", "main")
    writeEntryFile(conflict, "shared.txt", "main\n")
    commitAll(conflict, "main")
    check runGitIn(conflict, ["merge", "-q", "side"]).code != 0
    expectRefusal(conflict, ncrUnmergedEntries, @["shared.txt"])
    # The index being committed has no single content either.
    let mergeIndex = computeContentId(conflict, indexState(), caGitTreeSha1)
    check mergeIndex.outcome == cioNoContentId
    check mergeIndex.findings.len == 1
    if mergeIndex.findings.len == 1:
      check mergeIndex.findings[0].reason == ncrUnmergedEntries
    # Outside the scope, the conflict does not refuse.
    check expectComputed(conflict, scope = @["other"]).len > 0

    # --- assume-unchanged ---------------------------------------------------
    let assumed = newRepo(scratch, "assumed")
    writeEntryFile(assumed, "config.txt", "committed\n")
    writeEntryFile(assumed, "plain.txt", "plain\n")
    commitAll(assumed, "base")
    discard git(assumed, "update-index", "--assume-unchanged", "config.txt")
    writeEntryFile(assumed, "config.txt", "what the tests really read\n")
    expectRefusal(assumed, ncrAssumeUnchanged, @["config.txt"])
    # A commit takes the index as it is, so it is not refused.
    check expectComputed(assumed, indexState()).len > 0
    check expectComputed(assumed, scope = @["plain.txt"]).len > 0

    # --- skip-worktree with the file present, and absent --------------------
    let skipped = newRepo(scratch, "skipped")
    writeEntryFile(skipped, "present.txt", "indexed\n")
    writeEntryFile(skipped, "absent.txt", "indexed\n")
    commitAll(skipped, "base")
    discard git(skipped, "update-index", "--skip-worktree", "present.txt",
                "absent.txt")
    removeFile(skipped / "absent.txt")
    writeEntryFile(skipped, "present.txt", "what the tests really read\n")
    expectRefusal(skipped, ncrSkipWorktreePresent, @["present.txt"])
    # Absent is how a sparse checkout leaves it: the indexed content is the
    # content, and it is kept.
    let sparse = expectComputed(skipped, scope = @["absent.txt"])
    check sparse == gitTreeIdOfEntries([ContentEntry(path: "absent.txt",
      mode: "100644", content: "indexed\n")], caGitTreeSha1).id

    # --- a real sparse checkout with a sparse index -------------------------
    # git clears the mark of a present file when it reads such an index, yet
    # `add --update` still leaves the file out; the recorded mark must count.
    let cone = newRepo(scratch, "cone")
    writeEntryFile(cone, "in/a.txt", "a\n")
    writeEntryFile(cone, "out/b.txt", "b\n")
    commitAll(cone, "base")
    let coneTree = "git-tree-sha1:" & gitLine(cone, "rev-parse", "HEAD^{tree}")
    discard git(cone, "sparse-checkout", "set", "--cone", "--sparse-index",
                "in")
    check not fileExists(cone / "out" / "b.txt")
    check expectComputed(cone) == coneTree
    writeEntryFile(cone, "out/b.txt", "what the tests really read\n")
    expectRefusal(cone, ncrSkipWorktreePresent, @["out/b.txt"])

    # --- a nested repository with modified content --------------------------
    let outer = newRepo(scratch, "outer")
    writeEntryFile(outer, "top.txt", "top\n")
    let nested = newRepo(outer, "nested")
    writeEntryFile(nested, "inner.txt", "inner\n")
    commitAll(nested, "inner")
    commitAll(outer, "outer")
    check gitLine(outer, "ls-files", "-s", "nested").startsWith("160000 ")
    # Only untracked files inside: not modified content.
    writeEntryFile(nested, "scratch.tmp", "untracked\n")
    let withUntracked = expectComputed(outer)
    check withUntracked == "git-tree-sha1:" & gitLine(outer, "rev-parse",
                                                      "HEAD^{tree}")
    # A new clean commit inside: the gitlink moves to it.
    writeEntryFile(nested, "inner.txt", "inner, recommitted\n")
    discard git(nested, "commit", "-q", "-a", "-m", "again")
    let moved = expectComputed(outer)
    check moved != withUntracked
    # Modified tracked content inside: refused.
    writeEntryFile(nested, "inner.txt", "modified, not committed\n")
    expectRefusal(outer, ncrNestedRepositoryModified, @["nested"])
    check expectComputed(outer, scope = @["top.txt"]).len > 0

    # --- several states at once are all named --------------------------------
    discard git(outer, "update-index", "--assume-unchanged", "top.txt")
    let both = computeContentId(outer, workingTreeState(), caGitTreeSha1)
    check both.outcome == cioNoContentId
    check both.findings.len == 2

    # --- a path containing NUL, for manifest-v1 -----------------------------
    let entries = @[
      ContentEntry(path: "ok.txt", mode: "100644", content: "fine\n"),
      ContentEntry(path: "bad\0name", mode: "100644", content: "x\n")]
    let manifest = manifestV1Sha256(entries)
    check manifest.outcome == cioNoContentId
    check manifest.id == ""
    check manifest.findings.len == 1
    if manifest.findings.len == 1:
      check manifest.findings[0].reason == ncrUnrepresentablePath
      check manifest.findings[0].remedy().len > 0
    # Out of scope, it is not part of the claim.
    check manifestV1Sha256(entries, ["ok.txt"]).outcome == cioComputed

    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)

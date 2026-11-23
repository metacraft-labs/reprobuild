## HL-10 (push half) — comparing certified trees with the judged tree is a
## local question, in a partial clone too: ``compareTreesByEntries`` never
## fetches a tree the repository lacks, whichever git runs it.
##
## Why it matters: the local certificate store is per user, so most of the
## trees it names belong to other repositories, and in a partial clone (what
## workspace leaves are) git otherwise fetches every object it is asked about
## and lacks, from inside commands that look local, with no time limit. The
## gates' search for certified content that differs only in managed lock
## files asks about up to 64 such trees on every uncovered verdict
## (Test-Certificates.md §"Gate integration — push requirement").
##
## Fixture: a real upstream that allows filtered and any-object fetches, a
## real ``--filter=blob:none`` clone of it (every tree of the cloned history
## present), and a tree made upstream AFTER the clone — absent from the
## clone, fetchable from its promisor. Steps:
##
##   1. Compare HEAD's tree with [the absent upstream tree, the parent
##      commit's tree, a non-object name, HEAD's tree itself] using the git on
##      ``PATH``: the absent tree is not present, the parent's tree differs in
##      exactly ``repro.lock``, the bad name is not present, HEAD's tree is
##      present with no difference — and the absent tree is still absent.
##   2. The same through a git wrapper that drops ``GIT_NO_LAZY_FETCH`` from
##      its environment, standing in for a git older than 2.42 that ignores
##      the variable: the same answer, the tree still absent. Only the empty
##      ``GIT_ALLOW_PROTOCOL`` stops this fetch, so removing it fails here
##      (verified 2026-11-22 by deleting it from ``NoLazyFetch``).
##   3. Control: a plain ``git cat-file --batch-check`` of the absent tree in
##      the clone DOES fetch it, so steps 1 and 2 test a fetch that would
##      have happened.
##
## NO MOCKS: real repositories and the real git; the wrapper is a two-line
## shell script that only removes one variable before running that git.
## Skip rule: not on Windows (the wrapper is a POSIX shell script).

import std/[os, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_cli_support/content_id
import content_id_fixture

proc objectPresent(repo, oid: string): bool =
  ## Whether ``oid`` is in ``repo`` without asking any promisor for it.
  runGitIn(repo, ["cat-file", "-e", oid],
    env = [("GIT_NO_LAZY_FETCH", "1"), ("GIT_ALLOW_PROTOCOL", "")]).code == 0

suite "HL-10 — tree comparison never fetches in a partial clone":

  test "t_tree_comparison_never_fetches_in_a_partial_clone":
    when defined(windows):
      skip("the git wrapper that ignores GIT_NO_LAZY_FETCH is a POSIX " &
        "shell script")
    else:
      let scratch = enterHermeticGit()
      defer: leaveHermeticGit(scratch)
      let upstream = newRepo(scratch, "upstream")
      discard git(upstream, "config", "uploadpack.allowFilter", "true")
      discard git(upstream, "config", "uploadpack.allowAnySHA1InWant", "true")
      writeEntryFile(upstream, "src/main.c", "int main(void);\n")
      writeEntryFile(upstream, "repro.lock", "lock v1\n")
      commitAll(upstream, "base")
      writeEntryFile(upstream, "repro.lock", "lock v2\n")
      commitAll(upstream, "re-pin")

      discard git(scratch, "clone", "-q", "--filter=blob:none",
        "file://" & upstream, "leaf")
      let leaf = scratch / "leaf"
      let head = gitLine(leaf, "rev-parse", "HEAD^{tree}")
      let parent = gitLine(leaf, "rev-parse", "HEAD~1^{tree}")

      # A tree the clone never received: made upstream after cloning.
      writeEntryFile(upstream, "src/other.c", "int other(void);\n")
      commitAll(upstream, "later")
      let absent = gitLine(upstream, "rev-parse", "HEAD^{tree}")
      check not objectPresent(leaf, absent)

      proc checkAnswer(compared: TreeEntryComparisons) =
        checkpoint($compared)
        check compared.ok
        check compared.compared.len == 4
        if compared.compared.len == 4:
          check compared.compared[0].tree == absent
          check not compared.compared[0].present
          check compared.compared[1].present
          check compared.compared[1].differing == @["repro.lock"]
          check not compared.compared[2].present
          check compared.compared[3].present
          check compared.compared[3].differing.len == 0

      let candidates = [absent, parent, "not-an-object-name", head]

      # ---- 1. the git on PATH -------------------------------------------
      checkAnswer(compareTreesByEntries(leaf, head, candidates))
      check not objectPresent(leaf, absent)

      # ---- 2. a git that ignores GIT_NO_LAZY_FETCH ------------------------
      let realGit = findExe("git")
      require realGit.len > 0
      let wrapper = scratch / "git-ignoring-no-lazy-fetch"
      writeFile(wrapper, "#!/bin/sh\nunset GIT_NO_LAZY_FETCH\nexec " &
        quoteShell(realGit) & " \"$@\"\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      checkAnswer(compareTreesByEntries(leaf, head, candidates,
        ContentIdGit(binary: wrapper)))
      check not objectPresent(leaf, absent)

      # ---- 3. control: an unguarded lookup fetches it ---------------------
      let fetched = runGitIn(leaf, ["cat-file", "--batch-check"],
        input = absent & "\n")
      checkpoint(fetched.stdout & fetched.stderr)
      check fetched.stdout.startsWith(absent & " tree")
      check objectPresent(leaf, absent)

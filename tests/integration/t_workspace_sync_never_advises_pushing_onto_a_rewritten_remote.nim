## ``repro workspace sync`` — a checkout whose remote history was rewritten
## is never told to ``git push``.
##
## WHY THIS TEST EXISTS
##
## Force-push detection asked one question: are any of the commits between
## ``<remote>/<current branch>`` and ``HEAD`` in the recorded force-pushed
## set? On a LOCAL branch — one with no ``refs/remotes/<remote>/<branch>``
## counterpart — that ref does not resolve, the ``git log`` exits non-zero,
## and the question is never answered. The checkout then fell through to
## ``locally_unpublished``, whose remedy text was:
##
##   "local commits are not present on any remote-tracking branch; refused —
##    run 'git -C <path> push' then 'repro sync' ..."
##
## After a history rewrite that is the worst instruction the tool can give.
## The branch is sitting on history the remote deliberately removed, and
## ``git push`` puts it back. Measured at ca49246a against a checkout rebuilt
## from a real pre-force-push mirror (175 commits, EMPTY merge-base with the
## new history), on a local branch with one commit of the operator's own
## work: ``locally_unpublished``, and exactly that remedy.
##
## Two things have to be true for the fix to be a fix, and this test asserts
## both:
##
##   1. DETECTION — a branch with no remote counterpart whose history is
##      disjoint from the remote's trunk is recognised as sitting on
##      rewritten history, with no ``.repro/records`` and no recorded
##      force-pushed SHAs to lean on. That is the state a workspace is
##      actually in when it learns about a rewrite: it was not running a
##      sync when the rewrite happened.
##
##   2. WORDING — the remedy does not tell the operator to push. Asserting
##      the verdict alone would pass while the dangerous sentence survived,
##      because the sentence is in a different field from the tag.
##
## NEGATIVE CONTROL: an ordinary local feature branch, cut from the CURRENT
## trunk in a repo nobody rewrote, must still be ``locally_unpublished`` and
## must still be allowed to say "push" — otherwise the fix has simply
## replaced one wrong answer with another, everywhere.
##
## Skip rule: ``git`` missing on PATH (the convention this suite follows).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath, marker: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Rewrite Tester\"")
  writeFile(workPath / "README.md", marker & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m " &
    q("seed " & marker))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc rewriteOriginWithDisjointHistory(gitBin, originPath, workPath: string) =
  ## Replace the origin's ``main`` with a history that shares NO ancestor
  ## with the old one — an orphan root, force-pushed over the branch. This
  ## is the shape ten of the eleven real rewritten repos had: the merge-base
  ## of the old and new tips is empty.
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " switch --orphan rewritten")
  writeFile(workPath / "README.md", "rewritten history\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"rewritten root\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push --force " & q(originPath) & " rewritten:main")

proc localBranchWithOwnWork(gitBin, repoPath, branch: string): string =
  ## A branch that exists ONLY here: never pushed, so there is no
  ## ``refs/remotes/origin/<branch>`` for the force-push probe to use.
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " switch -c " & branch)
  writeFile(repoPath / "my-work.txt", "work the operator owns\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add my-work.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"my own work\"")
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc repoFragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & name & "\"\n" &
  "revision = \"main\"\n"

proc projectToml(remotes: seq[(string, string)]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"rewriteproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for (name, url) in remotes:
    result.add("[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url &
      "\"\n\n")
  result.add("includes = [\n")
  for (name, _) in remotes:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

proc entryFor(doc: JsonNode; name: string): JsonNode =
  for entry in doc["repos"]:
    if entry["name"].getStr() == name:
      return entry
  nil

proc advisesPush(reason: string): bool =
  ## Does this remedy hand the operator a RUNNABLE ``git … push``?
  ##
  ## The question is deliberately about the COMMAND, not the word. The
  ## rewrite-aware text says "do NOT push" — it names the verb in order to
  ## forbid it — so ``"push" in reason`` would condemn the fixed wording and
  ## the test would pass for the wrong reason in both directions. So: find
  ## each "push", walk back to the start of the quoted command it sits in,
  ## and ask whether that command is a ``git`` invocation. "run 'git -C x
  ## push'" is one; "do NOT push" is not.
  let lowered = reason.toLowerAscii()
  var idx = lowered.find("push")
  while idx >= 0:
    let before = lowered[max(0, idx - 60) ..< idx]
    let quoteAt = before.rfind('\'')
    let command = if quoteAt >= 0: before[quoteAt + 1 .. ^1] else: before
    if command.strip().startsWith("git "):
      return true
    idx = lowered.find("push", idx + 4)
  false

suite "repro workspace sync — never advise pushing onto a rewritten remote":

  test "t_workspace_sync_never_advises_pushing_onto_a_rewritten_remote":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sync-rewrite-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      var remotes: seq[(string, string)]

      # (1) The rewritten repo. Clone it FIRST, while the old history is
      # still what the origin serves, then rewrite the origin underneath the
      # checkout — the real sequence.
      let purgedOrigin = scratch / "origin-purged.git"
      let purgedSeed = scratch / "seed-purged"
      let oldTip = seedOrigin(gitBin, purgedOrigin, purgedSeed, "old")
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(purgedOrigin)) &
        " " & q(workspaceRoot / "purged"))
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " config user.name \"Rewrite Tester\"")
      let purgedHead = localBranchWithOwnWork(gitBin,
        workspaceRoot / "purged", "my-feature")
      rewriteOriginWithDisjointHistory(gitBin, purgedOrigin, purgedSeed)
      writeFile(workspaceRoot / "repos" / "purged.toml",
        repoFragmentToml("purged"))
      remotes.add(("purged", fileUrl(purgedOrigin)))

      # (2) The control repo: nobody rewrote it. Same branch shape — local
      # only, one unpublished commit — so the ONLY difference between the
      # two rows below is whether the remote history was rewritten.
      let intactOrigin = scratch / "origin-intact.git"
      let intactSeed = scratch / "seed-intact"
      discard seedOrigin(gitBin, intactOrigin, intactSeed, "intact")
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(intactOrigin)) &
        " " & q(workspaceRoot / "intact"))
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "intact") &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "intact") &
        " config user.name \"Rewrite Tester\"")
      let intactHead = localBranchWithOwnWork(gitBin,
        workspaceRoot / "intact", "my-feature")
      writeFile(workspaceRoot / "repos" / "intact.toml",
        repoFragmentToml("intact"))
      remotes.add(("intact", fileUrl(intactOrigin)))

      writeFile(workspaceRoot / "projects" / "rewriteproject.toml",
        projectToml(remotes))

      # THE PREMISE, asserted rather than assumed: no recorded force-push
      # history exists, and the local branch has no remote counterpart. If
      # either were false the case would be testing an easier problem than
      # the one the field posed.
      check not fileExists(workspaceRoot / ".repro" / "records")
      check runCmd(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " rev-parse --verify --quiet refs/remotes/origin/my-feature").code != 0

      let res = runShell(shellCommand(@[
        reproBin, "workspace", "sync", "rewriteproject", "--write-report",
        "--workspace-root=" & workspaceRoot,
      ]))
      let reportPath = workspaceRoot / ".repro" / "build" / "reports" /
        "sync-report.json"
      if not fileExists(reportPath):
        checkpoint("no sync report written; exit=" & $res.code & "; " &
          res.output)
      check fileExists(reportPath)
      let doc = parseFile(reportPath)

      # (1) The rewritten repo: detected, refused, and NOT told to push.
      let purged = entryFor(doc, "purged")
      check not purged.isNil
      if not purged.isNil:
        check purged["syncCase"].getStr() == "force_push_rebase"
        check purged["syncCase"].getStr() != "locally_unpublished"
        check purged["executionStatus"].getStr() == "refused"
        let reason = purged["refusalReason"].getStr()
        check reason.len > 0
        if advisesPush(reason):
          checkpoint("the remedy for a rewritten remote still advises a " &
            "push: " & reason)
        check not advisesPush(reason)
        # It must also say the thing an operator needs to hear.
        check "purged" in reason.toLowerAscii()

      # (2) NEGATIVE CONTROL: the untouched repo is still
      # ``locally_unpublished``, and publishing is still offered. Without
      # this row the fix could be "call everything a rewrite".
      let intact = entryFor(doc, "intact")
      check not intact.isNil
      if not intact.isNil:
        check intact["syncCase"].getStr() == "locally_unpublished"
        check intact["executionStatus"].getStr() == "refused"
        let reason = intact["refusalReason"].getStr()
        # Publishing is still OFFERED here — the fix must not answer
        # "rewrite" everywhere.
        check advisesPush(reason)

      check doc["summary"]["total"].getInt() == 2
      check doc["summary"]["refused"].getInt() == 2
      check doc["exitCode"].getInt() == 2

      # Neither checkout moved: both rows are refusals, and a refusal does
      # not touch the working tree. ``oldTip`` is asserted still reachable
      # in the rewritten checkout, which is what makes the situation
      # recoverable at all.
      check requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " rev-parse HEAD").strip() == purgedHead
      check requireGit(q(gitBin) & " -C " & q(workspaceRoot / "intact") &
        " rev-parse HEAD").strip() == intactHead
      check runCmd(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " cat-file -e " & q(oldTip & "^{commit}")).code == 0

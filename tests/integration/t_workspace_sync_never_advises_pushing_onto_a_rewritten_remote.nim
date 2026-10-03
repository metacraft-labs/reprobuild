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
##      rewritten history, and the remedy it is given is the rewrite-aware
##      one.
##
##      Note WHICH signal carries this case, because it is not the one an
##      earlier version of this comment claimed. The rewrite here is not
##      fetched before the sync, so the sync's OWN fetch watches
##      ``refs/remotes/origin/main`` jump to the rewritten root and records
##      the superseded SHA. Detection therefore runs through the RECORDED
##      force-push, and the case below asserts that record exists rather
##      than pretending it does not. The case that has no record to lean on
##      — the state a workspace is really in when it learns of a rewrite
##      some time after the fact — is the second one in this file.
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
import repro_test_support/reasoned_skip

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

proc seedOrigin(gitBin, originPath, workPath, marker: string;
                branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
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
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc rewriteOriginWithDisjointHistory(gitBin, originPath, workPath: string;
                                      branch = "main") =
  ## Replace the origin's trunk with a history that shares NO ancestor
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
    " push --force " & q(originPath) & " rewritten:" & branch)

proc commitOwnWorkOnCurrentBranch(gitBin, repoPath: string): string =
  ## One commit of the operator's own work on whatever branch is checked
  ## out — for the trunk-branch case, the checkout's own trunk.
  writeFile(repoPath / "my-work.txt", "work the operator owns\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add my-work.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"my own work\"")
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

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

proc branchTrackingFragmentToml(name, branch: string): string =
  ## The fragment shape every repo in the real workspace uses: a declared
  ## ``branch`` and NO ``revision``. The resolver copies the branch name into
  ## ``revision``, so this is not merely a spelling of the fragment above —
  ## it is the one the field defect was observed through.
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & name & "\"\n" &
  "branch = \"" & branch & "\"\n"

proc projectToml(remotes: seq[(string, string)]; trunk = "main"): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"rewriteproject\"\n" &
    "default_revision = \"" & trunk & "\"\n" &
    "trunk = \"" & trunk & "\"\n\n"
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

proc advisedReproSyncCommands(reason: string): seq[string] =
  ## Every ``repro sync …`` command a refusal names, exactly as an operator
  ## would copy it out of the quotes.
  ##
  ## The cases below RUN what this returns rather than a command the test
  ## author chose. That is the whole point: Interactive-UX-And-Progress.md
  ## Principle 2 is "Name the fix. Pair every refusal with the command that
  ## resolves it", and the only way to assert that property is to take the
  ## tool at its word. A test that hard-codes the right flags passes while
  ## the printed advice is one flag short of working, which is the defect
  ## these cases exist for.
  var i = 0
  while true:
    let start = reason.find("'repro sync", i)
    if start < 0: break
    let close = reason.find('\'', start + 1)
    if close < 0: break
    result.add(reason[start + 1 ..< close])
    i = close + 1

proc advisedCommandWith(reason, flag: string): string =
  ## The one advised ``repro sync`` command carrying ``flag``, or "".
  for command in advisedReproSyncCommands(reason):
    if flag in command:
      return command
  ""

proc flagsOf(command: string): seq[string] =
  for token in command.split(' '):
    if token.startsWith("--"):
      result.add(token.strip())

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

      # THE PREMISE, asserted rather than assumed: the local branch has no
      # remote counterpart, so the force-push probe cannot be asked about
      # ``<remote>/<current branch>`` at all.
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

      # WHICH SIGNAL CARRIED IT. This case's rewrite is not fetched before
      # the sync, so the sync's own fetch sees the transition and writes the
      # superseded SHA to ``.repro/workspace/force-pushes.json`` — the path
      # ``loadForcePushedCommits`` reads. Detection here therefore rides the
      # RECORDED force-push, and asserting so is what stops this case being
      # mistaken for coverage of the ancestry-only detector. The case below
      # asserts the same file is NEVER written, which is what leaves
      # ancestry as its only surviving signal.
      check fileExists(workspaceRoot / ".repro" / "workspace" /
        "force-pushes.json")

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

  test "t_workspace_sync_rewritten_remote_on_the_trunk_branch_is_not_locally_unpublished":
    ## The shape the FIELD defect was reported in, which the case above does
    ## not cover. Three facts separate them, and each one disarms a different
    ## piece of the detection:
    ##
    ##   1. the checkout sits on its repo's TRUNK branch (``dev``), not on a
    ##      local-only feature branch, so ``refs/remotes/origin/dev`` DOES
    ##      resolve and ``remoteBranchTip`` is non-empty — which is the input
    ##      ``canAutoRebase`` tests first;
    ##   2. the fragment declares ``branch`` and no ``revision``, the shape
    ##      every repo in a real workspace uses;
    ##   3. the remote-tracking refs were ALREADY fetched past the rewrite
    ##      before the sync ran, so the dispatcher's own force-push detector
    ##      (which compares the pre-fetch and post-fetch tips) sees no
    ##      transition and records NOTHING. That is what a workspace looks
    ##      like when it learns of a rewrite some time after the fact, and it
    ##      leaves ancestry as the only surviving signal.
    ##
    ## Under (3) there is no ``forcePushedBaseSha``, so the automatic replay
    ## is correctly declined and the verdict must be the rewrite-aware
    ## REFUSAL. The failure this guards against is the one measured in the
    ## field: ``locally_unpublished``, remedied with ``git -C <repo> push``,
    ## which republishes exactly the history the rewrite removed.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sync-rewrite-trunk-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      var remotes: seq[(string, string)]

      let purgedOrigin = scratch / "origin-purged.git"
      let purgedSeed = scratch / "seed-purged"
      let oldTip = seedOrigin(gitBin, purgedOrigin, purgedSeed, "old",
        branch = "dev")
      discard requireGit(q(gitBin) & " clone --branch dev " &
        q(fileUrl(purgedOrigin)) & " " & q(workspaceRoot / "purged"))
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " config user.name \"Rewrite Tester\"")
      let purgedHead = commitOwnWorkOnCurrentBranch(gitBin,
        workspaceRoot / "purged")
      rewriteOriginWithDisjointHistory(gitBin, purgedOrigin, purgedSeed,
        branch = "dev")
      # Fact (3): learn about the rewrite BEFORE the sync, exactly as a
      # workspace does when any earlier command happened to fetch.
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " fetch --prune origin")
      writeFile(workspaceRoot / "repos" / "purged.toml",
        branchTrackingFragmentToml("purged", "dev"))
      remotes.add(("purged", fileUrl(purgedOrigin)))

      # NEGATIVE CONTROL, same three facts except the rewrite.
      let intactOrigin = scratch / "origin-intact.git"
      let intactSeed = scratch / "seed-intact"
      discard seedOrigin(gitBin, intactOrigin, intactSeed, "intact",
        branch = "dev")
      discard requireGit(q(gitBin) & " clone --branch dev " &
        q(fileUrl(intactOrigin)) & " " & q(workspaceRoot / "intact"))
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "intact") &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / "intact") &
        " config user.name \"Rewrite Tester\"")
      let intactHead = commitOwnWorkOnCurrentBranch(gitBin,
        workspaceRoot / "intact")
      writeFile(workspaceRoot / "repos" / "intact.toml",
        branchTrackingFragmentToml("intact", "dev"))
      remotes.add(("intact", fileUrl(intactOrigin)))

      writeFile(workspaceRoot / "projects" / "rewriteproject.toml",
        projectToml(remotes, trunk = "dev"))

      # THE PREMISES, asserted rather than assumed. Each is a fact the case
      # above does NOT have, and without them this would silently re-test the
      # easier shape.
      #
      # ("no recorded force-push history" is fact (3), and it is asserted
      # AFTER the sync rather than here — before it, the check could not
      # fail whatever the code did.)
      #
      # (a) the branch DOES have a remote-tracking counterpart.
      check runCmd(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " rev-parse --verify --quiet refs/remotes/origin/dev").code == 0
      # (b) that counterpart already carries the rewritten tip, and shares no
      #     history with HEAD: git's "unrelated histories" answer is exit
      #     non-zero with EMPTY output.
      let mb = runCmd(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " merge-base HEAD refs/remotes/origin/dev")
      check mb.code != 0
      check mb.output.strip().len == 0
      # (c) the checkout is on the trunk branch, not a feature branch.
      check requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " symbolic-ref --short -q HEAD").strip() == "dev"

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

      # Fact (3) again, now as an OUTCOME rather than a setup step. Checking
      # before the sync could not fail — the workspace had just been created
      # — so it is checked here, after the sync has had every chance to
      # record one. Nothing was recorded, which is what makes ancestry the
      # only signal that could have produced the verdict below, and is the
      # single difference from the case above (which DOES get a record).
      check not fileExists(workspaceRoot / ".repro" / "workspace" /
        "force-pushes.json")

      let purged = entryFor(doc, "purged")
      check not purged.isNil
      if not purged.isNil:
        check purged["syncCase"].getStr() == "force_push_rebase"
        check purged["syncCase"].getStr() != "locally_unpublished"
        check purged["executionStatus"].getStr() == "refused"
        let reason = purged["refusalReason"].getStr()
        # Non-emptiness asserted SEPARATELY from content: a remedy that is
        # simply absent must not be able to satisfy "does not advise a push".
        check reason.len > 0
        if advisesPush(reason):
          checkpoint("the remedy for a rewritten trunk still advises a " &
            "push: " & reason)
        check not advisesPush(reason)
        check "purged" in reason.toLowerAscii()

      let intact = entryFor(doc, "intact")
      check not intact.isNil
      if not intact.isNil:
        check intact["syncCase"].getStr() == "locally_unpublished"
        check intact["executionStatus"].getStr() == "refused"
        let reason = intact["refusalReason"].getStr()
        check reason.len > 0
        check advisesPush(reason)

      check doc["summary"]["total"].getInt() == 2
      check doc["summary"]["refused"].getInt() == 2
      check doc["exitCode"].getInt() == 2

      # A refusal moves nothing, and the old history stays reachable.
      check requireGit(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " rev-parse HEAD").strip() == purgedHead
      check requireGit(q(gitBin) & " -C " & q(workspaceRoot / "intact") &
        " rev-parse HEAD").strip() == intactHead
      check runCmd(q(gitBin) & " -C " & q(workspaceRoot / "purged") &
        " cat-file -e " & q(oldTip & "^{commit}")).code == 0

  test "t_workspace_sync_rewritten_remote_remedy_resolves_the_refusal":
    ## The refusal is right to refuse, right to forbid the push — and then
    ## has to hand over a command that WORKS.
    ##
    ## Interactive-UX-And-Progress.md Principle 2: "Name the fix. Pair every
    ## refusal with the command that resolves it." The text named
    ## ``repro sync --force-sync``, and run exactly as printed that resolved
    ## nothing: both destructive sync paths route through the RA-9
    ## preview-and-confirm gate, which REFUSES in a non-interactive context
    ## without ``--yes`` — and every CI job and every agent is
    ## non-interactive. Measured on twelve rewritten recorder checkouts:
    ## ``repro sync --only=<the twelve> --force-sync`` answered
    ## ``refused 12, force-reset 0`` and re-printed the same advice, so the
    ## operator paid a full workspace re-run to learn the remedy was inert.
    ## Naming an incomplete command is worse than naming none.
    ##
    ## So these assertions do not hard-code the flags they think are right:
    ## they TAKE THE TOOL AT ITS WORD, extract the ``repro sync`` command out
    ## of the refusal, and run it. A test that typed ``--force-sync --yes``
    ## itself would stay green while the printed advice went back to being
    ## one flag short.
    ##
    ## The second half is the conditional advice, asserted in BOTH
    ## polarities, because a remedy offered where it cannot act is the same
    ## defect in the other direction:
    ##
    ##   * ``observed`` — the sync's own fetch watches the remote move, so a
    ##     superseded base is recorded and the replay has both inputs it
    ##     needs. ``--rebase-on-force-push`` is then the remedy that KEEPS
    ##     the operator's commits, and it must be offered.
    ##   * ``inferred`` — the rewrite was learned about after the fact (an
    ##     earlier command fetched), so nothing is recorded and
    ##     ``canAutoRebase`` is false whatever the flag says. Offering the
    ##     flag there would advertise a second inert command.
    ##
    ## Both repos sit on their declared trunk with a remote counterpart, so
    ## the ONLY difference between the two rows is whether the transition was
    ## observed.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case rewrites a real remote and then " &
        "runs the remedy the refusal names")
    else:
      let scratch = createTempDir("repro-sync-rewrite-remedy-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      var remotes: seq[(string, string)]

      proc seedRewritten(name: string; fetchBeforeSync: bool):
          tuple[origin, seedPath, oldTip, head: string] =
        let origin = scratch / ("origin-" & name & ".git")
        let seedPath = scratch / ("seed-" & name)
        let oldTip = seedOrigin(gitBin, origin, seedPath, "old " & name,
          branch = "dev")
        discard requireGit(q(gitBin) & " clone --branch dev " &
          q(fileUrl(origin)) & " " & q(workspaceRoot / name))
        discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / name) &
          " config user.email tester@example.invalid")
        discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / name) &
          " config user.name \"Rewrite Tester\"")
        let head = commitOwnWorkOnCurrentBranch(gitBin, workspaceRoot / name)
        rewriteOriginWithDisjointHistory(gitBin, origin, seedPath,
          branch = "dev")
        if fetchBeforeSync:
          discard requireGit(q(gitBin) & " -C " & q(workspaceRoot / name) &
            " fetch --prune origin")
        writeFile(workspaceRoot / "repos" / (name & ".toml"),
          branchTrackingFragmentToml(name, "dev"))
        remotes.add((name, fileUrl(origin)))
        (origin, seedPath, oldTip, head)

      let observed = seedRewritten("observed", fetchBeforeSync = false)
      let inferred = seedRewritten("inferred", fetchBeforeSync = true)
      writeFile(workspaceRoot / "projects" / "rewriteproject.toml",
        projectToml(remotes, trunk = "dev"))

      proc runSync(extra: openArray[string]): CmdResult =
        var argv = @[reproBin, "workspace", "sync", "rewriteproject",
          "--write-report", "--workspace-root=" & workspaceRoot]
        for arg in extra:
          argv.add(arg)
        runShell(shellCommand(argv))

      let reportPath = workspaceRoot / ".repro" / "build" / "reports" /
        "sync-report.json"
      proc report(): JsonNode = parseFile(reportPath)

      proc headOf(name: string): string =
        requireGit(q(gitBin) & " -C " & q(workspaceRoot / name) &
          " rev-parse HEAD").strip()

      # ---- the refusal, and what it advises ----------------------------
      let refusal = runSync([])
      checkpoint("bare sync: exit " & $refusal.code & "\n" & refusal.output)
      check fileExists(reportPath)
      let firstDoc = report()
      check firstDoc["summary"]["refused"].getInt() == 2
      check firstDoc["summary"]["forceReset"].getInt() == 0

      let observedReason = entryFor(firstDoc, "observed")["refusalReason"].getStr()
      let inferredReason = entryFor(firstDoc, "inferred")["refusalReason"].getStr()
      checkpoint("observed remedy: " & observedReason)
      checkpoint("inferred remedy: " & inferredReason)
      # THE PREMISE of the two polarities, asserted rather than assumed.
      #
      # It is read off ``force-pushes.json`` and not off the report, because
      # the report's ``forcePushedBaseSha`` is populated from the DECISION and
      # the planner copies the observation's base only into the accepted
      # rebase — a refusal's row carries "" whatever the observation saw. A
      # premise read there would be vacuously true for both rows.
      let forcePushesPath = workspaceRoot / ".repro" / "workspace" /
        "force-pushes.json"
      check fileExists(forcePushesPath)
      let recorded = parseFile(forcePushesPath)
      # ``observed``: the sync's own fetch watched the remote move, so the
      # superseded commits are on record and the replay has a base.
      check recorded.hasKey("observed")
      # ``inferred``: the rewrite was already fetched, so this run saw no
      # transition and recorded nothing for it. Ancestry is the only signal
      # that produced its verdict, and there is nothing to replay from.
      check not recorded.hasKey("inferred")

      # The preserving remedy is offered where it can act, and nowhere else.
      check "--rebase-on-force-push" in observedReason
      check "--rebase-on-force-push" notin inferredReason
      # Both name a discard remedy, since that one always applies.
      check advisedCommandWith(observedReason, "--force-sync").len > 0
      check advisedCommandWith(inferredReason, "--force-sync").len > 0

      # ---- running the advice resolves it: the discard remedy ----------
      let discardCommand = advisedCommandWith(inferredReason, "--force-sync")
      checkpoint("running the advised command: " & discardCommand)
      let discardRun = runSync(flagsOf(discardCommand) &
        @["--only=inferred"])
      checkpoint("advised discard run: exit " & $discardRun.code & "\n" &
        discardRun.output)
      let afterDiscard = report()
      # RESOLVED: not refused again, counted as the overwrite it is, and the
      # checkout is on the rewritten history.
      check afterDiscard["summary"]["refused"].getInt() == 0
      check afterDiscard["summary"]["forceReset"].getInt() == 1
      check discardRun.code == 0
      let inferredRemoteTip = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "inferred") &
        " rev-parse refs/remotes/origin/dev").strip()
      check headOf("inferred") == inferredRemoteTip
      check headOf("inferred") != inferred.head

      # ---- and the preserving remedy, where it was offered -------------
      let replayCommand = advisedCommandWith(observedReason,
        "--rebase-on-force-push")
      checkpoint("running the advised command: " & replayCommand)
      let replayRun = runSync(flagsOf(replayCommand) & @["--only=observed"])
      checkpoint("advised replay run: exit " & $replayRun.code & "\n" &
        replayRun.output)
      let afterReplay = report()
      check afterReplay["summary"]["refused"].getInt() == 0
      check afterReplay["summary"]["rebased"].getInt() == 1
      check replayRun.code == 0
      # The operator's commit is ON THE BRANCH, on top of the rewritten
      # upstream — asserted against refs, never the reflog.
      let observedRemoteTip = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "observed") &
        " rev-parse refs/remotes/origin/dev").strip()
      check requireGit(q(gitBin) & " -C " & q(workspaceRoot / "observed") &
        " rev-parse HEAD~1").strip() == observedRemoteTip
      check requireGit(q(gitBin) & " -C " & q(workspaceRoot / "observed") &
        " log -1 --format=%s").strip() == "my own work"
      check fileExists(workspaceRoot / "observed" / "my-work.txt")

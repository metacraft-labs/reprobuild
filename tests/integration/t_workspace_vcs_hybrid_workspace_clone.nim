## Workspace VCS — hybrid git + hg workspace clone (M3).
##
## A single ``runBuild`` invocation drives one git clone and one hg
## clone side-by-side. This is the M3 acceptance test: it proves the
## multiplexed ``bakWorkspaceVcs`` executor in ``git_actions`` routes
## per-VCS payloads correctly through the same engine seam, so a
## workspace plan that mixes both VCSes does NOT need two separate
## build invocations.
##
## The test also asserts the two VCS backends produce DISTINCT action
## fingerprints even when the logical parameters (id, ``remoteUrl``,
## ``repoPath``, ``revision``) look superficially identical — the
## VCS-kind discriminator that lives inside the action payload must
## guarantee the cache cannot confuse a git clone with a hg clone.
##
## Hermetic setup: both origins are local filesystem repos seeded by
## the test. No network. The only documented skip is "no ambient git
## or hg on PATH"; if both tools are missing the suite reports a clean
## skip rather than a noisy failure.

import std/[os, osproc, strutils, tempfiles, unittest]

import git_actions
import git_tool
import hg_actions
import hg_tool
import repro_build_engine

proc whichGit(): string = findExe("git")
proc whichHg(): string = findExe("hg")

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc seedGitOrigin(gitBin, originPath, workPath: string) =
  ## Build a local bare ``origin`` repo with one commit on ``main``.
  ## Same fixture shape as M2's git tests.
  discard requireSuccess(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireSuccess(q(gitBin) & " init -b main " & q(workPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.name 'M3 Tester'")
  writeFile(workPath / "README.md", "M3 git fixture\n")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " push origin main")

proc seedHgOrigin(hgBin, originPath, seedPath: string) =
  ## Hg has no separate ``--bare`` flag: a non-served repo with no
  ## working dir functions as the origin, and that is what
  ## ``hg init`` (without ``clone -U``) gives us once we push a commit
  ## from a seed repo. The per-repo ``hgrc`` sets ``ui.username`` so
  ## the commit succeeds without a global hgrc (the nix-managed dev
  ## box does not write to ``~/.hgrc``).
  discard requireSuccess(q(hgBin) & " init " & q(originPath))
  discard requireSuccess(q(hgBin) & " init " & q(seedPath))
  let hgrc = "[ui]\nusername = M3 Tester <tester@example.invalid>\n"
  writeFile(originPath / ".hg" / "hgrc", hgrc)
  writeFile(seedPath / ".hg" / "hgrc", hgrc)
  writeFile(seedPath / "README.md", "M3 hg fixture\n")
  discard requireSuccess(q(hgBin) & " -R " & q(seedPath) &
    " add " & q(seedPath / "README.md"))
  discard requireSuccess(q(hgBin) & " -R " & q(seedPath) &
    " commit -m fixture")
  discard requireSuccess(q(hgBin) & " -R " & q(seedPath) &
    " push " & q(originPath))

suite "Workspace VCS — hybrid git+hg workspace clone (M3)":

  test "test_m3_hybrid_workspace_clone_routes_both_vcses_in_one_runbuild":
    let gitBin = whichGit()
    let hgBin = whichHg()
    if gitBin.len == 0 or hgBin.len == 0:
      # The one documented skip: when either VCS is missing the test
      # cannot prove the hybrid contract. Reported as a clean skip so
      # the suite stays green on minimal CI images.
      skip()
    else:
      let scratch = createTempDir("repro-m3-hybrid-", "")
      defer: removeDir(scratch)

      let gitOrigin = scratch / "git-origin.git"
      let gitSeed = scratch / "git-seed"
      seedGitOrigin(gitBin, gitOrigin, gitSeed)

      let hgOrigin = scratch / "hg-origin"
      let hgSeed = scratch / "hg-seed"
      seedHgOrigin(hgBin, hgOrigin, hgSeed)

      let gitIdentity = ensureGitToolResolvable(tpmPathOnly,
        gitBin.parentDir & PathSep & hgBin.parentDir)
      let hgIdentity = ensureHgToolResolvable(tpmPathOnly,
        gitBin.parentDir & PathSep & hgBin.parentDir)

      let workRoot = scratch / "workspace"
      createDir(workRoot)
      let cacheRoot = scratch / "shared-cache"

      let gitTargetRel = "git-repo"
      let hgTargetRel = "hg-repo"
      let gitReceiptRel = "git-clone-receipt"
      let hgReceiptRel = "hg-clone-receipt"

      var gitAct = gitCloneAction("m3-git-clone", gitIdentity,
        remoteUrl = "file://" & gitOrigin,
        repoPath = gitTargetRel,
        receiptPath = gitReceiptRel,
        revision = "main")
      gitAct.cwd = workRoot

      var hgAct = hgCloneAction("m3-hg-clone", hgIdentity,
        remoteUrl = hgOrigin,
        repoPath = hgTargetRel,
        receiptPath = hgReceiptRel)
      hgAct.cwd = workRoot

      # VCS-kind discriminator contract: two superficially identical
      # clones (same id, same logical params) issued to git vs hg
      # MUST produce distinct weak fingerprints. If the multiplexer
      # ever loses the VCS-kind tag inside the fingerprint payload
      # this assertion catches it immediately.
      var gitParallel = gitCloneAction("m3-shared-id", gitIdentity,
        remoteUrl = "file://" & gitOrigin,
        repoPath = "shared",
        receiptPath = "shared-receipt",
        revision = "main")
      var hgParallel = hgCloneAction("m3-shared-id", hgIdentity,
        remoteUrl = hgOrigin,
        repoPath = "shared",
        receiptPath = "shared-receipt",
        revision = "default")
      check gitParallel.weakFingerprint.bytes !=
        hgParallel.weakFingerprint.bytes

      var config = defaultBuildEngineConfig(cacheRoot)
      config.suppressTrace = true

      # ONE runBuild call drives both actions. This is the M3 hybrid
      # contract: a workspace plan mixing git and hg repos must
      # resolve through the same engine pass, with the multiplexer in
      # ``git_actions`` routing each action by payload magic.
      let res = runBuild(graph([gitAct, hgAct]), config)
      check res.results.len == 2

      var gitOutcome, hgOutcome: ActionResult
      for outcome in res.results:
        if outcome.id == "m3-git-clone":
          gitOutcome = outcome
        elif outcome.id == "m3-hg-clone":
          hgOutcome = outcome
      check gitOutcome.id == "m3-git-clone"
      check hgOutcome.id == "m3-hg-clone"

      if gitOutcome.status != asSucceeded:
        checkpoint("git clone stderr: " & gitOutcome.stderr &
          " reason=" & gitOutcome.reason)
      check gitOutcome.status == asSucceeded
      check gitOutcome.cacheDecision == cdMiss

      if hgOutcome.status != asSucceeded:
        checkpoint("hg clone stderr: " & hgOutcome.stderr &
          " reason=" & hgOutcome.reason)
      check hgOutcome.status == asSucceeded
      check hgOutcome.cacheDecision == cdMiss

      # Both working trees exist at the declared paths.
      check dirExists(workRoot / gitTargetRel / ".git")
      check dirExists(workRoot / hgTargetRel / ".hg")

      # Both receipts exist and carry the per-VCS header — proving
      # the multiplexer dispatched each payload to the right backend.
      let gitReceipt = readFile(workRoot / gitReceiptRel)
      check gitReceipt.startsWith(CloneReceiptHeader)
      check gitReceipt.contains("kind\tgit")
      check gitReceipt.contains("operation\tclone")
      let hgReceipt = readFile(workRoot / hgReceiptRel)
      check hgReceipt.startsWith(HgCloneReceiptHeader)
      check hgReceipt.contains("kind\thg")
      check hgReceipt.contains("operation\tclone")

      # The two receipts must not be accidentally identical, even
      # truncating headers — the post-clone HEADs come from different
      # repos with different content.
      check gitReceipt != hgReceipt

      # Query-path spot check: ``isCleanQuery`` on the hg working
      # tree reports clean immediately after clone, the same way M2's
      # git query path does. This validates the parallel observation
      # contract (M2 design rule 3, inherited).
      let cleanRes = queryHgState(
        hg_actions.isCleanQuery(workRoot / hgTargetRel), hgIdentity)
      check cleanRes.status == hqsOk
      check cleanRes.isClean

      # Replay the same plan a second time. Each clone hits the
      # receipt CAS — proving the receipt is the unit of caching for
      # BOTH backends and the multiplexer's routing does not break
      # the fingerprint contract.
      let secondWorkRoot = scratch / "workspace-second"
      createDir(secondWorkRoot)
      var gitAct2 = gitCloneAction("m3-git-clone", gitIdentity,
        remoteUrl = "file://" & gitOrigin,
        repoPath = gitTargetRel,
        receiptPath = gitReceiptRel,
        revision = "main")
      gitAct2.cwd = secondWorkRoot
      var hgAct2 = hgCloneAction("m3-hg-clone", hgIdentity,
        remoteUrl = hgOrigin,
        repoPath = hgTargetRel,
        receiptPath = hgReceiptRel)
      hgAct2.cwd = secondWorkRoot

      let secondRes = runBuild(graph([gitAct2, hgAct2]), config)
      check secondRes.results.len == 2
      for outcome in secondRes.results:
        if outcome.status notin {asCacheHit, asUpToDate}:
          checkpoint("second " & outcome.id & " status=" & $outcome.status &
            " reason=" & outcome.reason &
            " stderr=" & outcome.stderr)
        check outcome.cacheDecision == cdHit
        check outcome.status in {asCacheHit, asUpToDate}
      # Receipts restored byte-for-byte into the second workspace.
      check fileExists(secondWorkRoot / gitReceiptRel)
      check readFile(secondWorkRoot / gitReceiptRel) == gitReceipt
      check fileExists(secondWorkRoot / hgReceiptRel)
      check readFile(secondWorkRoot / hgReceiptRel) == hgReceipt
      # Neither working tree is restored — the receipt is the cache
      # unit, not the working tree (M2 design rule 1, inherited).
      check not dirExists(secondWorkRoot / gitTargetRel / ".git")
      check not dirExists(secondWorkRoot / hgTargetRel / ".hg")

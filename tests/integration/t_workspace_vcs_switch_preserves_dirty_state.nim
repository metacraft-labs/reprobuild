## Workspace VCS — switch refuses on dirty (M2).
##
## The M2 switch action's contract: when the working tree is dirty,
## ``executeSwitch`` returns ``ActionResult`` with the structured
## reason ``"dirty"`` and does NOT invoke ``git switch``. The
## structured reason field is the contract — we deliberately do NOT
## match against git's human-facing "Your local changes would be
## overwritten" message, which is a moving target across git versions.
##
## Hermetic setup: local bare ``origin`` with two branches (``main``
## and ``feature``), clone into ``downstream``, dirty the working
## tree, then assert the switch action surfaces the dirty reason and
## leaves the dirty file untouched.

import std/[os, osproc, strutils, tempfiles, unittest]

import git_actions
import git_tool
import repro_build_engine

proc whichGit(): string = findExe("git")

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

proc configureRepo(gitBin, repoPath: string) =
  discard requireSuccess(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireSuccess(q(gitBin) & " -C " & q(repoPath) &
    " config user.name 'M2 Tester'")

proc seedTwoBranchOrigin(gitBin, originPath, workPath: string) =
  discard requireSuccess(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireSuccess(q(gitBin) & " init -b main " & q(workPath))
  configureRepo(gitBin, workPath)
  writeFile(workPath / "README.md", "M2 switch fixture\n")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " commit -m initial")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " push origin main")
  # Build a feature branch with one extra commit so a clean switch
  # has somewhere to land.
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " switch -c feature")
  writeFile(workPath / "feature.txt", "feature payload\n")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " add feature.txt")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " commit -m feature-commit")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " push origin feature")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " switch main")

suite "Workspace VCS — switch preserves dirty state (M2)":

  test "test_m2_switch_refuses_on_dirty_and_surfaces_structured_reason":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m2-switch-dirty-", "")
      defer: removeDir(scratch)

      let originPath = scratch / "origin.git"
      let seedWork = scratch / "seed"
      seedTwoBranchOrigin(ambient, originPath, seedWork)

      let downstream = scratch / "downstream"
      discard requireSuccess(q(ambient) & " clone " & q(originPath) &
        " " & q(downstream))
      configureRepo(ambient, downstream)
      # Track the remote feature branch so ``switch feature`` could
      # succeed on a clean tree.
      discard requireSuccess(q(ambient) & " -C " & q(downstream) &
        " branch --track feature origin/feature")

      # Dirty the working tree: modify the file tracked by main so a
      # switch to feature would clobber the local edit. The contract
      # under test is that the action refuses BEFORE invoking git
      # switch, not that we observe git's error message.
      let dirtyPath = downstream / "README.md"
      let dirtyContent = "locally modified by the M2 test\n"
      writeFile(dirtyPath, dirtyContent)

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      let cacheRoot = scratch / "shared-cache"
      let workRoot = scratch / "switch-work"
      createDir(workRoot)

      var switchAct = gitSwitchAction("m2-switch", identity,
        branchName = "feature",
        repoPath = downstream,
        receiptPath = "switch-receipt")
      switchAct.cwd = workRoot

      var config = defaultBuildEngineConfig(cacheRoot)
      config.suppressTrace = true

      let res = runBuild(graph([switchAct]), config)
      check res.results.len == 1
      let outcome = res.results[0]
      # Structured contract: the reason field is the test contract,
      # not the stderr text (M2 design rule 4).
      check outcome.status == asFailed
      check outcome.reason == "dirty"
      check outcome.exitCode == 1
      # The dirty file must be preserved verbatim — proof that the
      # executor refused BEFORE invoking git switch.
      check fileExists(dirtyPath)
      check readFile(dirtyPath) == dirtyContent
      # No receipt is written on the dirty-refusal path.
      check not fileExists(workRoot / "switch-receipt")
      # HEAD is still on main: the would-be switch did not happen.
      let headProbe = execCmdEx(q(ambient) & " -C " & q(downstream) &
        " rev-parse --abbrev-ref HEAD")
      check headProbe.exitCode == 0
      check headProbe.output.strip() == "main"

  test "test_m2_switch_succeeds_on_clean_tree":
    # Positive control: the switch action DOES advance HEAD when the
    # tree is clean. Without this we cannot tell whether the
    # ``dirty`` reason came from the executor's pre-check or from a
    # subtler bug that always refuses.
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m2-switch-clean-", "")
      defer: removeDir(scratch)

      let originPath = scratch / "origin.git"
      let seedWork = scratch / "seed"
      seedTwoBranchOrigin(ambient, originPath, seedWork)

      let downstream = scratch / "downstream"
      discard requireSuccess(q(ambient) & " clone " & q(originPath) &
        " " & q(downstream))
      configureRepo(ambient, downstream)
      discard requireSuccess(q(ambient) & " -C " & q(downstream) &
        " branch --track feature origin/feature")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      let cacheRoot = scratch / "switch-clean-cache"
      let workRoot = scratch / "switch-clean-work"
      createDir(workRoot)

      var switchAct = gitSwitchAction("m2-switch-clean", identity,
        branchName = "feature",
        repoPath = downstream,
        receiptPath = "switch-receipt")
      switchAct.cwd = workRoot

      var config = defaultBuildEngineConfig(cacheRoot)
      config.suppressTrace = true

      let res = runBuild(graph([switchAct]), config)
      check res.results.len == 1
      let outcome = res.results[0]
      if outcome.status != asSucceeded:
        checkpoint("clean switch stderr: " & outcome.stderr &
          " reason: " & outcome.reason)
      check outcome.status == asSucceeded
      check fileExists(workRoot / "switch-receipt")
      let receipt = readFile(workRoot / "switch-receipt")
      check receipt.startsWith(SwitchReceiptHeader)
      check receipt.contains("branch\tfeature")
      let headProbe = execCmdEx(q(ambient) & " -C " & q(downstream) &
        " rev-parse --abbrev-ref HEAD")
      check headProbe.exitCode == 0
      check headProbe.output.strip() == "feature"

  test "test_m2_is_clean_query_observes_dirty_state":
    # The query side of the M2 contract: ``queryGitState`` reports
    # the live working-tree state without going through ``runBuild``.
    # This is the path call sites use to fold VCS state into the
    # build's evidence (M4 will formalize the on-disk schema; M2
    # ships the query result type).
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m2-isclean-", "")
      defer: removeDir(scratch)

      let originPath = scratch / "origin.git"
      let seedWork = scratch / "seed"
      seedTwoBranchOrigin(ambient, originPath, seedWork)

      let downstream = scratch / "downstream"
      discard requireSuccess(q(ambient) & " clone " & q(originPath) &
        " " & q(downstream))
      configureRepo(ambient, downstream)

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      let cleanResult = queryGitState(isCleanQuery(downstream), identity)
      check cleanResult.status == gqsOk
      check cleanResult.isClean

      writeFile(downstream / "README.md", "made-dirty\n")
      let dirtyResult = queryGitState(isCleanQuery(downstream), identity)
      check dirtyResult.status == gqsOk
      check not dirtyResult.isClean

      let headResult = queryGitState(headShaQuery(downstream), identity)
      check headResult.status == gqsOk
      check headResult.headSha.len >= 7

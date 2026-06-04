## Workspace VCS — clone-action cache behavior (M2).
##
## The receipt is the unit of caching: a successful clone writes a
## small canonical text file recording (remote-url, requested revision,
## resolved post-clone HEAD, git-version, identity-digest). Two clones
## with the same logical parameters (same remote, same revision, same
## ``GitToolIdentity``) but different target temp roots must produce
## the same weak fingerprint, so the second clone is a cache hit on
## the receipt and the engine restores the receipt without invoking
## ``git clone`` again.
##
## The only documented skip is "no ambient git on PATH"; every other
## fixture is constructed hermetically from a local bare ``origin``
## repo, so the test never touches github.com.

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

proc seedBareOrigin(gitBin, originPath, workPath: string) =
  ## Build a local bare ``origin`` repo with one commit on ``main``.
  ## Per-repo ``user.email`` / ``user.name`` so the commit succeeds
  ## without a global gitconfig (which on the nix-managed dev box is a
  ## read-only ``~/.config/git/config`` symlink into the Nix store).
  discard requireSuccess(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireSuccess(q(gitBin) & " init -b main " & q(workPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.name 'M2 Tester'")
  writeFile(workPath / "README.md", "M2 fixture\n")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " push origin main")

suite "Workspace VCS — clone-action cache (M2)":

  test "test_m2_clone_cacheable_second_call_is_receipt_cas_hit":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m2-clone-cache-", "")
      defer: removeDir(scratch)

      let originPath = scratch / "origin.git"
      let seedWork = scratch / "seed"
      seedBareOrigin(ambient, originPath, seedWork)

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      let cacheRoot = scratch / "shared-cache"
      let firstRoot = scratch / "first"
      let secondRoot = scratch / "second"
      createDir(firstRoot)
      createDir(secondRoot)

      let cloneTargetRel = "clone"
      let receiptRel = "clone-receipt"

      proc cloneAction(): BuildAction =
        gitCloneAction("m2-clone", identity,
          remoteUrl = "file://" & originPath,
          repoPath = cloneTargetRel,
          receiptPath = receiptRel,
          revision = "main")

      let firstAction = cloneAction()
      let secondAction = cloneAction()

      check firstAction.weakFingerprint.bytes == secondAction.weakFingerprint.bytes

      var config = defaultBuildEngineConfig(cacheRoot)
      config.suppressTrace = true

      let firstAct = firstAction
      var firstActLocal = firstAct
      firstActLocal.cwd = firstRoot
      let firstRes = runBuild(graph([firstActLocal]), config)
      check firstRes.results.len == 1
      if firstRes.results[0].status != asSucceeded:
        checkpoint("first clone stderr: " & firstRes.results[0].stderr)
      check firstRes.results[0].status == asSucceeded
      check firstRes.results[0].cacheDecision == cdMiss
      check fileExists(firstRoot / receiptRel)
      check dirExists(firstRoot / cloneTargetRel / ".git")
      let firstReceipt = readFile(firstRoot / receiptRel)
      check firstReceipt.startsWith(CloneReceiptHeader)
      check firstReceipt.contains("operation\tclone")
      check firstReceipt.contains("head-sha\t")

      let secondAct = secondAction
      var secondActLocal = secondAct
      secondActLocal.cwd = secondRoot
      let secondRes = runBuild(graph([secondActLocal]), config)
      check secondRes.results.len == 1
      let outcome = secondRes.results[0]
      if outcome.status notin {asCacheHit, asUpToDate}:
        checkpoint("second clone status=" & $outcome.status &
          " reason=" & outcome.reason &
          " stderr=" & outcome.stderr)
      check outcome.cacheDecision == cdHit
      check outcome.status in {asCacheHit, asUpToDate}
      # The receipt CAS-restored to the second temp root must match the
      # first run's receipt byte-for-byte — that is what makes the
      # receipt the deterministic unit of caching (M2 design rule 1).
      check fileExists(secondRoot / receiptRel)
      check readFile(secondRoot / receiptRel) == firstReceipt
      # The working tree itself is deliberately NOT restored: the
      # receipt is the cacheable artifact, not the loose-object graph.
      check not dirExists(secondRoot / cloneTargetRel / ".git")

  test "test_m2_clone_fingerprint_differs_for_different_revisions":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m2-clone-fp-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      let mainAction = gitCloneAction("a", identity,
        remoteUrl = "file:///nonexistent.git",
        repoPath = "x",
        receiptPath = "r",
        revision = "main")
      let featureAction = gitCloneAction("a", identity,
        remoteUrl = "file:///nonexistent.git",
        repoPath = "x",
        receiptPath = "r",
        revision = "feature")
      # Different revisions → different weak fingerprints. This is the
      # contract that protects M9+ from cross-branch cache poisoning.
      check mainAction.weakFingerprint.bytes !=
        featureAction.weakFingerprint.bytes

      let differentUrl = gitCloneAction("a", identity,
        remoteUrl = "file:///other.git",
        repoPath = "x",
        receiptPath = "r",
        revision = "main")
      check mainAction.weakFingerprint.bytes !=
        differentUrl.weakFingerprint.bytes

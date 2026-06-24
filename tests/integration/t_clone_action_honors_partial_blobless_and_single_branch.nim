## RA-14 — clone action honors partial (blobless) + single-branch.
##
## A ``gitCloneAction`` carrying ``cloneFilter = "blob:none"`` and
## ``singleBranch = true`` against a local bare upstream must:
##
##   1. **Partial clone wired.** The resulting clone is a promisor /
##      partial clone — ``remote.origin.promisor = true`` and
##      ``remote.origin.partialclonefilter = blob:none`` in its config.
##      (Falsifiable: a plain clone sets neither; the flags would be
##      ignored.)
##   2. **Single branch only.** Only the pinned branch's remote-tracking
##      ref exists — the upstream's *other* branch has NO
##      ``refs/remotes/origin/<other>`` ref. (Falsifiable: a full clone
##      fetches every head, so the other branch's ref would be present.)
##   3. **Transparency.** The resolved working tree at the pinned
##      revision is byte-identical (same HEAD SHA + same file contents)
##      to a full, unfiltered, all-branches clone of the same revision.
##      A partial/blobless clone fetches blobs lazily at checkout, so the
##      checked-out files are present and identical even though the
##      object population of ``.git`` differs. (Falsifiable: a different
##      tree would mean the accelerator changed what was built — exactly
##      what RA-14 forbids.)
##
## Hermetic: a single ``createTempDir`` root holds the local bare
## upstream (two branches) and every clone; no network. The accelerator
## flags are EXCLUDED from the action fingerprint, so we also assert the
## filtered clone and a full clone share one weak fingerprint.
##
## Skip only when ``git`` is missing from PATH.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
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
    stderr.writeLine("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc seedBareOrigin(gitBin, originPath, workPath: string) =
  ## Bare ``origin`` with a ``main`` branch (README + a binary-ish blob to
  ## make the blobless filter meaningful) AND a second ``other`` branch so
  ## ``--single-branch`` has something to exclude.
  discard requireSuccess(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireSuccess(q(gitBin) & " init -b main " & q(workPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA14 Tester\"")
  writeFile(workPath / "README.md", "RA-14 fixture\n")
  writeFile(workPath / "data.bin", repeat("payload-", 4096))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " push origin main")
  # A second branch with a distinct commit, so a single-branch clone of
  # ``main`` legitimately omits it.
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " switch -c other")
  writeFile(workPath / "other.txt", "other-branch\n")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " commit -m other-commit")
  discard requireSuccess(q(gitBin) & " -C " & q(workPath) &
    " push origin other")

proc gitConfigValue(gitBin, repoPath, key: string): string =
  let res = run(q(gitBin) & " -C " & q(repoPath) & " config --get " & q(key))
  if res.code == 0: res.output.strip() else: ""

proc remoteTrackingBranches(gitBin, repoPath: string): seq[string] =
  let raw = requireSuccess(q(gitBin) & " -C " & q(repoPath) &
    " for-each-ref --format=" & q("%(refname)") & " refs/remotes/origin")
  result = @[]
  for line in raw.splitLines:
    let l = line.strip()
    if l.len > 0:
      result.add(l)
  result.sort()

proc headSha(gitBin, repoPath: string): string =
  requireSuccess(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc treeFiles(root: string): seq[(string, string)] =
  ## Sorted (relpath, contents) of every tracked file in the working tree,
  ## excluding ``.git``. Used to prove two checkouts are byte-identical.
  result = @[]
  for path in walkDirRec(root, relative = true):
    if path == ".git" or path.startsWith(".git" & DirSep):
      continue
    let abs = root / path
    if fileExists(abs):
      result.add((path.replace(DirSep, '/'), readFile(abs)))
  result.sort()

proc runCloneToTree(action: BuildAction; cwd, cacheRoot: string): ActionResult =
  var config = defaultBuildEngineConfig(cacheRoot)
  config.suppressTrace = true
  var local = action
  local.cwd = cwd
  let res = runBuild(graph([local]), config)
  doAssert res.results.len == 1
  res.results[0]

suite "RA-14 — partial + single-branch clone action":

  test "test_ra14_clone_honors_blobless_and_single_branch_transparently":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra14-clone-", "")
      defer: removeDir(scratch)

      let originPath = scratch / "origin.git"
      let seedWork = scratch / "seed"
      seedBareOrigin(ambient, originPath, seedWork)

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      let url = fileUrl(originPath)

      # --- Accelerated clone: blobless + single-branch on ``main`` -------
      let accelRoot = scratch / "accel"
      createDir(accelRoot)
      let accelAction = gitCloneAction("ra14-accel", identity,
        remoteUrl = url,
        repoPath = "clone",
        receiptPath = "clone-receipt",
        revision = "main",
        cloneFilter = "blob:none",
        singleBranch = true)
      let accelRes = runCloneToTree(accelAction, accelRoot, scratch / "cache-a")
      if accelRes.status != asSucceeded:
        checkpoint("accel clone stderr: " & accelRes.stderr)
      check accelRes.status == asSucceeded
      let accelClone = accelRoot / "clone"
      check dirExists(accelClone / ".git")

      # --- Full clone (no accelerators), all branches --------------------
      let fullRoot = scratch / "full"
      createDir(fullRoot)
      let fullAction = gitCloneAction("ra14-full", identity,
        remoteUrl = url,
        repoPath = "clone",
        receiptPath = "clone-receipt",
        revision = "main")
      let fullRes = runCloneToTree(fullAction, fullRoot, scratch / "cache-b")
      check fullRes.status == asSucceeded
      let fullClone = fullRoot / "clone"
      check dirExists(fullClone / ".git")

      # (1) Partial-clone config present on the accelerated clone, absent
      #     on the full clone.
      check gitConfigValue(ambient, accelClone, "remote.origin.promisor") ==
        "true"
      check gitConfigValue(ambient, accelClone,
        "remote.origin.partialclonefilter") == "blob:none"
      check gitConfigValue(ambient, fullClone, "remote.origin.promisor") == ""

      # (2) Single-branch: the accelerated clone tracks ONLY ``origin/main``;
      #     the full clone (default ``git clone`` fetches all heads) tracks
      #     ``origin/other`` too.
      let accelRefs = remoteTrackingBranches(ambient, accelClone)
      check accelRefs == @["refs/remotes/origin/main"]
      let fullRefs = remoteTrackingBranches(ambient, fullClone)
      check "refs/remotes/origin/other" in fullRefs

      # (3) Transparency: identical HEAD SHA and identical working-tree
      #     file contents at the pinned revision. A blobless clone fetches
      #     ``data.bin``'s blob lazily on checkout, so it is present and
      #     identical despite the differing object population.
      check headSha(ambient, accelClone) == headSha(ambient, fullClone)
      check treeFiles(accelClone) == treeFiles(fullClone)
      # Spot-check the large blob materialized correctly through the filter.
      check fileExists(accelClone / "data.bin")
      check readFile(accelClone / "data.bin") ==
        readFile(fullClone / "data.bin")

  test "test_ra14_accelerators_excluded_from_clone_fingerprint":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      # Same (remote, revision, identity); the accelerators differ. Because
      # they are EXCLUDED from the fingerprint (they never change the
      # resolved tree), all three must share one weak fingerprint so a
      # full clone and a partial/shallow/narrow clone hit the same receipt.
      let plain = gitCloneAction("a", identity,
        remoteUrl = "file:///nonexistent.git", repoPath = "x",
        receiptPath = "r", revision = "main")
      let blobless = gitCloneAction("a", identity,
        remoteUrl = "file:///nonexistent.git", repoPath = "x",
        receiptPath = "r", revision = "main",
        cloneFilter = "blob:none", singleBranch = true, depth = 1)
      check plain.weakFingerprint.bytes == blobless.weakFingerprint.bytes
      # Sanity: a genuine identity-bearing change (revision) DOES move the
      # fingerprint, proving the equality above is not vacuous.
      let otherRev = gitCloneAction("a", identity,
        remoteUrl = "file:///nonexistent.git", repoPath = "x",
        receiptPath = "r", revision = "feature",
        cloneFilter = "blob:none")
      check plain.weakFingerprint.bytes != otherRev.weakFingerprint.bytes

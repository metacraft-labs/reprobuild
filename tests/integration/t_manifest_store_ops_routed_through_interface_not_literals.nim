## Workspace-Manifest-Optional MO-10 — the remaining lock publish / read
## operations are routed through the ``LockStore`` interface, not the
## git-specific procs / ``.repo/manifests`` literals.
##
## MO-3 introduced the abstract ``LockStore`` and routed most manifest/lock
## call-sites through it, but left four lock operations calling the
## git-checkout procs directly: the ``repro workspace lock`` publish in
## ``runWorkspaceLockCommand``, the two pre-push gate publish sites in
## ``runCheckCommand``, and the ``repro workspace sync`` optimized-fetch lock
## read. MO-10 routes those through the ``GitCheckoutLockStore``'s
## ``publishPending`` / ``latestLockShas`` methods (mirroring the gate's
## already-routed lock READ and ``executePush``).
##
## This suite asserts BOTH halves of "routed through the interface, not
## literals":
##
##   A. BEHAVIOR — the ``GitCheckoutLockStore`` interface methods the routed
##      call-sites now invoke produce a lock record byte-identical (same
##      location, same committed+pushed result, same read-back shas) to the
##      underlying RA-7 / RA-14 git procs. ``publishPending`` commits + pushes
##      the ``locks/<project>/<repo>/<sha>.toml`` subtree to the manifest
##      upstream and reports ``spoOk``; ``latestLockShas`` reads that record
##      back as the ``path -> revision`` map the sync optimized-fetch consumes.
##
##   B. STRUCTURE — a focused assertion that the four routed call-sites in
##      ``repro_cli_support.nim`` reference the store interface
##      (``publishPending`` / a store-backed ``latestLockShas``) rather than
##      calling ``publishWorkspaceLock`` / ``latestLockShasViaGit`` directly.
##
## Falsifiability: revert any routed call-site back to the direct git proc and
## the corresponding STRUCTURE marker disappears (the test fails); break the
## store's publish/read equivalence and the BEHAVIOR half fails (wrong outcome,
## missing pushed record, or wrong read-back shas).
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import git_tool
import repro_cli_support
import repro_lock_store

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc commitCount(gitBin, repo, rev: string): int =
  let res = run(q(gitBin) & " -C " & q(repo) & " rev-list --count " & rev)
  if res.code != 0:
    return -1
  res.output.strip().parseInt()

proc seedManifestRepo(gitBin, scratch: string;
                      branch = "latest"): tuple[bare, work: string] =
  let bare = scratch / "manifest.git"
  let work = scratch / "manifest"
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(work))
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"MO-10 Tester\"")
  writeFile(work / "manifest.toml", "schema = \"manifest\"\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add manifest.toml")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(work) & " push -u origin " & branch)
  (bare: bare, work: work)

proc minimalLockToml(project, repo, sha: string): string =
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
  "[lock]\n" &
  "project = \"" & project & "\"\n" &
  "created_at = \"2026-06-02T10:14:33Z\"\n\n" &
  "[[repo]]\n" &
  "name = \"" & repo & "\"\n" &
  "path = \"" & repo & "\"\n" &
  "remote = \"origin\"\n" &
  "revision = \"" & sha & "\"\n"

proc writeLock(work, project, repo, sha: string) =
  let dir = work / "locks" / project / repo
  createDir(dir)
  writeFile(dir / (sha & ".toml"), minimalLockToml(project, repo, sha))

proc cliSupportSource(): string =
  ## Path to the routed source under test (tests/integration/<file>.nim →
  ## repo root → libs/...).
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  repoRoot / "libs" / "repro_cli_support" / "src" / "repro_cli_support.nim"

suite "MO-10: lock publish/read routed through LockStore, not literals":

  test "t_manifest_store_ops_routed_through_interface_not_literals":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-mo10-routed-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
      let (bare, work) = seedManifestRepo(gitBin, scratch)

      let project = "demo"
      let repo = "demo"
      let sha = "1111111111111111111111111111111111111111"

      let baseCount = commitCount(gitBin, bare, "refs/heads/latest")
      check baseCount >= 1

      # ---- (A) the store's publishPending — the method the routed
      # ``repro workspace lock`` / pre-push-gate publishes invoke — publishes
      # the lock record through the git-checkout backend. ----
      writeLock(work, project, repo, sha)
      let store: LockStore = newGitCheckoutLockStore(identity, work)
      let pub = store.publishPending()
      check pub.outcome == spoOk
      check pub.diagnostic.len > 0

      # Commit + push landed at the SAME location the direct RA-7 proc uses:
      # the bare upstream received the lock commit and the lock path.
      check commitCount(gitBin, work, "HEAD") == baseCount + 1
      check commitCount(gitBin, bare, "refs/heads/latest") == baseCount + 1
      let lsRes = run(q(gitBin) & " -C " & q(bare) &
        " ls-tree -r --name-only refs/heads/latest")
      check lsRes.code == 0
      check ("locks/" & project & "/" & repo & "/" & sha & ".toml") in
        lsRes.output

      # A second publish with nothing new staged is a clean no-op (spoNothing),
      # not a spurious failure — same as the direct proc's lpoNothingToPublish.
      let pub2 = store.publishPending()
      check pub2.outcome == spoNothing
      check commitCount(gitBin, bare, "refs/heads/latest") == baseCount + 1

      # ---- (A) the store's latestLockShas — the method the routed sync
      # optimized-fetch read invokes — reads that record back as the
      # ``path -> revision`` map the fetch loop consumes. ----
      let latest = store.latestLockShas(project)
      check latest.shas.len == 1
      check latest.shas.getOrDefault(repo) == sha
      check latest.lockKey.sha == sha

      # ---- (B) focused STRUCTURE assertion: the four routed call-sites in
      # repro_cli_support.nim reference the store interface, not the direct
      # git procs. Reverting a site to ``publishWorkspaceLock(identity, ...)``
      # / ``latestLockShasViaGit(identity, manifestsRoot, ...)`` removes its
      # marker below and fails this test. ----
      let src = readFile(cliSupportSource())
      # sync optimized-fetch read routed through the store:
      check "fetchStore.latestLockShas(resolved.projectName).shas" in src
      # `repro workspace lock` publish routed through the store:
      check "newGitCheckoutLockStore(identity, outcome.report.manifestLayerRoot)" in
        src
      # pre-push gate publish routed through the store:
      check "newGitCheckoutLockStore(identity, report.manifestLayerRoot)" in src
      # pre-push gate offered re-publish routed through the store:
      check "let storePub2 = publishStore.publishPending()" in src

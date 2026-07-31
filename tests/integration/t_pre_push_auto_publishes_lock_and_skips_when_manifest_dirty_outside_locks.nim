## RA-7 — lock publication (commit + push) with the dirty-outside-``locks/``
## guard.
##
## ``publishWorkspaceLock`` is the publication mechanism the pre-push gate
## (and explicit ``repro workspace lock``) call after writing a lock: it
## stages everything under ``locks/``, REFUSES if the manifest repo is
## dirty outside ``locks/`` (unstaging what it staged), commits, and pushes
## to the manifest repo's upstream.
##
## This test exercises that mechanism directly against a hermetic manifest
## repo with a local bare upstream:
##
##   1. Clean-outside-``locks/``: a freshly-written lock under ``locks/`` is
##      committed AND pushed; the upstream (bare) receives the lock commit
##      (assert the lock blob is reachable from the pushed branch in the
##      bare repo).
##   2. Dirty-outside-``locks/``: an unrelated tracked file is modified, a
##      new lock is written, publish REFUSES — no new commit, nothing
##      pushed, the staged ``locks/`` entry is unstaged, and the dirty file
##      is left byte-for-byte untouched.
##
## Falsifiable: the clean case asserts the bare upstream's commit count
## advanced and the lock path is present in the pushed tree; the dirty case
## asserts the commit count did NOT advance, the index has nothing staged,
## and the dirty file content is unchanged. Hermetic: only local
## ``git init`` / ``git init --bare`` repos; no network.
##
## The second case in this file covers the RA-21 "manifest layer is a plain
## directory" skip when that plain directory is NESTED INSIDE an unrelated
## Git checkout — the shape every workspace-tool-managed workspace has
## (``<workspace>/.repro/manifests`` inside a git-tracked workspace repo).
## Git repository discovery walks upwards, so the not-a-checkout guard has to
## compare the discovered top level against the candidate; otherwise the
## publish drives ``git add`` / ``git commit`` / ``git push`` against the
## ENCLOSING repository. See the case body for the exact assertions.
##
## The third case covers the complementary half: a manifest layer that IS its
## own checkout but whose lock path is IGNORED there. Keeping the manifest
## layer out of ordinary status/add noise is a legitimate operator choice, so
## publication forces the stage of its own generated records. Both halves are
## needed and neither substitutes for the other — forcing without the
## is-it-a-checkout guard would commit the lock into whatever repo happens to
## contain the layer.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

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
  let res = run(q(gitBin) & " -C " & q(repo) &
    " rev-list --count " & rev)
  if res.code != 0:
    return -1
  res.output.strip().parseInt()

proc seedManifestRepo(gitBin, scratch: string;
                      branch = "latest"): tuple[bare, work: string] =
  ## A bare upstream and a working checkout configured to track it, with
  ## an initial non-lock commit so the manifest repo is "clean".
  let bare = scratch / "manifest.git"
  let work = scratch / "manifest"
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(work))
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"RA-7 Tester\"")
  writeFile(work / "manifest.toml", "schema = \"manifest\"\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add manifest.toml")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " push -u origin " & branch)
  (bare: bare, work: work)

proc writeLock(work, project, repo, sha, body: string) =
  let dir = work / "locks" / project / repo
  createDir(dir)
  writeFile(dir / (sha & ".toml"), body)

proc validLock(project, repo, sha: string): string =
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
  "[lock]\nproject = \"" & project & "\"\n" &
  "created_at = \"2026-07-22T00:00:00Z\"\n\n" &
  "[[repo]]\nname = \"" & repo & "\"\npath = \"" & repo & "\"\n" &
  "remote = \"origin\"\nrevision = \"" & sha & "\"\n"

suite "RA-7 — lock publication (commit + push) and dirty-outside-locks guard":

  test "t_pre_push_auto_publishes_lock_and_skips_when_manifest_dirty_outside_locks":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra7-publish-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
      let (bare, work) = seedManifestRepo(gitBin, scratch)

      let baseCount = commitCount(gitBin, bare, "refs/heads/latest")
      check baseCount >= 1

      # ---- (1) clean-outside-locks → commit AND push ---------------------
      let firstSha = "1111111111111111111111111111111111111111"
      writeLock(work, "demo", "demo", firstSha,
        validLock("demo", "demo", firstSha))
      let pub1 = publishWorkspaceLock(identity, work)
      checkpoint("first publish diagnostic: " & pub1.diagnostic)
      check pub1.outcome == lpoPublished

      # The local manifest branch advanced by exactly one commit.
      check commitCount(gitBin, work, "HEAD") == baseCount + 1
      # The bare upstream RECEIVED the lock commit (falsifiable: count grew).
      check commitCount(gitBin, bare, "refs/heads/latest") == baseCount + 1
      # The pushed tree in the bare actually contains the lock path.
      let lsRes = run(q(gitBin) & " -C " & q(bare) &
        " ls-tree -r --name-only refs/heads/latest")
      check lsRes.code == 0
      check "locks/demo/demo/1111111111111111111111111111111111111111.toml" in
        lsRes.output
      let afterPushCount = commitCount(gitBin, bare, "refs/heads/latest")

      # ---- (2) dirty-outside-locks → REFUSE ------------------------------
      # Modify an unrelated tracked file, then write a NEW lock.
      let dirtyPath = work / "manifest.toml"
      let dirtyBefore = "schema = \"manifest\"\nDIRTY-EDIT\n"
      writeFile(dirtyPath, dirtyBefore)
      let secondSha = "2222222222222222222222222222222222222222"
      writeLock(work, "demo", "demo", secondSha,
        validLock("demo", "demo", secondSha))

      let pub2 = publishWorkspaceLock(identity, work)
      check pub2.outcome == lpoRefusedDirty

      # No new commit locally, nothing pushed to the bare.
      check commitCount(gitBin, work, "HEAD") == baseCount + 1
      check commitCount(gitBin, bare, "refs/heads/latest") == afterPushCount

      # The staged locks/ entry was UNSTAGED (index has nothing staged).
      let staged = run(q(gitBin) & " -C " & q(work) &
        " diff --cached --name-only")
      check staged.code == 0
      check staged.output.strip().len == 0

      # The dirty file is left byte-for-byte untouched.
      check readFile(dirtyPath) == dirtyBefore

      # And the new lock file is still on disk (publish never deletes it).
      check fileExists(work / "locks" / "demo" / "demo" /
        "2222222222222222222222222222222222222222.toml")

  test "t_lock_publish_skips_manifest_layer_nested_in_unrelated_checkout":
    ## RA-21 — a manifest layer that is a PLAIN DIRECTORY is "no publication
    ## boundary to honour" (``lpoNotPublishable``), a benign skip that must
    ## not gate a push. Git's repository discovery walks UPWARDS, so when that
    ## plain directory sits inside an unrelated checkout — exactly the
    ## ``<workspace>/.repro/manifests`` shape a workspace repo has —
    ## ``rev-parse --show-toplevel`` answers with the ENCLOSING repository.
    ## Publication must not accept that answer: every subsequent
    ## ``git -C <layer> add/commit/push`` would then operate on the workspace
    ## repository instead.
    ##
    ## Two nestings are covered because they fail differently:
    ##   a. the layer is IGNORED by the enclosing repo (``.repro/`` in its
    ##      ``.gitignore``) — ``git add`` errors, which used to surface as a
    ##      hard ``lpoFailed`` and refuse every push in the workspace;
    ##   b. the layer is NOT ignored — ``git add`` would SUCCEED and the
    ##      publish would commit workspace-repo content and push the
    ##      workspace repo's branch.
    ##
    ## Falsifiable in both: the enclosing repository's commit count is
    ## unchanged, its index has nothing staged, and its working tree stays
    ## clean — so neither a `git add -f` shortcut (which would make (a)
    ## commit into the enclosing repo) nor the old walk-up acceptance can
    ## pass. Hermetic: one local ``git init``; no remote, no network.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra21-nested-layer-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # An ordinary workspace checkout that ignores `.repro/`, exactly like a
      # `repo`/`repro`-managed workspace repository does.
      let workspace = scratch / "workspace"
      createDir(workspace)
      discard requireGit(q(gitBin) & " init -b main " & q(workspace))
      discard requireGit(q(gitBin) & " -C " & q(workspace) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspace) &
        " config user.name \"RA-21 Tester\"")
      writeFile(workspace / ".gitignore", ".repro/\n")
      writeFile(workspace / "README.md", "workspace\n")
      discard requireGit(q(gitBin) & " -C " & q(workspace) &
        " add .gitignore README.md")
      discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -m seed")
      let workspaceCommits = commitCount(gitBin, workspace, "HEAD")
      check workspaceCommits >= 1

      template assertWorkspaceUntouched(label: string) =
        checkpoint(label)
        # No commit was created in the enclosing repository.
        check commitCount(gitBin, workspace, "HEAD") == workspaceCommits
        # Nothing was staged in the enclosing repository's index.
        let staged = run(q(gitBin) & " -C " & q(workspace) &
          " diff --cached --name-only")
        check staged.code == 0
        check staged.output.strip().len == 0
        # And no tracked path in it was added/modified/removed. Untracked
        # files are excluded on purpose: case (b) below deliberately drops a
        # plain directory into the enclosing repo's working tree, and merely
        # existing there is not a publication side effect.
        let porcelain = run(q(gitBin) & " -C " & q(workspace) &
          " status --porcelain --untracked-files=no")
        check porcelain.code == 0
        check porcelain.output.strip().len == 0

      # ---- (a) nested AND ignored by the enclosing repo -------------------
      let ignoredLayer = workspace / ".repro" / "manifests"
      createDir(ignoredLayer)
      let ignoredSha = "3333333333333333333333333333333333333333"
      writeLock(ignoredLayer, "demo", "demo", ignoredSha,
        validLock("demo", "demo", ignoredSha))

      let pub3 = publishWorkspaceLock(identity, ignoredLayer)
      checkpoint("ignored-nested publish diagnostic: " & pub3.diagnostic)
      check pub3.outcome == lpoNotPublishable
      # The skip must be attributed to "this is not a checkout", never to the
      # enclosing repo's ignore rules.
      check "gitignore" notin pub3.diagnostic
      assertWorkspaceUntouched("after ignored-nested publish")
      # The lock file itself is untouched on disk — the workspace still has a
      # local record even though there is nowhere to publish it.
      check fileExists(ignoredLayer / "locks" / "demo" / "demo" /
        (ignoredSha & ".toml"))

      # ---- (b) nested but NOT ignored by the enclosing repo ---------------
      let trackedLayer = workspace / "manifests-plain"
      createDir(trackedLayer)
      let trackedSha = "4444444444444444444444444444444444444444"
      writeLock(trackedLayer, "demo", "demo", trackedSha,
        validLock("demo", "demo", trackedSha))

      let pub4 = publishWorkspaceLock(identity, trackedLayer)
      checkpoint("tracked-nested publish diagnostic: " & pub4.diagnostic)
      check pub4.outcome == lpoNotPublishable
      assertWorkspaceUntouched("after tracked-nested publish")
      check fileExists(trackedLayer / "locks" / "demo" / "demo" /
        (trackedSha & ".toml"))

  test "t_lock_publish_forces_generated_locks_ignored_in_the_manifest_checkout":
    ## Keeping the manifest layer out of ordinary `git status` / `git add`
    ## noise is a legitimate operator choice: a `.gitignore` in the manifest
    ## checkout, or a global `core.excludesFile` naming `.repro/` or `locks/`,
    ## reaches INSIDE that checkout. Lock publication must still work there,
    ## so it forces the stage of the records it generates itself. The pathspec
    ## is always reprobuild's own `locks/` subtree, so nothing the operator
    ## authored is swept past their ignore rules.
    ##
    ## Two ignore SOURCES are covered because they arrive by different routes:
    ##   a. a tracked `.gitignore` committed in the manifest checkout;
    ##   b. `.git/info/exclude` — an untracked, repo-local rule, the same
    ##      mechanism a global `core.excludesFile` uses to reach in from
    ##      outside the repository's own content.
    ##
    ## (b) additionally nests the manifest checkout inside a workspace repo
    ## that ignores `.repro/` — the real layout — and asserts the enclosing
    ## repo is left completely alone. That is what makes the force safe: the
    ## is-it-a-checkout-ROOT guard decides WHICH repository the forced add
    ## lands in, and without it a force would commit the lock into (and push
    ## the branch of) the enclosing workspace repo.
    ##
    ## Falsifiable: each half asserts the bare upstream's commit count grew
    ## and that the exact lock path is present in the pushed tree — an ignore
    ## that silently swallowed the record fails on both. Hermetic: local
    ## `git init` / `git init --bare` only; no network.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra7-forced-ignored-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # ---- (a) the manifest checkout's own tracked .gitignore -------------
      let dirA = scratch / "a"
      createDir(dirA)
      let (bareA, workA) = seedManifestRepo(gitBin, dirA)
      writeFile(workA / ".gitignore", "locks/\n")
      discard requireGit(q(gitBin) & " -C " & q(workA) & " add .gitignore")
      discard requireGit(q(gitBin) & " -C " & q(workA) &
        " commit -m ignore-locks")
      discard requireGit(q(gitBin) & " -C " & q(workA) &
        " push origin latest")
      let baseA = commitCount(gitBin, bareA, "refs/heads/latest")
      check baseA >= 2

      # Sanity: git really does refuse the unforced stage here, so the force
      # below is doing the work and not merely redundant.
      let shaA = "5555555555555555555555555555555555555555"
      writeLock(workA, "demo", "demo", shaA, validLock("demo", "demo", shaA))
      let unforced = run(q(gitBin) & " -C " & q(workA) & " add -- locks")
      check unforced.code != 0
      check "ignored" in unforced.output

      let pubA = publishWorkspaceLock(identity, workA)
      checkpoint("own-gitignore publish diagnostic: " & pubA.diagnostic)
      check pubA.outcome == lpoPublished
      check commitCount(gitBin, bareA, "refs/heads/latest") == baseA + 1
      let treeA = run(q(gitBin) & " -C " & q(bareA) &
        " ls-tree -r --name-only refs/heads/latest")
      check treeA.code == 0
      check ("locks/demo/demo/" & shaA & ".toml") in treeA.output
      # Publication leaves no residue in the operator's index.
      let stagedA = run(q(gitBin) & " -C " & q(workA) &
        " diff --cached --name-only")
      check stagedA.code == 0
      check stagedA.output.strip().len == 0

      # ---- (b) .git/info/exclude, nested in a workspace that ignores it ---
      let dirB = scratch / "b"
      createDir(dirB)
      let workspace = dirB / "workspace"
      createDir(workspace)
      discard requireGit(q(gitBin) & " init -b main " & q(workspace))
      discard requireGit(q(gitBin) & " -C " & q(workspace) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspace) &
        " config user.name \"RA-7 Tester\"")
      writeFile(workspace / ".gitignore", ".repro/\n")
      writeFile(workspace / "README.md", "workspace\n")
      discard requireGit(q(gitBin) & " -C " & q(workspace) &
        " add .gitignore README.md")
      discard requireGit(q(gitBin) & " -C " & q(workspace) & " commit -m seed")
      let workspaceCommits = commitCount(gitBin, workspace, "HEAD")

      # A REAL manifest checkout (its own upstream) at the real location.
      let bareB = dirB / "manifest.git"
      let layerB = workspace / ".repro" / "manifests"
      createDir(parentDir(layerB))
      discard requireGit(q(gitBin) & " init --bare -b latest " & q(bareB))
      discard requireGit(q(gitBin) & " init -b latest " & q(layerB))
      discard requireGit(q(gitBin) & " -C " & q(layerB) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(layerB) &
        " config user.name \"RA-7 Tester\"")
      writeFile(layerB / "manifest.toml", "schema = \"manifest\"\n")
      discard requireGit(q(gitBin) & " -C " & q(layerB) & " add manifest.toml")
      discard requireGit(q(gitBin) & " -C " & q(layerB) & " commit -m seed")
      discard requireGit(q(gitBin) & " -C " & q(layerB) &
        " remote add origin " & q(bareB))
      discard requireGit(q(gitBin) & " -C " & q(layerB) &
        " push -u origin latest")
      # The ignore arrives from OUTSIDE the repository's tracked content,
      # exactly the way a global core.excludesFile would.
      writeFile(layerB / ".git" / "info" / "exclude", "locks/\n")
      let baseB = commitCount(gitBin, bareB, "refs/heads/latest")
      check baseB >= 1

      let shaB = "6666666666666666666666666666666666666666"
      writeLock(layerB, "demo", "demo", shaB, validLock("demo", "demo", shaB))
      let pubB = publishWorkspaceLock(identity, layerB)
      checkpoint("info/exclude publish diagnostic: " & pubB.diagnostic)
      check pubB.outcome == lpoPublished
      check commitCount(gitBin, bareB, "refs/heads/latest") == baseB + 1
      let treeB = run(q(gitBin) & " -C " & q(bareB) &
        " ls-tree -r --name-only refs/heads/latest")
      check treeB.code == 0
      check ("locks/demo/demo/" & shaB & ".toml") in treeB.output

      # The enclosing workspace repo never took part: no commit, nothing
      # staged, no tracked change. This is the guard, not the force, working.
      check commitCount(gitBin, workspace, "HEAD") == workspaceCommits
      let stagedWs = run(q(gitBin) & " -C " & q(workspace) &
        " diff --cached --name-only")
      check stagedWs.code == 0
      check stagedWs.output.strip().len == 0
      let porcelainWs = run(q(gitBin) & " -C " & q(workspace) &
        " status --porcelain --untracked-files=no")
      check porcelainWs.code == 0
      check porcelainWs.output.strip().len == 0

      # ---- the routed store writes under the same ignore ------------------
      # ``GitCheckoutLockStore.putLock`` is the write path a configured
      # team/personal ``git-checkout`` route uses; an unrecorded team-tier
      # participation escalates to a push refusal, so it must force too.
      let shaC = "7777777777777777777777777777777777777777"
      let store: LockStore = newGitCheckoutLockStore(identity, layerB)
      let put = store.putLock(StoreLockRecord(
        key: StoreLockKey(project: "demo", repo: "demo", sha: shaC),
        body: validLock("demo", "demo", shaC)))
      checkpoint("routed putLock diagnostic: " & put.diagnostic)
      check put.outcome == spoOk
      # The record is really in the manifest checkout's history, not just on
      # disk under an ignore rule.
      let logC = run(q(gitBin) & " -C " & q(layerB) &
        " log --oneline -- locks/demo/demo/" & shaC & ".toml")
      check logC.code == 0
      check logC.output.strip().len > 0

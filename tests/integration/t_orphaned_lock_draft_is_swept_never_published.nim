## A lock DRAFT whose commit no ref reaches is swept, never published.
##
## push-hook-publication-protocol.md §"A draft whose commit no ref reaches is
## swept, never published" (reprobuild-pm issue
## 2026-09-29-post-commit-keys-a-lock-record-on-a-sha-the-prescribed-workflow-
## then-rewrites).
##
## The defect. ``post-commit`` writes an untracked draft
## ``locks/<project>/<repo>/<sha>.toml`` into the record store, keyed on the
## commit that fired it. At post-commit that SHA is provisional: the workflow
## this project prescribes (sync the mainline before measuring, which on a
## moving branch means rebasing — or simply ``git commit --amend``) rewrites
## it, and the draft is left naming a commit that exists on no branch. Nothing
## removed such a draft, and the explicit ``repro workspace lock`` publishes
## UNSCOPED — it stages every untracked canonical record it finds — so the
## orphan was committed and pushed into a store whose records are immutable.
## It could then never be removed or superseded.
##
## Scenario (each case builds its own hermetic fixture):
##
##   1. ``explicit lock publishes the rewritten commit, never the orphan`` —
##      commit A in ``lib-a``; the post-commit lock writer drafts A; the
##      upstream moves and A is rebased onto it as B (A is now reachable only
##      from the reflog, and post-commit stood down for the whole rebase, so
##      A's draft is still there); run
##      ``repro workspace lock``, which publishes. Assert the store's upstream
##      history holds NO record for A, DOES hold B's, and A's draft is gone
##      from the store's working tree.
##   2. ``post-commit for the rewritten commit sweeps the orphaned draft`` —
##      A is amended into B, and only the post-commit writer runs for B, in a
##      workspace that does not opt into publication. A's draft is debris and
##      is swept; B's draft is written. NEGATIVE CONTROLS in the same store:
##      a draft for an older commit still on the branch, a draft for a commit
##      on another branch, a draft whose commit object this checkout does
##      not have at all, a draft for a commit only a tag reaches, and a
##      TRACKED record whose commit is orphaned are all LEFT ALONE — only an
##      untracked draft of a provably orphaned commit is swept.
##   3. ``pre-push gate that finds the lock current still sweeps before it
##      publishes`` — the gate's "lock already current" arm writes nothing,
##      so the writer's sweep does not run there and the arm sweeps on its
##      own. An orphaned draft such as a ``repro`` without the sweep left
##      behind is planted OLDER than the current record, so the gate really
##      takes that arm, and the gate runs without ``--current-repo``, which
##      makes its publication unscoped. A's record must not reach the
##      upstream, and the gate output must name the sweep.
##   4. ``thousands of reachable drafts do not stop the sweep`` — every
##      commit that is not itself pushed leaves a reachable draft that is
##      never swept, so a long-lived workspace carries thousands. The
##      reachability probe must not put them all on one command line: past
##      the platform's limit it fails, and every orphan is then kept for good.
##
## Falsifiable against the unfixed tree: case 1 finds A's record in the
## upstream (the publisher staged it) and the draft still on disk; cases 2
## and 4 find A's draft still on disk; case 3 finds A's record in the
## upstream.
##
## Hermetic: local bare upstreams under one ``createTempDir``; real git, the
## real ``repro`` binary, the real filesystem. Nothing is mocked or stubbed.
## Skip only when ``git`` is missing.

import std/[json, os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

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

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"Orphan Sweep Tester\"")

proc projectToml(libAUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    storeRoot: string ## ``.repro/manifests``: manifest layer + record store
    storeBare: string ## the record store's upstream
    libA: string      ## the ``lib-a`` checkout in the workspace
    libASeed: string  ## a second clone that moves lib-a's upstream

proc setupFixture(gitBin, slug: string; publishLocks: bool): Fixture =
  result.scratch = createTempDir("repro-orphan-draft-" & slug & "-", "")
  result.reproBin = reproBinary()

  # ---- lib-a upstream with one pushed commit ------------------------------
  let libAOrigin = result.scratch / "origin-lib-a.git"
  let seed = result.scratch / "seed-lib-a"
  result.libASeed = seed
  discard requireGit(q(gitBin) & " init --bare -b main " & q(libAOrigin))
  discard requireGit(q(gitBin) & " init -b main " & q(seed))
  configIdentity(gitBin, seed)
  writeFile(seed / "README.md", "orphan-draft fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " remote add origin " & q(libAOrigin))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

  # ---- workspace whose `.repro/manifests` is a publishable record store ---
  result.workspaceRoot = result.scratch / "workspace"
  result.storeRoot = result.workspaceRoot / ".repro" / "manifests"
  createDir(result.storeRoot / "projects")
  createDir(result.storeRoot / "repos")
  writeFile(result.storeRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(libAOrigin)))
  writeFile(result.storeRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.storeBare = result.scratch / "store.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(result.storeBare))
  discard requireGit(q(gitBin) & " init -b main " & q(result.storeRoot))
  configIdentity(gitBin, result.storeRoot)
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) &
    " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) &
    " remote add origin " & q(result.storeBare))
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) &
    " push -u origin main")

  result.libA = result.workspaceRoot / "lib-a"
  discard requireGit(q(gitBin) & " clone --branch main " &
    q(fileUrl(libAOrigin)) & " " & q(result.libA))
  configIdentity(gitBin, result.libA)
  writeWorkspaceBranch(result.workspaceRoot, project = "lib-a",
    branch = "main")
  writeFile(result.workspaceRoot / ".repro-workspace.toml",
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\n" &
    "url = \"" & fileUrl(result.storeBare) & "\"\n" &
    "branch = \"main\"\n" &
    (if publishLocks: "publish_locks = true\n" else: ""))

proc pinHookRunner(fx: Fixture): string =
  ## The first dispatch installs the managed hooks into ``lib-a``, so every
  ## later ``git commit`` in the fixture fires a REAL post-commit hook. Point
  ## that hook at the binary under test: left to ``PATH`` it would run
  ## whatever pinned ``repro`` the host carries, which writes drafts of its own
  ## into this store and is not the code being tested. Returns the previous
  ## value so the caller can restore it.
  result = getEnv("REPROBUILD_REPRO")
  putEnv("REPROBUILD_REPRO", fx.reproBin)

proc restoreHookRunner(prior: string) =
  if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
  else: delEnv("REPROBUILD_REPRO")

proc commitIn(gitBin, repo, file, message: string): string =
  writeFile(repo / file, message & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " add " & q(file))
  discard requireGit(q(gitBin) & " -C " & q(repo) & " commit -m " &
    q(message))
  requireGit(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()

proc firePostCommit(fx: Fixture): CmdResult =
  result = runShell(shellCommand(@[
    fx.reproBin, "hooks", "dispatch", "post-commit",
    "--repo-root", fx.libA, "--"]))
  checkpoint("post-commit output: " & result.output)

proc draftRel(sha: string): string = "locks/lib-a/lib-a/" & sha & ".toml"

proc draftPath(fx: Fixture; sha: string): string =
  fx.storeRoot / draftRel(sha).replace('/', DirSep)

proc lastPostCommitTriggerSha(fx: Fixture): string =
  parseFile(fx.workspaceRoot / ".repro" / "build" / "reports" /
    "post-commit-report.json")["triggerSha"].getStr()

proc assertProvablyOrphaned(gitBin, repo, sha: string) =
  ## The fixture's own positive control: the commit OBJECT is still present
  ## (the reflog keeps it), and no ref reaches it. Without this the test could
  ## pass on a draft that was swept for some other reason.
  check runCmd(q(gitBin) & " -C " & q(repo) & " cat-file -e " & sha &
    "^{commit}").code == 0
  let containing = runCmd(q(gitBin) & " -C " & q(repo) &
    " branch -a --contains " & sha)
  check containing.code == 0
  check containing.output.strip().len == 0

suite "orphaned lock drafts are swept, never published":

  test "explicit lock publishes the rewritten commit, never the orphan":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this test drives real git repositories")
    else:
      let fx = setupFixture(gitBin, "explicit", publishLocks = true)
      defer: removeDir(fx.scratch)
      let priorRepro = pinHookRunner(fx)
      defer: restoreHookRunner(priorRepro)

      # Commit A; post-commit drafts it (local only).
      let shaA = commitIn(gitBin, fx.libA, "feature.txt", "feature A")
      check firePostCommit(fx).code == 0
      check lastPostCommitTriggerSha(fx) == shaA
      check fileExists(draftPath(fx, shaA))

      # Rewrite it the way the prescribed workflow does: the mainline moved,
      # and syncing means rebasing A onto it. A becomes B and survives only in
      # the reflog. Every commit the rebase replays fires the REAL post-commit
      # hook, which stands down mid-rebase, so A's draft is still on disk when
      # the explicit lock runs — the exact state the issue caught three times.
      discard commitIn(gitBin, fx.libASeed, "upstream.txt", "upstream moved")
      discard requireGit(q(gitBin) & " -C " & q(fx.libASeed) &
        " push origin main")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) & " fetch origin")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " rebase origin/main")
      let shaB = requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " rev-parse HEAD").strip()
      check shaB != shaA
      assertProvablyOrphaned(gitBin, fx.libA, shaA)
      check fileExists(draftPath(fx, shaA))

      # The explicit lock writes B and PUBLISHES (unscoped).
      let lockRes = runShell(shellCommand(@[
        fx.reproBin, "workspace", "lock",
        "--workspace-root=" & fx.workspaceRoot]))
      checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      # (a) The orphan never reached the store's upstream history.
      let aHistory = runCmd(q(gitBin) & " -C " & q(fx.storeBare) &
        " log --all --format=%H -- " & q(draftRel(shaA)))
      check aHistory.code == 0
      checkpoint("upstream history touching A's record: " & aHistory.output)
      check aHistory.output.strip().len == 0
      # (b) The record for the commit that actually exists WAS published.
      let upstreamTree = runCmd(q(gitBin) & " -C " & q(fx.storeBare) &
        " ls-tree -r --name-only refs/heads/main")
      check upstreamTree.code == 0
      checkpoint("upstream tree: " & upstreamTree.output)
      check draftRel(shaB) in upstreamTree.output.splitLines()
      check draftRel(shaA) notin upstreamTree.output.splitLines()
      # (c) The orphaned draft is gone from the store's working tree...
      check not fileExists(draftPath(fx, shaA))
      # ...and the operator was told, in a line naming the record.
      check "swept orphaned lock draft" in lockRes.output
      check draftRel(shaA) in lockRes.output

  test "post-commit for the rewritten commit sweeps the orphaned draft":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this test drives real git repositories")
    else:
      let fx = setupFixture(gitBin, "postcommit", publishLocks = false)
      defer: removeDir(fx.scratch)
      let priorRepro = pinHookRunner(fx)
      defer: restoreHookRunner(priorRepro)

      # NEGATIVE CONTROL 1 — an older commit that stays on the branch.
      let shaKept = commitIn(gitBin, fx.libA, "kept.txt", "kept commit")
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaKept))

      # NEGATIVE CONTROL 2 — a commit reachable only from ANOTHER branch.
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " checkout -q -b side")
      let shaSide = commitIn(gitBin, fx.libA, "side.txt", "side commit")
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaSide))
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " checkout -q main")

      # NEGATIVE CONTROL 3 — a draft naming a commit this checkout does not
      # have. Its reachability cannot be proven either way, so it must stay.
      let shaUnknown = "0123456789abcdef0123456789abcdef01234567"
      writeFile(draftPath(fx, shaUnknown), readFile(draftPath(fx, shaKept)))

      # NEGATIVE CONTROL 4 — a commit reachable from a TAG only. The branch
      # that carried it is deleted, so ``branch --contains`` finds nothing,
      # but a ref still reaches it and it is not orphaned.
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " checkout -q -b tagged")
      let shaTagged = commitIn(gitBin, fx.libA, "tagged.txt", "tagged commit")
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaTagged))
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " tag keep-me " & shaTagged)
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " checkout -q main")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " branch -q -D tagged")

      # NEGATIVE CONTROL 5 — a TRACKED record whose commit IS provably
      # orphaned. A tracked record is history, not a draft: the sweep must
      # never touch it, however dead its commit is.
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " checkout -q -b doomed")
      let shaTracked = commitIn(gitBin, fx.libA, "doomed.txt",
        "doomed commit")
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaTracked))
      discard requireGit(q(gitBin) & " -C " & q(fx.storeRoot) & " add -- " &
        q(draftRel(shaTracked)))
      discard requireGit(q(gitBin) & " -C " & q(fx.storeRoot) &
        " commit -q -m \"track a record\"")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " checkout -q main")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " branch -q -D doomed")
      assertProvablyOrphaned(gitBin, fx.libA, shaTracked)

      # Commit A, drafted by post-commit, then amended into B.
      let shaA = commitIn(gitBin, fx.libA, "feature.txt", "feature A")
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaA))
      writeFile(fx.libA / "feature.txt", "feature A, reworded\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " commit -a --amend -m \"feature B\"")
      let shaB = requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " rev-parse HEAD").strip()
      check shaB != shaA
      assertProvablyOrphaned(gitBin, fx.libA, shaA)

      # Only the post-commit writer runs for B — no explicit lock, no push.
      check firePostCommit(fx).code == 0
      check lastPostCommitTriggerSha(fx) == shaB
      check fileExists(draftPath(fx, shaB))

      # The orphan is debris and is swept...
      check not fileExists(draftPath(fx, shaA))
      # ...and the sweep is recorded in the post-commit log.
      let log = readFile(fx.workspaceRoot / ".repro" / "build" / "reports" /
        "post-commit-lock.log")
      checkpoint("post-commit log:\n" & log)
      check "swept orphaned lock draft" in log
      check draftRel(shaA) in log

      # Everything that is not provably orphaned is left alone.
      check fileExists(draftPath(fx, shaKept))
      check fileExists(draftPath(fx, shaSide))
      check fileExists(draftPath(fx, shaUnknown))
      check fileExists(draftPath(fx, shaTagged))
      check fileExists(draftPath(fx, shaTracked))
      # The log names every record post-commit WROTE, so look for a sweep
      # line about these two rather than for their paths at all.
      check ("swept orphaned lock draft '" & draftRel(shaTracked) & "'") notin
        log
      check ("swept orphaned lock draft '" & draftRel(shaTagged) & "'") notin
        log

      # Nothing was published: this workspace does not opt in, and
      # post-commit is local-only regardless.
      let upstreamLog = runCmd(q(gitBin) & " -C " & q(fx.storeBare) &
        " log --all --format=%H -- locks")
      check upstreamLog.code == 0
      check upstreamLog.output.strip().len == 0

  test "pre-push gate that finds the lock current still sweeps before it publishes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this test drives real git repositories")
    else:
      let fx = setupFixture(gitBin, "gate", publishLocks = true)
      defer: removeDir(fx.scratch)
      let priorRepro = pinHookRunner(fx)
      defer: restoreHookRunner(priorRepro)

      # Commit A and its draft; keep the draft's bytes.
      let shaA = commitIn(gitBin, fx.libA, "feature.txt", "feature A")
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaA))
      let draftABody = readFile(draftPath(fx, shaA))

      # Amend A into B; post-commit drafts B (and sweeps A).
      writeFile(fx.libA / "feature.txt", "feature A, reworded\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " commit -a --amend -m \"feature B\"")
      let shaB = requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " rev-parse HEAD").strip()
      check shaB != shaA
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaB))
      assertProvablyOrphaned(gitBin, fx.libA, shaA)

      # Re-plant A's draft, as a ``repro`` without the sweep would have left
      # it, dated BEFORE B's record. The gate reads the newest draft as the
      # current lock, so B's must stay the newest for the gate to find the
      # lock current and take the arm under test.
      writeFile(draftPath(fx, shaA), draftABody)
      setLastModificationTime(draftPath(fx, shaA),
        getLastModificationTime(draftPath(fx, shaB)) -
          initDuration(minutes = 5))

      # Publish B in lib-a so the gate's "HEAD is published" check passes.
      # Hooks are bypassed for THIS push only: it stands in for a push that
      # has already happened, and the gate under test is invoked below.
      let noHooks = fx.scratch / "no-hooks"
      createDir(noHooks)
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " -c core.hooksPath=" & q(noHooks) & " push origin main")

      # No ``--current-repo``: the gate resolves no anchored record, so the
      # publication that follows it is UNSCOPED and would stage A's draft.
      let gate = runCmd(q(fx.reproBin) & " check --mode=pre-push" &
        " --workspace-root=" & q(fx.workspaceRoot))
      checkpoint("gate output: " & gate.output)
      check gate.code == 0
      # Positive control: the gate took the arm that writes nothing.
      check "lock already current" in gate.output

      # The orphan never reached the upstream, and the gate said so.
      let aHistory = runCmd(q(gitBin) & " -C " & q(fx.storeBare) &
        " log --all --format=%H -- " & q(draftRel(shaA)))
      check aHistory.code == 0
      checkpoint("upstream history touching A's record: " & aHistory.output)
      check aHistory.output.strip().len == 0
      check not fileExists(draftPath(fx, shaA))
      check fileExists(draftPath(fx, shaB))
      check "swept orphaned lock draft" in gate.output
      check draftRel(shaA) in gate.output

  test "thousands of reachable drafts do not stop the sweep":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this test drives real git repositories")
    else:
      let fx = setupFixture(gitBin, "many", publishLocks = false)
      defer: removeDir(fx.scratch)
      let priorRepro = pinHookRunner(fx)
      defer: restoreHookRunner(priorRepro)

      let shaKept = commitIn(gitBin, fx.libA, "kept.txt", "kept commit")
      check firePostCommit(fx).code == 0
      let body = readFile(draftPath(fx, shaKept))

      # Commits reachable from branch ``many``, each with a draft. At ~52
      # bytes per SHA argument, 3000 of them are ~156 KB: past the 128 KiB a
      # single ``sh -c`` argument may carry on Linux, and far past Windows'
      # 32 767-character command line.
      const ManyDrafts = 3000
      let script = fx.scratch / "many.sh"
      writeFile(script, "set -e\ncd " & q(fx.libA) & "\n" &
        "c=$(git rev-parse HEAD); t=$(git rev-parse 'HEAD^{tree}')\n" &
        "for i in $(seq " & $ManyDrafts & "); do\n" &
        "  c=$(git commit-tree \"$t\" -p \"$c\" -m \"many $i\"); echo \"$c\"\n" &
        "done\n" &
        "git update-ref refs/heads/many \"$c\"\n")
      let made = requireGit("bash " & q(script))
      var manyShas: seq[string]
      for line in made.splitLines():
        if line.strip().len > 0: manyShas.add(line.strip())
      check manyShas.len == ManyDrafts
      for sha in manyShas:
        writeFile(draftPath(fx, sha), body)

      # Commit A, then amend it into B: A's draft is the one orphan.
      let shaA = commitIn(gitBin, fx.libA, "feature.txt", "feature A")
      check firePostCommit(fx).code == 0
      check fileExists(draftPath(fx, shaA))
      writeFile(fx.libA / "feature.txt", "feature A, reworded\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.libA) &
        " commit -a --amend -m \"feature B\"")
      assertProvablyOrphaned(gitBin, fx.libA, shaA)
      check firePostCommit(fx).code == 0

      check not fileExists(draftPath(fx, shaA))
      var keptCount = 0
      for sha in manyShas:
        if fileExists(draftPath(fx, sha)): inc keptCount
      check keptCount == ManyDrafts
      check fileExists(draftPath(fx, shaKept))
      let log = readFile(fx.workspaceRoot / ".repro" / "build" / "reports" /
        "post-commit-lock.log")
      check ("swept orphaned lock draft '" & draftRel(shaA) & "'") in log
      # No reachability probe failed along the way.
      check "lock draft sweep:" notin log

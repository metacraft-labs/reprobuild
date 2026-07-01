## Unified-Locking-And-Hooks HL-6 (§7.1 + §7.2) — the REAL post-commit hook
## (``repro hooks dispatch post-commit``) on an EVIDENCE-ONLY repo:
##
##   (a) §7.1 — best-effort publishes the repo's source-free
##       ``WorkspaceVcsEvidence`` triple (head-sha / clean / published) to its
##       HL-1-assigned backend, THROTTLED on head-sha change: a post-commit at a
##       NEW head-sha publishes the triple (``getEvidence`` reads it back); a
##       SECOND post-commit at an UNCHANGED head-sha is a NO-OP — no fresh
##       ``putEvidence`` (the backend's evidence record is byte-identical, and no
##       new evidence commit lands). Captures NO source; never blocks the commit.
##
##   (b) §7.2 — the evidence-only repo's objects are EXCLUDED from the eager
##       cache push: a sibling workspace alternated to the same shared bare
##       receives NO objects for the evidence-only repo (no ``refs/cache`` ref,
##       and the sibling cannot read the new commit), while a NON-evidence
##       (public) repo IS propagated (its ref lands + the sibling reads the
##       object). This proves the guard leaks no source objects locally.
##
## Falsifiability (reproduced by the review):
##   (a) removing the head-sha throttle makes the second unchanged-head
##       post-commit re-publish (a new evidence commit / changed record), so the
##       "no fresh evidence on the second run" assertion trips;
##   (b) removing the cache-push exclusion guard makes the sibling receive the
##       evidence-only repo's objects (its ``refs/cache`` ref lands), so the
##       exclusion assertion trips.
##
## Hermetic: local ``git init`` / ``git init --bare`` only; committed-file
## evidence backend; ``REPRO_WORKSPACE_CLONES`` pinned so the detached child
## resolves the SAME cache root. Config layers silenced with env overrides.
## Skip: ``git`` missing or ``./build/bin/repro`` absent.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_lock_store
import repro_test_support
import repro_workspace_manifests
import shared_clones
import evidence

const reproBinary = "./build/bin/repro"

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

proc gitConfig(gitBin, repo: string) =
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.name \"HL-6 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath, content: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", content & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc projectToml(secretUrl, publicUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"hl6\"\ndefault_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"secret-origin\"\nfetch = \"" & secretUrl & "\"\n\n" &
  "[[remote]]\nname = \"public-origin\"\nfetch = \"" & publicUrl & "\"\n\n" &
  "includes = [\n  \"repos/secret.toml\",\n  \"repos/public.toml\",\n]\n"

proc secretFragment(): string =
  ## The EVIDENCE-ONLY private repo (``participation = "evidence-only"``).
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\nname = \"secret\"\npath = \"secret\"\n" &
  "remote = \"secret-origin\"\nrevision = \"main\"\n" &
  "participation = \"evidence-only\"\n"

proc publicFragment(): string =
  ## A NORMAL shared/public repo — its objects MUST still propagate.
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\nname = \"pub\"\npath = \"pub\"\n" &
  "remote = \"public-origin\"\nrevision = \"main\"\n"

proc silenceLayers(scratch: string) =
  putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")

proc unsilenceLayers() =
  delEnv("REPROBUILD_SYSTEM_CONFIG")
  delEnv("REPROBUILD_USER_CONFIG")
  delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc dispatchPostCommit(reproBin, repoPath: string): tuple[code: int; output: string] =
  run(q(reproBin) & " hooks dispatch post-commit --repo-root=" &
    q(repoPath) & " --")

proc pollRefLands(gitBin, bare, refName: string; iters = 200): bool =
  ## The eager cache push is async; poll (bounded) for the namespaced ref.
  for _ in 0 ..< iters:
    let probe = run(q(gitBin) & " -C " & q(bare) &
      " rev-parse --verify --quiet " & refName)
    if probe.code == 0:
      return true
    sleep(50)
  false

suite "HL-6 — post-commit publishes evidence and excludes from cache push":

  test "t_post_commit_publishes_evidence_and_excludes_from_cache_push":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl6-postcommit-evidence-", "")
      defer: removeDir(scratch)
      let reproBin = absolutePath(reproBinary)

      # ---- upstreams + seeds ------------------------------------------
      let secretOrigin = scratch / "origin-secret.git"
      discard seedGitOrigin(gitBin, secretOrigin, scratch / "seed-secret",
        "secret fixture")
      let publicOrigin = scratch / "origin-public.git"
      discard seedGitOrigin(gitBin, publicOrigin, scratch / "seed-public",
        "public fixture")
      let secretUrl = fileUrl(secretOrigin)
      let publicUrl = fileUrl(publicOrigin)

      # ---- workspace + manifest ---------------------------------------
      let ws = scratch / "workspace"
      createDir(ws)
      let wsName = extractFilename(ws)
      let manifestsRoot = ws / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "hl6.toml",
        projectToml(secretUrl, publicUrl))
      writeFile(manifestsRoot / "repos" / "secret.toml", secretFragment())
      writeFile(manifestsRoot / "repos" / "public.toml", publicFragment())
      writeWorkspaceBranch(ws, project = "hl6", branch = "main")

      # Route the evidence-only repo to a committed-file backend (a repo-local
      # dir — no remote needed). This is the backend the post-commit evidence
      # refresh publishes to and reads back for throttling.
      let evStoreDir = ws / "evidence-store"
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"personal\", " &
        "backend = \"committed-file\", path = \"evidence-store\", " &
        "repos = [\"secret\"] }]\n")

      # ---- shared bares (RA-5) pinned via REPRO_WORKSPACE_CLONES -------
      let cacheRoot = scratch / "clones-cache"
      putEnv("REPRO_WORKSPACE_CLONES", cacheRoot)
      defer: delEnv("REPRO_WORKSPACE_CLONES")
      silenceLayers(scratch)
      defer: unsilenceLayers()

      let secretBareR = refreshSharedBare(gitBin, cacheRoot, secretUrl)
      check secretBareR.ok
      let secretBare = secretBareR.sharedBarePath
      let publicBareR = refreshSharedBare(gitBin, cacheRoot, publicUrl)
      check publicBareR.ok
      let publicBare = publicBareR.sharedBarePath

      # ---- clone both repos into the workspace + wire to their bares ---
      let secretRepo = ws / "secret"
      let pubRepo = ws / "pub"
      discard requireGit(q(gitBin) & " clone --branch main " & q(secretUrl) &
        " " & q(secretRepo))
      discard requireGit(q(gitBin) & " clone --branch main " & q(publicUrl) &
        " " & q(pubRepo))
      gitConfig(gitBin, secretRepo)
      gitConfig(gitBin, pubRepo)
      check wireAlternates(secretRepo, secretBare).ok
      check wireAlternates(pubRepo, publicBare).ok

      # A SIBLING workspace repo for the evidence-only repo, alternated to the
      # SAME shared bare — the leak target §7.2 protects.
      let siblingSecret = scratch / "sibling-secret"
      discard requireGit(q(gitBin) & " clone --branch main " & q(secretUrl) &
        " " & q(siblingSecret))
      check wireAlternates(siblingSecret, secretBare).ok

      let store: LockStore = newCommittedFileLockStore(evStoreDir)

      # =================================================================
      # (a) §7.1 — publish on the FIRST new head-sha.
      # =================================================================
      writeFile(secretRepo / "feature.txt", "secret work\n")
      discard requireGit(q(gitBin) & " -C " & q(secretRepo) & " add feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(secretRepo) &
        " commit -m \"secret feature\"")
      # Publish so HEAD is on origin (is-published evidence resolves true) and
      # the cache-push exclusion is exercised against a real branch tip.
      discard requireGit(q(gitBin) & " -C " & q(secretRepo) & " push origin main")
      let secretSha1 = requireGit(q(gitBin) & " -C " & q(secretRepo) &
        " rev-parse HEAD").strip()

      # Before any post-commit: NO evidence yet.
      check store.getEvidence("hl6", "secret").len == 0

      let d1 = dispatchPostCommit(reproBin, secretRepo)
      if d1.code != 0:
        checkpoint("post-commit 1 output: " & d1.output)
      check d1.code == 0  # never blocks the commit

      # The source-free triple was published to the backend, at the new head.
      let ev1 = store.getEvidence("hl6", "secret")
      check ev1.len == 3
      var evHead1 = ""
      var evClean1, evPub1 = false
      for rec in ev1:
        case rec.op
        of wvqHeadSha: evHead1 = rec.headSha
        of wvqIsClean: evClean1 = rec.isClean
        of wvqIsPublished: evPub1 = rec.isPublished
      check evHead1 == secretSha1   # head-sha of the just-committed revision
      check evClean1                # clean checkout
      check evPub1                  # HEAD published to origin
      # NO source leaked into the evidence store.
      for path in walkDirRec(evStoreDir):
        check "secret work" notin readFile(path)

      # The FIRST post-commit recorded a genuine publish (not a throttle).
      let logPath = ws / ".repro" / "workspace" / "post-commit-lock.log"
      check fileExists(logPath)
      let logAfter1 = readFile(logPath)
      check logAfter1.contains("evidence refreshed")
      check logAfter1.count("evidence refreshed") == 1
      check not logAfter1.contains("evidence refresh throttled")

      # =================================================================
      # (a) §7.1 THROTTLE — second post-commit at UNCHANGED head-sha is a
      # NO-OP: no fresh putEvidence.
      # =================================================================
      let d2 = dispatchPostCommit(reproBin, secretRepo)
      if d2.code != 0:
        checkpoint("post-commit 2 output: " & d2.output)
      check d2.code == 0

      # The evidence record is UNCHANGED (still the first head-sha triple).
      let ev2 = store.getEvidence("hl6", "secret")
      check ev2.len == 3
      var evHead2 = ""
      for rec in ev2:
        if rec.op == wvqHeadSha: evHead2 = rec.headSha
      check evHead2 == secretSha1
      # The SECOND post-commit recorded a THROTTLE (unchanged head-sha), NOT
      # another publish. Falsifiable: removing the throttle turns this into a
      # second "evidence refreshed" (two publishes, no throttle line).
      let logAfter2 = readFile(logPath)
      check logAfter2.contains("evidence refresh throttled")
      check secretSha1 in logAfter2
      # Still exactly ONE genuine publish across both runs.
      check logAfter2.count("evidence refreshed") == 1

      # =================================================================
      # (b) §7.2 — cache-push EXCLUSION for the evidence-only repo, while the
      # NON-evidence public repo IS propagated.
      # =================================================================
      # New commit + push in the PUBLIC repo, then fire its post-commit.
      writeFile(pubRepo / "pub-feature.txt", "public work\n")
      discard requireGit(q(gitBin) & " -C " & q(pubRepo) & " add pub-feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(pubRepo) &
        " commit -m \"pub feature\"")
      let pubSha = requireGit(q(gitBin) & " -C " & q(pubRepo) &
        " rev-parse HEAD").strip()

      let d3 = dispatchPostCommit(reproBin, pubRepo)
      check d3.code == 0

      # The public repo's cache ref LANDS in its shared bare (async — poll).
      check pollRefLands(gitBin, publicBare, "refs/cache/" & wsName & "/main")
      let pubRefSha = requireGit(q(gitBin) & " -C " & q(publicBare) &
        " rev-parse refs/cache/" & wsName & "/main").strip()
      check pubRefSha == pubSha

      # Now the evidence-only repo: even after ITS post-commit (already fired
      # twice above), the shared bare must have NO cache ref for it and the
      # sibling must NOT be able to read the new commit object. We give the
      # detached child ample time (the public push above already landed, so an
      # equally-fired evidence push would have landed by now if the guard were
      # absent), then assert ABSENCE.
      sleep(300)
      let evRefProbe = run(q(gitBin) & " -C " & q(secretBare) &
        " rev-parse --verify --quiet refs/cache/" & wsName & "/main")
      check evRefProbe.code != 0   # NO cache ref for the evidence-only repo
      # The sibling (alternated to the secret shared bare) cannot read the new
      # evidence-only commit object — its source objects were NOT propagated.
      let siblingRead = run(q(gitBin) & " -C " & q(siblingSecret) &
        " cat-file -e " & secretSha1)
      check siblingRead.code != 0

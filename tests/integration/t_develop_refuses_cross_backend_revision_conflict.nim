## DS-2 (CLI/develop.md §"Conflicts are refused, never resolved") — when two
## lock backends name the SAME repo:
##
##   * identical revisions merge silently — one entry in the set;
##   * differing revisions are a HARD ERROR naming the repo, both tiers, both
##     backends, and both revisions.
##
##   > Reprobuild does not pick a winner. A checkout can hold one revision, and
##   > guessing which backend wins would make the developer's source tree depend
##   > on the order backends happened to resolve in.
##
## This is the same refusal the multi-project union already applies
## (Workspace-And-Develop-Mode.md §"Union Rules") and the cross-tier loud error
## of Unified-Locking-And-Hooks.md §4.4.
##
## Fixture: one repo `shared` with TWO real commits (shaA, shaB). The committed
## lock (the PUBLIC tier's backend) pins shaA; a team route claims `shared` and
## the team git-checkout backend holds a record pinning shaB.
##
## Asserts:
##   1. DIFFERING revisions ⇒ exit 2, and the diagnostic names `shared`, both
##      tiers (public / team), both backends (committed-lock / git-checkout),
##      and BOTH revisions. Nothing is checked out — the refusal precedes any
##      mutation.
##   2. The refusal explicitly says no winner is picked (so a future reader
##      cannot mistake it for a resolvable precedence rule).
##   3. IDENTICAL revisions ⇒ exit 0, ONE entry, cloned once.
##
## Falsifiability / mutation: making the composer pick the higher-precedence
## backend instead of refusing turns (1) into an exit-0 clone at shaB, so the
## exit-2 and diagnostic assertions fail. Verified.
##
## Mocks: NONE. A real git repo with two real commits, the real git-checkout
## lock backend's on-disk record format, and the real ``repro`` binary.
##
## Hermetic: fresh tempdir; the other config layers are silenced. Skip: ``git``
## missing or repro unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_workspace_manifests

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

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"Conflict Tester\"")

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q("file://" & originPath) & " " & q(targetPath))

proc projectToml(sharedUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"shared-origin\"\nfetch = \"" & sharedUrl & "\"\n\n" &
  "includes = [\n  \"repos/shared.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc committedLock(url, sha: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds2-conflict\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"shared\", path = \"shared\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }]\n"

proc buildWorkspace(gitBin, scratch, origin, name, lockSha,
                    recordSha: string): string =
  ## One workspace whose committed lock pins ``lockSha`` and whose TEAM backend
  ## record pins ``recordSha``. Everything else is identical between the two
  ## cases, so the only variable is whether the two backends agree.
  let ws = scratch / name
  createDir(ws)
  let manifestsRoot = ws / ".repro" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "mix.toml",
    projectToml("file://" & origin))
  writeFile(manifestsRoot / "repos" / "shared.toml",
    repoFragment("shared", "shared-origin"))
  initGitRepo(gitBin, manifestsRoot)
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m manifests")
  cloneInto(gitBin, origin, ws / "shared")
  writeWorkspaceBranch(ws, project = "mix", branch = "main")
  writeFile(ws / "repro.lock", committedLock("file://" & origin, lockSha))
  writeFile(ws / ".repro-workspace.toml",
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\n" &
    "url = \"https://example.invalid/manifests.git\"\n\n" &
    "[locking]\n" &
    "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
    "path = \".repro/manifests\", repos = [\"shared\"] }]\n")
  # The git-checkout backend's on-disk record: the verbatim lock body at
  # ``locks/<project>/<repo>/<sha>.toml`` (identical bytes to ``putLock``'s).
  let dir = manifestsRoot / "locks" / "mix" / "shared"
  createDir(dir)
  writeFile(dir / (recordSha & ".toml"),
    "[[repo]]\nname = \"shared\"\npath = \"shared\"\nrevision = \"" &
      recordSha & "\"\n")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m " & q("lockstore: mix/shared@" & recordSha))
  ws

suite "DS-2: a cross-backend revision conflict is refused, never resolved":

  test "t_develop_refuses_cross_backend_revision_conflict":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds2-conflict-", "")
      defer: removeDir(scratch)

      # ---- one repo, TWO real commits: shaA and shaB. --------------------
      let origin = scratch / "origin-shared.git"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      let seed = scratch / "seed-shared"
      initGitRepo(gitBin, seed)
      writeFile(seed / "a.txt", "a\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add a.txt")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m a")
      let shaA = requireGit(q(gitBin) & " -C " & q(seed) &
        " rev-parse HEAD").strip()
      writeFile(seed / "b.txt", "b\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add b.txt")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m b")
      let shaB = requireGit(q(gitBin) & " -C " & q(seed) &
        " rev-parse HEAD").strip()
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " remote add origin " & q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")
      check shaA.len == 40
      check shaB.len == 40
      check shaA != shaB

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) DIFFERING revisions ⇒ hard refusal. -----------------------
      let wsConflict = buildWorkspace(gitBin, scratch, origin,
        "ws-conflict", shaA, shaB)
      let depsConflict = scratch / "deps-conflict"
      let bad = run(repro & " develop --all --into=" & q(depsConflict) &
        " --tool-provisioning=path", cwd = wsConflict)
      if bad.code != 2:
        checkpoint("conflict output: " & bad.output)
      check bad.code == 2
      check "shared" in bad.output
      check "public" in bad.output
      check "team" in bad.output
      check "committed-lock" in bad.output
      check "git-checkout" in bad.output
      check shaA in bad.output
      check shaB in bad.output
      # (2) the refusal is explicit that no winner is picked.
      check "does NOT pick a winner" in bad.output
      # The refusal precedes every mutation.
      check not dirExists(depsConflict / "shared")
      check not fileExists(wsConflict / ".repro" / "develop-overrides.toml")

      # ---- (3) IDENTICAL revisions merge silently ⇒ one entry. -----------
      let wsAgree = buildWorkspace(gitBin, scratch, origin,
        "ws-agree", shaA, shaA)
      let depsAgree = scratch / "deps-agree"
      let good = run(repro & " develop --all --into=" & q(depsAgree) &
        " --tool-provisioning=path", cwd = wsAgree)
      if good.code != 0:
        checkpoint("agreeing output: " & good.output)
      check good.code == 0
      check good.output.count("cloned shared @ " & shaA) == 1
      check requireGit(q(gitBin) & " -C " & q(depsAgree / "shared") &
        " rev-parse HEAD").strip() == shaA
      check "does NOT pick a winner" notin good.output

## DS-3 (CLI/develop.md §"Unreachable backends never narrow the set silently")
## — the PERSONAL half of the rule, mirroring Unified-Locking-And-Hooks.md
## Decision 2's warn-for-personal:
##
##   > a personal backend that cannot be read → warn and continue, and the
##   > report **enumerates the repos thereby omitted**. A narrowed set that is
##   > not named is indistinguishable from a complete one, which is the failure
##   > mode this rule exists to prevent.
##
##   > `--strict` promotes the personal-tier warning to the same refusal.
##
## The enumeration is the load-bearing half. Warning "your personal backend is
## unreachable" while silently dropping `mine` leaves the developer with a
## develop set that looks complete; naming `mine` is what makes the narrowing
## visible.
##
## Fixture: a manifest workspace whose `[locking]` route sends the PERSONAL tier
## to a git-checkout backend at ``.repro/manifests-personal`` — never cloned.
## `core` is public and pinned by the committed lock, so the run has real work
## it can still legitimately complete.
##
## Asserts:
##   1. exit 0 — the user's own backend must not block their work;
##   2. a WARNING naming the personal tier, the backend kind, the location and
##      the underlying diagnostic;
##   3. the omitted repo is ENUMERATED by name (`mine`);
##   4. the run still completes the reachable part (`core` is cloned) and does
##      NOT check out the omitted repo;
##   5. `--strict` promotes the warning to the SAME refusal the team tier gets
##      (exit 2), and then mutates nothing.
##
## Falsifiability / mutation: making the personal-tier omission silent (drop the
## per-repo enumeration, keep the warning) leaves (1), (2) and (4) passing while
## (3) fails — which is exactly the failure mode the rule targets. Verified.
##
## Mocks: NONE. A real manifest checkout, a real (deliberately absent) backend
## path, and the real ``repro`` binary.
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
    " config user.name \"Personal Tier Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q("file://" & originPath) & " " & q(targetPath))

proc projectToml(coreUrl, mineUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"mine-origin\"\nfetch = \"" & mineUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/mine.toml\",\n]\n"

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
  "inputs_digest = \"ds3-personal\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"core\", path = \"core\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }]\n"

suite "DS-3: an unreachable PERSONAL backend warns and NAMES the omissions":

  test "t_develop_warns_and_names_omitted_personal_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds3-personal-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let mineOrigin = scratch / "origin-mine.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      discard seedGitOrigin(gitBin, mineOrigin, scratch / "seed-mine")

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & mineOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "mine.toml",
        repoFragment("mine", "mine-origin"))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, mineOrigin, ws / "mine")
      writeWorkspaceBranch(ws, project = "mix", branch = "main")
      writeFile(ws / "repro.lock", committedLock("file://" & coreOrigin, coreSha))

      let personalBackend = ws / ".repro" / "manifests-personal"
      check not dirExists(personalBackend)
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"personal\", backend = \"git-checkout\", " &
        "path = \".repro/manifests-personal\", repos = [\"mine\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- warn-and-continue, with the omissions enumerated. -------------
      let deps = scratch / "deps"
      let res = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = ws)
      if res.code != 0:
        checkpoint("develop --all output: " & res.output)
      # (1) the user's own backend does not block their work.
      check res.code == 0
      # (2) a WARNING naming tier + kind + location + diagnostic.
      check "WARNING" in res.output
      check "personal" in res.output
      check "git-checkout" in res.output
      check personalBackend in res.output
      check "does not exist" in res.output
      # (3) the omitted repo is ENUMERATED — the load-bearing half.
      check "OMITTED" in res.output
      check "mine" in res.output
      # (4) the reachable part still completed; the omitted repo did not.
      check ("cloned core @ " & coreSha) in res.output
      check dirExists(deps / "core")
      check not dirExists(deps / "mine")

      # ---- --strict promotes the warning to the same refusal. ------------
      let depsStrict = scratch / "deps-strict"
      let strict = run(repro & " develop --all --strict --into=" &
        q(depsStrict) & " --tool-provisioning=path", cwd = ws)
      if strict.code != 2:
        checkpoint("strict output: " & strict.output)
      check strict.code == 2
      check "personal" in strict.output
      check personalBackend in strict.output
      check "WARNING" notin strict.output
      check not dirExists(depsStrict / "core")

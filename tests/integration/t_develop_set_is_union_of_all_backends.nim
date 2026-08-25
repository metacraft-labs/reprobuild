## DS-1 (CLI/develop.md §"The Develop Set Is The Workspace Lock Set") — the
## develop set is the UNION of the lock records readable from EVERY backend the
## configuration plane resolves for the workspace, not one file.
##
##   > Whenever Reprobuild looks at a project in a workspace, it can determine
##   > the set of projects that workspace's lock files manage. That set — the
##   > whole of it, across every lock backend — is what `repro develop` operates
##   > on.
##
## Before DS-1, ``executeDevelopAll`` read ``committedLockPath(root)`` and
## NOTHING else, so a workspace that declares a team route (which is exactly
## what ``repro locking adopt-manifest`` writes, and the shape the metacraft
## workspaces are in) could not see its own team-tier repos at all.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline):
##
##   <scratch>/
##     origin-core.git / seed-core   — a PUBLIC repo, pinned by the committed lock
##     origin-team.git / seed-team   — a TEAM repo, pinned ONLY by the team backend
##     ws/
##       repro.lock                  — the PUBLIC tier's backend (committed-file)
##       .repro/manifests/           — a git checkout; ALSO the TEAM backend
##       .repro-workspace.toml       — `[locking] route` team -> git-checkout,
##                                     naming `team-lib` (adopt-manifest's shape)
##       core/ team-lib/             — the workspace checkouts
##     deps/                         — the `--into` checkout-placement root
##
## ``repro workspace lock`` writes ``team-lib``'s per-repo record into the team
## backend. The two backends therefore pin DISJOINT repo sets, which is the
## common case the tier-isolation invariant produces.
##
## Asserts:
##   1. ``repro develop --all --into=<deps>`` exits 0 and clones BOTH the
##      committed lock's ``core`` AND the team backend's ``team-lib``.
##   2. Each checkout is at the EXACT revision its OWN backend pinned.
##   3. The M20 override file records both, so the union really became the
##      develop set rather than only being reported.
##
## Falsifiability / pre-fix failure: against a build whose ``executeDevelopAll``
## reads only ``committedLockPath(root)``, (1) prints only ``cloned core`` and
## the ``team-lib`` assertions fail — the team repo is invisible. Verified
## against the pre-DS-1 binary.
##
## Mocks: NONE. Real git repos on the real filesystem, a real manifest
## checkout, the real ``repro`` binary, the real git-checkout lock backend.
##
## Hermetic: fresh tempdir; the other config layers are silenced via the
## ``REPROBUILD_*_CONFIG`` overrides so the developer's own dotfiles/system
## config cannot contribute routes. Skip: ``git`` missing or repro unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_workspace_manifests

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

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
    " config user.name \"Develop Set Tester\"")

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
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Develop Set Tester\"")

proc projectToml(coreUrl, teamUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"team-origin\"\nfetch = \"" & teamUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/team-lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc depInline(name, path, url, sha: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", groups = \"\" }"

proc committedLock(deps: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds1-fixture\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps & "]\n"

suite "DS-1: the develop set is the union of every lock backend":

  test "t_develop_set_is_union_of_all_backends":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds1-union-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")
      check coreSha.len == 40
      check teamSha.len == 40

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & teamOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin"))

      # The team backend IS the manifest checkout (adopt-manifest's shape), so
      # it must be a real git repo for the git-checkout backend to commit into.
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, teamOrigin, ws / "team-lib")
      writeWorkspaceBranch(ws, project = "mix", branch = "main")

      # The PUBLIC tier's backend: the committed lock, naming ONLY `core`.
      writeFile(ws / "repro.lock",
        committedLock(depInline("core", "core", "file://" & coreOrigin, coreSha)))

      # The TEAM tier's route — byte-for-byte what `repro locking
      # adopt-manifest` scaffolds, naming ONLY `team-lib`.
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"team-lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # Publish `team-lib`'s per-repo record into the TEAM backend.
      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      check fileExists(manifestsRoot / "locks" / "mix" / "team-lib" /
        (teamSha & ".toml"))

      # ---- (1) develop --all sees BOTH backends. -------------------------
      let deps = scratch / "deps"
      let res = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = ws)
      if res.code != 0:
        checkpoint("develop --all output: " & res.output)
      check res.code == 0
      # The committed lock's PUBLIC repo.
      check ("cloned core @ " & coreSha) in res.output
      # The team backend's TEAM repo — invisible before DS-1.
      check ("cloned team-lib @ " & teamSha) in res.output

      # ---- (2) each checkout is at the revision ITS backend pinned. ------
      check dirExists(deps / "core")
      check dirExists(deps / "team-lib")
      check requireGit(q(gitBin) & " -C " & q(deps / "core") &
        " rev-parse HEAD").strip() == coreSha
      check requireGit(q(gitBin) & " -C " & q(deps / "team-lib") &
        " rev-parse HEAD").strip() == teamSha

      # ---- (3) the union really became the develop set. ------------------
      let ovPath = ws / ".repro" / "develop-overrides.toml"
      check fileExists(ovPath)
      let ov = readFile(ovPath)
      check "package = \"core\"" in ov
      check "package = \"team-lib\"" in ov

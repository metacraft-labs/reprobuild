## DS-1 (CLI/develop.md §"The Develop Set Is The Workspace Lock Set") — **no
## single row is a precondition for the others**, and the route is carried by
## **configuration layer 5**.
##
##   > The committed lock is *one source of equal status*, not a gate — a
##   > workspace that has no `repro.lock` at all but does have a declared team
##   > route resolves that route's repos […] the metacraft workspaces carry 126
##   > published `locks/<project>/<repo>/<sha>.toml` records and no
##   > `repro.lock`, and under the inverted reading they resolve nothing. An
##   > empty union — no backend yielded any record — is the only lock-set
##   > failure, and it names every backend consulted.
##
## This test reproduces the REAL workspace, not a convenient shape. Two things
## about `/home/zahary/m/js-support` made the shipped composer unreachable, and
## both are reproduced here deliberately:
##
##   1. there is **no `repro.lock`**. ``executeDevelopAll`` returned exit 1 on
##      that fact BEFORE ``composeDevelopLockSet`` was ever called, so the team
##      backend holding every record was never read. The command that was
##      written to serve this workspace could not run on it;
##   2. the team route lives in **`<git-common-dir>/repro/config.toml`**
##      (Unified-Locking-And-Hooks.md §4.3, configuration layer 5) — the
##      VCS-private layer that is never tracked and never pushed, which is how
##      the real workspaces carry their route. Every pre-existing develop test
##      declared its route in layer 4 (``.repro-workspace.toml``) and silenced
##      layer 5 by pointing ``REPROBUILD_VCS_PRIVATE_CONFIG`` at a nonexistent
##      file, so the layer used in production had no coverage at all.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline):
##
##   <scratch>/
##     origin-team.git / seed-team  — a TEAM repo, pinned ONLY by the team backend
##     ws/                          — a git repo (layer 5 needs a git-common-dir)
##       .git/repro/config.toml     — LAYER 5: `[locking] route` team ->
##                                    git-checkout `.repro/manifests`
##       .repro/manifests/          — a git checkout; the TEAM backend
##       .repro-workspace.toml      — manifest bootstrap ONLY, no `[locking]`
##       NO repro.lock              — the whole point
##     deps/                        — the `--into` checkout-placement root
##
## Asserts:
##   1. ``repro develop --all`` exits 0 and clones ``team-lib`` at the exact
##      revision the TEAM backend pinned — with no committed lock anywhere;
##   2. ``--dry-run`` resolves the same set and mutates NOTHING (no checkout,
##      no override file). This is the read-only query form;
##   3. the M20 override file records the team repo, so the route's repos
##      really became the develop set;
##   4. the ONLY lock-set failure is an EMPTY UNION: a route-less, lock-less
##      directory exits 1 with a diagnostic that NAMES every backend consulted
##      (here: the public committed-lock backend and its path).
##
## Falsifiability / pre-fix failure: against ``6b342175`` this test fails at
## (1) with
##
##   repro develop --all: no committed lock at <ws>/repro.lock — run
##   `repro lock refresh` first (a missing lock is a hard error; there is no
##   branch-tip fallback)
##   EXIT=1
##
## Mutation check: restoring the pre-composer ``if not fileExists(lockP):
## return (@[], @[], 1)`` gate in ``executeDevelopAll`` reproduces exactly that
## output and fails (1), (2) and (3); dropping the layer-5 read from
## ``composeLockingRouting`` makes the workspace resolve no routes, so (1)
## clones nothing and (4)'s empty-union failure fires on the MAIN workspace.
##
## Mocks: NONE. Real git repos on the real filesystem, a real manifest
## checkout, a real layer-5 config file inside a real ``.git``, the real
## ``repro`` binary, the real git-checkout lock backend.
##
## Hermetic: fresh tempdir; layers 2 and 3 are silenced via the
## ``REPROBUILD_*_CONFIG`` overrides. Layer 5 is deliberately NOT silenced —
## it is the layer under test — so it resolves from the fixture's own
## ``.git/repro/config.toml``. Skip: ``git`` missing or repro unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]

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
    " config user.name \"Layer5 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", "seed " & extractFilename(workPath) & "\n")
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
    " config user.name \"Layer5 Tester\"")

proc projectToml(teamUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"team-origin\"\nfetch = \"" & teamUrl & "\"\n\n" &
  "includes = [\n  \"repos/team-lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

suite "DS-1: the committed lock is not a gate; layer 5 carries the route":

  test "t_develop_composes_lock_set_without_a_committed_lock":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds1-layer5-", "")
      defer: removeDir(scratch)

      let teamOrigin = scratch / "origin-team.git"
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")
      check teamSha.len == 40

      # The workspace root is itself a git repo — layer 5 lives inside its
      # ``.git`` common dir, so without that this layer cannot exist at all.
      let ws = scratch / "workspace"
      initGitRepo(gitBin, ws)

      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & teamOrigin))
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin"))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, teamOrigin, ws / "team-lib")
      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")

      # Layer 4 carries the manifest bootstrap and NOTHING about locking: the
      # route must come from layer 5 alone or this test proves nothing.
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")

      # ---- LAYER 5 (Unified-Locking-And-Hooks.md §4.3) --------------------
      # ``<git-common-dir>/repro/config.toml`` — byte-for-byte the shape
      # ``repro locking adopt-manifest`` writes into the real workspaces.
      let layer5Dir = ws / ".git" / "repro"
      createDir(layer5Dir)
      writeFile(layer5Dir / "config.toml",
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"team-lib\"] }]\n")

      # THE POINT: no committed lock exists anywhere in this workspace.
      check not fileExists(ws / "repro.lock")

      # Layers 2 and 3 are silenced. Layer 5 is NOT — it is under test.
      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      # Publish `team-lib`'s per-repo record into the TEAM backend. This is the
      # only lock record that will exist.
      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      check fileExists(manifestsRoot / "locks" / "mix" / "team-lib" /
        (teamSha & ".toml"))

      # ---- (2) --dry-run resolves the set and mutates NOTHING. -----------
      # Run BEFORE the real placement so "nothing was created" is meaningful.
      let deps = scratch / "deps"
      let dry = run(repro & " develop --all --dry-run --into=" & q(deps) &
        " --tool-provisioning=path", cwd = ws)
      if dry.code != 0:
        checkpoint("develop --all --dry-run output: " & dry.output)
      check dry.code == 0
      check ("would clone team-lib @ " & teamSha) in dry.output
      check not dirExists(deps / "team-lib")
      check not fileExists(ws / ".repro" / "develop-overrides.toml")

      # ---- (1) the route's repos resolve with NO committed lock. ---------
      let res = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = ws)
      if res.code != 0:
        checkpoint("develop --all output: " & res.output)
      check res.code == 0
      check ("cloned team-lib @ " & teamSha) in res.output
      check dirExists(deps / "team-lib")
      check requireGit(q(gitBin) & " -C " & q(deps / "team-lib") &
        " rev-parse HEAD").strip() == teamSha

      # ---- (3) the route's repos really became the develop set. ----------
      let ovPath = ws / ".repro" / "develop-overrides.toml"
      check fileExists(ovPath)
      check "package = \"team-lib\"" in readFile(ovPath)

      # ---- (4) an EMPTY UNION is the only lock-set failure, and it names
      #          every backend consulted. --------------------------------
      # A directory with no committed lock AND no declared route: the built-in
      # public default is the only backend, it holds nothing, and the failure
      # says so by NAME and by PATH rather than reporting a healthy empty set.
      let bare = scratch / "bare"
      createDir(bare)
      let empty = run(repro & " develop --all --tool-provisioning=path",
        cwd = bare)
      if empty.code != 1:
        checkpoint("bare-directory output: " & empty.output)
      check empty.code == 1
      check "EMPTY" in empty.output
      check "no committed lock" in empty.output
      check (bare / "repro.lock") in empty.output

## DS-3 (CLI/develop.md §"Unreachable backends never narrow the set silently",
## mirroring Unified-Locking-And-Hooks.md Decision 2) — a **team** lock backend
## that cannot be read is a REFUSAL, not a smaller develop set.
##
##   > a public or team backend that cannot be read → refuse (exit 2), naming
##   > the tier, the backend kind and location, the underlying diagnostic, and
##   > one copy-pasteable remedy.
##
## The failure mode this rule exists to prevent is the quiet one: a workspace
## whose team manifests repo was never cloned would otherwise report a perfectly
## healthy public-only develop set, and the developer would have no way to tell
## that from a complete one.
##
## Fixture: a manifest workspace whose `[locking]` route sends the team tier to
## a git-checkout backend at ``.repro/manifests-team`` — a path that does not
## exist (the private manifests repo was never cloned). `core` stays public and
## IS pinned by the committed lock, so a "narrowed but plausible" answer is
## available and would look successful.
##
## Asserts:
##   1. exit 2 — the run refuses rather than proceeding with the public subset;
##   2. the diagnostic names the TIER (`team`), the BACKEND KIND
##      (`git-checkout`), the LOCATION, and the underlying diagnostic
##      (`does not exist`);
##   3. it carries ONE copy-pasteable remedy (`git clone … <location>`);
##   4. NOTHING was mutated — not even the public `core`, which would otherwise
##      have cloned fine. A refusal that half-applies is not a refusal.
##
## Falsifiability / mutation: downgrading the team-tier unreachable case to a
## warning-and-continue makes (1) exit 0 and (4) find a cloned `core`.
## Verified.
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
    " config user.name \"Unreachable Backend Tester\"")

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

proc committedLock(url, sha: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds3-team-unreachable\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"core\", path = \"core\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }]\n"

suite "DS-3: an unreachable TEAM lock backend refuses, never narrows":

  test "t_develop_refuses_unreachable_team_backend":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds3-team-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      discard seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")

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
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, teamOrigin, ws / "team-lib")
      writeWorkspaceBranch(ws, project = "mix", branch = "main")
      writeFile(ws / "repro.lock", committedLock("file://" & coreOrigin, coreSha))

      # The team route points at a private manifests repo that was NEVER
      # cloned. This is the realistic shape: the route ships in the config
      # layer, the checkout does not.
      let teamBackend = ws / ".repro" / "manifests-team"
      check not dirExists(teamBackend)
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests-team\", repos = [\"team-lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let deps = scratch / "deps"
      let res = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = ws)
      if res.code != 2:
        checkpoint("develop --all output: " & res.output)
      # (1) refuse, exit 2.
      check res.code == 2
      # (2) tier + backend kind + location + underlying diagnostic.
      check "team" in res.output
      check "git-checkout" in res.output
      check teamBackend in res.output
      check "does not exist" in res.output
      # (3) one copy-pasteable remedy.
      check "git clone" in res.output
      # (4) nothing was mutated — not even the public repo that WOULD have
      #     cloned fine, which is what makes this a refusal and not a
      #     partially-applied narrowing.
      check not dirExists(deps / "core")
      check not dirExists(deps / "team-lib")
      check not fileExists(ws / ".repro" / "develop-overrides.toml")

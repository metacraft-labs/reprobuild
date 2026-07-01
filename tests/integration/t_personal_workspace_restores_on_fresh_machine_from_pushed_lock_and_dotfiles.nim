## Unified-Locking-And-Hooks HL-7 (§8.4 CAPSTONE, §5 durability) — a personal
## workspace RESTORES on a FRESH MACHINE from (a) the durable lock pushed to a
## private manifests repo (Plane B) plus (b) the synced dotfiles ``apply-if``
## config (Plane A) — with NO manual per-repo steps. This is the end-to-end
## capability the two-plane model exists to deliver.
##
## The two planes, made concrete:
##   * Plane A (CONFIGURATION — regenerable). The route that says "this repo's
##     personal lock lives in the private manifests repo backend" is declared by
##     a USER DOTFILES ``apply-if`` (``REPROBUILD_USER_CONFIG``) scoped under the
##     workspace path. On the fresh machine this is the ONLY config present — no
##     VCS-private (``.git/repro/config.toml``) layer, no parent workspace repo.
##   * Plane B (LOCK-STORAGE — durable). The concrete locked SHA lives in a
##     SEPARATE private manifests repo (a ``git-checkout`` lock backend) as a
##     ``locks/<p>/<repo>/<sha>.toml`` record. It is DURABLE: cloned onto the
##     fresh machine, it carries the locked revision across machines.
##
## The app repo's own manifest fragment pins it by BRANCH ``main``, and the
## branch has ADVANCED past the locked revision (a second commit landed after
## the lock was published). So a naive ``git clone --branch main`` lands on the
## TIP, NOT the locked revision — the ONLY way to reconstruct the LOCKED state is
## to read the durable lock from the routed backend (via the dotfiles route) and
## check out that SHA. This is exactly what proves both planes are load-bearing.
##
## Fresh-machine simulation: a clean workspace with the app checkout ABSENT, the
## private manifests repo cloned (durable backend reachable), the dotfiles
## ``apply-if`` config synced (route present), and NO VCS-private config. Then a
## single ``repro workspace sync`` reconstructs the app repo AT THE LOCKED SHA
## with no per-repo steps.
##
## Assertions:
##   1. After ``repro workspace sync`` on the fresh machine, the app checkout
##      exists and its HEAD is the LOCKED SHA (``sha1``) — NOT the branch tip
##      (``sha2``). Reconstruction landed at the durable locked revision.
##   2. The sync summary reports the repo as ``cloned`` (no failure / refusal).
##
## Falsifiability (both planes independently load-bearing):
##   * WITHHOLD PLANE B (the pushed durable lock): with the private manifests
##     repo's ``locks/`` record removed, sync has no durable SHA to read, so the
##     fresh clone stays on the branch tip ``sha2`` — assertion (1) trips.
##   * WITHHOLD PLANE A (the dotfiles route): with the ``apply-if`` config
##     unset, the routing composes to nothing, sync never consults the routed
##     backend, and the checkout again stays on ``sha2`` — assertion (1) trips.
## Both are exercised below as explicit sub-cases.
##
## Hermetic: every git repo + backend lives in a fresh tempdir; the config
## arrives ONLY via ``REPROBUILD_USER_CONFIG`` (dotfiles), never ``$HOME`` /
## ``/etc``. Skip: ``git`` missing or ``./build/bin/repro`` absent.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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
    " config user.name \"HL-7 Tester\"")

proc tomlPath(p: string): string =
  '"' & p.replace("\\", "\\\\").replace("\"", "\\\"") & '"'

proc projectToml(appUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"personal\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"app-origin\"\nfetch = \"" & appUrl & "\"\n\n" &
  "includes = [\n  \"repos/app.toml\",\n]\n"

proc repoFragment(): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"app\"\n" &
  "path = \"app\"\n" &
  "remote = \"app-origin\"\n" &
  "revision = \"main\"\n"

proc workspaceLocal(): string =
  "schema = \"reprobuild.workspace.local.v1\"\n\n" &
  "[workspace]\n" &
  "project = \"personal\"\n" &
  "branch = \"main\"\n"

proc appHead(gitBin, ws: string): string =
  run(q(gitBin) & " -C " & q(ws / "app") & " rev-parse HEAD").output.strip()

suite "HL-7 — personal workspace restores on a fresh machine":

  test "t_personal_workspace_restores_on_fresh_machine_from_pushed_lock_and_dotfiles":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl7-capstone-", "")
      defer: removeDir(scratch)

      # ---- the app repo's origin: sha1 (LOCKED), then sha2 (branch tip) ----
      let appOrigin = scratch / "origin-app.git"
      let appSeed = scratch / "seed-app"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(appOrigin))
      discard requireGit(q(gitBin) & " init -b main " & q(appSeed))
      gitConfig(gitBin, appSeed)
      writeFile(appSeed / "a.txt", "one\n")
      discard requireGit(q(gitBin) & " -C " & q(appSeed) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(appSeed) & " commit -m one")
      discard requireGit(q(gitBin) & " -C " & q(appSeed) &
        " remote add origin " & q(appOrigin))
      discard requireGit(q(gitBin) & " -C " & q(appSeed) & " push origin main")
      let sha1 = requireGit(q(gitBin) & " -C " & q(appSeed) &
        " rev-parse HEAD").strip()
      # The branch ADVANCES after the lock is published.
      writeFile(appSeed / "b.txt", "two\n")
      discard requireGit(q(gitBin) & " -C " & q(appSeed) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(appSeed) & " commit -m two")
      discard requireGit(q(gitBin) & " -C " & q(appSeed) & " push origin main")
      let sha2 = requireGit(q(gitBin) & " -C " & q(appSeed) &
        " rev-parse HEAD").strip()
      check sha1 != sha2

      # ---- Plane B: the private manifests repo (durable personal backend) ---
      # A git-checkout lock backend carrying the pushed durable lock — the
      # ``app`` repo's PERSONAL participation record pinning ``sha1``. On the
      # fresh machine this stands in for "the private manifests repo I cloned".
      let privateManifests = scratch / "private-manifests"
      discard requireGit(q(gitBin) & " init -b main " & q(privateManifests))
      gitConfig(gitBin, privateManifests)
      let lockDir = privateManifests / "locks" / "personal" / "app"
      createDir(lockDir)
      writeFile(lockDir / (sha1 & ".toml"),
        "[[repo]]\npath = \"app\"\nrevision = \"" & sha1 & "\"\n")
      discard requireGit(q(gitBin) & " -C " & q(privateManifests) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(privateManifests) &
        " commit -m \"pushed personal lock\"")

      # ---- Plane A: the dotfiles apply-if route (personal → the backend) ----
      let personalRoutes = scratch / "personal-routes.toml"
      writeFile(personalRoutes,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"personal\", backend = \"git-checkout\", " &
        "path = " & tomlPath(privateManifests) & ", repos = [\"app\"] }]\n")

      # ---- the FRESH-MACHINE workspace: config-plane manifest, NO app ------
      # The ``.repo/manifests`` layer is the REGENERABLE config plane (repo
      # fragments, branch pins). It carries NO ``locks/`` — the durable lock is
      # in the private manifests repo (Plane B). The app checkout is ABSENT.
      let ws = scratch / "fresh-machine"
      createDir(ws)
      let manifestsRoot = ws / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "personal.toml",
        projectToml("file://" & appOrigin))
      writeFile(manifestsRoot / "repos" / "app.toml", repoFragment())
      writeFile(ws / ".repo" / "workspace.toml", workspaceLocal())

      # The dotfiles config: apply-if scoped under the workspace path.
      let userCfg = scratch / "dotfiles.toml"
      writeFile(userCfg,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "apply_if = [{ under = " & tomlPath(ws) &
        ", config = " & tomlPath(personalRoutes) & " }]\n")

      # Silence the OTHER config layers — the fresh machine has ONLY dotfiles.
      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      # Sanity: the app checkout is genuinely absent before the restore.
      check not dirExists(ws / "app")

      # =================================================================
      # (1)+(2) BOTH planes present → restore lands at the LOCKED sha1.
      # =================================================================
      putEnv("REPROBUILD_USER_CONFIG", userCfg)   # Plane A synced
      let restore = run(reproBinary & " workspace sync --workspace-root=" &
        q(ws) & " --json")
      if restore.code != 0:
        checkpoint("restore output: " & restore.output)
      check restore.code == 0
      check dirExists(ws / "app")
      # THE capstone assertion: reconstructed at the DURABLE LOCKED revision,
      # not the branch tip.
      check appHead(gitBin, ws) == sha1
      check appHead(gitBin, ws) != sha2
      # The repo was cloned (reconstructed with no manual per-repo steps).
      let report = parseFile(ws / ".repro" / "workspace" / "sync-report.json")
      var appEntry: JsonNode = nil
      for e in report["repos"]:
        if e["path"].getStr() == "app": appEntry = e
      check appEntry != nil
      check appEntry["executionStatus"].getStr() == "cloned"

      # =================================================================
      # Falsify — WITHHOLD PLANE A (the dotfiles route). Re-run from a fresh
      # (absent) checkout with the route UNSET: no route composes, sync never
      # reads the durable backend, so the clone stays on the branch tip sha2.
      # =================================================================
      block withholdPlaneA:
        removeDir(ws / "app")
        delEnv("REPROBUILD_USER_CONFIG")   # route withheld
        let noRoute = run(reproBinary & " workspace sync --workspace-root=" &
          q(ws) & " --json")
        check noRoute.code == 0
        check dirExists(ws / "app")
        # Without the route the fresh clone lands on the TIP, not the lock.
        check appHead(gitBin, ws) == sha2

      # =================================================================
      # Falsify — WITHHOLD PLANE B (the pushed durable lock). Route present,
      # but the private manifests repo's ``locks/`` record removed: no durable
      # SHA to read, so again the clone stays on sha2.
      # =================================================================
      block withholdPlaneB:
        removeDir(ws / "app")
        removeDir(privateManifests / "locks")
        discard requireGit(q(gitBin) & " -C " & q(privateManifests) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(privateManifests) &
          " commit -m \"drop pushed lock\"")
        putEnv("REPROBUILD_USER_CONFIG", userCfg)   # route present again
        let noLock = run(reproBinary & " workspace sync --workspace-root=" &
          q(ws) & " --json")
        check noLock.code == 0
        check dirExists(ws / "app")
        check appHead(gitBin, ws) == sha2
        delEnv("REPROBUILD_USER_CONFIG")

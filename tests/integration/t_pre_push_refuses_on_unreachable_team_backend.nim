## Unified-Locking-And-Hooks HL-3 (§6 Decision 2) — refuse-for-shared on an
## unreachable backend, driven through the REAL pre-push hook (``repro check
## --mode=pre-push`` + its post-gate per-backend publish).
##
## A TEAM-tier repo is routed to a git-checkout lock backend on its OWN private
## remote (NOT the ``.repo/manifests`` manifest). The backend's upstream bare is
## removed after its tracking branch is configured, so the pre-push publish push
## to the team backend FAILS (``publishWorkspaceLock`` → ``lpoFailed``). Because
## the tier is SHARED (team), Decision 2 says REFUSE: the gate must exit 2 with a
## ``lock-backend-unreachable`` ``CheckFailure`` naming the repo/backend + a
## copy-pasteable remedy.
##
## Assertions:
##   - the gate exits NON-ZERO (the push is refused);
##   - the report carries a ``lock-backend-unreachable`` failure whose
##     remediation names the ``team`` tier + ``git-checkout`` backend + the
##     ``repro push`` next step, and whose evidence names the publish cause;
##   - the manifest publish itself did NOT gate (no ``lock-publish-failure``):
##     the refusal is specifically the team backend being unreachable.
##
## Falsifiability (documented, reproduced by the review): treating a failed team
## outcome as a personal WARN (leaving exit 0) — or dropping the refuse policy —
## makes the gate exit 0 and drops the ``lock-backend-unreachable`` failure, so
## the ``check res.code != 0`` and the failure-presence assertions trip.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network. The
## system/dotfiles/VCS-private config layers are silenced with env overrides.
## Skip: ``git`` missing or ``./build/bin/repro`` absent.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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

proc gitConfig(gitBin, repo: string) =
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.name \"HL-3 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "HL-3 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q("file://" & originPath) & " " & q(targetPath))
  gitConfig(gitBin, targetPath)

proc seedGitCheckoutBackend(gitBin, checkoutRoot, bare: string) =
  ## A git-checkout lock backend that TRACKS a bare upstream — so the pre-push
  ## per-backend publish genuinely attempts a push. Removing the bare afterwards
  ## makes that push fail while ``@{u}`` still resolves from local config.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(bare))
  discard requireGit(q(gitBin) & " init -b main " & q(checkoutRoot))
  gitConfig(gitBin, checkoutRoot)
  writeFile(checkoutRoot / ".keep", "team lock backend\n")
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) & " add .keep")
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) &
    " commit -m \"seed team backend\"")
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) &
    " push -u origin main")

proc projectToml(coreUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"team\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc seedManifestGitLayer(gitBin, manifestsRoot, bare: string) =
  ## ``.repo/manifests`` is a healthy git checkout WITH an upstream so the gate
  ## runs the full manifest-present path. No repo is routed to it, so its own
  ## publish is a benign no-op — the ONLY failing backend is the team one.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(bare))
  discard requireGit(q(gitBin) & " init -b main " & q(manifestsRoot))
  gitConfig(gitBin, manifestsRoot)
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " push -u origin main")

proc backendUnreachableFailure(report: JsonNode): JsonNode =
  for f in report["failures"]:
    if f["property"].getStr() == "lock-backend-unreachable":
      return f
  return nil

proc publishFailureFailure(report: JsonNode): JsonNode =
  for f in report["failures"]:
    if f["property"].getStr() == "lock-publish-failure":
      return f
  return nil

suite "HL-3 — pre-push refuses on an unreachable team backend":

  test "t_pre_push_refuses_on_unreachable_team_backend":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl3-team-refuse-", "")
      defer: removeDir(scratch)

      # ---- the team repo's own origin + clone --------------------------
      let coreOrigin = scratch / "origin-core.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")

      # ---- workspace + a HEALTHY manifest checkout ---------------------
      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "team.toml",
        projectToml("file://" & coreOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      seedManifestGitLayer(gitBin, manifestsRoot, scratch / "manifest.git")

      cloneInto(gitBin, coreOrigin, ws / "core")
      writeWorkspaceBranch(ws, project = "team", branch = "main")

      # ---- the TEAM git-checkout backend on its OWN remote -------------
      let teamBackend = ws / "team-lockrepo"
      let teamBare = scratch / "team-backend.git"
      seedGitCheckoutBackend(gitBin, teamBackend, teamBare)

      # ---- route the team repo to that separate git-checkout backend ---
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [" &
        "{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \"team-lockrepo\", repos = [\"core\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- write the lock so the team backend has a pending record -----
      let lockRes = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      # ---- make the TEAM backend push FAIL: remove its bare upstream ----
      removeDir(teamBare)

      # ---- drive the REAL pre-push gate --------------------------------
      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & coreSha &
        " refs/heads/main 0000000000000000000000000000000000000000\n")
      let gateRes = run(reproBinary & " check --mode=pre-push" &
        " --workspace-root=" & q(ws) &
        " --current-repo=" & q(ws / "core") &
        " --pushed-refs=" & q(refsFile) & " --json")
      checkpoint("gate output: " & gateRes.output)

      # ---- REFUSE: exit non-zero ---------------------------------------
      check gateRes.code != 0

      let reportPath = ws / ".repro" / "workspace" / "check-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      check report["exitCode"].getInt() != 0

      # ---- the lock-backend-unreachable failure, tier + backend named ---
      let bf = backendUnreachableFailure(report)
      check bf != nil
      let remedy = bf["remediation"].getStr()
      check remedy.contains("team")
      check remedy.contains("git-checkout")
      check remedy.contains("repro push")
      let evidence = bf["evidence"].getStr()
      check evidence.contains("tier=team")
      check evidence.contains("backend=git-checkout")

      # ---- the manifest publish did NOT itself gate --------------------
      # No repo is routed to ``.repo/manifests``; its publish is a no-op, so the
      # ONLY refusal is the unreachable team backend (not a manifest publish
      # failure). Proves the refusal is the team-tier Decision-2 policy.
      check publishFailureFailure(report) == nil

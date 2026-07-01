## Unified-Locking-And-Hooks HL-7 (§8.4 corner: "one sibling public-clean +
## another team-unpublished") — in a MIXED public+team workspace, the public
## sibling passes but the team sibling's UNPUBLISHED HEAD fails the publication
## stage (exit 2). The existing per-repo cleanliness/publication stages run over
## the pushed repo's dependency-closure scope (RA-21); tier does not exempt a
## repo from the publication boundary — an unpublished HEAD a teammate cannot
## fetch is a refusal regardless of which backend the repo's LOCK routes to.
##
## Fixture (built ``./build/bin/repro``, black-box): a ``.repo/manifests``
## workspace with two cloned repos —
##   - ``pub``  → PUBLIC, clean + published, the pushed/current repo; it
##     ``depends = ["core"]`` so ``core`` is in its dependency closure;
##   - ``core`` → TEAM, routed (by NAME) to a separate git-checkout backend, but
##     with a LOCAL commit that was never pushed to its origin (HEAD unpublished).
##
## Assertions:
##   1. The gate REFUSES (exit 2).
##   2. The single failure is ``unpublished`` naming ``core`` + ``git push`` —
##      the public sibling is clean/published and does NOT fail.
##
## Falsifiability: the refusal depends on ``core`` being IN SCOPE (``pub``'s
## dependency closure). Dropping the ``depends = ["core"]`` edge narrows the
## closure to ``{pub}`` alone, so the unpublished team HEAD is no longer checked
## and the gate PASSES (exit 0) — assertion (1) trips. (Confirmed below by a
## second run with the edge removed: the gate passes.) This proves the corner
## cell is the publication stage genuinely gating the in-scope team sibling.
##
## Hermetic: every git repo + backend lives in a fresh tempdir; env overrides
## silence the other config layers. Skip: ``git`` missing or ``./build/bin/repro``
## absent.

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
    " config user.name \"HL-7 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "HL-7 fixture\n")
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

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  gitConfig(gitBin, path)
  writeFile(path / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(path) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(path) & " commit -m seed")

proc commitLocalUnpublished(gitBin, repoPath: string): string =
  writeFile(repoPath / "local.txt", "unpublished\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add local.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " commit -m local")
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc projectToml(pubUrl, coreUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"pub-origin\"\nfetch = \"" & pubUrl & "\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "includes = [\n  \"repos/pub.toml\",\n  \"repos/core.toml\",\n]\n"

proc pubFragment(withDepends: bool): string =
  result =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"pub\"\n" &
    "path = \"pub\"\n" &
    "remote = \"pub-origin\"\n" &
    "revision = \"main\"\n"
  if withDepends:
    result.add("depends = [\"core\"]\n")

proc coreFragment(): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"core\"\n" &
  "path = \"core\"\n" &
  "remote = \"core-origin\"\n" &
  "revision = \"main\"\n"

proc readReport(ws: string): JsonNode =
  parseFile(ws / ".repro" / "workspace" / "check-report.json")

proc buildWorkspace(gitBin, scratch: string; withDepends: bool):
    tuple[ws, pubSha, unpubSha: string] =
  let pubOrigin = scratch / "origin-pub.git"
  let coreOrigin = scratch / "origin-core.git"
  let pubSha = seedGitOrigin(gitBin, pubOrigin, scratch / "seed-pub")
  discard seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")

  let ws = scratch / "workspace"
  createDir(ws)
  let manifestsRoot = ws / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "mix.toml",
    projectToml("file://" & pubOrigin, "file://" & coreOrigin))
  writeFile(manifestsRoot / "repos" / "pub.toml", pubFragment(withDepends))
  writeFile(manifestsRoot / "repos" / "core.toml", coreFragment())

  cloneInto(gitBin, pubOrigin, ws / "pub")
  cloneInto(gitBin, coreOrigin, ws / "core")
  writeWorkspaceBranch(ws, project = "mix", branch = "main")

  # The team backend (a separate git-checkout) — ``core`` routes here by name.
  let teamBackend = ws / "manifests-team"
  initGitRepo(gitBin, teamBackend)

  writeFile(ws / ".repro-workspace.toml",
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\n" &
    "url = \"https://example.invalid/manifests.git\"\n\n" &
    "[locking]\n" &
    "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
    "path = \"manifests-team\", repos = [\"core\"] }]\n")

  # ``core`` gains a LOCAL commit never pushed — its HEAD is unpublished.
  let unpubSha = commitLocalUnpublished(gitBin, ws / "core")
  (ws: ws, pubSha: pubSha, unpubSha: unpubSha)

suite "HL-7 — mixed public-clean + team-unpublished refuses":

  test "t_mixed_public_clean_team_unpublished_refuses":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl7-pub-team-unpub-", "")
      defer: removeDir(scratch)

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- team sibling IN SCOPE (pub depends on core) → REFUSE ------------
      block refuses:
        let sub = scratch / "in-scope"
        createDir(sub)
        let (ws, pubSha, unpubSha) = buildWorkspace(gitBin, sub,
          withDepends = true)
        check pubSha != unpubSha

        let refsFile = sub / "pushed-refs.txt"
        writeFile(refsFile, "refs/heads/main " & pubSha &
          " refs/heads/main 0000000000000000000000000000000000000000\n")
        let gate = run(reproBinary & " check --mode=pre-push" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / "pub") &
          " --pushed-refs=" & q(refsFile) & " --json")
        checkpoint("gate output: " & gate.output)
        check gate.code == 2

        let report = readReport(ws)
        check report["exitCode"].getInt() == 2
        # The public sibling is clean+published; the ONLY failure is core's
        # unpublished HEAD.
        var unpub: JsonNode = nil
        for f in report["failures"]:
          if f["property"].getStr() == "unpublished": unpub = f
        check unpub != nil
        check unpub["repo"].getStr() == "core"
        check unpub["remediation"].getStr().contains("git push")
        check unpub["remediation"].getStr().contains("core")

      # ---- FALSIFY: team sibling OUT of scope (no depends) → PASS ----------
      # With ``core`` removed from ``pub``'s dependency closure the publication
      # stage never checks it, so the unpublished team HEAD is not gated and the
      # push is allowed. Proves the refusal above is the in-scope publication
      # stage genuinely gating the team sibling.
      block passesWhenOutOfScope:
        let sub = scratch / "out-of-scope"
        createDir(sub)
        let (ws, pubSha, _) = buildWorkspace(gitBin, sub, withDepends = false)

        let refsFile = sub / "pushed-refs.txt"
        writeFile(refsFile, "refs/heads/main " & pubSha &
          " refs/heads/main 0000000000000000000000000000000000000000\n")
        let gate = run(reproBinary & " check --mode=pre-push" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / "pub") &
          " --pushed-refs=" & q(refsFile) & " --json")
        checkpoint("out-of-scope gate output: " & gate.output)
        check gate.code == 0

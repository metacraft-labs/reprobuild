## Unified-Locking-And-Hooks HL-7 (§8.4 corner: "private repo declared in no
## backend-supplying layer") — a repo whose visibility tier is PRIVATE (it is
## declared in a ``visibility = "private"`` manifest layer) but which NO
## configuration layer routes to a backend must be a LOUD lock-failure refusal
## at the pre-push gate — NEVER a silent pass. A private repo's participation
## cannot be recorded in the public committed lock, so with nowhere to put it the
## only correct answer is to refuse and name the remedy (§5 durability: every
## private repo needs an assigned durable backend).
##
## The refusal is driven through the REAL gate (``repro check --mode=pre-push``).
## The workspace declares SOME ``[locking]`` route (so the routed gate path is
## taken — ``hasExplicitRoutes`` is true) but that route only covers the PUBLIC
## repo; the private-layer repo is left unrouted, so ``resolveRepoBackends``
## raises ``StoreRoutingError`` inside the gate. The gate CATCHES it and surfaces
## a structured ``lock-failure`` ``CheckFailure`` (exit 2) whose evidence carries
## the ``StoreRoutingError`` message (naming the repo, its tier, and the
## ``[[locking.route]]`` / ``apply_if`` remedy).
##
## Fixture (built ``./build/bin/repro``, black-box): a two-layer composer
## workspace via ``.repo/workspace.toml`` with local_path manifest layers —
##   - a PUBLIC layer contributing ``pub`` (wvPublic);
##   - a PRIVATE layer (``visibility = "private"``) contributing ``secret``
##     (wvPersonal) — the private-tier repo with NO route.
## A ``.repro-workspace.toml`` ``[locking]`` route covers ONLY ``pub``.
##
## Assertions:
##   1. The gate REFUSES (exit 2) — never a silent exit 0.
##   2. A ``lock-failure`` ``CheckFailure`` is present; its evidence names the
##      unrouted private repo (``secret``), its tier (``private``), and the
##      ``[locking] route`` / ``apply_if`` remedy.
##
## Falsifiability: SWALLOWING the routing error (routing the private repo, so no
## error is raised) makes the gate reach a clean verdict — exit 0 with no
## ``lock-failure`` — so assertions (1)/(2) trip. Exercised below by ADDING a
## route for ``secret`` and re-running: the gate no longer refuses, proving the
## refusal above is the genuine unrouted-private gate, not an unrelated failure.
##
## Hermetic: every git repo + manifest layer lives in a fresh tempdir; env
## overrides silence the system/dotfiles/VCS-private config layers. Skip:
## ``git`` missing or ``./build/bin/repro`` absent.

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

proc publicProjectToml(pubUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"pub-origin\"\nfetch = \"" & pubUrl & "\"\n\n" &
  "includes = [\n  \"repos/pub.toml\",\n]\n"

proc privateProjectToml(secretUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"secret-origin\"\nfetch = \"" & secretUrl & "\"\n\n" &
  "includes = [\n  \"repos/secret.toml\",\n]\n"

proc repoFragment(name, remote: string; depends: seq[string] = @[]): string =
  result =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\n" &
    "revision = \"main\"\n"
  if depends.len > 0:
    var quoted: seq[string]
    for d in depends: quoted.add("\"" & d & "\"")
    result.add("depends = [" & quoted.join(", ") & "]\n")

proc lockFailure(report: JsonNode): JsonNode =
  for f in report["failures"]:
    if f["property"].getStr() == "lock-failure":
      return f
  return nil

suite "HL-7 — unrouted private repo refuses loudly":

  test "t_unrouted_private_repo_refuses_loudly":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl7-unrouted-private-", "")
      defer: removeDir(scratch)

      # ---- two origin repos --------------------------------------------
      let pubOrigin = scratch / "origin-pub.git"
      let secretOrigin = scratch / "origin-secret.git"
      let pubSha = seedGitOrigin(gitBin, pubOrigin, scratch / "seed-pub")
      discard seedGitOrigin(gitBin, secretOrigin, scratch / "seed-secret")

      # ---- two local_path manifest layers: public + private ------------
      let publicLayer = scratch / "manifest-public"
      createDir(publicLayer / "projects")
      createDir(publicLayer / "repos")
      writeFile(publicLayer / "projects" / "mix.toml",
        publicProjectToml("file://" & pubOrigin))
      # ``pub`` depends on the private ``secret`` — bringing it into the pushed
      # repo's dependency-closure scope so the routed CURRENCY read (not only the
      # lock refresh) also encounters the unrouted private repo and refuses.
      writeFile(publicLayer / "repos" / "pub.toml",
        repoFragment("pub", "pub-origin", depends = @["secret"]))

      let privateLayer = scratch / "manifest-private"
      createDir(privateLayer / "projects")
      createDir(privateLayer / "repos")
      writeFile(privateLayer / "projects" / "mix.toml",
        privateProjectToml("file://" & secretOrigin))
      writeFile(privateLayer / "repos" / "secret.toml",
        repoFragment("secret", "secret-origin"))

      # ---- the workspace: both repos cloned in ------------------------
      let ws = scratch / "workspace"
      createDir(ws)
      cloneInto(gitBin, pubOrigin, ws / "pub")
      cloneInto(gitBin, secretOrigin, ws / "secret")

      # ``.repo/workspace.toml`` — the composer-mode workspace with a PUBLIC
      # layer and a PRIVATE (``visibility = "private"``) layer. Repos from the
      # private layer inherit the ``wvPersonal`` tier.
      createDir(ws / ".repo")
      writeFile(ws / ".repo" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"mix\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "local_path = \"" & publicLayer & "\"\n" &
        "visibility = \"public\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\n" &
        "local_path = \"" & privateLayer & "\"\n" &
        "visibility = \"private\"\nbranch = \"main\"\n")

      # ---- the [locking] route covers ONLY the public repo -------------
      # A route EXISTS (so the routed gate path runs), but ``secret`` (private)
      # is declared in NO backend-supplying layer.
      let committedStoreDir = ws / "committed-store"
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"public\", backend = \"committed-file\", " &
        "path = \"committed-store\", repos = [\"pub\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & pubSha &
        " refs/heads/main 0000000000000000000000000000000000000000\n")

      # =================================================================
      # (1)+(2) unrouted private repo ⇒ LOUD lock-failure refusal (exit 2).
      # =================================================================
      block refusesLoudly:
        let gate = run(reproBinary & " check --mode=pre-push" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / "pub") &
          " --pushed-refs=" & q(refsFile) & " --json")
        checkpoint("gate output: " & gate.output)
        check gate.code == 2

        let report = parseFile(ws / ".repro" / "workspace" / "check-report.json")
        check report["exitCode"].getInt() == 2
        let lf = lockFailure(report)
        check lf != nil
        let evidence = lf["evidence"].getStr()
        # The routing error (surfaced verbatim in the failure evidence) names the
        # offending repo, its tier, and the ``[locking] route`` / ``apply_if``
        # remedy — the StoreRoutingError message the spec §8.4 requires.
        check evidence.contains("secret")
        check evidence.contains("personal") or evidence.contains("private")
        check evidence.contains("apply_if") or evidence.contains("[locking] route")

      # =================================================================
      # Falsify — SWALLOW the routing error by ROUTING the private repo. With
      # ``secret`` routed to a backend the gate no longer raises, so it reaches
      # a clean verdict (exit 0, no ``lock-failure``). Proves the refusal above
      # is the genuine unrouted-private gate.
      # =================================================================
      block routedNoLongerRefuses:
        discard committedStoreDir  # (public store dir referenced above)
        let personalDb = scratch / "personal-db"
        createDir(personalDb)
        writeFile(ws / ".repro-workspace.toml",
          "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
          "[manifest]\n" &
          "url = \"https://example.invalid/manifests.git\"\n\n" &
          "[locking]\n" &
          "route = [" &
          "{ visibility = \"public\", backend = \"committed-file\", " &
          "path = \"committed-store\", repos = [\"pub\"] }, " &
          "{ visibility = \"personal\", backend = \"committed-file\", " &
          "path = \"personal-store\", repos = [\"secret\"] }]\n")
        let gate = run(reproBinary & " check --mode=pre-push" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / "pub") &
          " --pushed-refs=" & q(refsFile) & " --json")
        checkpoint("routed gate output: " & gate.output)
        let report = parseFile(ws / ".repro" / "workspace" / "check-report.json")
        # With the private repo routed there is NO lock-failure refusal.
        check lockFailure(report) == nil

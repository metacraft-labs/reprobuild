## Unified-Locking-And-Hooks HL-2 (§6 Decision 1 — target read path) — the
## pre-push currency read routes PER-REPO to each repo's ASSIGNED backend: a
## team repo's locked SHA is read from the TEAM backend and a personal repo's
## from the PERSONAL backend, NOT from a single git-checkout manifest store.
##
## Fixture (built ``./build/bin/repro``, black-box) — a full ``.repo/manifests``
## workspace with a team repo (``core``) and a personal repo (``secret``), whose
## ``[locking]`` routes point team → a SEPARATE ``manifests-team`` git-checkout
## backend and personal → an external-cli DB stub. The gate's default manifest
## layer (``.repo/manifests``) therefore holds NO lock record at all.
##
## Asserts:
##   1. After ``repro workspace lock`` + a clean ``repro check --mode=pre-push``,
##      the gate reports ``already-current`` — it found each repo's record in ITS
##      backend (team in ``manifests-team``, personal in the DB), NOT in the
##      empty ``.repo/manifests``.
##   2. After TAMPERING the TEAM backend's newest record for ``core`` to a bogus
##      SHA (committed into ``manifests-team``), the clean gate is NO LONGER
##      ``already-current`` — the ONLY way to observe that mismatch is to read
##      ``core``'s locked SHA from the TEAM backend (``manifests-team``), which
##      the gate's default ``.repo/manifests`` store never sees.
##   3. The personal repo's record is read from the DB (present there, absent
##      from every git manifest).
##
## Falsifiability: a single ``newGitCheckoutLockStore`` over ``.repo/manifests``
## finds NO record for either repo (they live in ``manifests-team`` / the DB), so
## (1) would NOT be ``already-current`` — the gate would treat the clean, locked
## workspace as needing a fresh lock. Confirmed by pointing the currency read at
## the single manifest store: (1) flips away from ``already-current``.
##
## Hermetic: fresh tempdir; env silences the other config layers. Skip: ``git``
## missing or ``./build/bin/repro`` absent.

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

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"HL-2 Tester\"")
  writeFile(path / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(path) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(path) & " commit -m seed")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
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
    " config user.name \"HL-2 Tester\"")

proc writeStubCli(path: string) =
  writeFile(path, """#!/usr/bin/env bash
set -euo pipefail
db="${DB_DIR:?DB_DIR unset}"
op="$1"; key="$2"
safe=$(printf '%s' "$key" | tr '/' '_')
if [ "$op" = "put" ]; then
  json=$(cat)
  val=$(printf '%s' "$json" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
  printf '%s' "$val" > "$db/$safe"
  exit 0
elif [ "$op" = "get" ]; then
  if [ -f "$db/$safe" ]; then
    val=$(cat "$db/$safe")
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":true,"value":"%s"}' "$val"
  else
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":false}'
  fi
  exit 0
fi
echo "unknown op: $op" >&2
exit 1
""")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc projectToml(coreUrl, secretUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"secret-origin\"\nfetch = \"" & secretUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/secret.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc readReport(ws: string): JsonNode =
  parseFile(ws / ".repro" / "workspace" / "check-report.json")

suite "HL-2 — pre-push currency read routes per backend":

  test "t_pre_push_currency_read_routes_per_backend":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl2-currency-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let secretOrigin = scratch / "origin-secret.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let secretSha = seedGitOrigin(gitBin, secretOrigin, scratch / "seed-secret")

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & secretOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "secret.toml",
        repoFragment("secret", "secret-origin"))

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, secretOrigin, ws / "secret")
      writeWorkspaceBranch(ws, project = "mix", branch = "main")

      # ---- the SEPARATE team backend + personal DB ---------------------
      let teamManifest = ws / "manifests-team"
      initGitRepo(gitBin, teamManifest)
      let db = scratch / "personal-db"
      createDir(db)
      let stub = scratch / "personal-store.sh"
      writeStubCli(stub)
      putEnv("DB_DIR", db)
      defer: delEnv("DB_DIR")

      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [" &
        "{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \"manifests-team\", repos = [\"core\"] }, " &
        "{ visibility = \"personal\", backend = \"external-cli\", " &
        "program = \"" & stub & "\", repos = [\"secret\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- lock: records land in manifests-team + the DB ---------------
      let lockRes = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      # (3) team record in the SEPARATE team manifest, personal record in the DB,
      # and NOTHING in the gate's default .repo/manifests (proving the routing).
      check fileExists(teamManifest / "locks" / "mix" / "core" /
        (coreSha & ".toml"))
      check fileExists(db / ("lock_mix_secret_" & secretSha))
      check not dirExists(manifestsRoot / "locks")

      # ---- (1) clean gate reads each repo from its backend → current ---
      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & coreSha &
        " refs/heads/main 0000000000000000000000000000000000000000\n")
      let gate1 = run(reproBinary & " check --mode=pre-push" &
        " --workspace-root=" & q(ws) &
        " --current-repo=" & q(ws / "core") &
        " --pushed-refs=" & q(refsFile) & " --json")
      if gate1.code != 0:
        checkpoint("gate1 output: " & gate1.output)
      check gate1.code == 0
      let report1 = readReport(ws)
      check report1["exitCode"].getInt() == 0
      # Currency read routed per backend → the lock is already current (NOT a
      # fresh create). A single .repo/manifests store would have found nothing.
      check report1["lockUpdate"]["kind"].getStr() == "already-current"

      # ---- (2) tamper the TEAM backend record → stale via the team read -
      # Write a bogus SHA into the team backend's ``core`` record and commit it,
      # WITHOUT touching core's (published) HEAD. Only a currency read that
      # actually consults the TEAM backend can see this mismatch.
      let bogusSha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      let tamperDir = teamManifest / "locks" / "mix" / "core"
      createDir(tamperDir)
      writeFile(tamperDir / (bogusSha & ".toml"),
        "[[repo]]\npath = \"core\"\nrevision = \"" & bogusSha & "\"\n")
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) &
        " add -A")
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) &
        " commit -m tamper")

      let gate2 = run(reproBinary & " check --mode=pre-push" &
        " --workspace-root=" & q(ws) &
        " --current-repo=" & q(ws / "core") &
        " --pushed-refs=" & q(refsFile) & " --json")
      if gate2.code != 0:
        checkpoint("gate2 output: " & gate2.output)
      let report2 = readReport(ws)
      # The team-backend read saw the bogus newest SHA (≠ HEAD) → the gate is no
      # longer already-current. A single .repo/manifests store never sees the
      # tampered team-backend record, so this mismatch is ONLY observable by
      # routing the currency read to the TEAM backend.
      check report2["lockUpdate"]["kind"].getStr() != "already-current"

## Unified-Locking-And-Hooks HL-4 (§8.2 / §8.4 integrity-mismatch row) —
## PER-TIER INTEGRITY VERIFICATION on the manifest-present / MIXED pre-push path,
## driven through the REAL pre-push hook (``repro check --mode=pre-push``).
##
## Before HL-4, ``verifyLockedIntegrityAtCoordinates`` ran ONLY on the
## manifest-LESS committed-lock branch of the gate. A manifest-present / mixed
## workspace's currency check compared SHAs only — so a tampered team/personal
## backend record whose pinned revision no longer describes reachable content was
## SILENTLY REFRESHED instead of refused. HL-4 recomputes each in-scope locked
## entry's multihash AT its coordinates, per tier, on the manifest-present path
## too, and REFUSES on ``locked-integrity-mismatch`` naming the tier + backend.
##
## Fixture: a full ``.repo/manifests`` workspace (manifest-present) with a TEAM
## repo (``core``) routed to a SEPARATE ``manifests-team`` git-checkout backend
## and a PERSONAL repo (``secret``) routed to an external-cli DB stub. The
## gate's default ``.repo/manifests`` layer therefore holds NO lock record — each
## repo's record lives ONLY in its assigned backend.
##
## Cases (each drives the real gate binary black-box):
##
##   A. CLEAN mixed workspace (no tamper) — the gate PASSES (exit 0) and reports
##      NO ``locked-integrity-mismatch`` failure. This is the HL-4 no-false-
##      positive guarantee on a clean mixed workspace (HL-4 integration_test_2
##      "the clean-path no-regression must hold"): every recomputed integrity
##      equals the recorded one, so the per-tier integrity check is a no-op.
##
##   B. TAMPERED TEAM backend record — write a NEW newest record for ``core``
##      into the team git-checkout backend pinning a bogus 40-hex SHA whose commit
##      object is ABSENT from the ``core`` checkout, WITHOUT touching ``core``'s
##      published HEAD. The gate REFUSES (exit 2) with a ``locked-integrity-
##      mismatch`` failure naming ``tier=team`` + the ``git-checkout`` backend.
##
##   C. TAMPERED PERSONAL backend record — write a bogus 40-hex SHA into the
##      external-cli DB for ``secret``. The gate REFUSES (exit 2) with a
##      ``locked-integrity-mismatch`` failure naming ``tier=personal`` + the
##      ``external-cli`` backend. (Integrity mismatch is a TAMPER/corruption —
##      distinct from HL-3's unreachable-backend, which WARNS for personal; a
##      personal record whose content is corrupt still refuses, HL-4 deliverable
##      1: "the gate REFUSES on locked-integrity-mismatch … for the PERSONAL
##      backend record".)
##
## Falsifiability (documented; reproduced by the review): revert the manifest-
## present path to the SHA-only comparison (delete the HL-4 per-tier integrity
## block) and case B / case C stop refusing — the tampered team/personal record
## is silently REFRESHED and the gate does NOT emit ``locked-integrity-mismatch``
## (its ``exitCode`` is 0 and ``kind != already-current`` instead), so the
## ``check ... code == 2`` and failure-presence assertions trip.
##
## The no-false-positive assertion is carried HERE (case A) — the HL-2 test
## ``t_pre_push_currency_read_routes_per_backend`` is NOT rewritten (HL-4 lists it
## as integration_test_2 = "the clean-path no-regression must hold"); case A is
## the focused clean-mixed-workspace assertion HL-4 adds on top of it.
##
## Hermetic: fresh tempdir; only local ``git init`` / ``git init --bare`` repos;
## no network. The system/dotfiles/VCS-private config layers are silenced with
## env overrides. Skip: ``git`` missing or ``./build/bin/repro`` absent.

import std/[base64, json, os, osproc, strutils, tempfiles, unittest]

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
    " config user.name \"HL-4 Tester\"")
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
    " config user.name \"HL-4 Tester\"")

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

proc integrityMismatch(report: JsonNode): JsonNode =
  for f in report["failures"]:
    if f["property"].getStr() == "locked-integrity-mismatch":
      return f
  return nil

const bogusSha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

suite "HL-4 — integrity mismatch surfaces per tier on the manifest-present path":

  test "t_integrity_mismatch_surfaces_per_tier":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl4-integrity-", "")
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

      # ---- the SEPARATE team git-checkout backend + personal external DB ----
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

      # ---- lock: real records land in manifests-team + the DB ---------------
      let lockRes = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      # Sanity: team record in the team backend, personal record in the DB, and
      # NOTHING in the gate's default .repo/manifests (proving the routing).
      check fileExists(teamManifest / "locks" / "mix" / "core" /
        (coreSha & ".toml"))
      check fileExists(db / ("lock_mix_secret_" & secretSha))
      check not dirExists(manifestsRoot / "locks")

      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & coreSha &
        " refs/heads/main 0000000000000000000000000000000000000000\n")

      proc gate(current: string): tuple[code: int; output: string] =
        run(reproBinary & " check --mode=pre-push" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / current) &
          " --pushed-refs=" & q(refsFile) & " --json")

      # ==== CASE A — CLEAN mixed workspace: NO false integrity mismatch =======
      let gateClean = gate("core")
      if gateClean.code != 0:
        checkpoint("clean gate output: " & gateClean.output)
      check gateClean.code == 0
      let reportClean = readReport(ws)
      check reportClean["exitCode"].getInt() == 0
      # The per-tier integrity check ran and found every record intact — no
      # false ``locked-integrity-mismatch`` on a clean mixed workspace.
      check integrityMismatch(reportClean) == nil

      # ==== CASE B — TAMPER the TEAM backend record → REFUSE (tier=team) ======
      # Write a NEW newest record for ``core`` pinning a bogus SHA whose commit
      # object is absent from the ``core`` checkout, WITHOUT touching core's HEAD.
      let teamTamperDir = teamManifest / "locks" / "mix" / "core"
      createDir(teamTamperDir)
      writeFile(teamTamperDir / (bogusSha & ".toml"),
        "[[repo]]\npath = \"core\"\nrevision = \"" & bogusSha & "\"\n")
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) & " commit -m tamper")

      let gateTeam = gate("core")
      checkpoint("team-tamper gate output: " & gateTeam.output)
      check gateTeam.code == 2
      let reportTeam = readReport(ws)
      check reportTeam["exitCode"].getInt() == 2
      let teamFail = integrityMismatch(reportTeam)
      check teamFail != nil
      # tier + backend named in BOTH the remediation and the evidence.
      check teamFail["remediation"].getStr().contains("tier=team")
      check teamFail["remediation"].getStr().contains("git-checkout")
      check teamFail["evidence"].getStr().contains("tier=team")
      check teamFail["evidence"].getStr().contains("backend=git-checkout")
      check teamFail["repo"].getStr() == "core"

      # ---- restore the team backend to a clean record so case C isolates -----
      removeFile(teamTamperDir / (bogusSha & ".toml"))
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) & " commit -m untamper")
      # sanity: the team backend is clean again → no team integrity mismatch.
      let gateAfterTeam = gate("core")
      check gateAfterTeam.code == 0
      check integrityMismatch(readReport(ws)) == nil

      # ==== CASE C — TAMPER the PERSONAL backend record → REFUSE (personal) ===
      # The external-cli DB stores each key's base64 of the FRAMED store record
      # (``encodeRecord``). ``latestLock(mix, secret)`` reads the ``latest/...``
      # key → the DB file ``latest_mix_secret``. Decode it, swap the pinned
      # ``secret`` HEAD for a bogus SHA whose commit object is ABSENT from the
      # ``secret`` checkout, and re-encode — WITHOUT touching secret's HEAD. Only
      # a per-tier integrity check that reads the PERSONAL backend and recomputes
      # at the coordinates can catch this. Personal-tier integrity mismatch
      # REFUSES (a corruption/tamper, distinct from HL-3's unreachable backend
      # which WARNS for personal).
      let latestFile = db / "latest_mix_secret"
      check fileExists(latestFile)
      let framed = base64.decode(readFile(latestFile).strip())
      check framed.contains(secretSha)
      let tamperedFramed = framed.replace(secretSha, bogusSha)
      check tamperedFramed != framed
      writeFile(latestFile, base64.encode(tamperedFramed))

      let gatePersonal = gate("secret")
      checkpoint("personal-tamper gate output: " & gatePersonal.output)
      check gatePersonal.code == 2
      let reportPersonal = readReport(ws)
      check reportPersonal["exitCode"].getInt() == 2
      let personalFail = integrityMismatch(reportPersonal)
      check personalFail != nil
      check personalFail["remediation"].getStr().contains("tier=personal")
      check personalFail["remediation"].getStr().contains("external-cli")
      check personalFail["evidence"].getStr().contains("tier=personal")
      check personalFail["evidence"].getStr().contains("backend=external-cli")
      check personalFail["repo"].getStr() == "secret"

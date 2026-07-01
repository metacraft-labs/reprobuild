## Unified-Locking-And-Hooks HL-2 (§6 Decision 1) — a MIXED public/team/personal
## workspace, driven through the REAL pre-push hook (``repro check
## --mode=pre-push`` + its post-gate publish), records EACH repo's lock in ITS
## OWN durable backend and in NO OTHER. No repo's SHA ever crosses a tier.
##
## Fixture (built ``./build/bin/repro``, black-box) — a full ``.repo/manifests``
## workspace with three cloned repos, plus a ``.repro-workspace.toml`` whose
## ``[locking]`` table routes each repo (by NAME → tier-by-layer) to a distinct
## backend:
##   - ``pub``    → PUBLIC  → committed-file store (``committed-store/``);
##   - ``core``   → TEAM    → git-checkout at the existing ``.repo/manifests``;
##   - ``secret`` → PERSONAL→ external-cli DB stub.
##
## Asserts, after the pre-push gate + publish:
##   1. the TEAM repo's SHA lives in ``.repo/manifests/locks/...`` and NOT in the
##      committed-file store nor the personal DB;
##   2. the PERSONAL repo's SHA lives in the personal DB and NOT in the manifest
##      nor the committed-file store;
##   3. the PUBLIC repo's SHA lives in the committed-file store and NOT in the
##      manifest nor the personal DB;
##   4. the team git manifest lock TOMLs contain ONLY the team repo's path — no
##      ``secret``/``pub`` path leaked into the cross-tier manifest.
##
## Falsifiability: restoring the pre-HL-2 monolithic ``writeLockFile`` (every
## observed repo in the one ``.repo/manifests`` lock TOML) makes assertion (4)
## trip — the personal/public paths reappear in the manifest — and the personal
## DB / committed-file isolation checks in (1)-(3) fail. Confirmed by pointing
## ``manifestOwnedRepos`` back at ``lockRepos`` unconditionally: the ``secret``
## and ``pub`` paths leak into ``.repo/manifests`` and the test fails.
##
## Hermetic: every git repo + backend lives in a fresh tempdir; env overrides
## silence the system/dotfiles/VCS-private config layers. Skip: ``git`` missing
## or ``./build/bin/repro`` absent.

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

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"HL-2 Tester\"")
  writeFile(workPath / "README.md", "HL-2 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
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

proc projectToml(pubUrl, coreUrl, secretUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"pub-origin\"\nfetch = \"" & pubUrl & "\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"secret-origin\"\nfetch = \"" & secretUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/pub.toml\",\n" &
  "  \"repos/core.toml\",\n" &
  "  \"repos/secret.toml\",\n" &
  "]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

suite "HL-2 — mixed workspace: each record in its own backend only":

  test "t_mixed_workspace_each_record_in_its_own_backend_only":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl2-mixed-", "")
      defer: removeDir(scratch)

      # ---- three origin repos ------------------------------------------
      let pubOrigin = scratch / "origin-pub.git"
      let coreOrigin = scratch / "origin-core.git"
      let secretOrigin = scratch / "origin-secret.git"
      let pubSha = seedGitOrigin(gitBin, pubOrigin, scratch / "seed-pub")
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let secretSha = seedGitOrigin(gitBin, secretOrigin, scratch / "seed-secret")

      # ---- workspace + manifest ----------------------------------------
      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & pubOrigin, "file://" & coreOrigin,
          "file://" & secretOrigin))
      writeFile(manifestsRoot / "repos" / "pub.toml",
        repoFragment("pub", "pub-origin"))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "secret.toml",
        repoFragment("secret", "secret-origin"))

      cloneInto(gitBin, pubOrigin, ws / "pub")
      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, secretOrigin, ws / "secret")

      # Metadata branch so the single-project resolver knows the project.
      writeWorkspaceBranch(ws, project = "mix", branch = "main")

      # ---- the personal external-cli DB stub ---------------------------
      let db = scratch / "personal-db"
      createDir(db)
      let stub = scratch / "personal-store.sh"
      writeStubCli(stub)
      putEnv("DB_DIR", db)
      defer: delEnv("DB_DIR")

      # The committed-file (public) store lives under the workspace.
      let committedStoreDir = ws / "committed-store"

      # ---- the [locking] routes (named → tier-by-layer) ----------------
      # public → committed-file; team → git-checkout at the EXISTING
      # ``.repo/manifests``; personal → external-cli. Each route NAMES its repo.
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [" &
        "{ visibility = \"public\", backend = \"committed-file\", " &
        "path = \"committed-store\", repos = [\"pub\"] }, " &
        "{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repo/manifests\", repos = [\"core\"] }, " &
        "{ visibility = \"personal\", backend = \"external-cli\", " &
        "program = \"" & stub & "\", repos = [\"secret\"] }]\n")

      # Silence the other config layers.
      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- workspace lock: the write path partitions per backend -------
      let lockRes = run(reproBinary & " workspace lock --workspace-root=" &
        q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      # ---- drive the REAL pre-push gate (which also publishes) ---------
      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & coreSha &
        " refs/heads/main 0000000000000000000000000000000000000000\n")
      let gateRes = run(reproBinary & " check --mode=pre-push" &
        " --workspace-root=" & q(ws) &
        " --current-repo=" & q(ws / "core") &
        " --pushed-refs=" & q(refsFile) & " --json")
      if gateRes.code != 0:
        checkpoint("gate output: " & gateRes.output)
      check gateRes.code == 0

      # ---- (1) the TEAM repo's SHA is in the manifest, nowhere else ----
      let teamLock = manifestsRoot / "locks" / "mix" / "core" /
        (coreSha & ".toml")
      check fileExists(teamLock)

      # ---- (2) the PERSONAL repo's SHA is in the DB, nowhere else ------
      check fileExists(db / ("lock_mix_secret_" & secretSha))
      # Absent from the manifest.
      check not fileExists(manifestsRoot / "locks" / "mix" / "secret" /
        (secretSha & ".toml"))

      # ---- (3) the PUBLIC repo's SHA is in committed-file, nowhere else-
      check fileExists(committedStoreDir / "locks" / "mix" / "pub" /
        (pubSha & ".rec"))
      check not fileExists(manifestsRoot / "locks" / "mix" / "pub" /
        (pubSha & ".toml"))
      check not fileExists(db / ("lock_mix_pub_" & pubSha))
      check not fileExists(db / ("lock_mix_core_" & coreSha))

      # ---- (4) NO cross-tier SHA leaked into the team git manifest -----
      # Every ``locks/`` TOML in the manifest must mention ONLY the team repo's
      # path ("core") — never "secret" or "pub". The pre-HL-2 monolithic write
      # would have dropped all three paths into one TOML here.
      let manifestLocks = manifestsRoot / "locks" / "mix"
      for pathStr in walkDirRec(manifestLocks):
        if pathStr.endsWith(".toml"):
          let body = readFile(pathStr)
          check body.contains("core")
          if body.contains("\"secret\"") or body.contains("path = \"secret\""):
            checkpoint("CROSS-TIER LEAK: personal path in manifest " & pathStr &
              "\n" & body)
          check not body.contains("path = \"secret\"")
          check not body.contains("path = \"pub\"")

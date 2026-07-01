## Unified-Locking-And-Hooks HL-2 (§10 Migration) — a legacy ``.repo/manifests``
## workspace with NO team route must NEVER silently go public-only. Locking it
## emits a LOUD one-time migration guidance naming ``repro locking
## adopt-manifest``, and running that verb scaffolds a WORKING team route that
## makes the existing manifest the team backend.
##
## Fixture (built ``./build/bin/repro``, black-box) — a full ``.repo/manifests``
## workspace with two cloned repos and NO ``[locking]`` config at all (the
## legacy shape), env-silenced system/dotfiles/VCS-private layers.
##
## Asserts:
##   1. ``repro workspace lock`` on the un-routed legacy manifest prints the LOUD
##      guidance (mentions the missing team route AND ``adopt-manifest``) — it is
##      NOT silent.
##   2. ``repro locking adopt-manifest`` writes a team route into the VCS-private
##      config layer (never pushed) naming every repo → git-checkout at
##      ``.repo/manifests``.
##   3. After the scaffold, ``repro locking explain --json`` resolves every repo
##      to the TEAM tier with the ``git-checkout`` backend (NOT public-only) — a
##      WORKING team route.
##
## Falsifiability: dropping the migration guard makes (1) silent (no guidance in
## the lock output) — the assertion on the guidance text trips. Dropping the
## ``adopt-manifest`` scaffold makes (3) resolve every repo to the public
## committed-lock default instead of the team git-checkout — that assertion
## trips. Confirmed by no-op-ing ``maybeWarnLegacyManifestWithoutTeamRoute``: (1)
## goes silent and fails.
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

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"HL-2 Tester\"")
  writeFile(workPath / "README.md", "legacy fixture\n")
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

proc projectToml(aUrl, bUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"legacy\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
  "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
  "includes = [\n  \"repos/a.toml\",\n  \"repos/b.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

suite "HL-2 — legacy manifest without team route warns and scaffolds":

  test "t_legacy_manifest_without_team_route_warns_and_scaffolds":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("hl2-legacy-", "")
      defer: removeDir(scratch)

      let aOrigin = scratch / "origin-a.git"
      let bOrigin = scratch / "origin-b.git"
      discard seedGitOrigin(gitBin, aOrigin, scratch / "seed-a")
      discard seedGitOrigin(gitBin, bOrigin, scratch / "seed-b")

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "legacy.toml",
        projectToml("file://" & aOrigin, "file://" & bOrigin))
      writeFile(manifestsRoot / "repos" / "a.toml", repoFragment("a", "a-origin"))
      writeFile(manifestsRoot / "repos" / "b.toml", repoFragment("b", "b-origin"))

      cloneInto(gitBin, aOrigin, ws / "a")
      cloneInto(gitBin, bOrigin, ws / "b")
      writeWorkspaceBranch(ws, project = "legacy", branch = "main")

      # NO .repro-workspace.toml [locking] table — the legacy shape. Silence the
      # other config layers so there is definitively NO team route.
      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      let vcsPrivate = scratch / "vcs-private.toml"
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", vcsPrivate)
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) locking the un-routed legacy manifest WARNS loudly ------
      let lockRes = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      check lockRes.code == 0
      # The guidance is loud and names the remedy — NOT silent.
      check lockRes.output.contains("no team route") or
        lockRes.output.contains("NO team route")
      check lockRes.output.contains("adopt-manifest")

      # ---- (2) adopt-manifest scaffolds the team route -----------------
      let adoptRes = run(reproBinary & " locking adopt-manifest" &
        " --workspace-root=" & q(ws))
      if adoptRes.code != 0:
        checkpoint("adopt-manifest output: " & adoptRes.output)
      check adoptRes.code == 0
      # The route was written into the VCS-private config layer.
      check fileExists(vcsPrivate)
      let cfgBody = readFile(vcsPrivate)
      check cfgBody.contains("git-checkout")
      check cfgBody.contains(".repo/manifests")
      check cfgBody.contains("\"team\"")

      # ---- (3) explain now resolves every repo to the TEAM backend -----
      let explainRes = run(reproBinary & " locking explain --workspace-root=" &
        q(ws) & " --json 2>/dev/null")
      check explainRes.code == 0
      let parsed = parseJson(explainRes.output.strip())
      check parsed["repos"].len == 2
      for r in parsed["repos"]:
        check r["tier"].getStr() == "team"
        check r["backend"].getStr() == "git-checkout"
        check r["layer"].getStr() == "vcs-private"

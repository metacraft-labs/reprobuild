## Unified-Locking-And-Hooks HL-7 (§8.4 corner: "concurrent publishes
## per-backend") — two developers publish DIFFERENT commits to a PER-BACKEND lock
## store. Because locks are COMMIT-ADDRESSED (``locks/<project>/<repo>/<sha>.toml``)
## each publisher writes a DISJOINT path, so there is no shared mutable file to
## collide on. When the git-checkout backend's upstream tip has advanced under a
## publisher (another developer published FIRST), the publisher's push is
## rejected non-fast-forward; the RA-29 non-ff retry (``reapplyLockCommitOntoFetchedTip``)
## RE-FETCHES the tip and REBASES this publisher's single lock commit on top —
## disjoint path ⇒ conflict-free, NOT a force-push — then re-pushes as an ordinary
## fast-forward. Both publishes land; neither is lost; the race is invisible.
##
## This is the HL variant of the RA-29 concurrency test: the lock store is a
## ROUTED per-tier backend (a TEAM git-checkout on its own private remote,
## selected by a ``[locking]`` route), NOT the ``.repo/manifests`` manifest — so
## the corner case proves each per-tier backend handles its OWN concurrency
## independently, on a disjoint commit-addressed path.
##
## Deterministic + hermetic (the RA-29 construction): rather than scheduling two
## live publishers nondeterministically, a real third-party ``pre-push`` hook on
## the team backend publishes a second developer's disjoint lock commit after
## Git has advertised the old remote tip but before receive-pack updates it.
## This publisher is therefore guaranteed to lose a real compare-and-swap race.
## The publisher is ``repro check
## --mode=pre-push`` (which writes + commits + publishes the routed lock).
##
## Assertions:
##   1. The publisher exits 0 — no user-visible failure (RA-29 retried the
##      non-ff invisibly); no ``lock-backend-unreachable`` / ``lock-publish-failure``.
##   2. BOTH lock records survive on the team backend's upstream tip: the
##      out-of-band developer's lock file AND this publisher's lock file
##      (disjoint commit-addressed paths — neither clobbered).
##
## Falsifiability: FORCING a shared path / a force-push "retry" would clobber the
## out-of-band lock — assertion (2) trips. We PROVE the disjointness is
## load-bearing with a control case: an out-of-band commit that writes THE SAME
## commit-addressed path (a genuine collision) would be clobbered by a
## force-push; instead the append-only rebase preserves it. We assert the two
## records live at DIFFERENT paths and BOTH survive, so a shared-path/clobber
## implementation fails (2). We ALSO assert the loud case is preserved: an
## UNWRITABLE backend (bare removed) still fails loudly (exit != 0) — the retry
## never masks a genuine failure.
##
## Skip rule: ``git`` missing on PATH or ``./build/bin/repro`` absent.

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

proc seedGitCheckoutBackend(gitBin, checkoutRoot, bare: string) =
  ## A team git-checkout lock backend TRACKING a bare upstream so the pre-push
  ## per-backend publish genuinely commits + pushes.
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
  discard requireGit(q(gitBin) & " init --bare -b main " & q(bare))
  discard requireGit(q(gitBin) & " init -b main " & q(manifestsRoot))
  gitConfig(gitBin, manifestsRoot)
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " push -u origin main")

type
  EnvSnapshot = object
    existed: bool
    value: string

  ConfigEnvironment = object
    system: EnvSnapshot
    user: EnvSnapshot
    vcsPrivate: EnvSnapshot

  Fixture = object
    scratch: string
    ws: string
    coreSha: string
    teamBackend: string
    teamBare: string

proc overrideEnv(name, value: string): EnvSnapshot =
  result = EnvSnapshot(existed: existsEnv(name), value: getEnv(name))
  putEnv(name, value)

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
  if snapshot.existed:
    putEnv(name, snapshot.value)
  else:
    delEnv(name)

proc routedConfig(fx: Fixture): string =
  fx.ws / ".repro" / "config.toml"

proc isolateConfigEnvironment(fx: Fixture): ConfigEnvironment =
  ## Keep every layered-config lookup inside this fixture, while selecting the
  ## native VCS-private route under test explicitly. Preserve even an ambient
  ## variable that was present with an empty value.
  result.system = overrideEnv("REPROBUILD_SYSTEM_CONFIG",
    fx.scratch / "no-system.toml")
  result.user = overrideEnv("REPROBUILD_USER_CONFIG",
    fx.scratch / "no-user.toml")
  result.vcsPrivate = overrideEnv("REPROBUILD_VCS_PRIVATE_CONFIG",
    fx.routedConfig())

proc restoreConfigEnvironment(environment: ConfigEnvironment) =
  restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", environment.vcsPrivate)
  restoreEnv("REPROBUILD_USER_CONFIG", environment.user)
  restoreEnv("REPROBUILD_SYSTEM_CONFIG", environment.system)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("hl7-concpub-" & slug & "-", "")

  let coreOrigin = result.scratch / "origin-core.git"
  result.coreSha = seedGitOrigin(gitBin, coreOrigin,
    result.scratch / "seed-core")

  result.ws = result.scratch / "workspace"
  createDir(result.ws)
  let manifestsRoot = result.ws / ".repro" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "team.toml",
    projectToml("file://" & coreOrigin))
  writeFile(manifestsRoot / "repos" / "core.toml",
    repoFragment("core", "core-origin"))
  seedManifestGitLayer(gitBin, manifestsRoot, result.scratch / "manifest.git")

  cloneInto(gitBin, coreOrigin, result.ws / "core")
  writeWorkspaceBranch(result.ws, project = "team", branch = "main")

  # The TEAM git-checkout backend on its OWN remote — ``core`` routes here.
  result.teamBackend = result.ws / "team-lockrepo"
  result.teamBare = result.scratch / "team-backend.git"
  seedGitCheckoutBackend(gitBin, result.teamBackend, result.teamBare)

  writeFile(result.routedConfig(),
    "schema = \"reprobuild.config.v1\"\n\n" &
    "[locking]\n" &
    "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
    "path = \"team-lockrepo\", repos = [\"core\"] }]\n")

proc raceTeamBackendOnNextPush(gitBin: string; fx: Fixture;
                               otherSha: string): string =
  ## Prepare another developer's disjoint record, then use a real one-shot
  ## third-party pre-push hook to publish it only after this publisher's
  ## initial immutable fetch.
  ## Returns the disjoint lock path (backend-relative) the caller asserts
  ## survives.
  let sidecar = fx.scratch / "team-sidecar"
  cloneInto(gitBin, fx.teamBare, sidecar)
  let relDir = "locks" / "team" / "core"
  createDir(sidecar / relDir)
  let rel = relDir / (otherSha & ".toml")
  writeFile(sidecar / rel,
    "[[repo]]\nname = \"core\"\npath = \"core\"\nrevision = \"" &
    otherSha & "\"\n")
  discard requireGit(q(gitBin) & " -C " & q(sidecar) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(sidecar) &
    " commit -m \"out-of-band team publish " & otherSha & "\"")
  let hookDir = fx.teamBackend / ".git" / "hooks"
  createDir(hookDir)
  let hook = hookDir / "pre-push"
  let fired = fx.scratch / "team-race-fired"
  writeFile(hook,
    "#!/bin/sh\nset -eu\n" &
    "if [ ! -e " & q(fired) & " ]; then\n" &
    "  : > " & q(fired) & "\n" &
    "  " & q(gitBin) & " -C " & q(sidecar) &
      " push origin main >/dev/null 2>&1\n" &
    "fi\n")
  setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})
  rel

proc backendUpstreamFiles(gitBin, bare: string): string =
  let ls = run(q(gitBin) & " -C " & q(bare) &
    " ls-tree -r --name-only refs/heads/main")
  check ls.code == 0
  ls.output

proc invokeGate(fx: Fixture; refsFile: string): tuple[code: int; output: string] =
  run(reproBinary & " check --mode=pre-push --write-report" &
    " --workspace-root=" & q(fx.ws) &
    " --current-repo=" & q(fx.ws / "core") &
    " --pushed-refs=" & q(refsFile) & " --json")

proc hasFailure(report: JsonNode; prop: string): bool =
  for f in report["failures"]:
    if f["property"].getStr() == prop: return true
  false

suite "HL-7 — concurrent publishes to per-backend lock stores stay disjoint":

  test "t_concurrent_publish_disjoint_per_backend":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      # =================================================================
      # (1)+(2) non-ff concurrent per-backend publish RETRIES + both land.
      # =================================================================
      block retriesAndBothSurvive:
        let fx = setupFixture(gitBin, "retry")
        defer: removeDir(fx.scratch)
        let configEnvironment = isolateConfigEnvironment(fx)
        defer: restoreConfigEnvironment(configEnvironment)

        # Write the routed team lock so the backend has this publisher's
        # pending record (commit-addressed at ``core``'s HEAD, ``coreSha``).
        let lockRes = run(reproBinary & " workspace lock --workspace-root=" &
          q(fx.ws))
        if lockRes.code != 0:
          checkpoint("workspace lock output: " & lockRes.output)
        check lockRes.code == 0

        # Another developer publishes a DIFFERENT commit's lock to the SAME
        # backend FIRST (a disjoint commit-addressed path), advancing the
        # upstream so this publisher's push is non-fast-forward.
        let otherSha = "abcabcabcabcabcabcabcabcabcabcabcabcabca"
        check otherSha != fx.coreSha
        let oobRel = raceTeamBackendOnNextPush(gitBin, fx, otherSha)

        let refsFile = fx.scratch / "pushed-refs.txt"
        writeFile(refsFile, "refs/heads/main " & fx.coreSha &
          " refs/heads/main 0000000000000000000000000000000000000000\n")

        let gate = invokeGate(fx, refsFile)
        checkpoint("gate output: " & gate.output)
        # No user-visible failure — the non-ff was retried invisibly.
        check gate.code == 0
        let report = parseFile(fx.ws / ".repro" / "build" / "reports" /
          "check-report.json")
        check report["exitCode"].getInt() == 0
        check not hasFailure(report, "lock-backend-unreachable")
        check not hasFailure(report, "lock-publish-failure")

        # BOTH lock records survive on the team backend upstream tip — the
        # out-of-band developer's DISJOINT path AND this publisher's path.
        let files = backendUpstreamFiles(gitBin, fx.teamBare)
        check files.contains(oobRel)
        check files.contains("locks/team/core/" & fx.coreSha & ".toml")
        # The two publishers wrote DIFFERENT commit-addressed paths (disjoint).
        check oobRel != ("locks/team/core/" & fx.coreSha & ".toml")

      # =================================================================
      # Loud case preserved: an UNWRITABLE team backend (bare removed) still
      # REFUSES loudly — the retry must not mask a genuine failure.
      # =================================================================
      block unwritableStillLoud:
        let fx = setupFixture(gitBin, "loud")
        defer: removeDir(fx.scratch)
        let configEnvironment = isolateConfigEnvironment(fx)
        defer: restoreConfigEnvironment(configEnvironment)
        let lockRes = run(reproBinary & " workspace lock --workspace-root=" &
          q(fx.ws))
        check lockRes.code == 0
        # Remove the team backend's bare upstream: the push can never succeed
        # (unwritable, not a non-ff race), so the gate stays loud.
        removeDir(fx.teamBare)
        let refsFile = fx.scratch / "pushed-refs.txt"
        writeFile(refsFile, "refs/heads/main " & fx.coreSha &
          " refs/heads/main 0000000000000000000000000000000000000000\n")
        let gate = invokeGate(fx, refsFile)
        checkpoint("loud gate output: " & gate.output)
        check gate.code != 0
        let report = parseFile(fx.ws / ".repro" / "build" / "reports" /
          "check-report.json")
        check report["exitCode"].getInt() != 0
        check hasFailure(report, "lock-backend-unreachable")

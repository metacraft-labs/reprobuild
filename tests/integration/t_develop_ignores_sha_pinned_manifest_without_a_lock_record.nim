## CLI/develop.md §"The Develop Set Is The Workspace Lock Set" — the
## membership rule, stated exactly:
##
##   > A repo is *develop-manageable* in workspace `W` if some lock record
##   > readable from `W` names it and pins it to an exact revision.
##
## and §"Which record, for a commit-addressed backend":
##
##   > There is no branch-tip fallback: a backend that yields no record for the
##   > resolved key contributes nothing and says so.
##
## A LOCK RECORD is the only thing that makes a repo develop-manageable. The
## repo's own manifest fragment carries an ADVISORY `revision`, and the
## per-repo populator falls back to it when the backend holds no record. That
## fallback must never reach the develop set.
##
## Testing the fallback by SNIFFING the resulting string for SHA shape is not
## sufficient, and this test is the falsification of that approach. It rejects
## the common branch-name form (`main`, `dev`), so a fixture whose manifest says
## `revision = "main"` passes either way and proves nothing. But a manifest may
## legitimately pin a SHA directly — that is exactly what `repo manifest -r`
## style snapshots emit, and what this workspace's own lock snapshots contain —
## and then the advisory revision is byte-indistinguishable from a real pin.
## A shape check accepts it, and the repo silently enters the develop set at the
## MANIFEST's revision while its assigned backend holds no lock record at all:
## a checkout at a revision nobody locked, reported as a healthy success.
##
## Fixture: a manifest workspace with a REACHABLE team git-checkout backend that
## holds NO record for `team-lib`, and a `repos/team-lib.toml` fragment whose
## `revision` is a real 40-char SHA (the team repo's branch tip). `core` is
## public, pinned by the committed lock, so the run has legitimate work to do
## and a "narrowed but plausible" success is available.
##
## Asserts:
##   1. `--all` exits 0 and clones `core` (the reachable, genuinely locked part);
##   2. `team-lib` is NOT checked out — no lock record, no membership;
##   3. the exclusion is NAMED, not silent, and says there is no branch-tip
##      fallback;
##   4. `--only=team-lib` is a loud exact-name error rather than a silent
##      selection of an unlocked repo.
##
## Falsifiability: against a composer that only shape-checks the resolved
## revision, (1) additionally prints `cloned team-lib @ <manifest sha>`, (2) and
## (3) fail, and (4) succeeds in checking the repo out. Verified against that
## build.
##
## Mocks: NONE. Real git repos on the real filesystem, a real manifest
## checkout, a real (deliberately record-less) git-checkout lock backend, and
## the real ``repro`` binary.
##
## Hermetic: fresh tempdir; the other config layers are silenced via the
## ``REPROBUILD_*_CONFIG`` overrides. Skip: ``git`` missing or repro unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_workspace_manifests

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

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
    " config user.name \"Develop Set Tester\"")

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

proc repoFragment(name, remote, revision: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"" & revision & "\"\n"

proc committedLock(url, sha: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"advisory-manifest-fixture\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"core\", path = \"core\", coord_kind = \"vcs\", url = \"" &
    url & "\", ref = \"main\", revision = \"" & sha &
    "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", groups = \"\" }]\n"

suite "an advisory SHA-pinned manifest is not a lock record":

  test "t_develop_ignores_sha_pinned_manifest_without_a_lock_record":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds1-advisory-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")
      check coreSha.len == 40
      check teamSha.len == 40

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & teamOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin", "main"))
      # The load-bearing line: the fragment's ADVISORY revision is a real,
      # resolvable 40-char SHA — the `repo manifest -r` snapshot shape.
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin", teamSha))

      # A REACHABLE team backend that simply holds no `locks/...` record.
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")
      check not dirExists(manifestsRoot / "locks")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, teamOrigin, ws / "team-lib")
      writeWorkspaceBranch(ws, project = "mix", branch = "main")
      writeFile(ws / "repro.lock",
        committedLock("file://" & coreOrigin, coreSha))
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"team-lib\"] }]\n")

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
      if res.code != 0:
        checkpoint("develop --all output: " & res.output)
      # (1) the genuinely locked part still completes.
      check res.code == 0
      check ("cloned core @ " & coreSha) in res.output
      check dirExists(deps / "core")
      # (2) the advisory manifest revision never becomes a develop-set entry.
      check ("cloned team-lib @ " & teamSha) notin res.output
      check not dirExists(deps / "team-lib")
      # (3) and the omission is NAMED, with the reason.
      check "no exact locked revision recorded for 'team-lib" in res.output
      check "there is no branch-tip fallback" in res.output

      # (4) naming it explicitly is a loud exact-name error, not a silent
      # selection of a repo nothing locked.
      let only = run(repro & " develop --only=team-lib --into=" &
        q(scratch / "deps-only") & " --tool-provisioning=path", cwd = ws)
      if only.code != 2:
        checkpoint("--only output: " & only.output)
      check only.code == 2
      check "names no repo in this workspace's lock set" in only.output
      check not dirExists(scratch / "deps-only" / "team-lib")

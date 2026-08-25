## DS-3 (CLI/develop.md §"Unreachable backends never narrow the set silently")
## — the rule is about a BACKEND, not about one backend KIND.
##
##   > A backend whose medium exists but cannot be read — wrong permissions,
##   > missing credentials, an unreadable `locks/` subtree — must produce the
##   > same refusal as one that is absent.
##
## ``t_develop_refuses_unreadable_backend_before_membership_degrades`` proves
## this for the ``git-checkout`` backend. That was the only kind whose
## readability probe was ever hardened; the other directory-backed kinds still
## answered the probe with a bare ``dirExists``, which only requires the PARENT
## to be traversable. So a routed ``committed-file`` store at mode ``000``
## reported itself READABLE, every ``fileExists`` inside it answered "no such
## record" rather than raising, and the run exited 0 having quietly dropped a
## repo whose record was sitting right there.
##
## Reproduced against the build that shipped the git-checkout fix, on a store
## holding a real published record:
##
##   EXIT=1
##   repro develop --all: no exact locked revision recorded for 'team-lib
##     (tier=team backend=committed-file)' …
##   … team tier / committed-file backend at <store>:
##     readable, but it holds no lock record for this workspace
##
## Both of those statements are false, and the second is worse than silence:
## the diagnostic added to make an empty answer ATTRIBUTABLE asserted that an
## unreadable backend was readable and empty. Under the git-checkout route the
## identical fixture exits 2 with a remedy, which is what makes this a gap in
## the fix rather than a gap in the spec.
##
## Fixture: a public ``core`` pinned by the committed lock plus a team
## ``team-lib`` routed (configuration layer 5) to a ``committed-file`` lock
## store. ``core`` resolving is what makes the narrowing VISIBLE: the union is
## non-empty, so without the fix the command exits 0 and looks healthy.
##
## Asserts, with the store at mode 000:
##   1. exit 2 — the same refusal an ABSENT backend gets;
##   2. the refusal names the tier, the backend KIND, the location, the
##      underlying diagnostic and one copy-pasteable remedy;
##   3. the repo the route declared is NAMED, not silently dropped;
##   4. NOTHING was placed — not even ``core``, which would have cloned fine;
##   5. with the bits restored the same workspace resolves both repos, so the
##      refusal is about readability and nothing else.
##
## Mocks: NONE. Real git repos, a real committed-file lock store holding a
## real published record, real filesystem permissions, the real ``repro``
## binary.
##
## Hermetic: fresh tempdir; layers 2/3 silenced, layer 5 supplied by the
## fixture. The permission bits are restored in a ``defer`` so the tempdir is
## always removable. Skip: ``git`` missing, repro unbuilt, or running as root
## (root reads a mode-000 directory regardless of its bits, so the fixture
## cannot express the condition under test — a skip is honest where a pass
## would be a lie).

import std/[os, osproc, strutils, tempfiles, unittest]

when defined(posix):
  from std/posix import Mode, chmod, geteuid

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

proc cannotModelUnreadableDirectory(): bool =
  when defined(posix):
    geteuid() == 0
  else:
    true

proc setDirectoryMode(path: string; mode: int): int =
  when defined(posix):
    int(chmod(path.cstring, Mode(mode)))
  else:
    -1

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
    " config user.name \"Any-Kind Backend Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", "seed " & extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
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
    " config user.name \"Any-Kind Backend Tester\"")

proc projectToml(coreUrl, teamUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"team-origin\"\nfetch = \"" & teamUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/team-lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc committedLock(url, sha: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds3-any-kind\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"core\", path = \"core\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }]\n"

suite "DS-3: an unreadable backend refuses whatever KIND it is":

  test "t_develop_refuses_unreadable_backend_of_any_kind":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary) or
        cannotModelUnreadableDirectory():
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds3-any-kind-", "")

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")

      let ws = scratch / "workspace"
      initGitRepo(gitBin, ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      # The routed TEAM medium — deliberately NOT the manifest checkout, so
      # membership resolution is unaffected and the only thing under test is
      # the backend's own readability probe.
      let storeDir = ws / ".repro" / "lockstore-team"
      defer:
        discard setDirectoryMode(storeDir, 0o755)
        removeDir(scratch)

      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & teamOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin"))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, teamOrigin, ws / "team-lib")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")
      writeFile(ws / "repro.lock",
        committedLock("file://" & coreOrigin, coreSha))
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")

      createDir(ws / ".git" / "repro")
      writeFile(ws / ".git" / "repro" / "config.toml",
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"committed-file\", " &
        "path = \".repro/lockstore-team\", repos = [\"team-lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      # Publish the team record while the store is still readable, so the ONLY
      # thing that changes below is readability — not the record's existence.
      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      check dirExists(storeDir)

      # ---- the store EXISTS, holds a record, and cannot be read. ---------
      check setDirectoryMode(storeDir, 0o000) == 0
      let deps = scratch / "deps"
      let r = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = ws)
      check setDirectoryMode(storeDir, 0o755) == 0
      if r.code != 2:
        checkpoint("unreadable committed-file output: " & r.output)

      # (1) the same refusal an ABSENT backend gets.
      check r.code == 2
      # (2) tier, kind, location, diagnostic, remedy.
      check "team" in r.output
      check "committed-file" in r.output
      check storeDir in r.output
      check "cannot be read" in r.output
      check "chmod" in r.output
      # The old, false claim must be gone.
      check "readable, but it holds no lock record" notin r.output
      # (3) the route's repo is named, not dropped.
      check "team-lib" in r.output
      # (4) a refusal that half-applies is not a refusal: `core` resolves
      # perfectly well from the committed lock and must NOT have been placed.
      check not dirExists(deps / "core")
      check not dirExists(deps / "team-lib")
      check not fileExists(ws / ".repro" / "develop-overrides.toml")

      # ---- (5) control: readable again, the same workspace resolves. -----
      let ok = run(repro & " develop --all --into=" & q(scratch / "deps-ok") &
        " --tool-provisioning=path", cwd = ws)
      if ok.code != 0:
        checkpoint("control output: " & ok.output)
      check ok.code == 0
      check dirExists(scratch / "deps-ok" / "core")
      check dirExists(scratch / "deps-ok" / "team-lib")
      check requireGit(q(gitBin) & " -C " &
        q(scratch / "deps-ok" / "team-lib") & " rev-parse HEAD").strip() ==
        teamSha

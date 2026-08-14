## DS-3 (CLI/develop.md §"Unreachable backends never narrow the set silently")
## — **"Unreadable" includes degrading to silence.**
##
##   > The rule binds the *observable outcome*, not one code path. A backend
##   > whose medium exists but cannot be read — wrong permissions, missing
##   > credentials, an unreadable `locks/` subtree — must produce the same
##   > refusal as one that is absent. In particular, an unreadable backend must
##   > never be allowed to degrade **membership resolution** first, such that
##   > its repos never become assignments and the policy above is bypassed
##   > entirely: that path exits 0 with the set narrowed and nothing said,
##   > which is precisely the outcome this section forbids.
##
## ``t_develop_refuses_unreachable_team_backend`` already covers the ABSENT
## backend. This covers the two EXISTING-BUT-UNREADABLE shapes, which are the
## ones that slipped through, and it covers them on the production
## configuration layer (layer 5, ``<git-common-dir>/repro/config.toml``):
##
##   A. the whole routed checkout is unreadable (mode 000). This is the severe
##      case and it used to be the SILENT one: the routed medium is also the
##      workspace's manifest layer, so membership resolution degraded FIRST,
##      `team-lib` never became a ``RepoBackendAssignment``, no ``LockStore``
##      was ever constructed for it, and the DS-3 policy never saw it. Result:
##      exit 0, the repo dropped, and NO notice of any kind;
##   B. only the ``locks/`` subtree is unreadable. Membership resolves fine
##      here, so a notice WAS emitted — but the run still exited 0, where a
##      team-tier backend that cannot be read requires exit 2. A notice on a
##      zero exit is not a refusal.
##
## Both must now behave exactly like an absent backend: exit 2, naming the
## tier, the backend kind, the location, the underlying diagnostic and one
## copy-pasteable remedy, with NOTHING mutated.
##
## Fixture: a workspace whose LAYER-5 config routes the team tier to the
## git-checkout backend at ``.repro/manifests`` — the same checkout that
## supplies membership, which is what makes case A's bypass possible and is
## exactly the real workspaces' shape.
##
## Falsifiability / pre-fix failure: against ``6b342175``, case A gives
##
##   EXIT=0, deps/ contains only `core`, and the ENTIRE output is
##   "repro develop --all: cloned core @ <sha> -> …"
##
## — no mention of `team-lib` or of the backend, anywhere. Case B gives
##
##   repro develop --all: no exact locked revision recorded for 'team-lib
##   (tier=team backend=git-checkout)' … EXIT=0
##
## Mutation check: reverting ``readabilityDiagnostic`` to the bare
## ``dirExists`` probe makes BOTH cases exit 0 again; keeping the probe but
## removing the route-level probe that runs BEFORE membership resolution makes
## case A alone exit 0 again (case B still refuses), which is precisely the
## "degrade membership first" bypass the spec passage names.
##
## Mocks: NONE. Real git repos, a real manifest checkout, real filesystem
## permissions, the real ``repro`` binary.
##
## Hermetic: fresh tempdir; layers 2/3 silenced, layer 5 supplied by the
## fixture. The permission bits are restored in a ``defer`` so the tempdir is
## always removable. Skip: ``git`` missing, repro unbuilt, or running as root
## (root bypasses the permission bits, so the fixture cannot express the
## condition under test — a skip is honest where a pass would be a lie).

import std/[os, osproc, posix, strutils, tempfiles, unittest]

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
    " config user.name \"Unreadable Backend Tester\"")

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
    " config user.name \"Unreadable Backend Tester\"")

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
  "inputs_digest = \"ds3-unreadable\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"core\", path = \"core\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }]\n"

suite "DS-3: an existing-but-UNREADABLE backend refuses like an absent one":

  test "t_develop_refuses_unreadable_backend_before_membership_degrades":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary) or geteuid() == 0:
      # root reads a mode-000 directory regardless of its bits, so the fixture
      # cannot express "unreadable" at all under root.
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds3-unreadable-", "")

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")

      let ws = scratch / "workspace"
      initGitRepo(gitBin, ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      let locksDir = manifestsRoot / "locks"
      # Restore the bits no matter how this test exits, or the tempdir cleanup
      # itself fails and the next run inherits an undeletable directory.
      defer:
        discard chmod(manifestsRoot.cstring, 0o755)
        discard chmod(locksDir.cstring, 0o755)
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
      createDir(ws / ".repro")
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

      # LAYER 5 — the production layer (Unified-Locking-And-Hooks.md §4.3).
      createDir(ws / ".git" / "repro")
      writeFile(ws / ".git" / "repro" / "config.toml",
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"team-lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      # Publish the team record while the backend is still readable, so the
      # ONLY thing that changes below is readability — not the record's
      # existence. Without this, "no record" would be a confounder.
      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      check fileExists(locksDir / "mix" / "team-lib" / (teamSha & ".toml"))

      # ---- Case A: the whole routed checkout is unreadable. --------------
      # It is ALSO the manifest layer, so membership resolution reads it too.
      check chmod(manifestsRoot.cstring, 0o000) == 0
      let depsA = scratch / "deps-a"
      let a = run(repro & " develop --all --into=" & q(depsA) &
        " --tool-provisioning=path", cwd = ws)
      check chmod(manifestsRoot.cstring, 0o755) == 0
      if a.code != 2:
        checkpoint("case A output: " & a.output)
      check a.code == 2
      check "team" in a.output
      check "git-checkout" in a.output
      check manifestsRoot in a.output
      check "cannot be read" in a.output
      # The repo the unreadable route declared is NAMED, not silently dropped.
      check "team-lib" in a.output
      # One copy-pasteable remedy, and it fits what is on disk: the checkout
      # EXISTS, so `git clone` would be nonsense — the remedy is to fix the
      # permissions.
      check "chmod" in a.output
      # A refusal that half-applies is not a refusal: `core` would have cloned
      # perfectly well, and must not have.
      check not dirExists(depsA / "core")
      check not dirExists(depsA / "team-lib")
      check not fileExists(ws / ".repro" / "develop-overrides.toml")

      # ---- Case B: only the `locks/` subtree is unreadable. --------------
      # Membership resolves fine here, so this case DID emit a notice before —
      # and still exited 0. A team-tier backend that cannot be read is exit 2.
      check chmod(locksDir.cstring, 0o000) == 0
      let depsB = scratch / "deps-b"
      let b = run(repro & " develop --all --into=" & q(depsB) &
        " --tool-provisioning=path", cwd = ws)
      check chmod(locksDir.cstring, 0o755) == 0
      if b.code != 2:
        checkpoint("case B output: " & b.output)
      check b.code == 2
      check "team" in b.output
      check "git-checkout" in b.output
      check locksDir in b.output
      check "cannot be read" in b.output
      check "chmod" in b.output
      check not dirExists(depsB / "core")
      check not dirExists(depsB / "team-lib")
      check not fileExists(ws / ".repro" / "develop-overrides.toml")

      # ---- Control: with the bits restored, the SAME workspace succeeds. --
      # This is what makes the two refusals attributable to readability and
      # nothing else.
      let depsOk = scratch / "deps-ok"
      let ok = run(repro & " develop --all --into=" & q(depsOk) &
        " --tool-provisioning=path", cwd = ws)
      if ok.code != 0:
        checkpoint("control output: " & ok.output)
      check ok.code == 0
      check ("cloned core @ " & coreSha) in ok.output
      check ("cloned team-lib @ " & teamSha) in ok.output

## DS-1 — the public tier's committed-lock backend is the **in-repo**
## `repro.lock` of every participating repo, not one file at the workspace root.
##
## CLI/develop.md §"The Develop Set Is The Workspace Lock Set" states the rule
## over lock FILES, plural, and over readability rather than location:
##
##   > Whenever Reprobuild looks at a project in a workspace, it can determine
##   > the set of projects that workspace's lock **files** manage. That set —
##   > the whole of it, across every lock backend — is what `repro develop`
##   > operates on.
##   >
##   > A repo is *develop-manageable* in workspace `W` if some lock record
##   > readable from `W` names it and pins it to an exact revision. Which
##   > **file** that record lives in is a storage detail, not a boundary the
##   > user should have to think about.
##
## Unified-Locking-And-Hooks.md §3, the *public* row, says where that medium
## lives and what one record holds: "in-repo committed `repro.lock`
## (committed-file / MO-1 sentinel) | the solved-graph pins for **the repo's**
## public dependencies + **the repo's own** public coordinates". MO-1
## (Workspace-Manifest-Optional.milestones.org) puts the file "**committed in
## the project repo**", and `committedLockPath` places it next to the project
## file. A multi-repo workspace ROOT is not a project dir, so
## `<workspaceRoot>/repro.lock` is a file the model has no place for — and
## `repro lock refresh` at such a root correctly refuses with "no solver inputs
## found", so it is not merely absent but unobtainable.
##
## The composer nevertheless read exactly that one path. In a workspace where
## every participating repo commits its own `repro.lock` — the shape the
## workspace CLAUDE.md describes ("Locking is **per repo**: each participating
## repo commits its own `repro.lock` … There is no workspace-wide lock file and
## no shared lock index") — the union therefore came out EMPTY, and since "An
## empty union … is the only lock-set failure" every consumer downstream failed
## with it: `repro develop` exits 1, and the pre-push gate's flake stage
## escalates the unresolvable develop set to `flake_lock_stale`
## (`flake-develop-set-unresolvable`), refusing every push with no repair
## available.
##
## Asserts:
##
##   1. a public-only, manifest-described workspace with NO root `repro.lock`
##      and one committed `repro.lock` per participating repo resolves its
##      develop set: `repro develop --list` exits 0 and lists both repos;
##   2. the listed revision is the one the repo's LOCK records, not the repo's
##      current `HEAD` — `liba`'s checkout is advanced one commit past its lock,
##      and the lock's revision is what appears (state `drifted`). This is what
##      makes the read a RECORD read; a fix that reported live `HEAD`s would
##      resolve just as non-empty and be worthless;
##   3. the run creates no `<workspaceRoot>/repro.lock` — the model forbids it,
##      and manufacturing one is not the repair;
##   4. NEGATIVE — with the per-repo locks removed, the union is EMPTY again:
##      exit 1, and the inventory names both the root path and the participating
##      repos it probed. The guard stays a guard;
##   5. NEGATIVE — an UNPARSEABLE in-repo lock contributes nothing (still exit
##      1). A reader that fell back to the checkout's `HEAD` on a bad record
##      would turn "this repo is locked" into "this repo exists", which is the
##      rubber stamp this test exists to forbid.
##
## Falsifiability / pre-fix behavior: against the single-root read, (1) fails
## with `the workspace lock set at <ws> is EMPTY: no lock backend readable from
## this workspace yielded a single lock record`.
##
## Mocks: NONE. Real git repos on the real filesystem, real committed locks, the
## real `repro` binary.
##
## Hermetic: fresh tempdir; configuration layers 2, 3 and 5 are silenced via the
## `REPROBUILD_*_CONFIG` overrides, so the workspace declares no `[locking]`
## route at all and the built-in public default is the only tier. Skip: `git`
## missing or `repro` unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check`: this helper runs outside any `test` body, where
  ## `unittest.check` cannot see the injected `testStatusIMPL` and would report
  ## `[OK]` after printing "Check failed".
  let res = runCmd(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  createDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Per Repo Lock Tester\"")
  writeFile(workPath / "seed.txt", "seed " & extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Per Repo Lock Tester\"")

proc selfPinnedLock(name, url, sha: string): string =
  ## The lock a repo commits about ITSELF: schema v2, one dep at path ``.``.
  ## Byte-for-byte the shape `repro lock refresh` writes in a single-project
  ## repo, and the shape every participating repo of the reporting workspace
  ## carries.
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"per-repo-lock-fixture\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"" & name & "\", path = \".\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha & "\", version = \"\"" &
  ", visibility = \"public\", participation = \"\", depends = \"\"" &
  ", tags = \"\" }]\n"

proc projectToml(libaUrl, libbUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"ws\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"liba-origin\"\nfetch = \"" & libaUrl & "\"\n\n" &
  "[[remote]]\nname = \"libb-origin\"\nfetch = \"" & libbUrl & "\"\n\n" &
  "includes = [\n  \"repos/liba.toml\",\n  \"repos/libb.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

suite "DS-1: the public tier reads each participating repo's own committed lock":

  test "t_develop_reads_each_participating_repos_committed_lock":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("ds1-per-repo-lock-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let libaOrigin = scratch / "origin-liba.git"
      let libbOrigin = scratch / "origin-libb.git"
      let libaSha = seedOrigin(gitBin, libaOrigin, scratch / "seed-liba")
      let libbSha = seedOrigin(gitBin, libbOrigin, scratch / "seed-libb")

      # A manifest-described, PUBLIC-ONLY workspace: `.repro/manifests` supplies
      # membership and nothing else (it is not a git checkout, so it is not a
      # record store either — §10, "the presence of `projects/`, `repos/` …
      # says nothing about where records should go").
      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "ws.toml",
        projectToml(fileUrl(libaOrigin), fileUrl(libbOrigin)))
      writeFile(manifestsRoot / "repos" / "liba.toml",
        repoFragment("liba", "liba-origin"))
      writeFile(manifestsRoot / "repos" / "libb.toml",
        repoFragment("libb", "libb-origin"))
      cloneInto(gitBin, libaOrigin, ws / "liba")
      cloneInto(gitBin, libbOrigin, ws / "libb")
      writeWorkspaceBranch(ws, project = "ws", branch = "main")

      # Each repo commits its OWN lock, pinning ITSELF. Nothing pins anything
      # at the workspace root.
      writeFile(ws / "liba" / "repro.lock",
        selfPinnedLock("liba", fileUrl(libaOrigin), libaSha))
      writeFile(ws / "libb" / "repro.lock",
        selfPinnedLock("libb", fileUrl(libbOrigin), libbSha))
      discard requireGit(q(gitBin) & " -C " & q(ws / "liba") &
        " add repro.lock")
      discard requireGit(q(gitBin) & " -C " & q(ws / "liba") &
        " commit -m lock")
      discard requireGit(q(gitBin) & " -C " & q(ws / "libb") &
        " add repro.lock")
      discard requireGit(q(gitBin) & " -C " & q(ws / "libb") &
        " commit -m lock")
      # …and `liba` then moves ON, so its lock's revision and its HEAD differ.
      # (2) below turns that gap into the assertion that the composer reads the
      # RECORD.
      writeFile(ws / "liba" / "work.txt", "later work\n")
      discard requireGit(q(gitBin) & " -C " & q(ws / "liba") & " add work.txt")
      discard requireGit(q(gitBin) & " -C " & q(ws / "liba") &
        " commit -m later")
      let libaHead = requireGit(q(gitBin) & " -C " & q(ws / "liba") &
        " rev-parse HEAD").strip()
      check libaHead != libaSha

      check not fileExists(ws / "repro.lock")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) the develop set resolves from the per-repo locks. ----------
      let listed = runCmd(q(reproBin) &
        " develop --list --tool-provisioning=path --workspace-root=" & q(ws))
      if listed.code != 0:
        checkpoint("develop --list output: " & listed.output)
      check listed.code == 0
      check "is EMPTY" notin listed.output
      check "liba" in listed.output
      check "libb" in listed.output
      # The medium that answered is NAMED as what it is.
      check "the in-repo repro.lock of each participating repo" in listed.output

      # ---- (2) the RECORD's revision, not the checkout's HEAD. ------------
      check libaSha in listed.output
      check libbSha in listed.output
      check libaHead notin listed.output

      # ---- (3) nothing manufactured a workspace-root lock. ----------------
      check not fileExists(ws / "repro.lock")

      # ---- (4) NEGATIVE — no readable record anywhere still FAILS. --------
      removeFile(ws / "liba" / "repro.lock")
      removeFile(ws / "libb" / "repro.lock")
      let empty = runCmd(q(reproBin) &
        " develop --list --tool-provisioning=path --workspace-root=" & q(ws))
      if empty.code == 0:
        checkpoint("develop --list output: " & empty.output)
      check empty.code == 1
      check "is EMPTY" in empty.output
      check "no committed lock" in empty.output
      # Both the root path the model would have used and the repos actually
      # probed are named, so an empty answer stays attributable.
      check (ws / "repro.lock") in empty.output
      check "participating repo checkout(s)" in empty.output

      # ---- (5) NEGATIVE — an unparseable in-repo lock pins nothing. -------
      # No fallback to the checkout's HEAD: a record that cannot be read is not
      # a repo that is locked.
      writeFile(ws / "liba" / "repro.lock", "this is not a lock document\n")
      let garbage = runCmd(q(reproBin) &
        " develop --list --tool-provisioning=path --workspace-root=" & q(ws))
      if garbage.code == 0:
        checkpoint("develop --list output: " & garbage.output)
      check garbage.code == 1
      check "is EMPTY" in garbage.output
      check libaHead notin garbage.output

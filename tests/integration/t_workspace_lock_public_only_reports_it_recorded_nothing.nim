## `repro workspace lock` in a PUBLIC-ONLY workspace must not report work it
## did not do.
##
## Unified-Locking-And-Hooks.md §8.4, row "Public-only workspace, no configured
## route and no record store":
##
##   > No store is synthesized: the record-store root is unset, no `locks/`
##   > record is written under `.repro/records` (nor under a legacy
##   > `.repro/manifests`), and the gate emits no "cannot publish lock"
##   > diagnostic. Publication is the repo's own push of its in-tree
##   > `repro.lock` (§8.2 public row, §10).
##
## …and §6 Decision 1's public row: the public partition is "recorded in the
## committed `repro.lock` (the in-repo committed-file medium; for the MO-1
## sentinel this is `repro lock refresh`, not a separate store write)".
##
## So writing NOTHING here is the specified behavior, and this test does not
## challenge it. What it pins is the REPORT. `renderLockTextLines` reached its
## "no manifest partition lock was written" arm and printed
##
##   workspace lock: recorded per-repo lock entries (trigger=<repo>@<sha>)
##
## unconditionally — including for this shape, where `recordRoutedParticipation`
## returns `@[]` by construction ("A no-op when the workspace declares no
## `[locking]` routes") and not one byte is written anywhere. Observed on a real
## workspace: exit 0, that sentence, and `find` afterwards showing no file
## created, modified or touched. An operation that announces work it did not do
## is a defect independently of whether doing nothing was correct: every reader —
## human or the gate's own log — takes "recorded" at face value.
##
## Asserts, on ONE fixture, both halves of the distinction:
##
##   1. PUBLIC-ONLY (no `[locking]` route, `.repro/manifests` present but not a
##      git checkout, so no manifest layer owns the trigger): exit 0, the
##      workspace tree is BYTE-IDENTICAL across a repeat run (path set +
##      contents, `.git` included), the false claim is absent, and the truthful
##      line names what publishes instead (`repro lock refresh`, in the repo);
##   2. ROUTED (the same workspace, now with a `[locking]` route to a
##      committed-file backend): the "recorded per-repo lock entries" sentence
##      is still printed, and the record it claims really is on disk.
##
## (2) is the mutation guard that keeps (1) honest: a "fix" that deleted the
## sentence, or made it conditional on something that is false everywhere, would
## satisfy (1) and fail (2).
##
## Falsifiability / pre-fix behavior: with the unconditional sentence restored,
## (1) fails on `"recorded per-repo lock entries" notin output`. With the
## sentence suppressed everywhere, (2) fails.
##
## Mocks: NONE. Real git repos on the real filesystem, the real `repro` binary,
## the real committed-file lock backend.
##
## Hermetic: fresh tempdir; configuration layers 2, 3 and 5 are silenced via the
## `REPROBUILD_*_CONFIG` overrides so only the fixture's own layer 4 speaks.
## Skip: `git` missing or `repro` unbuilt.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

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

proc treeSnapshot(root: string): seq[string] =
  ## Every file under ``root`` as "<relative path>\0<contents>", sorted.
  ##
  ## Contents, not mtimes: the claim under test is "nothing was recorded", and a
  ## record is content. A path list alone would miss a rewrite in place; mtimes
  ## alone are too coarse on filesystems with a one-second stamp.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile},
      relative = true):
    var body = ""
    try:
      body = readFile(root / path)
    except CatchableError:
      body = "<unreadable>"
    result.add(path.replace('\\', '/') & "\0" & body)
  result.sort()

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

proc projectToml(libAUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

suite "workspace lock — a public-only run reports that it recorded nothing":

  test "t_workspace_lock_public_only_reports_it_recorded_nothing":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-public-only-lock-report-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # A published, clean lib-a whose origin is a real bare repo.
      let origin = scratch / "origin-lib-a.git"
      let seed = scratch / "seed-lib-a"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seed))
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.name \"Public Only Tester\"")
      writeFile(seed / "README.md", "public-only fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
        q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")
      let libASha = requireGit(q(gitBin) & " -C " & q(seed) &
        " rev-parse HEAD").strip()

      # The workspace declares NO `[locking]` route and its `.repro/manifests`
      # is not a git checkout — the default public-only shape (§10, "A workspace
      # with neither a configured route nor a record store is public-only and
      # writes only `repro.lock`").
      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "lib-a.toml",
        projectToml(fileUrl(origin)))
      writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
        q(ws / "lib-a"))
      writeWorkspaceBranch(ws, project = "lib-a", branch = "main")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) PUBLIC-ONLY: nothing is written, and nothing is claimed. ----
      #
      # The FIRST run is not snapshotted: `maybeWarnLegacyManifestWithoutTeamRoute`
      # emits its one-time "`.repro/manifests` with no team route" advice and
      # drops `.repro/workspace/legacy-manifest-migration.warned` to throttle
      # itself. That marker is a once-per-workspace notification receipt, not a
      # lock record, and folding it into the comparison would make this test
      # assert the absence of a file that has every right to appear. The second
      # run's tree is therefore the honest baseline: by then every
      # once-per-workspace side effect has already happened, so anything that
      # changes is the lock operation's own doing.
      let warmUp = runCmd(q(reproBin) & " workspace lock --workspace-root=" &
        q(ws))
      if warmUp.code != 0:
        checkpoint("workspace lock (warm-up) output: " & warmUp.output)
      check warmUp.code == 0

      let before = treeSnapshot(ws)
      let res = runCmd(q(reproBin) & " workspace lock --workspace-root=" & q(ws))
      if res.code != 0:
        checkpoint("workspace lock output: " & res.output)
      check res.code == 0

      # The report must not survive its own evidence: the tree is untouched.
      let after = treeSnapshot(ws)
      if before != after:
        checkpoint("tree changed by a run that recorded nothing")
      check before == after
      check not dirExists(manifestsRoot / "locks")

      # THE DEFECT: this sentence was printed here, for a run that wrote
      # nothing into any backend, because no backend exists to write into.
      if "recorded per-repo lock entries" in res.output:
        checkpoint("workspace lock output: " & res.output)
      check "recorded per-repo lock entries" notin res.output

      # …and the truthful line names the medium that DOES publish a public
      # repo's lock (§6 Decision 1 public row / §8.4).
      check "recorded nothing" in res.output
      check "repro lock refresh" in res.output
      check "public-only" in res.output

      # ---- (2) ROUTED: the claim is still made where it is TRUE. ----------
      # Same workspace, now with a `[locking]` route to a committed-file
      # backend. There is still no git-checkout manifest layer, so no partition
      # document is written and the renderer takes the SAME arm — but this time
      # a per-repo record really is recorded, and saying so is correct.
      let store = ws / "committed-store"
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"public\", backend = \"committed-file\", " &
        "path = \"committed-store\", repos = [\"lib-a\"] }]\n")

      let routed = runCmd(q(reproBin) & " workspace lock --workspace-root=" &
        q(ws))
      if routed.code != 0:
        checkpoint("routed workspace lock output: " & routed.output)
      check routed.code == 0
      check "recorded per-repo lock entries" in routed.output
      check "recorded nothing" notin routed.output
      # The claim is backed by a record on disk.
      check fileExists(store / "locks" / "lib-a" / "lib-a" /
        (libASha & ".rec"))

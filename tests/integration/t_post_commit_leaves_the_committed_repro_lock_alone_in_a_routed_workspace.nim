## Unified-Locking-And-Hooks.md §8.1 (public row) and §13.1–§13.3 — the
## `post-commit` hook writes NOTHING to a public repo's committed `repro.lock`,
## and leaves its working tree clean, in a workspace that declares `[locking]`
## routes.
##
## ## Why this case exists
##
## reprobuild-pm issue `2026-11-16-post-commit-may-write-the-committed-repro-lock.md`
## read the HL-2 milestone record — `executeWorkspaceLock`, the post-commit
## path, "records each repo's participation through its ASSIGNED backend by
## `recordRoutedParticipation` (public → committed `repro.lock` / committed-file
## store, …)" — as saying that a commit in a ROUTED workspace makes post-commit
## write the public repo's committed `repro.lock`. If it did, every commit in
## such a repo would leave the tree dirty with a lock describing the commit
## BEFORE the one that carries it: exactly the self-reference §13.1 shows has no
## closing order, and the reason §13.3 makes `pre-commit` the only writer.
##
## The routed case is the one nothing else pins. Without an explicit route
## `recordRoutedParticipation` returns before resolving a backend at all; with
## one, a public repo nobody claims resolves to the built-in `committed-lock`
## backend, and that is the assignment whose handling is in question. The
## pre-push twin, `t_pre_push_verifies_the_committed_lock_and_never_rewrites_it`,
## runs in an unrouted workspace and a different hook.
##
## ## The fixture is built to provoke the write
##
##   * `repro-workspace.toml` declares a `[locking]` route (a visibility-keyed
##     personal route no repo matches), so `hasExplicitRoutes` holds and the
##     routed participation step really runs, resolving `lib-a` and `lib-b`
##     to the built-in `committed-lock` default;
##   * `lib-a` carries a committed `repro.lock` pinning SIBLING `lib-b`;
##   * `lib-b` then MOVES (a new commit), so a writer that refreshed the lock
##     at post-commit would have a different pin to write;
##   * a commit lands in `lib-a`, and the hook is dispatched exactly as the
##     installed hook body dispatches it (`repro hooks dispatch post-commit`).
##
## ## What is asserted
##
##   1. the hook exits 0 (it never blocks a commit);
##   2. it REACHED the lock writer, the writer succeeded, and it ran ROUTED:
##      the post-commit report's outcome is `no-manifest-record` (filed only
##      after `executeWorkspaceLock`, and with it `recordRoutedParticipation`,
##      returned) and the `lock-report.json` it writes beside it says
##      `routed = true`. A dirty-sibling refusal, a raised writer, or a route
##      nobody saw would leave (3)–(5) green for the wrong reason;
##   3. `repro.lock` is byte-identical to `HEAD:repro.lock`;
##   4. it was not written at all (mtime unchanged): identical bytes are still
##      a write;
##   5. `git status --porcelain` in `lib-a` is empty.
##
## ## Falsifiability (measured, not asserted)
##
## Mutation: in `recordRoutedParticipation`, after `resolveRepoBackends`, every
## assignment whose `store` is nil (the `committed-lock` backend) appends
## `# refreshed` to `<workspaceRoot>/<repoPath>/repro.lock` when that file
## exists. Result (reprobuild `agents` @ `bc3c6478b3`, Linux, Nim 2.3.1): RED
## on (3), (4) and (5), with (1) and (2) still green, so the test sees a
## post-commit write of the committed lock when one happens. Reverted: GREEN.
##
## ## Test-double policy
##
## NO mocks, doubles or fakes: real bare origins, real `git`, the real
## `build/bin/repro`. The committed lock is hand-written on purpose — it is the
## artifact whose survival is under test, so it must be the operator's bytes.
## Configuration layers outside the workspace are silenced through their
## documented env overrides so the host's own config cannot add or remove a
## route.
##
## Skip rule: `git` missing on PATH.

import std/[json, os, osproc, strutils, times, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_test_support/recipe_dependencies
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
mainline = "main"
"""

proc projectToml(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"lib-a\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

proc committedLockToml(libBUrl, libBRev: string): string =
  ## A well-formed solved-graph lock whose single dep is the SIBLING. The
  ## foreign `platform` and made-up digest make these bytes impossible for a
  ## regeneration to reproduce by accident.
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"amd64-windows\"\n" &
  "optimal = false\n" &
  "inputs_digest = \"fnv1a64:0000000000000001\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"lib-b\", path = \"lib-b\", coord_kind = \"vcs\", url = \"" &
  libBUrl & "\", revision = \"" & libBRev &
  "\", integrity = \"git-sha1:" & libBRev &
  "\", version = \"\", visibility = \"public\", participation = \"\", " &
  "depends = \"\", tags = \"\" }]\n"

proc seedPublishedRepo(gitBin, origin, seed, marker: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  discard requireGit(q(gitBin) & " init -b main " & q(seed))
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.name \"Post-commit Lock Tester\"")
  writeFile(seed / "README.md", marker & "\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
    q(origin))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(seed) & " rev-parse HEAD").strip()

proc configureIdentity(gitBin, repo: string) =
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.name \"Post-commit Lock Tester\"")

suite "post-commit — a routed workspace leaves the committed `repro.lock` alone":

  test "t_post_commit_leaves_the_committed_repro_lock_alone_in_a_routed_workspace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real bare origins, real " &
        "clones and real commits for the hook to observe")
    else:
      let scratch = createTempDir("repro-post-commit-lock-untouched-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      # A host `REPRO_WORKSPACE_CONFIG` would replace the fixture's
      # `repro-workspace.toml`, and with it the route under test.
      let hadWorkspaceConfig = existsEnv("REPRO_WORKSPACE_CONFIG")
      let priorWorkspaceConfig = getEnv("REPRO_WORKSPACE_CONFIG")
      delEnv("REPRO_WORKSPACE_CONFIG")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")
        if hadWorkspaceConfig:
          putEnv("REPRO_WORKSPACE_CONFIG", priorWorkspaceConfig)

      let originB = scratch / "origin-lib-b.git"
      discard seedPublishedRepo(gitBin, originB, scratch / "seed-lib-b",
        "sibling fixture")
      let originA = scratch / "origin-lib-a.git"
      discard seedPublishedRepo(gitBin, originA, scratch / "seed-lib-a",
        "committing fixture")

      let ws = scratch / "workspace"
      createDir(ws / "projects")
      createDir(ws / "repos")
      writeFile(ws / "projects" / "lib-a.toml",
        projectToml(fileUrl(originA), fileUrl(originB)))
      writeFile(ws / "repos" / "lib-a.toml", libAFragmentToml)
      writeFile(ws / "repos" / "lib-b.toml", libBFragmentToml)
      writeWorkspaceBranch(ws, project = "lib-a", branch = "main")

      # An explicit route, so the routed participation step resolves every
      # repo's backend. No repo is personal, so both public repos fall to the
      # built-in `committed-lock` default: the assignment under test.
      writeFile(ws / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"personal\", " &
        "backend = \"committed-file\", path = \"personal-store\" }]\n")

      let libA = ws / "lib-a"
      let libB = ws / "lib-b"
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(originA)) & " " &
        q(libA))
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(originB)) & " " &
        q(libB))
      configureIdentity(gitBin, libA)
      configureIdentity(gitBin, libB)

      writeDependencyRecipe(libB, [])
      discard requireGit(q(gitBin) & " -C " & q(libB) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " commit -m recipe")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " push origin main")
      let libBPinned = requireGit(q(gitBin) & " -C " & q(libB) &
        " rev-parse HEAD").strip()
      writeDependencyRecipe(libA, ["lib-b"], library = false)

      writeFile(libA / "repro.lock",
        committedLockToml(fileUrl(originB), libBPinned))
      discard requireGit(q(gitBin) & " -C " & q(libA) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(libA) & " commit -m lock")
      discard requireGit(q(gitBin) & " -C " & q(libA) & " push origin main")

      # The sibling MOVES after the lock was committed, so the lock is now
      # behind `lib-b`'s HEAD — a refresh would have something to write.
      writeFile(libB / "README.md", "sibling moved\n")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " commit -am moved")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " push origin main")
      let libBMoved = requireGit(q(gitBin) & " -C " & q(libB) &
        " rev-parse HEAD").strip()
      check libBMoved != libBPinned

      # The commit that fires the hook.
      writeFile(libA / "README.md", "committing fixture, edited\n")
      discard requireGit(q(gitBin) & " -C " & q(libA) & " commit -am edit")

      let lockPath = libA / "repro.lock"
      let headLock = requireGit(q(gitBin) & " -C " & q(libA) &
        " show HEAD:repro.lock")
      check readFile(lockPath) == headLock
      let beforeMtime = getLastModificationTime(lockPath)
      check requireGit(q(gitBin) & " -C " & q(libA) &
        " status --porcelain").strip() == ""

      let res = runCmd(q(reproBin) & " hooks dispatch post-commit --repo-root=" &
        q(libA) & " --")
      checkpoint("post-commit output:\n" & res.output)

      # (1) never blocks the commit.
      check res.code == 0

      # (2) the lock writer ran to completion, including the routed step.
      let reportPath = ws / ".repro" / "build" / "reports" /
        "post-commit-report.json"
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        checkpoint("post-commit report:\n" & pretty(report))
        check report{"outcome"}.getStr() == "no-manifest-record"
      # ...and it ran ROUTED. `no-manifest-record` alone is also what an
      # unrouted public-only workspace reports, so without this a fixture whose
      # route stopped being seen would silently become the unrouted case.
      let lockReportPath = ws / ".repro" / "build" / "reports" /
        "lock-report.json"
      check fileExists(lockReportPath)
      if fileExists(lockReportPath):
        let lockReport = parseFile(lockReportPath)
        checkpoint("lock report:\n" & pretty(lockReport))
        check lockReport{"routed"}.getBool(false)

      # (3) byte-identical to the committed lock.
      check readFile(lockPath) == headLock
      # (4) not written at all.
      check getLastModificationTime(lockPath) == beforeMtime
      # (5) the tree the commit just left clean is still clean.
      check requireGit(q(gitBin) & " -C " & q(libA) &
        " status --porcelain").strip() == ""

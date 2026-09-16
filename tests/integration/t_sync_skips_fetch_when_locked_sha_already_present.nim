## RA-14 — optimized fetch: skip the network fetch when the locked SHA
## is already present.
##
## ``repro workspace sync`` must NOT issue a ``git fetch`` for a checkout
## that already has the locked revision reachable (Google ``repo``'s
## ``--optimized-fetch`` equivalent). This is the single biggest
## re-``sync`` win for an already-current workspace.
##
## The test is FALSIFIABLE and HERMETIC:
##
##   * Two repos are built from local ``git init --bare`` upstreams in a
##     tempdir (no network) and cloned into the workspace at their tips.
##   * A per-repo lock file records each repo's locked SHA:
##       - ``present`` is locked at the SHA the workspace already has →
##         the fetch MUST be skipped.
##       - ``branchpinned`` is at the SHA its lock records, exactly like
##         ``present`` -- but its manifest pins a BRANCH, not a commit, so
##         its fetch MUST run anyway. See "WHY THE THIRD REPO EXISTS".
##       - ``behind`` is locked at a NEW upstream SHA the workspace does
##         NOT yet have (upstream advanced after the clone) → the fetch
##         MUST run.
##   * Each repo's upstream is advanced AFTER the workspace clone is taken,
##     so "was this repo fetched?" is answerable from the checkout itself:
##     a fetch moves ``refs/remotes/origin/main``, and a skipped fetch
##     leaves that ref exactly where the clone put it.
##
## HOW THIS USED TO BE OBSERVED, AND WHY IT IS NOT ANY MORE
##
## The observation used to be a ``git`` wrapper shim placed first on PATH,
## recording the argv of every ``fetch``. Two things were wrong with it, and
## the second is the serious one.
##
## It assembled PATH with a literal ``":"``, so on Windows the shim was
## never on PATH. And a shim that is not on PATH records nothing -- which
## made ``check not presentFetched`` true, because no fetch of anything had
## been observed. The assertion carrying the contract was answering from an
## empty set. (Two positive assertions beside it failed, so the file was red
## on Windows rather than falsely green -- but a green line that measures
## nothing is one relaxed neighbour away from a silent pass.) Even with the
## separator corrected the shim cannot work there: it is an extensionless
## bash script, and ``CreateProcess`` will not execute one.
##
## So the observation is the REMOTE-TRACKING REF instead. No shim, no PATH
## manipulation, no interpreter; identical on every platform; and it cannot
## be satisfied by an empty measurement, because every assertion names a
## specific SHA that must or must not have moved.
##
## WHY THE THIRD REPO EXISTS
##
## The skip's justification is "the answer cannot have changed". That holds
## for a SHA pin and for nothing else. For a BRANCH pin the question sync
## asks is "where is the branch NOW", which the local object store cannot
## answer -- and the predicate used to accept the LOCK STORE's recorded SHA
## as its target, so a branch-pinned repo whose recorded SHA was still
## reachable locally skipped its fetch. A force-push, whose whole signature
## is the remote tip moving off the recorded SHA, was therefore never
## observed: the optimization suppressed the only probe that could have seen
## it, and the planner then read stale refs as current. ``present`` and
## ``branchpinned`` sit in identical local states and differ only in the
## shape of their pin, so the pair pins the rule down from both sides.
##
## Skip rule: only when ``git`` is missing from PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA14 Tester\"")
  writeFile(workPath / "README.md", "RA-14 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedSecondCommit(gitBin, workPath: string; branch = "main"): string =
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"second commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA14 Tester\"")

# ---- manifest + lock TOML --------------------------------------------------

proc projectTomlWithRepos(remotes: seq[(string, string)]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for (name, url) in remotes:
    result.add("[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url & "\"\n\n")
  result.add("includes = [\n")
  for (name, _) in remotes:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

proc repoFragmentToml(name, remoteName: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remoteName & "\"\n" &
  "revision = \"main\"\n"

proc repoFragmentTomlPinned(name, remoteName, sha: string): string =
  ## Fragment pinned to a concrete COMMIT rather than a branch name --
  ## the shape every vendored reference tree in a real workspace uses,
  ## and the only shape for which skipping the network fetch is sound.
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remoteName & "\"\n" &
  "revision = \"" & sha & "\"\n"

proc lockToml(project: string; repos: seq[(string, string)]): string =
  ## ``repos`` is (path, sha). A strict-reader-valid single lock pinning
  ## every repo to its locked SHA.
  result =
    "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
    "[lock]\n" &
    "project = \"" & project & "\"\n" &
    "created_at = \"2026-06-21T10:00:00Z\"\n\n"
  for (path, sha) in repos:
    result.add("[[repo]]\n")
    result.add("name = \"" & path & "\"\n")
    result.add("path = \"" & path & "\"\n")
    result.add("remote = \"origin\"\n")
    result.add("revision = \"" & sha & "\"\n\n")

suite "RA-14 — sync skips fetch when locked SHA already present":

  test "t_sync_skips_fetch_when_locked_sha_already_present":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra14-optfetch-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let manifestsRoot = workspaceRoot
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")

      # ``present``: SHA-pinned at the commit it already has. Its upstream
      # is advanced AFTER the clone, so a fetch — if one ran — would move
      # its ``origin/main``. That ref not moving is how the skip is
      # observed.
      let presentOrigin = scratch / "origin-present.git"
      let presentSeed = scratch / "seed-present"
      let presentSha = seedGitOrigin(gitBin, presentOrigin, presentSeed)
      cloneInto(gitBin, presentOrigin, workspaceRoot / "present")
      let presentUpstreamSha = seedSecondCommit(gitBin, presentSeed)

      let behindOrigin = scratch / "origin-behind.git"
      let behindSeed = scratch / "seed-behind"
      discard seedGitOrigin(gitBin, behindOrigin, behindSeed)
      cloneInto(gitBin, behindOrigin, workspaceRoot / "behind")
      # Advance ``behind``'s upstream; the workspace clone does NOT yet have
      # this commit, so the lock pins a SHA the checkout cannot reach.
      let behindLockedSha = seedSecondCommit(gitBin, behindSeed)

      # ``branchpinned``: the SAME local state as ``present`` — sitting at
      # the commit its lock records, upstream advanced afterwards —
      # differing only in that the manifest pins the BRANCH ``main`` rather
      # than a commit.
      let branchOrigin = scratch / "origin-branchpinned.git"
      let branchSeed = scratch / "seed-branchpinned"
      let branchSha = seedGitOrigin(gitBin, branchOrigin, branchSeed)
      cloneInto(gitBin, branchOrigin, workspaceRoot / "branchpinned")
      let branchUpstreamSha = seedSecondCommit(gitBin, branchSeed)

      writeFile(manifestsRoot / "repos" / "present.toml",
        repoFragmentTomlPinned("present", "present", presentSha))
      writeFile(manifestsRoot / "repos" / "behind.toml",
        repoFragmentToml("behind", "behind"))
      writeFile(manifestsRoot / "repos" / "branchpinned.toml",
        repoFragmentToml("branchpinned", "branchpinned"))
      writeFile(manifestsRoot / "projects" / "myproject.toml",
        projectTomlWithRepos(@[
          ("present", fileUrl(presentOrigin)),
          ("behind", fileUrl(behindOrigin)),
          ("branchpinned", fileUrl(branchOrigin))]))

      # Lock: ``present`` at the SHA the workspace already has (→ skip),
      # ``behind`` at the advanced upstream SHA (→ must fetch).
      let lockDir = workspaceRoot / ".repro" / "manifests" / "locks" /
        "myproject" / "present"
      createDir(lockDir)
      # ``branchpinned``'s recorded SHA is one the checkout ALREADY has —
      # the exact state in which the old predicate skipped its fetch.
      writeFile(lockDir / (presentSha & ".toml"),
        lockToml("myproject", @[
          ("present", presentSha), ("behind", behindLockedSha),
          ("branchpinned", branchSha)]))

      proc remoteTip(repo: string): string =
        requireGit(q(gitBin) & " -C " & q(workspaceRoot / repo) &
          " rev-parse refs/remotes/origin/main").strip()

      # THE PREMISE, asserted rather than assumed: before the sync every
      # checkout's ``origin/main`` still names its clone-time commit, and
      # each upstream has genuinely moved past it. Without this the "did not
      # move" assertions below could hold because nothing ever could have
      # moved.
      check remoteTip("present") == presentSha
      check remoteTip("branchpinned") == branchSha
      check presentUpstreamSha != presentSha
      check branchUpstreamSha != branchSha

      let res = runShell(shellCommand(@[
        reproBin, "workspace", "sync", "myproject",
        "--workspace-root=" & workspaceRoot,
      ]))
      if res.code != 0:
        checkpoint("sync output: " & res.output)
      # Exit code may be 0 (all advanced/noop) — sync of ``behind`` is a
      # clean fast-forward; ``present`` is a noop.
      check res.code in {0, 2}

      # The optimized-fetch contract, observed on the refs a fetch writes.
      #
      # ``present`` — SHA-pinned at a commit it already has. Nothing a fetch
      # could return can change that answer, so no fetch runs and
      # ``origin/main`` stays at the clone-time commit even though the
      # upstream moved.
      check remoteTip("present") == presentSha
      check remoteTip("present") != presentUpstreamSha

      # ``branchpinned`` — the same local state, BRANCH pin. The question is
      # "where is the branch now", so the fetch must run and ``origin/main``
      # must advance. Under the old predicate this ref did not move, and a
      # force-push on this branch was invisible to the planner.
      check remoteTip("branchpinned") == branchUpstreamSha
      check remoteTip("branchpinned") != branchSha

      # ``behind`` — branch-pinned AND missing its locked SHA. Fetched under
      # both the old rule and the new one: the skip never drops a fetch the
      # workspace actually needs.
      check remoteTip("behind") == behindLockedSha

      # Determinism: ``behind`` advanced to its locked SHA (the fetch +
      # fast-forward ran), ``present`` stayed at its already-locked SHA.
      let behindHead = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "behind") & " rev-parse HEAD").strip()
      check behindHead == behindLockedSha
      let presentHead = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "present") & " rev-parse HEAD").strip()
      check presentHead == presentSha

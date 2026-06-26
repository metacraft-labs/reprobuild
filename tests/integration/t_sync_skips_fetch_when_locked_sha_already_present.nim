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
##       - ``behind`` is locked at a NEW upstream SHA the workspace does
##         NOT yet have (upstream advanced after the clone) → the fetch
##         MUST run.
##   * A ``git`` wrapper shim first on PATH records the full argv of every
##     ``fetch`` invocation into a marker file. The test then asserts:
##       - exactly ONE fetch ran,
##       - and it targeted ``behind`` (``-C <…>/behind``), never
##         ``present``.
##
##   Falsifiable: the pre-RA-14 path fetched every existing tree
##   unconditionally, so BOTH repos would appear in the markers. Removing
##   the optimized-fetch skip flips the ``present`` assertion.
##
##   The optimization is SOUND in the other direction too: ``behind`` is
##   genuinely missing its locked SHA, so it is NOT skipped — proving the
##   skip predicate never drops a fetch the workspace actually needs.
##
## Skip rule: only when ``git`` is missing from PATH.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

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

# ---- git wrapper shim: record the full argv of every fetch -----------------

proc writeFetchRecordingShim(shimDir, realGit, markersDir: string): string =
  createDir(shimDir)
  createDir(markersDir)
  let shim = shimDir / "git"
  var lines: seq[string]
  lines.add("#!/usr/bin/env bash")
  lines.add("REAL_GIT=" & q(realGit))
  lines.add("MARKERS=" & q(markersDir))
  lines.add("is_fetch=0")
  lines.add("for a in \"$@\"; do")
  lines.add("  if [ \"$a\" = \"fetch\" ]; then is_fetch=1; break; fi")
  lines.add("done")
  lines.add("if [ \"$is_fetch\" = \"1\" ]; then")
  lines.add("  tag=\"$$-$(date +%s%N)\"")
  lines.add("  printf '%s\\n' \"$*\" > \"$MARKERS/$tag.fetch\"")
  lines.add("fi")
  lines.add("exec \"$REAL_GIT\" \"$@\"")
  writeFile(shim, lines.join("\n") & "\n")
  when not defined(windows):
    discard runCmd("chmod +x " & q(shim))
  result = shim

proc fetchInvocations(markersDir: string): seq[string] =
  result = @[]
  for path in walkDir(markersDir):
    if path.path.endsWith(".fetch"):
      result.add(readFile(path.path).strip())

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
      let manifestsRoot = workspaceRoot / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")

      # Two repos. ``present`` stays at its tip; ``behind`` gets an extra
      # upstream commit AFTER the workspace clone is taken.
      let presentOrigin = scratch / "origin-present.git"
      let presentSeed = scratch / "seed-present"
      let presentSha = seedGitOrigin(gitBin, presentOrigin, presentSeed)
      cloneInto(gitBin, presentOrigin, workspaceRoot / "present")

      let behindOrigin = scratch / "origin-behind.git"
      let behindSeed = scratch / "seed-behind"
      discard seedGitOrigin(gitBin, behindOrigin, behindSeed)
      cloneInto(gitBin, behindOrigin, workspaceRoot / "behind")
      # Advance ``behind``'s upstream; the workspace clone does NOT yet have
      # this commit, so the lock pins a SHA the checkout cannot reach.
      let behindLockedSha = seedSecondCommit(gitBin, behindSeed)

      writeFile(manifestsRoot / "repos" / "present.toml",
        repoFragmentToml("present", "present"))
      writeFile(manifestsRoot / "repos" / "behind.toml",
        repoFragmentToml("behind", "behind"))
      writeFile(manifestsRoot / "projects" / "myproject.toml",
        projectTomlWithRepos(@[
          ("present", fileUrl(presentOrigin)),
          ("behind", fileUrl(behindOrigin))]))

      # Lock: ``present`` at the SHA the workspace already has (→ skip),
      # ``behind`` at the advanced upstream SHA (→ must fetch).
      let lockDir = manifestsRoot / "locks" / "myproject" / "present"
      createDir(lockDir)
      writeFile(lockDir / (presentSha & ".toml"),
        lockToml("myproject", @[
          ("present", presentSha), ("behind", behindLockedSha)]))

      # Fetch-recording git shim first on PATH.
      let markersDir = scratch / "markers"
      let shimDir = scratch / "shim-bin"
      discard writeFetchRecordingShim(shimDir, gitBin, markersDir)
      let newPath = shimDir & ":" & getEnv("PATH")

      let res = runShell(shellCommand(@[
        reproBin, "workspace", "sync", "myproject",
        "--workspace-root=" & workspaceRoot,
      ], @[("PATH", newPath)]))
      if res.code != 0:
        checkpoint("sync output: " & res.output)
      # Exit code may be 0 (all advanced/noop) — sync of ``behind`` is a
      # clean fast-forward; ``present`` is a noop.
      check res.code in {0, 2}

      let fetches = fetchInvocations(markersDir)

      # The optimized-fetch contract: exactly ONE fetch ran, and it was for
      # ``behind``. ``present`` (already at its locked SHA) was skipped.
      let presentFetched = fetches.anyIt(it.contains(DirSep & "present"))
      let behindFetched = fetches.anyIt(it.contains(DirSep & "behind"))
      if presentFetched:
        checkpoint("optimized-fetch FAILED to skip 'present'; fetches=" &
          $fetches)
      check not presentFetched
      check behindFetched
      check fetches.len == 1

      # Determinism: ``behind`` advanced to its locked SHA (the fetch +
      # fast-forward ran), ``present`` stayed at its already-locked SHA.
      let behindHead = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "behind") & " rev-parse HEAD").strip()
      check behindHead == behindLockedSha
      let presentHead = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "present") & " rev-parse HEAD").strip()
      check presentHead == presentSha

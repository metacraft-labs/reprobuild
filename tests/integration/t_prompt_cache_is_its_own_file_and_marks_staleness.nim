## ``repro prompt`` answers from a purpose-built cache, not from a report.
##
## Spec: CLI/prompt.md §"Hard Requirements" (fast on every render, no side
## effects) + CLI/README.md §"Report Documents" (a report is never a source of
## truth and is never read back).
##
## The prompt segment used to scrape ``sync-report.json``. That was wrong in
## three ways: it read a report back as if it were state; it had no
## invalidation or staleness bound, so it could confidently print drift counts
## describing a workspace that had since moved; and once the report became
## opt-in the segment simply went blank until someone happened to run
## ``sync --report``. The replacement is ``.repro/build/prompt-cache.json``,
## written by the commands that CHANGE workspace state, carrying a timestamp
## and the branch it describes.
##
## Sub-cases:
##
##   1. ``prompt_cache_written_by_sync_without_report`` — run
##      ``repro workspace sync`` with NO ``--report``. The prompt cache MUST
##      exist and no ``sync-report.json`` may be written. ``repro prompt
##      --format json`` reports the live repo count, ``cacheWrittenBy = sync``
##      and ``stale = false``. This is the regression: the prompt works
##      without the operator opting into an artifact.
##   2. ``prompt_marks_cache_stale_when_branch_changed`` — the recorded
##      workspace branch is changed behind the cache's back. The counts are
##      still shown (a probably-right number beats no number) but marked:
##      ``stale = true``, ``staleReason = branch-changed``, and the plain
##      segment carries the ``?`` marker.
##   3. ``prompt_marks_cache_stale_when_metadata_is_newer`` — the workspace
##      metadata is rewritten with the SAME branch, so only its mtime moves.
##      ``staleReason = metadata-newer``.
##   4. ``prompt_survives_a_missing_cache`` — delete the cache. The prompt
##      still exits 0 and still renders the branch (which comes from metadata,
##      not the cache); ``haveCache = false`` and the counts are zero.
##
## Assertions: as enumerated above, plus the drift count itself — one of the
## two repos is checked out on a branch other than the recorded workspace
## branch, so a correct cache records ``driftRepos = 1``.
##
## Falsifiability:
##   - If the prompt still scraped ``sync-report.json``, sub-case 1 fails: the
##     sync ran without ``--report``, so no report exists and the repo count
##     would be 0.
##   - If the cache had no staleness model (the old behaviour), sub-cases 2
##     and 3 fail: ``stale`` would stay false while the numbers described a
##     workspace that had moved.
##   - If ``prompt`` computed the repo set live instead of from the cache,
##     sub-case 4 fails — it would still report 2 repos with the cache gone,
##     and the per-render latency budget would be broken.
##   - If ``prompt`` required the cache, sub-case 4 fails with a non-zero exit
##     or an empty segment.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b dev " & q(originPath))
  discard requireGit(q(gitBin) & " init -b dev " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Prompt Cache Tester\"")
  writeFile(workPath / "README.md", "prompt-cache fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin dev")
  # A second published branch so one workspace clone can sit off the trunk.
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " checkout -b side")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push -u origin side")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " checkout dev")
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath, branch: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Prompt Cache Tester\"")
  if branch != "dev":
    discard requireGit(q(gitBin) & " -C " & q(targetPath) &
      " checkout " & branch)

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl, bUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"dev\"\n" &
  "trunk = \"dev\"\n\n" &
  "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
  "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

proc repoToml(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"dev\"\n"

proc workspaceMetadata(branch: string): string =
  "schema = \"reprobuild.workspace.local.v1\"\n" &
  "[workspace]\n" &
  "project = \"myproject\"\n" &
  "branch = \"" & branch & "\"\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    originA, originB: string

proc metadataPath(fx: Fixture): string =
  fx.workspaceRoot / ".repro" / "workspace.toml"

proc cachePath(fx: Fixture): string =
  fx.workspaceRoot / ".repro" / "build" / "prompt-cache.json"

proc syncReportPath(fx: Fixture): string =
  fx.workspaceRoot / ".repro" / "build" / "reports" / "sync-report.json"

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-promptcache-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.originA = result.scratch / "origin-lib-a.git"
  result.originB = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, result.originA, result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, result.originB, result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(result.originA), fileUrl(result.originB)))
  writeFile(workspaceRoot / "repos" / "lib-a.toml",
    repoToml("lib-a", "a-origin"))
  writeFile(workspaceRoot / "repos" / "lib-b.toml",
    repoToml("lib-b", "b-origin"))
  createDir(workspaceRoot / ".repro")
  writeFile(workspaceRoot / ".repro" / "workspace.toml",
    workspaceMetadata("dev"))
  result.workspaceRoot = workspaceRoot

  # lib-a on the recorded workspace branch, lib-b off it — one drifted repo.
  cloneInto(gitBin, result.originA, workspaceRoot / "lib-a", "dev")
  cloneInto(gitBin, result.originB, workspaceRoot / "lib-b", "side")

proc invokeSyncWithoutReport(fx: Fixture): CmdResult =
  ## Deliberately NO ``--report``: the prompt must not need one.
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc promptJson(fx: Fixture): JsonNode =
  let res = runShell(shellCommand(@[
    fx.reproBin, "prompt", "--format=json",
    "--workspace-root=" & fx.workspaceRoot,
  ]))
  if res.code != 0:
    checkpoint("prompt output: " & res.output)
  check res.code == 0
  parseJson(res.output.strip())

proc promptPlain(fx: Fixture): string =
  let res = runShell(shellCommand(@[
    fx.reproBin, "prompt",
    "--workspace-root=" & fx.workspaceRoot,
  ]))
  check res.code == 0
  res.output.strip()

suite "repro prompt reads a purpose-built cache, not a report":

  test "t_prompt_cache_is_its_own_file_and_marks_staleness":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "main")
      defer: removeDir(fx.scratch)

      # ---- (1) sync WITHOUT --report still feeds the prompt. -------------
      let syncRes = invokeSyncWithoutReport(fx)
      if syncRes.code notin [0, 2]:
        checkpoint("sync output: " & syncRes.output)
      check syncRes.code in [0, 2]

      check fileExists(cachePath(fx))
      # The report is opt-in and was NOT requested, so it must be absent —
      # which is exactly why the cache has to be a separate file.
      check not fileExists(syncReportPath(fx))

      var state = promptJson(fx)
      check state["inWorkspace"].getBool()
      check state["branch"].getStr() == "dev"
      check state["haveCache"].getBool()
      check state["cacheWrittenBy"].getStr() == "sync"
      check state["repoCount"].getInt() == 2
      check state["driftRepos"].getInt() == 1
      check state["stale"].getBool() == false
      check state["staleReason"].getStr() == ""
      # Fresh: the drift field carries no staleness marker.
      check promptPlain(fx) == "[ws:dev ●1]"

      # ---- (2) the workspace branch moved behind the cache's back. -------
      writeFile(metadataPath(fx), workspaceMetadata("feature-x"))
      state = promptJson(fx)
      check state["branch"].getStr() == "feature-x"
      check state["stale"].getBool() == true
      check state["staleReason"].getStr() == "branch-changed"
      # The count is still surfaced — marked, not suppressed.
      check state["driftRepos"].getInt() == 1
      check promptPlain(fx) == "[ws:feature-x ●1?]"

      # ---- (3) same branch, but the metadata is newer than the cache. ----
      writeFile(metadataPath(fx), workspaceMetadata("dev"))
      state = promptJson(fx)
      check state["branch"].getStr() == "dev"
      check state["stale"].getBool() == true
      check state["staleReason"].getStr() == "metadata-newer"

      # A fresh sync re-establishes coherence: same metadata, newer cache.
      discard invokeSyncWithoutReport(fx)
      state = promptJson(fx)
      check state["stale"].getBool() == false

      # ---- (4) the cache is an optimization, never a requirement. --------
      removeFile(cachePath(fx))
      state = promptJson(fx)
      check state["inWorkspace"].getBool()
      check state["haveCache"].getBool() == false
      check state["repoCount"].getInt() == 0
      check state["driftRepos"].getInt() == 0
      # The branch comes from metadata, so it survives the cache going away.
      check state["branch"].getStr() == "dev"
      check promptPlain(fx) == "[ws:dev]"

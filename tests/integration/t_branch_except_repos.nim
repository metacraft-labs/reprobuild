## ``repro branch <path> --except=a,b`` forks every repo of the new
## workspace's set EXCEPT the named ones (CLI/branch.md §"--except").
##
## The defect this pins: every fork guard is decided per repo in pre-flight and
## refuses the whole command, so ONE repo whose source clone is corrupt, or
## whose role branch cannot be fetched, aborted a fork of two hundred. The only
## way to leave it out was ``--projects``, which names the projects to KEEP and
## so drops every other repo of the blocked repo's project with it. And a
## ``--projects`` given a repo's directory name failed ``projects_unresolved``
## without saying which names it would have accepted.
##
## Sub-cases:
##
##   1. ``t_except_leaves_a_blocked_repo_out`` — lib-b's source clone has lost
##      its objects, so its clean/dirty probe fails. Without ``--except`` the
##      fork refuses (``probe_failed``) and creates nothing. With
##      ``--except=lib-b`` it exits 0: lib-b is reported ``excluded`` with an
##      empty ``baselineSource`` and ``headSha``, has no checkout in the new
##      workspace, the other repos (from BOTH projects) are on the new branch,
##      the recorded project set is the inherited one, unchanged, and the
##      feature mark and ``[workspace].branch`` are written.
##   2. ``t_except_under_mainline_leaves_an_unfetchable_repo_out`` — under
##      ``--mainline`` lib-b's remote advertises a ``main`` whose newest commit
##      object it has lost, so ``ls-remote`` (the branch-collision probe)
##      still answers but ``fetch`` dies on the missing object. The fork
##      refuses with exactly ``mainline_fetch_failed`` for lib-b, the refusal
##      the issue reported; with ``--except=lib-b`` it cuts the rest from their
##      mainlines and exits 0. (A remote that is simply gone fails the
##      collision probe as well, and its ``probe_failed`` takes precedence, so
##      it would not exercise this refusal.)
##   3. ``t_except_unknown_name_is_refused_before_anything_is_created`` — a
##      name that matches no member repo is ``except_unresolved``, exit 2,
##      naming the unknown entry and ``repro workspace repos list``; the
##      destination is not created.
##   4. ``t_rerun_without_except_brings_the_excluded_repo_in`` — once lib-b's
##      source clone is repaired, re-running the same fork WITHOUT the flag
##      resumes it: lib-b is materialized and branched, the repos already on
##      the branch report ``already``.
##   5. ``t_projects_unresolved_lists_the_project_names`` — ``--projects`` given
##      a repo's directory name is ``projects_unresolved``, and the diagnostic
##      lists the projects the workspace defines.
##
## Falsifiability: before ``--except`` existed, cases 1-4 fail at the parser
## (``--except`` is an unsupported flag, exit 2, no report). Case 1 also fails
## if an excluded repo is still probed (the corrupt clone refuses the fork) or
## cloned (``lib-b`` would exist in the destination), and if an exclusion edits
## membership (the recorded set would differ). Case 4 fails if a resumed fork
## re-labels converged repos ``branched``. Case 5 fails if the diagnostic only
## echoes the given name.
##
## Real components (NO mocks): the real ``git`` binary, real bare repos, the
## engine-built ``build/bin/repro`` as a subprocess. Local bares + ``file://``
## URLs stand in for network remotes, as in every workspace integration test.
## The "corrupt clone" and the "remote that cannot serve its mainline" are
## real ones: object files are deleted, inside this test's own temp directory
## only (``deleteInsideScratch``).
##
## Skip rule: ``git`` missing on PATH.

import std/[json, options, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"Except Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "except fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(fileUrl(originPath)))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc projectToml(name: string; repos: openArray[(string, string)]): string =
  ## A project including one fragment per ``(repo name, origin url)``.
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name & "\"\n\n"
  for (repo, url) in repos:
    result.add("[[remote]]\nname = \"" & repo & "-origin\"\nfetch = \"" &
      url & "\"\n\n")
  result.add("includes = [\n")
  for (repo, _) in repos:
    result.add("  \"repos/" & repo & ".toml\",\n")
  result.add("]\n")

proc repoToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & name & "-origin\"\n" &
  "mainline = \"main\"\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    origins: seq[(string, string)] ## (repo name, bare origin path)

proc setupFixture(gitBin, slug: string): Fixture =
  ## A source workspace with TWO enabled projects: ``alpha`` (lib-a, lib-b) and
  ## ``beta`` (lib-c). lib-b shares its project with lib-a on purpose: leaving
  ## it out through ``--projects`` would drop lib-a too, which is the cost
  ## ``--except`` removes. The root declares its mainline so the same fixture
  ## serves ``--mainline``.
  result.scratch = createTempDir("repro-branch-except-" & slug & "-", "")
  result.reproBin = reproBinary()
  for name in ["lib-a", "lib-b", "lib-c"]:
    let origin = result.scratch / ("origin-" & name & ".git")
    seedGitOrigin(gitBin, origin, result.scratch / ("seed-" & name))
    result.origins.add((name, origin))
  let rootBare = result.scratch / "origin-repro-workspace.git"
  seedBareWithFiles(gitBin, result.scratch, rootBare, [
    ("repro-workspace.toml", "schema = \"reprobuild.workspace.settings.v1\"" &
      "\n\n[workspace]\nmainline = \"main\"\n"),
    ("projects/alpha.toml", projectToml("alpha", [
      ("lib-a", fileUrl(result.origins[0][1])),
      ("lib-b", fileUrl(result.origins[1][1]))])),
    ("projects/beta.toml", projectToml("beta", [
      ("lib-c", fileUrl(result.origins[2][1]))])),
    ("repos/lib-a.toml", repoToml("lib-a")),
    ("repos/lib-b.toml", repoToml("lib-b")),
    ("repos/lib-c.toml", repoToml("lib-c")),
  ])
  result.workspaceRoot = result.scratch / "source-workspace"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(rootBare)) & " " &
    q(result.workspaceRoot))
  gitConfig(gitBin, result.workspaceRoot)
  for (name, origin) in result.origins:
    discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
      q(result.workspaceRoot / name))
    gitConfig(gitBin, result.workspaceRoot / name)
  writeWorkspaceProjects(result.workspaceRoot, @["alpha", "beta"])
  writeWorkspaceBranch(result.workspaceRoot, project = "alpha", branch = "main")

proc deleteInsideScratch(fx: Fixture; path: string) =
  ## Remove ``path`` only when it is an absolute path strictly inside this
  ## test's own temp directory. The fixture corrupts and repairs checkouts by
  ## deleting files, and a mistaken path must fail the test rather than
  ## delete anything outside it.
  let scratch = normalizedPath(absolutePath(fx.scratch))
  let target = normalizedPath(absolutePath(path))
  doAssert path.isAbsolute, "refusing a relative delete: " & path
  doAssert target.startsWith(scratch & DirSep) and target != scratch,
    "refusing to delete outside the test scratch dir: " & target
  if dirExists(target):
    removeDir(target)
  elif fileExists(target):
    removeFile(target)

proc corruptClone(fx: Fixture; repoPath: string) =
  ## Delete every object file of the checkout at ``repoPath``: HEAD still
  ## names a commit, but ``git status`` fails with "bad object HEAD" — the
  ## corrupt-clone case that blocked a real fork. Each file is deleted by its
  ## absolute path through ``deleteInsideScratch``.
  let objects = repoPath / ".git" / "objects"
  doAssert dirExists(objects), "no object directory at " & objects
  var files: seq[string]
  for path in walkDirRec(objects):
    files.add(path)
  doAssert files.len > 0, "no object files to delete under " & objects
  for path in files:
    deleteInsideScratch(fx, path)

proc breakRemoteMainline(gitBin: string; fx: Fixture; name: string) =
  ## Push a new ``main`` commit to ``name``'s bare origin, then delete that
  ## commit's object from the origin. The source checkout has never fetched
  ## the commit, so ``git fetch`` must ask for it and the remote's
  ## upload-pack fails ("not our ref"), while ``git ls-remote`` still lists
  ## the ref. A push this small is stored as loose objects, so the commit is
  ## one file; the delete goes through ``deleteInsideScratch``.
  let seed = fx.scratch / ("seed-" & name)
  var origin = ""
  for (repo, path) in fx.origins:
    if repo == name:
      origin = path
  doAssert origin.len > 0, "no origin for " & name
  writeFile(seed / "README.md", "advanced mainline\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -am advance")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")
  let sha = requireGit(q(gitBin) & " -C " & q(origin) &
    " rev-parse refs/heads/main").strip()
  let objectPath = origin / "objects" / sha[0 .. 1] / sha[2 .. ^1]
  doAssert fileExists(objectPath), "pushed commit is not a loose object: " &
    objectPath
  deleteInsideScratch(fx, objectPath)

proc invokeFork(fx: Fixture; path: string;
                extra: seq[string] = @[]): CmdResult =
  var argv = @[fx.reproBin, "branch", "--write-report", path,
               "--workspace-root=" & fx.workspaceRoot]
  for e in extra:
    argv.add(e)
  runShell(shellCommand(argv))

proc readReport(root: string): JsonNode =
  let reportPath = root / ".repro" / "build" / "reports" / "branch-report.json"
  check fileExists(reportPath)
  if fileExists(reportPath): parseFile(reportPath) else: newJObject()

proc entryByPath(report: JsonNode; path: string): JsonNode =
  if report.hasKey("repos"):
    for entry in report["repos"]:
      if entry["path"].getStr() == path:
        return entry
  newJNull()

proc outcomeOf(report: JsonNode; path: string): string =
  let entry = entryByPath(report, path)
  if entry.kind == JObject: entry["outcome"].getStr() else: "<absent>"

proc diagnosticsOf(report: JsonNode): string =
  if report.hasKey("repos"):
    for entry in report["repos"]:
      result.add(entry["diagnostic"].getStr() & "\n")

proc checkExcluded(report: JsonNode; path: string) =
  let entry = entryByPath(report, path)
  check entry.kind == JObject
  if entry.kind == JObject:
    check entry["outcome"].getStr() == "excluded"
    # Nothing was probed or resolved for it, so the report asserts no
    # baseline.
    check entry["baselineSource"].getStr() == ""
    check entry["headSha"].getStr() == ""

suite "repro branch --except leaves named repos out of a fork":

  test "t_except_leaves_a_blocked_repo_out":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "blocked")
      defer: removeDirEventually(fx.scratch)
      corruptClone(fx, fx.workspaceRoot / "lib-b")

      # Without the flag the corrupt clone refuses the whole fork.
      let refusedDest = fx.scratch / "feature-refused"
      let refused = invokeFork(fx, refusedDest)
      checkpoint("refused: " & refused.output)
      check refused.code == 1
      check not dirExists(refusedDest)
      check outcomeOf(readReport(fx.workspaceRoot), "lib-b") == "probe_failed"

      let dest = fx.scratch / "feature-except"
      let res = invokeFork(fx, dest, @["--except=lib-b"])
      checkpoint("except: " & res.output)
      check res.code == 0
      check res.output.contains("workspace branch: lib-b excluded")

      # The excluded repo has no checkout at all; every other repo, from both
      # projects, is on the new branch, and so is the root.
      check not dirExists(dest / "lib-b")
      for name in ["lib-a", "lib-c"]:
        check dirExists(dest / name / ".git")
        check currentBranch(gitBin, dest / name) == "feature-except"
      check currentBranch(gitBin, dest) == "feature-except"

      let report = readReport(dest)
      check report["exitCode"].getInt() == 0
      checkExcluded(report, "lib-b")
      check outcomeOf(report, "lib-a") == "branched"
      check outcomeOf(report, "lib-c") == "branched"

      # Membership is not edited: the new workspace records the inherited set,
      # and lib-b stays a member without a checkout. The feature mark and the
      # branch are recorded, because an exclusion is not a failure.
      check readWorkspaceProjects(dest) == @["alpha", "beta"]
      check readWorkspaceBranch(dest) == some("feature-except")
      check readWorkspaceFeatureStarted(dest)
      check report["featureStarted"].getBool()

  test "t_except_under_mainline_leaves_an_unfetchable_repo_out":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "mainline")
      defer: removeDirEventually(fx.scratch)
      # lib-b's remote still answers `ls-remote` but cannot serve its
      # mainline's tip, so its role branch cannot be fetched.
      breakRemoteMainline(gitBin, fx, "lib-b")

      let refusedDest = fx.scratch / "trunk-refused"
      let refused = invokeFork(fx, refusedDest, @["--mainline"])
      checkpoint("refused: " & refused.output)
      # A pre-flight refusal: exit 2, nothing created, and lib-b is the one
      # blocker.
      check refused.code == 2
      check not dirExists(refusedDest)
      let refusal = readReport(fx.workspaceRoot)
      check outcomeOf(refusal, "lib-b") == "mainline_fetch_failed"
      check outcomeOf(refusal, "lib-a") == "ready"
      check outcomeOf(refusal, "lib-c") == "ready"

      let dest = fx.scratch / "trunk-except"
      let res = invokeFork(fx, dest, @["--mainline", "--except=lib-b"])
      checkpoint("except: " & res.output)
      check res.code == 0
      check not dirExists(dest / "lib-b")
      for name in ["lib-a", "lib-c"]:
        check currentBranch(gitBin, dest / name) == "trunk-except"
      let report = readReport(dest)
      checkExcluded(report, "lib-b")
      check outcomeOf(report, "lib-a") == "branched_from_mainline"
      check outcomeOf(report, "lib-c") == "branched_from_mainline"
      check readWorkspaceProjects(dest) == @["alpha", "beta"]

  test "t_except_unknown_name_is_refused_before_anything_is_created":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "unknown")
      defer: removeDirEventually(fx.scratch)
      let dest = fx.scratch / "feature-typo"
      let res = invokeFork(fx, dest, @["--except=lib-b,lib-typo,other-typo"])
      checkpoint("output: " & res.output)
      check res.code == 2
      check not dirExists(dest)
      let report = readReport(fx.workspaceRoot)
      check report["exitCode"].getInt() == 2
      check outcomeOf(report, "") == "except_unresolved"
      let diag = diagnosticsOf(report)
      # EVERY unknown entry is named, the known one is not, and the listing
      # command is the remedy.
      check "lib-typo" in diag
      check "other-typo" in diag
      check "'lib-b'" notin diag
      check "repro workspace repos list" in diag

  test "t_rerun_without_except_brings_the_excluded_repo_in":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "resume")
      defer: removeDirEventually(fx.scratch)
      corruptClone(fx, fx.workspaceRoot / "lib-b")
      let dest = fx.scratch / "feature-resume"
      let first = invokeFork(fx, dest, @["--except=lib-b"])
      checkpoint("first: " & first.output)
      check first.code == 0
      check not dirExists(dest / "lib-b")

      # Repair the blocker: replace the corrupt clone with a fresh one.
      deleteInsideScratch(fx, fx.workspaceRoot / "lib-b")
      discard requireGit(q(gitBin) & " clone " &
        q(fileUrl(fx.origins[1][1])) & " " & q(fx.workspaceRoot / "lib-b"))

      let second = invokeFork(fx, dest)
      checkpoint("second: " & second.output)
      check second.code == 0
      check dirExists(dest / "lib-b" / ".git")
      check currentBranch(gitBin, dest / "lib-b") == "feature-resume"
      let report = readReport(dest)
      check outcomeOf(report, "lib-b") == "branched"
      check outcomeOf(report, "lib-a") == "already"
      check outcomeOf(report, "lib-c") == "already"
      check readWorkspaceProjects(dest) == @["alpha", "beta"]

  test "t_projects_unresolved_lists_the_project_names":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "projects")
      defer: removeDirEventually(fx.scratch)
      let dest = fx.scratch / "feature-dirname"
      # A repo's directory name, the usual mistake.
      let res = invokeFork(fx, dest, @["--projects=lib-a"])
      checkpoint("output: " & res.output)
      check res.code == 2
      check not dirExists(dest)
      let report = readReport(fx.workspaceRoot)
      check outcomeOf(report, "") == "projects_unresolved"
      let diag = diagnosticsOf(report)
      check "alpha" in diag
      check "beta" in diag

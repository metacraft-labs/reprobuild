## ``repro sync --mainline`` — reconcile a feature branch with each repo's own
## manifest-declared mainline.
##
## Drives the compiled ``repro`` binary against hermetic workspaces whose
## fragments declare DIFFERENT mainlines, because that is the case the flag
## exists for: `repro ws forall -c 'git rebase origin/dev'` silently corrupts
## every repo that tracks `latest` or `live`, and only the manifest knows which
## is which.
##
## Sub-cases (each its own ``test_sync_mainline_*`` block):
##
##   1. ``test_sync_mainline_fast_forwards_when_branch_has_no_local_commits``
##      Trunk moved, the feature branch has no commits of its own — a
##      fast-forward, which needs no decision. Reported ``fast_forwarded``,
##      HEAD lands on the mainline tip, exit 0.
##   2. ``test_sync_mainline_reports_diverged_without_a_flavor``
##      Both sides moved and no ``--rebase``/``--merge`` was given. Exit 2, the
##      diagnostic names BOTH flags, and NOTHING is mutated — this is the
##      triage step of the workflow, so it must be safe to run at any time.
##   3. ``test_sync_mainline_rebase_replays_local_commits``
##      Same fixture with ``--rebase``: the local commit is replayed onto the
##      mainline tip, which becomes an ancestor of HEAD.
##   4. ``test_sync_mainline_merge_records_a_merge_commit``
##      Same fixture with ``--merge``: HEAD becomes a merge whose parents are
##      the old branch tip and the mainline tip.
##   5. ``test_sync_mainline_leaves_conflicting_repo_untouched``
##      Both sides edited the same line. The repo is reported ``conflict`` and
##      left EXACTLY as it was — same HEAD, clean tree, no rebase in progress.
##      This is the per-repo atomicity guarantee.
##   6. ``test_sync_mainline_reconciles_each_repo_against_its_own_mainline``
##      Three repos tracking `dev` / `latest` / `live`, each behind its own
##      trunk. All three fast-forward, each toward a DIFFERENT branch.
##   7. ``test_sync_mainline_only_selects_a_subset``
##      ``--only`` restricts the run; the unnamed repo is untouched, and an
##      unknown name is an error rather than a silent empty selection.
##   8. ``test_sync_mainline_refuses_dirty_repo_when_integrating``
##      A flavor was chosen but the tree is dirty: refused, uncommitted work
##      still present.
##
## No mocks: real git repositories, real filesystem, the real binary.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc removeDirEventually(path: string) =
  for attempt in 0 ..< 20:
    if not dirExists(path):
      return
    try:
      removeDir(path)
      return
    except OSError:
      if attempt == 19:
        raise
      sleep(100)

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

# ---- fixture ---------------------------------------------------------------

type
  RepoSpec = object
    name: string
    mainline: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    specs: seq[RepoSpec]

proc originOf(fx: Fixture; name: string): string =
  fx.scratch / ("origin-" & name & ".git")

proc seedOf(fx: Fixture; name: string): string =
  fx.scratch / ("seed-" & name)

proc seedOrigin(gitBin, originPath, workPath, branch: string) =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Sync Tester\"")
  writeFile(workPath / "shared.txt", "base\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)

proc advanceTrunk(gitBin, seedPath, branch, content: string): string =
  ## Push a commit onto the origin's mainline, simulating a teammate landing
  ## work on trunk after you branched.
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " switch " & branch)
  writeFile(seedPath / "shared.txt", content)
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " commit -m " & q("trunk advance"))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " push origin " & branch)
  requireGit(q(gitBin) & " -C " & q(seedPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Sync Tester\"")

proc startFeatureBranch(gitBin, repoPath, branch: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " switch -c " & branch)

proc commitLocal(gitBin, repoPath, file, content, message: string) =
  writeFile(repoPath / file, content)
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m " & q(message))

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc isAncestor(gitBin, repoPath, maybeAncestor, descendant: string): bool =
  runCmd(q(gitBin) & " -C " & q(repoPath) & " merge-base --is-ancestor " &
    maybeAncestor & " " & descendant).code == 0

proc parentCount(gitBin, repoPath, rev: string): int =
  let out0 = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-list --parents -n 1 " & rev).strip()
  out0.splitWhitespace().len - 1

proc isClean(gitBin, repoPath: string): bool =
  runCmd(q(gitBin) & " -C " & q(repoPath) & " status --porcelain").output
    .strip().len == 0

proc rebaseInProgress(repoPath: string): bool =
  dirExists(repoPath / ".git" / "rebase-merge") or
    dirExists(repoPath / ".git" / "rebase-apply")

proc projectToml(fx: Fixture): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"mainline-sync-fixture\"\n" &
    "default_revision = \"main\"\n\n"
  for s in fx.specs:
    result.add("[[remote]]\nname = \"" & s.name & "-origin\"\nfetch = \"" &
      fileUrl(fx.originOf(s.name)) & "\"\n\n")
  result.add("includes = [\n")
  for s in fx.specs:
    result.add("  \"repos/" & s.name & ".toml\",\n")
  result.add("]\n")

proc fragmentToml(s: RepoSpec): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\nname = \"" & s.name & "\"\npath = \"" & s.name & "\"\n" &
  "remote = \"" & s.name & "-origin\"\nbranch = \"" & s.mainline & "\"\n"

proc setupFixture(gitBin, slug: string; specs: seq[RepoSpec]): Fixture =
  result.scratch = createTempDir("repro-sync-mainline-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.specs = specs
  for s in specs:
    seedOrigin(gitBin, result.originOf(s.name), result.seedOf(s.name),
      s.mainline)
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "mainline-sync-fixture.toml",
    projectToml(result))
  for s in specs:
    writeFile(workspaceRoot / "repos" / (s.name & ".toml"), fragmentToml(s))
  result.workspaceRoot = workspaceRoot

proc cloneAll(gitBin: string; fx: Fixture) =
  for s in fx.specs:
    cloneInto(gitBin, fx.originOf(s.name), fx.workspaceRoot / s.name)

proc invokeSync(fx: Fixture; extra: seq[string]): CmdResult =
  var argv = @[fx.reproBin, "sync", "--mainline", "--write-report",
    "--workspace-root=" & fx.workspaceRoot, "mainline-sync-fixture"]
  argv.add(extra)
  runShell(shellCommand(argv))

proc readReport(fx: Fixture): JsonNode =
  let p = fx.workspaceRoot / ".repro" / "build" / "reports" / "sync-report.json"
  check fileExists(p)
  parseFile(p)

proc entryByName(report: JsonNode; name: string): JsonNode =
  for e in report["repos"]:
    if e["name"].getStr() == name:
      return e
  newJNull()

const oneRepo = @[RepoSpec(name: "prod", mainline: "dev")]

# ---- the suite -------------------------------------------------------------

suite "repro sync --mainline":

  test "test_sync_mainline_fast_forwards_when_branch_has_no_local_commits":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "ff", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      let trunkTip = advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "moved\n")

      let res = invokeSync(fx, @[])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      let e = entryByName(report, "prod")
      check e["outcome"].getStr() == "fast_forwarded"
      check e["mainlineBranch"].getStr() == "dev"
      check e["branch"].getStr() == "feature-x"
      # The branch actually advanced to the mainline tip.
      check headSha(gitBin, repoPath) == trunkTip

  test "test_sync_mainline_reports_diverged_without_a_flavor":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "diverged", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      commitLocal(gitBin, repoPath, "mine.txt", "mine\n", "local work")
      let before = headSha(gitBin, repoPath)
      discard advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "moved\n")

      let res = invokeSync(fx, @[])
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      let e = entryByName(report, "prod")
      check e["outcome"].getStr() == "diverged"
      check e["action"].getStr() == "none"
      # Principle 2: the diagnostic must name BOTH resolutions.
      check e["diagnostic"].getStr().contains("--rebase")
      check e["diagnostic"].getStr().contains("--merge")
      # The triage step must be safe to run at any time: nothing moved.
      check headSha(gitBin, repoPath) == before

  test "test_sync_mainline_rebase_replays_local_commits":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "rebase", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      # A file trunk does not touch, so the integration is clean.
      commitLocal(gitBin, repoPath, "mine.txt", "mine\n", "local work")
      let trunkTip = advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "moved\n")

      let res = invokeSync(fx, @["--rebase"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      let e = entryByName(report, "prod")
      check e["outcome"].getStr() == "integrated"
      check e["action"].getStr() == "rebase"
      # Replayed ON TOP of trunk: the mainline tip is now an ancestor, and the
      # result is linear (a rebase records no merge commit).
      check isAncestor(gitBin, repoPath, trunkTip, "HEAD")
      check parentCount(gitBin, repoPath, "HEAD") == 1
      check fileExists(repoPath / "mine.txt")

  test "test_sync_mainline_merge_records_a_merge_commit":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "merge", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      commitLocal(gitBin, repoPath, "mine.txt", "mine\n", "local work")
      let localTip = headSha(gitBin, repoPath)
      let trunkTip = advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "moved\n")

      let res = invokeSync(fx, @["--merge"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let e = entryByName(readReport(fx), "prod")
      check e["outcome"].getStr() == "integrated"
      check e["action"].getStr() == "merge"
      # A merge, not a replay: two parents, and BOTH tips are ancestors.
      check parentCount(gitBin, repoPath, "HEAD") == 2
      check isAncestor(gitBin, repoPath, trunkTip, "HEAD")
      check isAncestor(gitBin, repoPath, localTip, "HEAD")

  test "test_sync_mainline_leaves_conflicting_repo_untouched":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "conflict", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      # BOTH sides edit shared.txt — a genuine conflict.
      commitLocal(gitBin, repoPath, "shared.txt", "mine\n", "local edit")
      let before = headSha(gitBin, repoPath)
      discard advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "theirs\n")

      let res = invokeSync(fx, @["--rebase"])
      check res.code == 2

      let e = entryByName(readReport(fx), "prod")
      check e["outcome"].getStr() == "conflict"
      check e["action"].getStr() == "none"

      # The per-repo atomicity guarantee: the repo is EXACTLY as it was.
      check headSha(gitBin, repoPath) == before
      check isClean(gitBin, repoPath)
      check not rebaseInProgress(repoPath)
      check readFile(repoPath / "shared.txt") == "mine\n"

  test "test_sync_mainline_reconciles_each_repo_against_its_own_mainline":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # The case the flag exists for: one command, three different trunks.
      let fx = setupFixture(gitBin, "heterogeneous", @[
        RepoSpec(name: "prod", mainline: "dev"),
        RepoSpec(name: "specs", mainline: "latest"),
        RepoSpec(name: "infra", mainline: "live")])
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)

      var tips: seq[string]
      for s in fx.specs:
        startFeatureBranch(gitBin, fx.workspaceRoot / s.name, "feature-x")
        tips.add(advanceTrunk(gitBin, fx.seedOf(s.name), s.mainline, "moved\n"))

      let res = invokeSync(fx, @[])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check entryByName(report, "prod")["mainlineBranch"].getStr() == "dev"
      check entryByName(report, "specs")["mainlineBranch"].getStr() == "latest"
      check entryByName(report, "infra")["mainlineBranch"].getStr() == "live"
      for i, s in fx.specs:
        check entryByName(report, s.name)["outcome"].getStr() == "fast_forwarded"
        # Each landed on ITS OWN trunk, not on a single shared branch name.
        check headSha(gitBin, fx.workspaceRoot / s.name) == tips[i]

  test "test_sync_mainline_only_selects_a_subset":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "only", @[
        RepoSpec(name: "prod", mainline: "dev"),
        RepoSpec(name: "specs", mainline: "latest")])
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      for s in fx.specs:
        startFeatureBranch(gitBin, fx.workspaceRoot / s.name, "feature-x")
        discard advanceTrunk(gitBin, fx.seedOf(s.name), s.mainline, "moved\n")
      let specsBefore = headSha(gitBin, fx.workspaceRoot / "specs")

      let res = invokeSync(fx, @["--only=prod"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["repos"].len == 1
      check report["repos"][0]["name"].getStr() == "prod"
      # The unnamed repo was not touched.
      check headSha(gitBin, fx.workspaceRoot / "specs") == specsBefore

      # A typo must be an error, not a silent empty selection that reads
      # exactly like "there was nothing to do".
      let bad = invokeSync(fx, @["--only=no-such-repo"])
      check bad.code != 0
      check bad.output.contains("names no repo")

  test "test_sync_mainline_refuses_dirty_repo_when_integrating":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      commitLocal(gitBin, repoPath, "mine.txt", "mine\n", "local work")
      discard advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "moved\n")
      let before = headSha(gitBin, repoPath)
      writeFile(repoPath / "uncommitted.txt", "wip\n")

      let res = invokeSync(fx, @["--rebase"])
      check res.code == 2

      let e = entryByName(readReport(fx), "prod")
      check e["outcome"].getStr() == "dirty"
      check headSha(gitBin, repoPath) == before
      # The WIP is still there — refusing must not consume it.
      check fileExists(repoPath / "uncommitted.txt")

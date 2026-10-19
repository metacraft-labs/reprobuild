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
##   9. ``test_sync_mainline_clones_missing_repo_and_filters_routine_output``
##      A declared repo with no checkout is cloned onto its mainline; the text
##      output omits routine repos unless ``--verbose``.
##
## ``--dry-run`` (CLI/sync.md §`--dry-run` with `--mainline`): print the plan,
## exit 0, mutate NOTHING — no fetch (checkouts or the shared-bare cache), no
## clone, no ff/rebase/merge, no receipts, no report even under
## ``--write-report``. Every dry-run case below passes ``--write-report``
## (``invokeSync`` always does) precisely so the "no report" half is tested.
##
##  10. ``test_sync_mainline_dry_run_previews_fast_forward_without_fetching``
##      The checkout's remote-tracking ref is behind the origin (trunk moved
##      twice; the checkout fetched after the first move only). The plan is a
##      ``fast_forward`` computed against the STALE ref, and afterwards HEAD,
##      branch and ``refs/remotes/origin/dev`` are all unchanged — the second
##      move was not fetched — and no receipts / engine cache / report exist.
##      The JSON carries ``dryRun: true`` and ``headAfter == headBefore``; the
##      text says ``would fast_forward`` and ``(dry-run)``.
##  11. ``test_sync_mainline_dry_run_does_not_clone_missing_checkout``
##      A declared repo with no checkout: planned as ``clone``, but nothing is
##      cloned and the shared-bare clone cache under
##      ``.repro/workspace/engine-cache`` (where ``refreshSharedBare`` would
##      put it on this path) is never created.
##  12. ``test_sync_mainline_dry_run_plans_rebase_without_integrating``
##      Diverged repo with ``--rebase``: planned ``integrated`` / ``rebase``,
##      HEAD and tree unchanged, no rebase in progress, exit 0.
##  13. ``test_sync_mainline_dry_run_exits_zero_on_a_refusal``
##      Diverged repo without a flavor: the plan reports ``diverged`` (a real
##      run exits 2, sub-case 2), but a dry run is informational and exits 0.
##
##  14. ``test_sync_mainline_scopes_the_full_active_project_set``
##      Metadata-only multi-project workspace: later positional repos survive
##      selectors; sync reconciles the scoped active union without enabling
##      inactive projects or touching other active projects.
##
## No mocks: real git repositories, real filesystem, the real binary.
## Existing cases skip when git is absent; the scope regression requires git.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import repro_workspace_manifests

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

proc reportPath(fx: Fixture): string =
  fx.workspaceRoot / ".repro" / "build" / "reports" / "sync-report.json"

proc stdoutJson(output: string): JsonNode =
  ## ``runShell`` merges stderr into stdout, so the ``--json`` document is
  ## located by its outermost braces rather than parsed whole.
  let first = output.find('{')
  let last = output.rfind('}')
  if first < 0 or last < first:
    checkpoint("no JSON document in output:\n" & output)
    return newJNull()
  parseJson(output[first .. last])

proc gitRev(gitBin, repoPath, rev: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse " & rev).strip()

proc currentBranch(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) &
    " branch --show-current").strip()

proc fetchCheckout(gitBin, repoPath: string) =
  ## Bring the checkout's remote-tracking refs up to date by hand, the way an
  ## operator would before a dry run that (by contract) does not fetch.
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " fetch origin")

proc checkDryRunLeftNoState(fx: Fixture) =
  ## The workspace-side half of the dry-run contract: no receipts (the fetch
  ## and clone actions write them), no engine cache (the build engine's cache
  ## root, which on the mainline path is ALSO where ``refreshSharedBare`` puts
  ## the shared-bare clone cache), and no report despite ``--write-report``.
  let ws = fx.workspaceRoot / ".repro" / "workspace"
  check not dirExists(ws / "receipts")
  check not dirExists(ws / "engine-cache")
  check not fileExists(fx.reportPath())

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

  test "test_sync_mainline_clones_missing_repo_and_filters_routine_output":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a repository")
    else:
      let fx = setupFixture(gitBin, "missing-clone", @[
        RepoSpec(name: "prod", mainline: "dev"),
        RepoSpec(name: "specs", mainline: "latest")])
      defer: removeDirEventually(fx.scratch)
      # Only clone prod, leaving specs missing
      cloneInto(gitBin, fx.originOf("prod"), fx.workspaceRoot / "prod")

      let res = invokeSync(fx, @[])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      # Phase announcement
      check res.output.contains("workspace sync: checking 2 repositories...")
      # Missing repo specs is cloned to its mainline branch
      check dirExists(fx.workspaceRoot / "specs" / ".git")
      check requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "specs") & " branch --show-current").strip() == "latest"
      # Exception-based reporting: specs is reported as cloned, but up-to-date prod is omitted by default
      check res.output.contains("specs")
      check res.output.contains("cloned")
      check not res.output.contains("workspace sync: prod")
      # Summary line shows total counts
      check res.output.contains("1 up_to_date")
      check res.output.contains("1 cloned")

      # With --verbose, routine repos are included
      let resVerbose = invokeSync(fx, @["--verbose"])
      check resVerbose.code == 0
      check resVerbose.output.contains("workspace sync: prod up_to_date")

  test "test_sync_mainline_dry_run_previews_fast_forward_without_fetching":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a repository")
    else:
      let fx = setupFixture(gitBin, "dry-ff", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      let before = headSha(gitBin, repoPath)
      # First trunk move, fetched: the plan has something to fast-forward to.
      let fetchedTip = advanceTrunk(gitBin, fx.seedOf("prod"), "dev",
        "moved\n")
      fetchCheckout(gitBin, repoPath)
      # Second trunk move, NOT fetched: a dry run that fetched would move
      # `origin/dev` onto it, which is exactly the mutation under test.
      let unfetchedTip = advanceTrunk(gitBin, fx.seedOf("prod"), "dev",
        "moved again\n")
      check fetchedTip != unfetchedTip
      check gitRev(gitBin, repoPath, "refs/remotes/origin/dev") == fetchedTip

      let res = invokeSync(fx, @["--dry-run", "--json"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # Nothing moved: not HEAD, not the branch, not the remote-tracking ref.
      check headSha(gitBin, repoPath) == before
      check currentBranch(gitBin, repoPath) == "feature-x"
      check gitRev(gitBin, repoPath, "refs/remotes/origin/dev") == fetchedTip
      check isClean(gitBin, repoPath)
      checkDryRunLeftNoState(fx)

      # The plan is the report document, on stdout, marked as a dry run, and
      # computed against the STALE ref: a fast-forward is still pending.
      let plan = stdoutJson(res.output)
      check plan.kind == JObject
      if plan.kind == JObject:
        check plan.hasKey("dryRun") and plan["dryRun"].getBool()
        check plan["exitCode"].getInt() == 0
        let e = entryByName(plan, "prod")
        check e["outcome"].getStr() == "fast_forwarded"
        check e["action"].getStr() == "fast_forward"
        check e["headBefore"].getStr() == before
        check e["headAfter"].getStr() == before

      # The text form says what WOULD happen, and flags the summary.
      let text = invokeSync(fx, @["--dry-run"])
      if text.code != 0:
        checkpoint("output: " & text.output)
      check text.code == 0
      check text.output.contains("would fast_forward")
      check text.output.contains("(dry-run)")
      check headSha(gitBin, repoPath) == before
      check gitRev(gitBin, repoPath, "refs/remotes/origin/dev") == fetchedTip
      checkDryRunLeftNoState(fx)

  test "test_sync_mainline_dry_run_does_not_clone_missing_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a repository")
    else:
      let fx = setupFixture(gitBin, "dry-clone", oneRepo)
      defer: removeDirEventually(fx.scratch)
      # Deliberately no clone: `prod` is declared but missing.

      let res = invokeSync(fx, @["--dry-run", "--json"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      check not dirExists(fx.workspaceRoot / "prod")
      checkDryRunLeftNoState(fx)

      let plan = stdoutJson(res.output)
      check plan.kind == JObject
      if plan.kind == JObject:
        check plan.hasKey("dryRun") and plan["dryRun"].getBool()
        let e = entryByName(plan, "prod")
        check e["outcome"].getStr() == "missing_checkout"
        check e["action"].getStr() == "clone"
        check e["headAfter"].getStr() == ""

      let text = invokeSync(fx, @["--dry-run"])
      if text.code != 0:
        checkpoint("output: " & text.output)
      check text.code == 0
      check text.output.contains("would clone")
      check text.output.contains("(dry-run)")
      check not dirExists(fx.workspaceRoot / "prod")
      checkDryRunLeftNoState(fx)

  test "test_sync_mainline_dry_run_plans_rebase_without_integrating":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a repository")
    else:
      let fx = setupFixture(gitBin, "dry-rebase", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      commitLocal(gitBin, repoPath, "mine.txt", "mine\n", "local work")
      let before = headSha(gitBin, repoPath)
      let trunkTip = advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "moved\n")
      # Fetched by hand, so the (non-fetching) plan sees the divergence.
      fetchCheckout(gitBin, repoPath)

      let res = invokeSync(fx, @["--dry-run", "--json", "--rebase"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      check headSha(gitBin, repoPath) == before
      check currentBranch(gitBin, repoPath) == "feature-x"
      check not isAncestor(gitBin, repoPath, trunkTip, "HEAD")
      check not rebaseInProgress(repoPath)
      check isClean(gitBin, repoPath)
      checkDryRunLeftNoState(fx)

      let plan = stdoutJson(res.output)
      check plan.kind == JObject
      if plan.kind == JObject:
        check plan.hasKey("dryRun") and plan["dryRun"].getBool()
        check plan["flavor"].getStr() == "rebase"
        let e = entryByName(plan, "prod")
        check e["outcome"].getStr() == "integrated"
        check e["action"].getStr() == "rebase"
        check e["headAfter"].getStr() == before

      let text = invokeSync(fx, @["--dry-run", "--rebase"])
      if text.code != 0:
        checkpoint("output: " & text.output)
      check text.code == 0
      check text.output.contains("would rebase")
      check text.output.contains("(dry-run)")
      check headSha(gitBin, repoPath) == before

  test "test_sync_mainline_dry_run_exits_zero_on_a_refusal":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a repository")
    else:
      let fx = setupFixture(gitBin, "dry-refusal", oneRepo)
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      let repoPath = fx.workspaceRoot / "prod"
      startFeatureBranch(gitBin, repoPath, "feature-x")
      commitLocal(gitBin, repoPath, "mine.txt", "mine\n", "local work")
      let before = headSha(gitBin, repoPath)
      discard advanceTrunk(gitBin, fx.seedOf("prod"), "dev", "moved\n")
      fetchCheckout(gitBin, repoPath)

      let res = invokeSync(fx, @["--dry-run", "--json"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      # A real run exits 2 here (sub-case 2); a dry run is informational.
      check res.code == 0
      check headSha(gitBin, repoPath) == before
      checkDryRunLeftNoState(fx)

      let plan = stdoutJson(res.output)
      check plan.kind == JObject
      if plan.kind == JObject:
        check plan["exitCode"].getInt() == 0
        let e = entryByName(plan, "prod")
        check e["outcome"].getStr() == "diverged"
        check e["action"].getStr() == "none"
        check e["diagnostic"].getStr().contains("--rebase")

  test "test_sync_mainline_scopes_the_full_active_project_set":
    # Metadata-only workspace: positionals filter the active union, rather
    # than replacing it with the first project. Real upstreams make omitted
    # and accidentally widened selections visible in both reports and HEADs.
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "active-projects", @[
      RepoSpec(name: "prod", mainline: "dev"),
      RepoSpec(name: "specs", mainline: "latest"),
      RepoSpec(name: "infra", mainline: "live"),
      RepoSpec(name: "inactive", mainline: "dev")])
    defer: removeDirEventually(fx.scratch)
    cloneAll(gitBin, fx)
    for i, name in ["group-a", "group-b", "group-c", "inactive-project"]:
      var project = fx
      project.specs = @[fx.specs[i]]
      writeFile(fx.workspaceRoot / "projects" / (name & ".toml"),
        projectToml(project).replace("mainline-sync-fixture", name))
    writeWorkspaceProjects(fx.workspaceRoot,
      @["group-a", "group-b", "group-c"])

    var before, tips: seq[string]
    for s in fx.specs:
      before.add(headSha(gitBin, fx.workspaceRoot / s.name))
      tips.add(advanceTrunk(gitBin, fx.seedOf(s.name), s.mainline, "moved\n"))
      require before[^1] != tips[^1]

    proc scopedSync(projects, extra: seq[string]): CmdResult =
      var argv = @[fx.reproBin, "sync", "--mainline", "--write-report",
        "--workspace-root=" & fx.workspaceRoot]
      argv.add(projects)
      argv.add(extra)
      runShell(shellCommand(argv))

    # --only names an active repo supplied by the SECOND positional project.
    # Both orders must select the same repo, so order cannot hide truncation.
    for projects in [@["group-a", "group-b"], @["group-b", "group-a"]]:
      let preview = scopedSync(projects,
        @["--only=specs", "--dry-run", "--json"])
      checkpoint(preview.output)
      require preview.code == 0
      let report = parseJson(preview.output)
      require report["repos"].len == 1
      check report["repos"][0]["name"].getStr() == "specs"
      for i, s in fx.specs:
        check headSha(gitBin, fx.workspaceRoot / s.name) == before[i]

    # Naming an inactive project must not enable it or widen the active set.
    let inactive = scopedSync(@["group-a", "inactive-project"],
      @["--dry-run", "--json"])
    checkpoint(inactive.output)
    require inactive.code == 0
    let inactiveReport = parseJson(inactive.output)
    require inactiveReport["repos"].len == 1
    check inactiveReport["repos"][0]["name"].getStr() == "prod"

    # Execute the union: the second project reconciles, while the third
    # active project and the inactive project remain untouched.
    let synced = scopedSync(@["group-a", "group-b"], @["--json"])
    checkpoint(synced.output)
    require synced.code == 0
    let report = readReport(fx)
    require report["repos"].len == 2
    for i in 0 .. 1:
      let s = fx.specs[i]
      check entryByName(report, s.name)["mainlineBranch"].getStr() == s.mainline
      check entryByName(report, s.name)["outcome"].getStr() == "fast_forwarded"
      check headSha(gitBin, fx.workspaceRoot / s.name) == tips[i]
    for i in 2 .. 3:
      check headSha(gitBin, fx.workspaceRoot / fx.specs[i].name) == before[i]

    # A single project still narrows a workspace with several active ones.
    let single = scopedSync(@["group-c"], @["--json"])
    checkpoint(single.output)
    require single.code == 0
    require readReport(fx)["repos"].len == 1
    check headSha(gitBin, fx.workspaceRoot / "infra") == tips[2]
    check headSha(gitBin, fx.workspaceRoot / "inactive") == before[3]

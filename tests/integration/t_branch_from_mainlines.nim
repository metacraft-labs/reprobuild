## WV-7 — ``repro branch <path> --from-mainlines`` takes the repo SET from the
## workspace it is run in and the STARTING COMMIT of every repo from that
## repo's manifest-declared mainline.
##
## The flag exists because those two things are separable and every other route
## conflates them: joining the workspace again from its URL gets mainline
## commits but re-derives membership, and forking normally then running
## ``repro switch --mainline`` in the new workspace lands every repo ON trunk
## rather than on the feature branch. See ``reprobuild-specs/CLI/branch.md``
## §"``--from-mainlines``" and the WV-7 milestone in
## ``reprobuild-specs/Workspace-Management.milestones.org``.
##
## Sub-cases:
##
##   1. ``test_wv7_from_mainlines_cuts_from_mainline_not_source_head`` — the
##      happy path and the central falsification. The source checkouts sit on a
##      feature branch with a local-only commit; the fork's repos land at the
##      MAINLINE tips instead, one per repo (`dev` for lib-a, `latest` for
##      lib-b — heterogeneous within one run), with a repo that has no source
##      checkout at all cut from its mainline too. The repo SET still comes
##      from the source workspace, the root repo is cut from its own mainline,
##      the report records ``mainline_head`` + ``mainlineBranch``, and the
##      source workspace is provably untouched. The unpublished source HEAD
##      does NOT refuse the run, because no source HEAD is propagated.
##   2. ``test_wv7_fetch_default_refreshes_the_mainline`` — a commit pushed to
##      the mainline AFTER the source workspace last fetched is the branch
##      point under the default ``--fetch``, and is deliberately NOT under
##      ``--no-fetch`` (which cuts from the ref already on disk). The pair is
##      what makes "--fetch is the default" a claim rather than a comment.
##   3. ``test_wv7_undeclared_mainline_refuses_before_creating_anything`` — a
##      fragment that declares no ``branch``, whose ``revision`` is a pin, in a
##      project with no ``trunk``: exit 2, ``mainline_undeclared``, and the
##      destination directory does not exist afterwards. No ``origin/HEAD``
##      inference.
##   4. ``test_wv7_unresolvable_mainline_names_fetch`` — a declared mainline
##      with no remote-tracking ref refuses (``mainline_unresolved``) and, on a
##      ``--no-fetch`` run, names ``--fetch`` as the remedy.
##   5. ``test_wv7_from_mainlines_and_existing_branch_contradict`` — the two
##      flags fix the branch point in incompatible ways; exit 2, nothing
##      created.
##   6. ``test_wv7_fetch_requires_from_mainlines`` — ``--fetch`` / ``--no-fetch``
##      on their own would be a flag that silently does nothing, so they are a
##      usage error without ``--from-mainlines``.
##
## Real components (NO mocks): the real ``git`` binary, real bare repos on the
## real filesystem, and the real engine-built ``build/bin/repro`` spawned as a
## subprocess. The only substitution is local bare repos + ``file://`` URLs
## standing in for network remotes, which keeps the test hermetic (no network)
## — the same convention every workspace integration test uses.
##
## Falsifiability:
##   - If ``--from-mainlines`` fell through to the source HEAD, case 1's
##     per-repo SHA assertions fail (the source HEAD is a local-only commit the
##     mainline does not carry).
##   - If the mainline were inferred from ``origin/HEAD`` rather than read from
##     the manifest, case 1 would cut lib-b from `main` instead of `latest`,
##     and case 3 would succeed instead of refusing.
##   - If the fetch phase were skipped (or ``--no-fetch`` ignored), the two
##     halves of case 2 would report the same SHA.
##   - If the publication pre-flight still ran, case 1 would refuse with
##     ``source_head_unpublished`` instead of forking.
##   - If either flag guard regressed, cases 5 and 6 would materialize a
##     workspace or exit 0.
##
## Skip rule: ``git`` missing on PATH (same convention as M9–M16 / WV-6).

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

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
    " config user.name \"WV-7 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch: string): string =
  ## Bare origin whose ONLY branch is ``branch`` (the repo's mainline), plus a
  ## seeded working clone pushed to it. Returns the mainline tip SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "WV-7 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(fileUrl(originPath)))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc pushMainlineCommit(gitBin, originPath, scratch, slug, branch: string):
    string =
  ## Advance the ORIGIN's mainline by one commit, through a throwaway clone the
  ## workspace knows nothing about. Returns the new tip SHA.
  let workPath = scratch / ("advance-" & slug)
  removeDir(workPath)
  discard requireGit(q(gitBin) & " clone --branch " & branch & " " &
    q(fileUrl(originPath)) & " " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "ADVANCED.md", "moved on\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m 'mainline moves on'")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc commitLocalOnly(gitBin, repoPath, branch: string): string =
  ## Put the checkout on a feature branch carrying a commit that exists nowhere
  ## else. Under the DEFAULT fork this is what would be propagated (and what
  ## ``--unpublished`` guards); ``--from-mainlines`` must ignore it entirely.
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " switch -c " & branch)
  writeFile(repoPath / "LOCAL.md", "local only\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m 'local only'")
  result = headSha(gitBin, repoPath)

proc projectToml(libAUrl, libBUrl, libCUrl: string): string =
  ## Deliberately declares NO ``trunk``: every repo's mainline must come from
  ## its own fragment, which is what makes the heterogeneous case real.
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"wv7\"\n" &
  "default_revision = \"dev\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" & libCUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/lib-a.toml\",\n" &
  "  \"repos/lib-b.toml\",\n" &
  "  \"repos/lib-c.toml\",\n" &
  "]\n"

proc fragmentToml(name, remote, branch: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"" & branch & "\"\n" &
  "branch = \"" & branch & "\"\n"

type
  Wv7Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    rootBare: string
    libAOrigin: string
    libBOrigin: string
    libCOrigin: string
    libAMainline: string   ## `dev` tip at setup time
    libBMainline: string   ## `latest` tip at setup time
    libCMainline: string   ## `dev` tip at setup time (no source checkout)

proc setupFixture(gitBin, slug: string): Wv7Fixture =
  ## A source workspace cloned from a root workspace repo (the shape
  ## ``repro workspace init`` produces). lib-a's mainline is ``dev`` and
  ## lib-b's is ``latest`` — heterogeneous on purpose. lib-c is DECLARED but
  ## never checked out in the source, so the absent-source path is exercised by
  ## the same run. The refusal cases rewrite a fragment in the source
  ## workspace's own manifests afterwards, which is where the fork reads them.
  result.scratch = createTempDir("repro-wv7-mainlines-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libBOrigin = result.scratch / "origin-lib-b.git"
  result.libCOrigin = result.scratch / "origin-lib-c.git"
  result.libAMainline = seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a", branch = "dev")
  result.libBMainline = seedGitOrigin(gitBin, result.libBOrigin,
    result.scratch / "seed-lib-b", branch = "latest")
  result.libCMainline = seedGitOrigin(gitBin, result.libCOrigin,
    result.scratch / "seed-lib-c", branch = "dev")

  result.rootBare = result.scratch / "origin-repro-workspace.git"
  seedBareWithFiles(gitBin, result.scratch, result.rootBare, [
    ("projects/wv7.toml", projectToml(
      fileUrl(result.libAOrigin), fileUrl(result.libBOrigin),
      fileUrl(result.libCOrigin))),
    ("repos/lib-a.toml", fragmentToml("lib-a", "lib-a-origin", "dev")),
    ("repos/lib-b.toml", fragmentToml("lib-b", "lib-b-origin", "latest")),
    ("repos/lib-c.toml", fragmentToml("lib-c", "lib-c-origin", "dev")),
  ])

  result.workspaceRoot = result.scratch / "source-workspace"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(result.rootBare)) &
    " " & q(result.workspaceRoot))
  gitConfig(gitBin, result.workspaceRoot)
  for (name, origin, branch) in [("lib-a", result.libAOrigin, "dev"),
                                 ("lib-b", result.libBOrigin, "latest")]:
    discard requireGit(q(gitBin) & " clone --branch " & branch & " " &
      q(fileUrl(origin)) & " " & q(result.workspaceRoot / name))
    gitConfig(gitBin, result.workspaceRoot / name)
  writeWorkspaceBranch(result.workspaceRoot, project = "wv7", branch = "main")

proc invokeFork(fx: Wv7Fixture; branch, path: string;
                extra: seq[string] = @[]): CmdResult =
  var argv = @[fx.reproBin, "branch", "--write-report", path,
               "--branch=" & branch,
               "--workspace-root=" & fx.workspaceRoot]
  for e in extra:
    argv.add(e)
  runShell(shellCommand(argv))

proc readReport(root: string): JsonNode =
  let reportPath = root / ".repro" / "build" / "reports" / "branch-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc entryByPath(report: JsonNode; path: string): JsonNode =
  for entry in report["repos"]:
    if entry["path"].getStr() == path:
      return entry
  newJNull()

suite "WV-7 — repro branch --from-mainlines":

  test "test_wv7_from_mainlines_cuts_from_mainline_not_source_head":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "happy")
      defer: removeDirEventually(fx.scratch)

      # Both source checkouts move OFF their mainline onto a feature branch
      # carrying a commit no remote has. Under the default fork this is exactly
      # what would be propagated (and refused by ``--unpublished``); here it
      # must be ignored.
      let srcShaA = commitLocalOnly(gitBin, fx.workspaceRoot / "lib-a",
        "old-work")
      let srcShaB = commitLocalOnly(gitBin, fx.workspaceRoot / "lib-b",
        "old-work")
      check srcShaA != fx.libAMainline
      check srcShaB != fx.libBMainline
      check not dirExists(fx.workspaceRoot / "lib-c")

      let forkPath = fx.scratch / "next-task"
      let res = invokeFork(fx, "feature-y", forkPath, @["--from-mainlines"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # Every repo is ON the new branch, AT its own mainline tip — not at the
      # source HEAD, and not all at one branch's tip.
      for (name, tip) in [("lib-a", fx.libAMainline),
                          ("lib-b", fx.libBMainline),
                          ("lib-c", fx.libCMainline)]:
        check dirExists(forkPath / name / ".git")
        check currentBranch(gitBin, forkPath / name) == "feature-y"
        check headSha(gitBin, forkPath / name) == tip
      check headSha(gitBin, forkPath / "lib-a") != srcShaA
      check headSha(gitBin, forkPath / "lib-b") != srcShaB

      # The root workspace repo is branched too, from ITS mainline.
      check currentBranch(gitBin, forkPath) == "feature-y"

      let recorded = readWorkspaceBranch(forkPath)
      check recorded.isSome
      check recorded.get() == "feature-y"
      check readWorkspaceFeatureStarted(forkPath)

      # Report: provenance is auditable per repo, and the publication question
      # was never asked (no source HEAD was propagated).
      let report = readReport(forkPath)
      check report["exitCode"].getInt() == 0
      check report["form"].getStr() == "fork"
      for (name, mainline) in [("lib-a", "dev"), ("lib-b", "latest"),
                               ("lib-c", "dev")]:
        let entry = entryByPath(report, name)
        check entry["outcome"].getStr() == "branched_from_mainline"
        check entry["baselineSource"].getStr() == "mainline_head"
        check entry["mainlineBranch"].getStr() == mainline
        check entry["publication"].getStr() == ""
      check entryByPath(report, ".")["baselineSource"].getStr() ==
        "mainline_head"

      # The SOURCE workspace kept its feature branch, its local-only commit,
      # and gained no branch of its own.
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "old-work"
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == srcShaA
      check currentBranch(gitBin, fx.workspaceRoot / "lib-b") == "old-work"
      check headSha(gitBin, fx.workspaceRoot / "lib-b") == srcShaB
      check not dirExists(fx.workspaceRoot / "lib-c")

  test "test_wv7_fetch_default_refreshes_the_mainline":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "fetch")
      defer: removeDirEventually(fx.scratch)

      # The mainline moves after the source workspace was cloned. The source
      # checkout has never seen this commit.
      let advanced = pushMainlineCommit(gitBin, fx.libAOrigin, fx.scratch,
        "lib-a", "dev")
      check advanced != fx.libAMainline

      # --no-fetch cuts from the ref already on disk: the OLD tip.
      let stalePath = fx.scratch / "stale-fork"
      let staleRes = invokeFork(fx, "feature-stale", stalePath,
        @["--from-mainlines", "--no-fetch"])
      if staleRes.code != 0:
        checkpoint("output: " & staleRes.output)
      check staleRes.code == 0
      check headSha(gitBin, stalePath / "lib-a") == fx.libAMainline

      # The default (--fetch) refreshes it first and lands on the NEW tip.
      let freshPath = fx.scratch / "fresh-fork"
      let freshRes = invokeFork(fx, "feature-fresh", freshPath,
        @["--from-mainlines"])
      if freshRes.code != 0:
        checkpoint("output: " & freshRes.output)
      check freshRes.code == 0
      check headSha(gitBin, freshPath / "lib-a") == advanced

      # And the refresh did not move the SOURCE checkout off its own branch.
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "dev"
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == fx.libAMainline

  test "test_wv7_undeclared_mainline_refuses_before_creating_anything":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "undeclared")
      defer: removeDirEventually(fx.scratch)

      # lib-b now declares no ``branch``, and its ``revision`` is an exact
      # commit rather than a branch name. The project declares no ``trunk``, so
      # there is nothing to read — and ``origin/HEAD`` must NOT be inferred.
      writeFile(fx.workspaceRoot / "repos" / "lib-b.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\n" &
        "name = \"lib-b\"\n" &
        "path = \"lib-b\"\n" &
        "remote = \"lib-b-origin\"\n" &
        "revision = \"" & fx.libBMainline & "\"\n")

      let forkPath = fx.scratch / "never-created"
      let res = invokeFork(fx, "feature-z", forkPath, @["--from-mainlines"])
      check res.code == 2
      check not dirExists(forkPath)

      let report = readReport(fx.workspaceRoot)
      check report["exitCode"].getInt() == 2
      let entry = entryByPath(report, "lib-b")
      check entry["outcome"].getStr() == "mainline_undeclared"
      check entry["diagnostic"].getStr().contains("branch")

  test "test_wv7_unresolvable_mainline_names_fetch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "unresolved")
      defer: removeDirEventually(fx.scratch)

      # Point lib-b's fragment at a branch that exists nowhere by rewriting the
      # manifest in the source workspace's root repo (the membership manifests
      # live there, and the fork reads them from the source).
      writeFile(fx.workspaceRoot / "repos" / "lib-b.toml",
        fragmentToml("lib-b", "lib-b-origin", "no-such-mainline"))

      let forkPath = fx.scratch / "never-created"
      let res = invokeFork(fx, "feature-z", forkPath,
        @["--from-mainlines", "--no-fetch"])
      check res.code == 2
      check not dirExists(forkPath)

      let report = readReport(fx.workspaceRoot)
      let entry = entryByPath(report, "lib-b")
      check entry["outcome"].getStr() == "mainline_unresolved"
      check entry["mainlineBranch"].getStr() == "no-such-mainline"
      check entry["diagnostic"].getStr().contains("--fetch")

  test "test_wv7_from_mainlines_and_existing_branch_contradict":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "conflict")
      defer: removeDirEventually(fx.scratch)

      let forkPath = fx.scratch / "never-created"
      let res = invokeFork(fx, "feature-z", forkPath,
        @["--from-mainlines", "--existing-branch"])
      check res.code == 2
      check not dirExists(forkPath)
      check res.output.contains("--from-mainlines")
      check res.output.contains("--existing-branch")

  test "test_wv7_fetch_requires_from_mainlines":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "lonely-fetch")
      defer: removeDirEventually(fx.scratch)

      let forkPath = fx.scratch / "never-created"
      let res = invokeFork(fx, "feature-z", forkPath, @["--no-fetch"])
      check res.code != 0
      check not dirExists(forkPath)
      check res.output.contains("--from-mainlines")

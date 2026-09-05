## F0.3 — ``repro branch`` must not silently fork a workspace that cannot push.
##
## The defect this file gates against, from
## ``reprobuild-specs/ReproOS-Attestation-Execution.milestones.org`` §F0.3:
## the fork form cuts each new branch at the source workspace's per-repo
## committed HEAD, including repos sitting on unpushed feature branches, and
## names every new branch after the destination directory. When such a HEAD is
## on no remote, the resulting workspace fails ``repro check --mode=pre-push``
## from the moment it exists — that gate requires a published HEAD in every
## repo of the PUSHED repo's transitive develop-set closure, so one carried
## commit refuses every push whose closure reaches it, in repos the operator
## never touched. On 2026-09-03 six repos arrived that way and nothing warned,
## because the shared bare cache had the objects and the clone succeeded.
##
## Cases (each is a named gate in the milestone):
##
##   1. ``t_branch_refuses_unpublished_source_by_default`` — a source repo on
##      an unpushed commit refuses the fork (exit 2) BEFORE anything is
##      created, and the diagnostic names the repo, its source branch, its
##      commit and all three policies.
##   2. ``t_branch_carry_preserves_attribution`` — ``--unpublished=carry``
##      forks, and the SOURCE BRANCH NAME survives into the new workspace as a
##      local ref at the carried commit (plus ``sourceBranch`` in the report).
##      Without it the commits would exist only on a branch named after the
##      destination directory, which is what made the original incident take
##      reflog archaeology to reconstruct.
##   3. ``t_branch_clean_source_is_unaffected`` — the ordinary case gains no
##      refusal, no flag and no changed outcome. This matters as much as the
##      other two: a safety check that fires on healthy input gets disabled by
##      its users.
##   4. ``t_branch_fetch_resolves_apparently_unpublished_head`` — a HEAD that
##      IS on the repo's remote but which this checkout has not fetched (the
##      ``nim-langserver`` row of the milestone's table, whose stale remote a
##      fetch resolved) must NOT be reported as unpublished. Detection that
##      cannot tell "nobody fetched it" from "it exists nowhere" is noisy
##      enough to get turned off.
##   5. ``t_branch_declared_policy_starts_from_manifest_revision`` — the third
##      policy: those repos start at their manifest-declared revision and the
##      unpublished work stays behind in the source.
##
## Real components (NO mocks): the real ``git`` binary, real bare repos on the
## real filesystem, and the real engine-built ``build/bin/repro`` spawned as a
## subprocess. Local bares + ``file://`` URLs stand in for network remotes,
## which is the convention every workspace integration test in this tree uses
## and is what keeps the run hermetic. The fixture shape is deliberately the
## same as ``t_branch_forks_new_workspace_on_feature_branch.nim``'s.
##
## Falsifiability:
##   - Restore the pre-F0.3 behaviour (no publication probe) and case 1 exits 0
##     with a materialized workspace; cases 2/5 lose their distinct outcomes.
##   - Drop the attribution branch and case 2 fails on the source-branch ref.
##   - Judge publication WITHOUT the fetch (``allowFetch = false``) and case 4
##     refuses a perfectly publishable fork.
##   - Make the check fire unconditionally and case 3 fails.
##
## Skip rule: ``git`` missing on PATH (same convention as the M9–M27 tests).

import std/[json, os, osproc, strutils, tempfiles]

import ct_test_unittest_parallel
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
    " config user.name \"F0.3 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "F0.3 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(fileUrl(originPath)))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
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

proc branchSha(gitBin, repoPath, branch: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse --verify --quiet refs/heads/" & branch)
  if res.code != 0: "" else: res.output.strip()

proc projectTomlWith2Remotes(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/lib-a.toml\",\n" &
  "  \"repos/lib-b.toml\",\n" &
  "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    rootBare: string
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string): Fixture =
  ## A source workspace that is a real clone of a root workspace repo — the
  ## shape ``repro workspace init`` produces and the shape the fork form needs.
  result.scratch = createTempDir("repro-f03-branch-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, result.libBOrigin,
    result.scratch / "seed-lib-b")

  result.rootBare = result.scratch / "origin-repro-workspace.git"
  seedBareWithFiles(gitBin, result.scratch, result.rootBare, [
    ("projects/lib-a.toml", projectTomlWith2Remotes(
      fileUrl(result.libAOrigin), fileUrl(result.libBOrigin))),
    ("repos/lib-a.toml", libAFragmentToml),
    ("repos/lib-b.toml", libBFragmentToml),
  ])

  result.workspaceRoot = result.scratch / "source-workspace"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(result.rootBare)) &
    " " & q(result.workspaceRoot))
  gitConfig(gitBin, result.workspaceRoot)
  for (name, origin) in [("lib-a", result.libAOrigin),
                         ("lib-b", result.libBOrigin)]:
    discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
      q(result.workspaceRoot / name))
    gitConfig(gitBin, result.workspaceRoot / name)
  writeWorkspaceBranch(result.workspaceRoot, project = "lib-a", branch = "main")

proc commitLocalOnly(gitBin, repoPath, fileName, branch: string): string =
  ## Put ``repoPath`` on ``branch`` and add a commit that is pushed nowhere.
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " checkout -b " &
    branch)
  writeFile(repoPath / fileName, "unpublished work\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add " & q(fileName))
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"local only\"")
  result = headSha(gitBin, repoPath)

proc invokeFork(fx: Fixture; branch, path: string;
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

suite "F0.3 — repro branch and unpublished source HEADs":

  test "t_branch_refuses_unpublished_source_by_default":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "refuse")
      defer: removeDirEventually(fx.scratch)

      let localSha = commitLocalOnly(gitBin, fx.workspaceRoot / "lib-a",
        "local-only.txt", "migrate-to-self-hosted-runners")
      let forkPath = fx.scratch / "feature-workspace"

      let res = invokeFork(fx, "feature-x", forkPath)
      checkpoint("output: " & res.output)
      # Refused, not merely warned about.
      check res.code == 2
      # BEFORE creating anything: no destination workspace exists at all.
      check not dirExists(forkPath)

      # The refusal report lands in the SOURCE workspace (there is no target
      # to put it in) and names the repo, the branch and the commit.
      let report = readReport(fx.workspaceRoot)
      check report["exitCode"].getInt() == 2
      let libA = entryByPath(report, "lib-a")
      check libA["outcome"].getStr() == "source_head_unpublished"
      check libA["publication"].getStr() == "unpublished"
      check libA["sourceBranch"].getStr() == "migrate-to-self-hosted-runners"
      check libA["headSha"].getStr() == localSha
      let diag = libA["diagnostic"].getStr()
      check "migrate-to-self-hosted-runners" in diag
      check "--unpublished=carry" in diag
      check "--unpublished=declared" in diag
      check "pre-push" in diag

      # lib-b was fine and is reported as such rather than being tarred with
      # lib-a's brush.
      check entryByPath(report, "lib-b")["publication"].getStr() == "published"

      # The SOURCE workspace is untouched: same branch, same HEAD.
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") ==
        "migrate-to-self-hosted-runners"
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == localSha

  test "t_branch_carry_preserves_attribution":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "carry")
      defer: removeDirEventually(fx.scratch)

      let localSha = commitLocalOnly(gitBin, fx.workspaceRoot / "lib-a",
        "local-only.txt", "fix-python-entry-step-definition-line")
      let forkPath = fx.scratch / "feature-workspace"

      let res = invokeFork(fx, "feature-x", forkPath,
        @["--unpublished=carry"])
      checkpoint("output: " & res.output)
      check res.code == 0

      # The work came across, on the workspace branch, at the same commit.
      check headSha(gitBin, forkPath / "lib-a") == localSha
      check fileExists(forkPath / "lib-a" / "local-only.txt")
      check currentBranch(gitBin, forkPath / "lib-a") == "feature-x"

      # ATTRIBUTION: the originating branch name survives into the new
      # workspace, pointing at the carried commit. Without this the commits
      # exist only under a name derived from the destination directory.
      check branchSha(gitBin, forkPath / "lib-a",
        "fix-python-entry-step-definition-line") == localSha

      # ... and it is recorded in the report too, so an audit does not depend
      # on the ref still being there.
      let report = readReport(forkPath)
      let libA = entryByPath(report, "lib-a")
      check libA["outcome"].getStr() == "branched"
      check libA["publication"].getStr() == "unpublished"
      check libA["sourceBranch"].getStr() ==
        "fix-python-entry-step-definition-line"
      check libA["baselineSource"].getStr() == "source_head"

      # A published repo gets no spurious attribution branch.
      check branchSha(gitBin, forkPath / "lib-b", "main") != ""
      check entryByPath(report, "lib-b")["publication"].getStr() == "published"

  test "t_branch_clean_source_is_unaffected":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean")
      defer: removeDirEventually(fx.scratch)

      let shaA = headSha(gitBin, fx.workspaceRoot / "lib-a")
      let shaB = headSha(gitBin, fx.workspaceRoot / "lib-b")
      let forkPath = fx.scratch / "feature-workspace"

      # No policy flag. The healthy case must not need one.
      let res = invokeFork(fx, "feature-x", forkPath)
      checkpoint("output: " & res.output)
      check res.code == 0

      for (name, sha) in [("lib-a", shaA), ("lib-b", shaB)]:
        check currentBranch(gitBin, forkPath / name) == "feature-x"
        check headSha(gitBin, forkPath / name) == sha

      let report = readReport(forkPath)
      check report["exitCode"].getInt() == 0
      for name in ["lib-a", "lib-b"]:
        let entry = entryByPath(report, name)
        check entry["outcome"].getStr() == "branched"
        check entry["publication"].getStr() == "published"
        check entry["diagnostic"].getStr() == ""

      # Nothing about the healthy path mentions the new machinery: no
      # refusal, no advice, and no fetch announcement on the way through.
      check "unpublished" notin res.output
      check "fetching their remotes" notin res.output

  test "t_branch_fetch_resolves_apparently_unpublished_head":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "fetchresolves")
      defer: removeDirEventually(fx.scratch)

      # The ``nim-langserver`` row of the F0.3 table: the commit IS on the
      # repo's remote — this checkout has simply never fetched it. Build
      # exactly that: commit, publish the commit by pushing to the remote's
      # URL (pushing to a URL rather than to the remote NAME updates no
      # remote-tracking ref), and leave the stale ``origin/main`` in place.
      #
      # Note the publication predicate is scoped to the repo's DECLARED remote,
      # exactly as `repro check --mode=pre-push` scopes it. That is deliberate:
      # a commit reachable only through some other remote would still be
      # refused by the gate, so a fork that accepted it would be handing the
      # operator a workspace the gate rejects. "Unfetched" is about staleness
      # of the ref, not about which remote is asked.
      let libA = fx.workspaceRoot / "lib-a"
      let sha = commitLocalOnly(gitBin, libA, "elsewhere.txt", "codetracer")
      discard requireGit(q(gitBin) & " -C " & q(libA) & " push " &
        q(fileUrl(fx.libAOrigin)) & " HEAD:refs/heads/main")

      # Precondition: with nothing fetched, the raw predicate says "not on any
      # remote-tracking branch" — i.e. this IS the shape that would be
      # misreported by a check that judges before fetching.
      check requireGit(q(gitBin) & " -C " & q(libA) &
        " branch -r --contains HEAD").strip() == ""

      let forkPath = fx.scratch / "feature-workspace"
      let res = invokeFork(fx, "feature-x", forkPath)
      checkpoint("output: " & res.output)
      # NOT refused: a fetch resolves it, so it is not the unpublished
      # condition at all.
      check res.code == 0
      check headSha(gitBin, forkPath / "lib-a") == sha

      let report = readReport(forkPath)
      let entry = entryByPath(report, "lib-a")
      check entry["outcome"].getStr() == "branched"
      check entry["publication"].getStr() == "published_after_fetch"
      # And no attribution branch: nothing was carried that was not already
      # published under its own name.
      check branchSha(gitBin, forkPath / "lib-a", "codetracer") == ""

  test "t_branch_declared_policy_starts_from_manifest_revision":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "declared")
      defer: removeDirEventually(fx.scratch)

      let publishedSha = headSha(gitBin, fx.workspaceRoot / "lib-a")
      let localSha = commitLocalOnly(gitBin, fx.workspaceRoot / "lib-a",
        "local-only.txt", "live")
      check localSha != publishedSha
      let forkPath = fx.scratch / "feature-workspace"

      let res = invokeFork(fx, "feature-x", forkPath,
        @["--unpublished=declared"])
      checkpoint("output: " & res.output)
      check res.code == 0

      # The new workspace starts lib-a where the MANIFEST says, not where the
      # source happened to be, and the unpublished work did not come across.
      check headSha(gitBin, forkPath / "lib-a") == publishedSha
      check not fileExists(forkPath / "lib-a" / "local-only.txt")
      check currentBranch(gitBin, forkPath / "lib-a") == "feature-x"

      let entry = entryByPath(readReport(forkPath), "lib-a")
      check entry["outcome"].getStr() == "branched_from_declared_baseline"
      check entry["baselineSource"].getStr() == "declared_checkout"

      # The source keeps its work — ``declared`` leaves it behind, it does not
      # discard it.
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == localSha
      check fileExists(fx.workspaceRoot / "lib-a" / "local-only.txt")

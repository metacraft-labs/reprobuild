## ``repro switch --mainline`` and the ``--fetch`` / ``--no-fetch`` axis.
##
## Drives the compiled ``repro`` binary against hermetic three-repo workspaces
## whose fragments declare DIFFERENT tracking branches, which is the whole
## point of ``--mainline``: in a real workspace the mainline is `dev` for
## product repos, `latest` for spec repos and `live` for infra, so a single
## branch name cannot express "put me back on trunk".
##
## Sub-cases (each its own ``test_switch_*`` block):
##
##   1. ``test_switch_mainline_sends_each_repo_to_its_declared_branch``
##      Three fragments declaring `dev` / `latest` / `live`; every repo lands
##      on its own, the report's per-entry ``targetBranch`` records which, and
##      ``[workspace].branch`` is deliberately NOT rewritten because no single
##      branch describes the workspace.
##   2. ``test_switch_mainline_refuses_fragment_without_branch``
##      A revision-only fragment has no ``branch`` to target — exit 2, named
##      with its fragment path, nothing mutated.
##   3. ``test_switch_mainline_rejects_branch_positional``
##      ``--mainline dev`` is a usage error, not a precedence question.
##   4. ``test_switch_fetch_by_default_fast_forwards_behind_branch``
##      The remote moved after cloning; the default fetch picks it up and the
##      repo is reported ``fast_forwarded`` with HEAD at the new tip.
##   5. ``test_switch_no_fetch_leaves_behind_branch_untouched``
##      Same fixture with ``--no-fetch``: the switch succeeds but HEAD stays
##      at the stale commit, proving the axis actually controls something.
##   6. ``test_switch_refuses_diverged_branch_instead_of_repointing``
##      Local and remote both moved. `switch` REFUSES (exit 2) and leaves the
##      local commit reachable — it must never `checkout -B` the branch to the
##      remote tip the way the ungated `pull` path once did.
##
## No mocks: real git repositories on the real filesystem, driven through the
## real `repro` binary. Skip rule: ``git`` missing on PATH.

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

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
  RepoSeed = object
    name: string
    origin: string
    seedPath: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    seeds: seq[RepoSeed]

proc seedOrigin(gitBin, originPath, workPath, branch: string) =
  ## Seed a bare origin whose primary branch is ``branch``, with one commit.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Switch Tester\"")
  writeFile(workPath / "README.md", "fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)

proc advanceOrigin(gitBin, seedPath, branch, marker: string): string =
  ## Add a commit on ``branch`` in the seed tree and push it. Returns the SHA.
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " switch " & branch)
  writeFile(seedPath / (marker & ".txt"), marker & "\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " commit -m " & q("advance " & marker))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " push origin " & branch)
  requireGit(q(gitBin) & " -C " & q(seedPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Switch Tester\"")

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc commitReachable(gitBin, repoPath, sha: string): bool =
  ## Is ``sha`` still reachable from SOME ref? The divergence case turns on
  ## this: a repoint would orphan the local commit.
  runCmd(q(gitBin) & " -C " & q(repoPath) &
    " merge-base --is-ancestor " & sha & " HEAD").code == 0

proc projectToml(seeds: seq[RepoSeed]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"mainline-fixture\"\n" &
    "default_revision = \"main\"\n\n"
  for s in seeds:
    result.add("[[remote]]\nname = \"" & s.name & "-origin\"\nfetch = \"" &
      fileUrl(s.origin) & "\"\n\n")
  result.add("includes = [\n")
  for s in seeds:
    result.add("  \"repos/" & s.name & ".toml\",\n")
  result.add("]\n")

proc fragmentToml(name, branch: string; useBranchField: bool): string =
  ## ``useBranchField = false`` writes a revision-only fragment, which is the
  ## shape that leaves ``ResolvedRepo.branch`` empty and so has no
  ## ``--mainline`` target.
  result =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\n"
  if useBranchField:
    result.add("branch = \"" & branch & "\"\n")
  else:
    result.add("revision = \"" & branch & "\"\n")

proc setupFixture(gitBin, slug: string;
                  specs: seq[tuple[name, branch: string;
                                   useBranchField: bool]]): Fixture =
  result.scratch = createTempDir("repro-switch-mainline-" & slug & "-", "")
  result.reproBin = reproBinary()
  for spec in specs:
    var seed = RepoSeed(name: spec.name)
    seed.origin = result.scratch / ("origin-" & spec.name & ".git")
    seed.seedPath = result.scratch / ("seed-" & spec.name)
    seedOrigin(gitBin, seed.origin, seed.seedPath, spec.branch)
    result.seeds.add(seed)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "mainline-fixture.toml",
    projectToml(result.seeds))
  for i, spec in specs:
    writeFile(workspaceRoot / "repos" / (spec.name & ".toml"),
      fragmentToml(spec.name, spec.branch, spec.useBranchField))
  result.workspaceRoot = workspaceRoot

proc cloneAll(gitBin: string; fx: Fixture) =
  for s in fx.seeds:
    cloneInto(gitBin, s.origin, fx.workspaceRoot / s.name)

proc seedMetadata(fx: Fixture; branch: string) =
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "mainline-fixture", branch = branch)

proc invokeSwitch(fx: Fixture; extra: seq[string]): CmdResult =
  var argv = @[fx.reproBin, "switch", "--write-report", "--yes",
    "--workspace-root=" & fx.workspaceRoot]
  argv.add(extra)
  runShell(shellCommand(argv))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "switch-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc entryByName(report: JsonNode; name: string): JsonNode =
  for entry in report["repos"]:
    if entry["name"].getStr() == name:
      return entry
  newJNull()

# ---- the suite -------------------------------------------------------------

suite "repro switch --mainline / --fetch":

  test "test_switch_mainline_sends_each_repo_to_its_declared_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # The heterogeneous case this flag exists for: three repos, three
      # different mainlines, one command.
      let fx = setupFixture(gitBin, "heterogeneous", @[
        (name: "prod", branch: "dev", useBranchField: true),
        (name: "specs", branch: "latest", useBranchField: true),
        (name: "infra", branch: "live", useBranchField: true)])
      defer: removeDirEventually(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadata(fx, "some-feature-branch")

      let res = invokeSwitch(fx, @["--mainline"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      # No single requested branch under --mainline.
      check report["branch"].getStr() == ""

      check entryByName(report, "prod")["targetBranch"].getStr() == "dev"
      check entryByName(report, "specs")["targetBranch"].getStr() == "latest"
      check entryByName(report, "infra")["targetBranch"].getStr() == "live"

      # Each repo was already on its own mainline (that is what `git clone`
      # leaves you on), so this is the no-op arm — the value under test is
      # that each repo was aimed at the RIGHT branch, not that it moved.
      for entry in report["repos"]:
        check entry["outcome"].getStr() == "already_on_branch"

      check currentBranch(gitBin, fx.workspaceRoot / "prod") == "dev"
      check currentBranch(gitBin, fx.workspaceRoot / "specs") == "latest"
      check currentBranch(gitBin, fx.workspaceRoot / "infra") == "live"

      # No single branch describes this workspace, so the metadata is left
      # alone rather than being given a name that fits none of the repos.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "some-feature-branch"

  test "test_switch_mainline_refuses_fragment_without_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ``specs`` is revision-only, so it declares no branch to aim at.
      let fx = setupFixture(gitBin, "no-branch-field", @[
        (name: "prod", branch: "dev", useBranchField: true),
        (name: "specs", branch: "latest", useBranchField: false)])
      defer: removeDirEventually(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadata(fx, "main")

      let res = invokeSwitch(fx, @["--mainline"])
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      let specsEntry = entryByName(report, "specs")
      check specsEntry["outcome"].getStr() == "no_mainline_branch_refused"
      # Principle 2: the diagnostic must name the offending FRAGMENT, since
      # that is the file the operator has to edit.
      check specsEntry["diagnostic"].getStr().contains("specs")
      check specsEntry["diagnostic"].getStr().contains("branch")

      # Refuse-and-report mutated nothing.
      check currentBranch(gitBin, fx.workspaceRoot / "prod") == "dev"

  test "test_switch_mainline_rejects_branch_positional":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "usage", @[
        (name: "prod", branch: "dev", useBranchField: true)])
      defer: removeDirEventually(fx.scratch)
      cloneAll(gitBin, fx)
      seedMetadata(fx, "dev")

      let res = invokeSwitch(fx, @["--mainline", "dev"])
      check res.code != 0
      check res.output.contains("takes no branch positional")

  test "test_switch_fetch_by_default_fast_forwards_behind_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "ff-default", @[
        (name: "prod", branch: "dev", useBranchField: true)])
      defer: removeDirEventually(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadata(fx, "dev")
      let staleSha = headSha(gitBin, fx.workspaceRoot / "prod")

      # The remote moves AFTER the clone — the situation the default exists
      # for. Without a fetch the workspace would look current and build old
      # code.
      let advancedSha = advanceOrigin(gitBin, fx.seeds[0].seedPath,
        "dev", "newer")
      check advancedSha != staleSha

      let res = invokeSwitch(fx, @["--mainline"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check entryByName(report, "prod")["outcome"].getStr() == "fast_forwarded"

      # HEAD actually advanced to the remote tip.
      check headSha(gitBin, fx.workspaceRoot / "prod") == advancedSha
      check currentBranch(gitBin, fx.workspaceRoot / "prod") == "dev"

  test "test_switch_no_fetch_leaves_behind_branch_untouched":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-fetch", @[
        (name: "prod", branch: "dev", useBranchField: true)])
      defer: removeDirEventually(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadata(fx, "dev")
      let staleSha = headSha(gitBin, fx.workspaceRoot / "prod")
      let advancedSha = advanceOrigin(gitBin, fx.seeds[0].seedPath,
        "dev", "newer")
      check advancedSha != staleSha

      let res = invokeSwitch(fx, @["--mainline", "--no-fetch"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      # No fetch, so no fast-forward: the repo is simply already on `dev`.
      check entryByName(report, "prod")["outcome"].getStr() ==
        "already_on_branch"
      # The axis controls something real: HEAD is STILL the stale commit.
      check headSha(gitBin, fx.workspaceRoot / "prod") == staleSha

  test "test_switch_refuses_diverged_branch_instead_of_repointing":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "diverged", @[
        (name: "prod", branch: "dev", useBranchField: true)])
      defer: removeDirEventually(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadata(fx, "dev")
      let repoPath = fx.workspaceRoot / "prod"

      # Local commit the remote does not carry...
      writeFile(repoPath / "local-work.txt", "precious\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " commit -m " & q("unpublished local work"))
      let localSha = headSha(gitBin, repoPath)

      # ...and a remote commit the local branch does not carry. Both moved:
      # this is genuine divergence, not a fast-forward in either direction.
      discard advanceOrigin(gitBin, fx.seeds[0].seedPath, "dev", "remote-side")

      let res = invokeSwitch(fx, @["--mainline"])
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      let entry = entryByName(report, "prod")
      check entry["outcome"].getStr() == "diverged_refused"
      check entry["diagnostic"].getStr().contains("diverged")

      # The whole point: the local commit SURVIVED. A `checkout -B` to the
      # remote tip would have orphaned it.
      check headSha(gitBin, repoPath) == localSha
      check commitReachable(gitBin, repoPath, localSha)
      check fileExists(repoPath / "local-work.txt")

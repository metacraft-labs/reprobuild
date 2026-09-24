## M10 — ``repro workspace sync`` force-push rebase integration test.
##
## CONTRACT NOTE (changed): the rebase is an OPT-IN.
##
## These cases used to drive the rebase with a BARE ``repro sync``, because
## ``--rebase-on-force-push`` defaulted to on. That default is the safety
## defect fixed alongside this edit — it made a plain sync reset every
## checkout whose remote had been rewritten, with no RA-9 preview and no
## confirmation, and (measured on a real workspace) reset twelve of them
## while reporting ``force-reset 0, skipped 0``.
##
## So the rebase is now requested explicitly, with ``--rebase-on-force-push
## --yes``, and what each case asserts about the rebase ITSELF — detection,
## patch-id selection, replay order, no duplication — is unchanged. The
## bare-sync invocation that used to stand in for the opt-in is not dropped:
## it is now asserted to REFUSE, which is the behaviour it should always
## have had. The gating contract in full (preview, confirmation, counting,
## conflict recovery) lives in
## ``t_workspace_sync_does_not_rewrite_a_force_pushed_checkout_unasked.nim``.

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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): tuple[initialSha, firstSha: string] =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M10 Tester\"")
  
  # Initial commit (parent of P0)
  writeFile(workPath / "README.md", "Initial\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m initial")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  let initialSha = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()
  
  # P0 commit
  writeFile(workPath / "p0.txt", "P0 content\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add p0.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"P0 commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  let firstSha = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()
  
  (initialSha: initialSha, firstSha: firstSha)

proc forcePushNewCommit(gitBin, originPath, workPath, baseSha: string;
                        branch = "main"): string =
  # Reset the seed workdir to baseSha (initial commit), make a different commit, and force-push.
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " reset --hard " & q(baseSha))
  writeFile(workPath / "f1.txt", "F1 content\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add f1.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"F1 force pushed commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push --force origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc forcePushRelandingOneLocalCommit(gitBin, originPath, workPath, baseSha,
                                      clonePath, relandSha: string;
                                      branch = "main"): string =
  ## The rewrite shape a real one has: the upstream does NOT merely replace
  ## the tip, it RE-LANDS part of the local work under a new SHA. Here the
  ## seed is reset to ``baseSha``, grows its own commit, then cherry-picks
  ## ``relandSha`` out of the workspace clone — so that commit exists upstream
  ## with a different SHA and a byte-identical patch — and force-pushes.
  ##
  ## Why this matters: after such a rewrite most of what a checkout carries
  ## "ahead" of its remote is already THERE, and replaying it is not merely
  ## redundant, it is fatal — ``git cherry-pick`` of an already-applied commit
  ## produces an empty commit and exits non-zero.
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " reset --hard " &
    q(baseSha))
  writeFile(workPath / "f1.txt", "F1 content\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add f1.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"F1 force pushed commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " fetch " &
    q(clonePath) & " " & branch & ":refs/remotes/work/" & branch)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " cherry-pick " &
    q(relandSha))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push --force origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"M10 Tester\"")

proc appendLocalCommit(gitBin, repoPath, filename, message: string): string =
  writeFile(repoPath / filename, "local divergence\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add " & q(filename))
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m " & q(message))
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

type
  M10Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libOrigin: string
    libSeedPath: string
    initialSha: string
    pushedSha: string # P0

const libFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
"""

proc projectTomlWithRemote(libUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib.toml\",\n" &
    "]\n"

proc setupFixture(gitBin, slug: string): M10Fixture =
  result.scratch = createTempDir("repro-m10-" & slug & "-", "")
  result.reproBin = reproBinary()

  let libOrigin = result.scratch / "origin-lib.git"
  result.libSeedPath = result.scratch / "seed-lib"
  let seeds = seedGitOrigin(gitBin, libOrigin, result.libSeedPath)
  result.initialSha = seeds.initialSha
  result.pushedSha = seeds.firstSha
  result.libOrigin = libOrigin

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectTomlWithRemote(fileUrl(libOrigin)))
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragmentToml)
  result.workspaceRoot = workspaceRoot

proc readReport(fixture: M10Fixture): JsonNode =
  let reportPath = fixture.workspaceRoot / ".repro" / "build" / "reports" /
    "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc getClingoEnv(): seq[tuple[name, value: string]] =
  var clingoLib = getEnv("CLINGO_LIB")
  var zstdLib = getEnv("ZSTD_LIB")
  if (clingoLib.len == 0 or zstdLib.len == 0) and dirExists("/nix/store"):
    for kind, path in walkDir("/nix/store", relative = false):
      if kind == pcDir:
        let name = path.lastPathPart
        if name.contains("clingo-5."):
          clingoLib = path / "lib"
        elif name.contains("zstd-1."):
          zstdLib = path / "lib"
  if clingoLib.len > 0 and zstdLib.len > 0:
    let dyld = clingoLib & ":" & zstdLib
    result.add(("DYLD_LIBRARY_PATH", dyld))
    result.add(("DYLD_FALLBACK_LIBRARY_PATH", dyld))
    result.add(("LD_LIBRARY_PATH", dyld))

proc invokeSync(fixture: M10Fixture; extraArgs: openArray[string] = []): CmdResult =
  var cmdArgs = @[
    fixture.reproBin, "workspace", "sync", "--write-report", "myproject",
    "--workspace-root=" & fixture.workspaceRoot,
  ]
  for arg in extraArgs:
    cmdArgs.add(arg)
  runShell(shellCommand(cmdArgs, env = getClingoEnv()))

proc onlyRepoEntry(report: JsonNode): JsonNode =
  check report["repos"].len == 1
  report["repos"][0]

suite "repro workspace sync (force-push rebase)":

  test "detects force-push and rebases local commits":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      fail()

    let fx = setupFixture(gitBin, "force-push-rebase")
    defer: removeDir(fx.scratch)

    # Clone target to workspace (at P0)
    cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")

    # Create local commits C1, C2 on local main
    discard appendLocalCommit(gitBin, fx.workspaceRoot / "lib", "c1.txt", "local C1")
    discard appendLocalCommit(gitBin, fx.workspaceRoot / "lib", "c2.txt", "local C2")

    # Force-push new history (F1) to remote
    let advancedSha = forcePushNewCommit(gitBin, fx.libOrigin, fx.libSeedPath, fx.initialSha)

    # 1. Run sync with --no-rebase-on-force-push: it must refuse
    let resRefused = invokeSync(fx, ["--no-rebase-on-force-push"])
    checkpoint("resRefused output: " & resRefused.output)
    check resRefused.code == 2

    # Check refused report
    let entryRefused = onlyRepoEntry(readReport(fx))
    check entryRefused["path"].getStr() == "lib"
    check entryRefused["syncCase"].getStr() == "force_push_rebase"
    check entryRefused["action"].getStr() == "none"
    check entryRefused["executionStatus"].getStr() == "refused"

    # 1b. A BARE sync must refuse too. The rebase is an opt-in, so the
    # default and the explicit ``--no-`` spelling agree; before the fix they
    # did not, and the default was the destructive one.
    let resDefault = invokeSync(fx)
    checkpoint("resDefault output: " & resDefault.output)
    check resDefault.code == 2
    let entryDefault = onlyRepoEntry(readReport(fx))
    check entryDefault["syncCase"].getStr() == "force_push_rebase"
    check entryDefault["action"].getStr() == "none"
    check entryDefault["executionStatus"].getStr() == "refused"
    # And it moved nothing: HEAD still carries C1 and C2 over the old base.
    check requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib") &
      " rev-parse HEAD~2").strip() == fx.pushedSha

    # 2. Ask for the rebase explicitly and confirm it (non-TTY, so ``--yes``
    # is what carries the RA-9 confirmation).
    let res = invokeSync(fx, ["--rebase-on-force-push", "--yes"])
    if res.code != 0:
      checkpoint("output: " & res.output)
    check res.code == 0

    # Verify workspace state
    # Check that local commits C1 and C2 were rebased on top of F1
    # HEAD's parent's parent must be F1 (advancedSha)
    let parent2 = requireGit(q(gitBin) & " -C " &
      q(fx.workspaceRoot / "lib") & " rev-parse HEAD~2").strip()
    check parent2 == advancedSha

    # Check sync report
    let entry = onlyRepoEntry(readReport(fx))
    check entry["path"].getStr() == "lib"
    check entry["syncCase"].getStr() == "force_push_rebase"
    check entry["action"].getStr() == "force_push_rebase"
    check entry["forcePushedBaseSha"].getStr() == fx.pushedSha
    check entry["executionStatus"].getStr() == "succeeded"

    # Push the rebased commits to origin to make it clean
    discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib") &
      " push origin main")

    # Subsequent sync should be clean
    let res2 = invokeSync(fx)
    check res2.code == 0
    let entry2 = onlyRepoEntry(readReport(fx))
    check entry2["syncCase"].getStr() == "clean_at_locked_revision"
    check entry2["action"].getStr() == "none"
    check entry2["executionStatus"].getStr() == "noop"

  test "replays only the commits the rewrite did not already re-land":
    ## The recovery must select the commits to replay BY PATCH ID, not by
    ## taking the whole ``<baseSha>..HEAD`` range.
    ##
    ## A real rewrite reshapes history and re-lands most of the local work
    ## upstream under new SHAs. The range then contains commits whose change
    ## is already on the new tip, and ``git cherry-pick`` of such a commit
    ## produces an EMPTY commit and exits non-zero ("The previous cherry-pick
    ## is now empty"). The executor aborts on the first failure, so a range
    ## replay dies on its first already-landed commit and never reaches the
    ## work the operator still owns — the recovery fails precisely in the
    ## situation it was built for. Calibrated against the workspace this was
    ## measured in: ``codetracer-cairo-recorder`` was 210 commits "ahead" of
    ## its rewritten remote and exactly 3 were patch-id-unique.
    ##
    ## Here C1 is re-landed upstream while C2 and C3 are not, so the correct
    ## replay set is {C2, C3} — in that order — and the range {C1, C2, C3} is
    ## both wrong and unrunnable.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      fail()

    let fx = setupFixture(gitBin, "force-push-reland")
    defer: removeDir(fx.scratch)

    let libPath = fx.workspaceRoot / "lib"
    cloneInto(gitBin, fx.libOrigin, libPath)
    let c1 = appendLocalCommit(gitBin, libPath, "c1.txt", "local C1")
    let c2 = appendLocalCommit(gitBin, libPath, "c2.txt", "local C2")
    let c3 = appendLocalCommit(gitBin, libPath, "c3.txt", "local C3")

    let newTip = forcePushRelandingOneLocalCommit(gitBin, fx.libOrigin,
      fx.libSeedPath, fx.initialSha, libPath, c1)

    # THE PREMISE, asserted rather than assumed. If C1 were not genuinely
    # present upstream under a different SHA, this would be re-testing the
    # easy case the test above already covers.
    check newTip != c1
    check newTip != c2
    check newTip != c3
    let upstreamSubjects = requireGit(q(gitBin) & " -C " & q(fx.libSeedPath) &
      " log --format=%s " & q(fx.initialSha & "..HEAD"))
    check "local C1" in upstreamSubjects
    check "local C2" notin upstreamSubjects
    check "local C3" notin upstreamSubjects

    # The rebase is an opt-in (see the contract note at the top of this
    # file); this case is about WHICH commits it replays, so it asks for it.
    let res = invokeSync(fx, ["--rebase-on-force-push", "--yes"])
    if res.code != 0:
      checkpoint("output: " & res.output)
    check res.code == 0

    let entry = onlyRepoEntry(readReport(fx))
    check entry["syncCase"].getStr() == "force_push_rebase"
    check entry["action"].getStr() == "force_push_rebase"
    check entry["executionStatus"].getStr() == "succeeded"

    # Exactly TWO commits were replayed — the ones the rewrite did not
    # re-land — and they sit directly on the new remote tip, oldest first.
    let replayed = requireGit(q(gitBin) & " -C " & q(libPath) &
      " rev-list --count " & q(newTip & "..HEAD")).strip()
    check replayed == "2"
    check requireGit(q(gitBin) & " -C " & q(libPath) &
      " rev-parse HEAD~2").strip() == newTip
    # Order is asserted, not assumed: a selection that replays the unique
    # commits newest-first still lands two commits on the right base.
    check requireGit(q(gitBin) & " -C " & q(libPath) &
      " log -1 --format=%s HEAD").strip() == "local C3"
    check requireGit(q(gitBin) & " -C " & q(libPath) &
      " log -1 --format=%s HEAD~1").strip() == "local C2"

    # And the re-landed commit was NOT duplicated. Counting subjects catches
    # the failure that an ancestry check cannot: a second "local C1" sitting
    # on top of the upstream one would satisfy every SHA relation above.
    let subjects = requireGit(q(gitBin) & " -C " & q(libPath) &
      " log --format=%s").strip().splitLines()
    var c1Count = 0
    var c2Count = 0
    var c3Count = 0
    for line in subjects:
      if line.strip() == "local C1": inc c1Count
      if line.strip() == "local C2": inc c2Count
      if line.strip() == "local C3": inc c3Count
    check c1Count == 1
    check c2Count == 1
    check c3Count == 1
    # Non-vacuity: the log was actually read, and carries the upstream
    # history too (initial + F1 + re-landed C1 + C2 + C3).
    check subjects.len == 5

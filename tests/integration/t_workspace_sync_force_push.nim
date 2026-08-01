## M10 — ``repro workspace sync`` force-push rebase integration test.

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

    # 2. Run workspace sync with default settings (should rebase automatically)
    let res = invokeSync(fx)
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

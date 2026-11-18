## A torn `.repro/workspace/force-pushes.json` must not cost the recovery
## records: reprobuild-pm issue
## 2026-11-12-force-pushes-json-recovery-records-are-lost-on-a-torn-write.
##
## End to end through the real `repro workspace sync`: the workspace already
## carries an unparsable force-pushes.json (a crash mid-write), then the
## remote is force-pushed and sync detects it. Before the fix the unparsable
## file was read as `[]` and the detection write replaced it, destroying the
## earlier records. Now the torn bytes survive in a `.corrupt-*` copy and the
## fresh detection is recorded in a valid new file.
##
## Test-double policy: none; real git remotes, real repro binary.

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
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
mainline = "main"
"""

proc projectTomlWithRemote(libUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "\n" &
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

suite "repro workspace sync (torn force-pushes.json)":

  test "a torn record file is quarantined and the new detection is recorded":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      fail()

    let fx = setupFixture(gitBin, "force-push-torn-record")
    defer: removeDir(fx.scratch)

    cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")
    let wsDir = fx.workspaceRoot / ".repro" / "workspace"
    createDir(wsDir)
    let recordPath = wsDir / "force-pushes.json"
    let torn = "[{\"repo\": \"older\", \"superseded\": \"" &
      repeat('a', 40) & "\"},\n{\"re"
    writeFile(recordPath, torn)

    let newTip = forcePushNewCommit(gitBin, fx.libOrigin, fx.libSeedPath,
      fx.initialSha)
    check newTip != fx.pushedSha

    let res = invokeSync(fx)
    checkpoint("output: " & res.output)

    # The torn bytes are preserved verbatim next to the record file.
    var quarantined: seq[string]
    for f in walkFiles(recordPath & ".corrupt-*"):
      quarantined.add(f)
    check quarantined.len == 1
    if quarantined.len == 1:
      check readFile(quarantined[0]) == torn

    # The detection of THIS run is recorded in a fresh, parsable file.
    check fileExists(recordPath)
    let records = parseFile(recordPath)
    check records.kind == JArray
    var found = false
    for r in records:
      if r{"superseded"}.getStr() == fx.pushedSha:
        found = true
    check found

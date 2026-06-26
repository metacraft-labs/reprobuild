## RA-27 — communicate-before-execute + live progress for `repro workspace
## sync` (Interactive-UX-And-Progress.md Principle 1).
##
## A multi-repo `repro workspace sync` must:
##   (a) ANNOUNCE the plan (which repos / what action) BEFORE the per-repo
##       results — the plan text appears at an EARLIER offset than the
##       summary in the captured output;
##   (b) emit per-repo progress/status for each repo;
##   (c) end with a scannable summary digest;
##   (d) under `--json`, emit a valid machine surface carrying the plan +
##       per-repo results;
##   (e) under `--dry-run`, print the plan and NOT mutate (no fetch/clone
##       side-effects on disk).
##
## Falsifiability (confirmed by hand, then reverted):
##   - removing the plan announcement makes (a)/(b) fail (no plan substring,
##     plan offset no longer precedes the summary);
##   - making `--dry-run` fall through to the real sync makes (e) fail (the
##     advanced upstream is fast-forwarded into the checkout).
##
## Hermetic: local `git init --bare` upstreams; skip when git is absent.

import std/[json, os, osproc, streams, strutils, tempfiles, unittest]

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

proc seedGitOrigin(gitBin, originPath, workPath, branch: string): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA27 Tester\"")
  writeFile(workPath / "README.md", "RA27 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedSecondCommit(gitBin, originPath, workPath, branch: string): string =
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"second commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA27 Tester\"")

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl, bUrl, cUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
    "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
    "[[remote]]\nname = \"c-origin\"\nfetch = \"" & cUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
    "]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

type
  RepoSeed = object
    origin: string
    seedPath: string
    sha: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    a, b, c: RepoSeed

proc seedRepo(gitBin, scratch, name: string): RepoSeed =
  result.origin = scratch / ("origin-" & name & ".git")
  result.seedPath = scratch / ("seed-" & name)
  result.sha = seedGitOrigin(gitBin, result.origin, result.seedPath, "main")

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra27prog-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.a = seedRepo(gitBin, result.scratch, "lib-a")
  result.b = seedRepo(gitBin, result.scratch, "lib-b")
  result.c = seedRepo(gitBin, result.scratch, "lib-c")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(result.a.origin), fileUrl(result.b.origin),
      fileUrl(result.c.origin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml",
    repoFragment("lib-a", "a-origin"))
  writeFile(manifestsRoot / "repos" / "lib-b.toml",
    repoFragment("lib-b", "b-origin"))
  writeFile(manifestsRoot / "repos" / "lib-c.toml",
    repoFragment("lib-c", "c-origin"))
  result.workspaceRoot = workspaceRoot

proc invokeSync(fx: Fixture; extra: openArray[string] = []): CmdResult =
  var argv = @[fx.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fx.workspaceRoot]
  for e in extra: argv.add(e)
  runShell(shellCommand(argv))

proc captureStdoutOnly(argv: openArray[string]): string =
  ## Capture ONLY stdout (no stderr merge) so a `--json` document can be
  ## parsed without progress/diagnostic stderr lines corrupting it.
  let process = startProcess(argv[0], args = @argv[1 .. ^1],
    options = {poUsePath})
  defer: process.close()
  let outStream = process.outputStream
  var buf = ""
  var line = ""
  while outStream.readLine(line):
    buf.add(line)
    buf.add("\n")
  discard process.waitForExit()
  buf

suite "RA-27 — announce plan + live progress + dry-run":

  test "t_long_operations_announce_plan_and_emit_live_progress":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "main")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.a.origin, fx.workspaceRoot / "lib-a")
      cloneInto(gitBin, fx.b.origin, fx.workspaceRoot / "lib-b")
      cloneInto(gitBin, fx.c.origin, fx.workspaceRoot / "lib-c")

      # ---- (e) --dry-run prints the plan and does NOT mutate -------------
      # Advance every upstream so a REAL sync would fast-forward each clone.
      let advancedA = seedSecondCommit(gitBin, fx.a.origin, fx.a.seedPath, "main")
      let advancedB = seedSecondCommit(gitBin, fx.b.origin, fx.b.seedPath, "main")
      let advancedC = seedSecondCommit(gitBin, fx.c.origin, fx.c.seedPath, "main")

      let beforeA = headSha(gitBin, fx.workspaceRoot / "lib-a")
      let beforeB = headSha(gitBin, fx.workspaceRoot / "lib-b")
      let beforeC = headSha(gitBin, fx.workspaceRoot / "lib-c")

      let dry = invokeSync(fx, ["--dry-run"])
      check dry.code == 0
      # The plan is announced — every repo is named with an intended action.
      check dry.output.contains("dry-run")
      check dry.output.contains("lib-a")
      check dry.output.contains("lib-b")
      check dry.output.contains("lib-c")
      # NOT mutated: each clone is still at its pre-sync HEAD (the advanced
      # upstreams were not fast-forwarded in).
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == beforeA
      check headSha(gitBin, fx.workspaceRoot / "lib-b") == beforeB
      check headSha(gitBin, fx.workspaceRoot / "lib-c") == beforeC
      check beforeA != advancedA  # the upstream really did advance
      # A dry run does not write a sync report artifact.
      check not fileExists(fx.workspaceRoot / ".repro" / "workspace" /
        "sync-report.json")

      # ---- (a)/(b)/(c) plan precedes summary; per-repo progress; digest --
      let res = invokeSync(fx)
      check res.code in [0, 2]
      let captured = res.output

      # (a) PLAN is announced and appears BEFORE the per-repo result lines /
      # the summary digest. Drive ordering by comparing string offsets.
      let planIdx = captured.find("workspace sync plan:")
      let summaryIdx = captured.find("workspace sync summary:")
      check planIdx >= 0
      check summaryIdx >= 0
      check planIdx < summaryIdx
      # The plan lists every repo (real repo set, not hardcoded).
      let planSection = captured[planIdx ..< summaryIdx]
      check planSection.contains("lib-a")
      check planSection.contains("lib-b")
      check planSection.contains("lib-c")

      # (b) per-repo progress/status is emitted for each repo (the per-repo
      # result lines after the plan).
      check captured.contains("workspace sync: lib-a")
      check captured.contains("workspace sync: lib-b")
      check captured.contains("workspace sync: lib-c")

      # (c) a final summary digest appears with the counts.
      check captured.contains("workspace sync summary:")
      check captured.contains("updated ")

      # The real sync DID fast-forward (proves dry-run earlier was a true
      # no-op, not a vacuous pass).
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == advancedA
      check headSha(gitBin, fx.workspaceRoot / "lib-b") == advancedB
      check headSha(gitBin, fx.workspaceRoot / "lib-c") == advancedC

      # ---- (d) --json emits a valid machine surface --------------------
      # Capture stdout ONLY so progress/diagnostic stderr cannot corrupt the
      # JSON document.
      let jsonText = captureStdoutOnly(@[fx.reproBin, "workspace", "sync",
        "myproject", "--workspace-root=" & fx.workspaceRoot, "--json"])
      let doc = parseJson(jsonText)
      check doc.hasKey("plan")
      check doc["plan"].len == 3
      check doc.hasKey("repos")
      check doc["repos"].len == 3
      check doc.hasKey("summary")
      check doc["summary"].hasKey("total")
      check doc["summary"]["total"].getInt() == 3
      # The plan entries carry the real repo names + an intended action.
      var planNames: seq[string]
      for entry in doc["plan"]:
        planNames.add(entry["name"].getStr())
        check entry["intendedAction"].getStr() in ["update", "clone"]
      check "lib-a" in planNames
      check "lib-b" in planNames
      check "lib-c" in planNames

## TC-1 — ``repro test`` withholds the certificate (with an ambient remedy)
## when the workspace is NOT in a publishable state.
##
## Principle 2 (Interactive-UX): the tests STILL RUN, but no certificate is
## issued, and the run ends with an actionable message naming the offender and
## the remedy:
##   1. DIRTY working tree → "working tree dirty" + "commit ..." remedy.
##   2. UNPUSHED HEAD       → "unpushed" + "git push" remedy.
##
## In both cases the certificate file is NOT written even though the trivial
## test target passes.
##
## Falsifiability: if issuance were forced in a dirty/unpushed state, the
## "cert file absent" check would fail. See the milestone note.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"TC1 Tester\"")
  writeFile(workPath / "README.md", "TC-1 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"TC1 Tester\"")

proc projectToml(libAUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libASeed: string
    libASha: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-tc1d-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASeed = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, result.libASeed)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.workspaceRoot = workspaceRoot
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc seedLock(fx: Fixture) =
  let res = runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot]))
  if res.code != 0:
    checkpoint("workspace lock failed: " & res.output)
  check res.code == 0

proc writePassingFixture(path, selector: string) =
  var obj = newJObject()
  obj["fallbackBuildCostNs"] = %1
  obj["fallbackTestCostNs"] = %1
  var edges = newJArray()
  var e = newJObject()
  e["id"] = %1
  e["selector"] = %selector
  e["historyKey"] = %selector
  e["buildDeps"] = newJArray()
  var cmd = newJArray()
  cmd.add(%"sh"); cmd.add(%"-c"); cmd.add(%"exit 0")
  e["runCmd"] = cmd
  e["testName"] = %selector
  edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  writeFile(path, obj.pretty() & "\n")

proc runReproTest(fx: Fixture; fixtureJson: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--certify",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a")]),
    fx.workspaceRoot)

proc certPath(fx: Fixture): string =
  defaultCertificatePath(fx.workspaceRoot, fx.libASha, currentPlatformTag())

suite "TC-1 — repro test withholds the certificate on a non-publishable state":

  test "t_repro_test_reports_no_certificate_with_remedy_when_dirty_or_unpushed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # --- case 1: DIRTY working tree --------------------------------------
      block:
        let fx = setupFixture(gitBin, "dirty")
        defer: removeDir(fx.scratch)
        seedLock(fx)
        # Dirty the in-scope repo AFTER locking.
        writeFile(fx.workspaceRoot / "lib-a" / "scratch.txt", "uncommitted\n")

        let fixtureJson = fx.scratch / "fixture.json"
        writePassingFixture(fixtureJson, "t-unit")

        let res = runReproTest(fx, fixtureJson)
        # The trivial target still PASSES (the run executed), so the shard
        # exit code is 0 — the only effect of the dirty state is no cert.
        check res.code == 0
        check (not fileExists(certPath(fx)))
        check res.output.contains("no certificate")
        check res.output.contains("dirty")
        # RA-28 remedy: name a concrete next step (commit / stash).
        check (res.output.contains("commit") or res.output.contains("stash"))

      # --- case 2: UNPUSHED HEAD -------------------------------------------
      block:
        let fx = setupFixture(gitBin, "unpushed")
        defer: removeDir(fx.scratch)
        # Commit a new revision in the in-scope repo but do NOT push it.
        writeFile(fx.workspaceRoot / "lib-a" / "feature.txt", "new\n")
        discard requireGit(q(gitBin) & " -C " &
          q(fx.workspaceRoot / "lib-a") & " add feature.txt")
        discard requireGit(q(gitBin) & " -C " &
          q(fx.workspaceRoot / "lib-a") & " commit -m feature")
        let newSha = requireGit(q(gitBin) & " -C " &
          q(fx.workspaceRoot / "lib-a") & " rev-parse HEAD").strip()

        let fixtureJson = fx.scratch / "fixture.json"
        writePassingFixture(fixtureJson, "t-unit")

        let res = runReproTest(fx, fixtureJson)
        check res.code == 0
        let cp = defaultCertificatePath(
          fx.workspaceRoot, newSha, currentPlatformTag())
        check (not fileExists(cp))
        check res.output.contains("no certificate")
        # Offender named + the ``git push`` remedy surfaced.
        check (res.output.contains("unpushed") or
               res.output.contains("unpublished") or
               res.output.contains("push"))
        check res.output.contains("push")

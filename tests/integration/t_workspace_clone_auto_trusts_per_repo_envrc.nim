## RA-12 — after ``repro workspace init`` / ``pull``, freshly cloned
## shell-hook files (``.envrc``) are auto-trusted by running the activator's
## trust command (``direnv allow <dir>``) for EACH discovered ``.envrc``
## directory: the workspace root (which doubles as the host/org root), and
## every checked-out repo that ships an ``.envrc``. Repos with NO ``.envrc``
## are NOT trusted.
##
## The challenge: real ``direnv`` is usually absent in the sandbox. The
## activator binary is INJECTABLE via the ``REPRO_DIRENV_BIN`` env seam
## (``resolveDirenvBin`` honors it before falling back to ``findExe``). The
## test points it at a FAKE direnv script that appends each ``allow <dir>``
## invocation to a log file, so the auto-trust pass is observable without a
## real direnv.
##
## Fixture (all hermetic local repos via ``file://`` origins):
##   - ``lib-a``: origin ships an ``.envrc`` → after clone, lib-a's tree has
##     one, so it must be trusted.
##   - ``lib-b``: origin has NO ``.envrc`` → must NOT be trusted.
##   - the workspace root gets its OWN ``.envrc`` written directly (the
##     host/org-root hook) → must be trusted.
##
## Assertions:
##   1. With the fake direnv injected, ``init`` succeeds and the fake's log
##      records ``allow`` for the workspace root AND lib-a, but NOT lib-b.
##   2. ``pull`` (the other entry point) behaves identically.
##   3. Graceful skip: with ``REPRO_DIRENV_BIN`` pointed at a NON-EXISTENT
##      path (no activator), ``init`` still SUCCEEDS (exit 0), the fake log
##      is never written, and the report records the skip (no auto-trust,
##      no failure).
##
## Falsifiability:
##   - If the auto-trust pass were absent, the fake direnv would never be
##     invoked → the log assertions (workspace root + lib-a present) fail.
##   - If the pass trusted EVERY repo regardless of ``.envrc`` presence,
##     lib-b would appear in the log → the "lib-b absent" assertion fails.
##   - If a missing activator ABORTED init, the graceful-skip half would see
##     a non-zero exit → that assertion fails.
##
## Skip rule: ``git`` missing on PATH.

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

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA12 Tester\"")

proc seedOrigin(gitBin, originPath, workPath, branch: string;
                withEnvrc: bool): string =
  ## Seed a bare origin on ``branch`` with one commit. When ``withEnvrc`` is
  ## set the committed tree includes an ``.envrc`` shell-hook file. Returns
  ## the tip SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "RA12 fixture\n")
  if withEnvrc:
    writeFile(workPath / ".envrc", "export RA12=1\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl, bUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"dev\"\n" &
  "trunk = \"dev\"\n\n" &
  "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
  "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/lib-a.toml\",\n" &
  "  \"repos/lib-b.toml\",\n" &
  "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "a-origin"
revision = "dev"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "b-origin"
revision = "dev"
"""

proc writeManifest(workspaceRoot, aOrigin, bOrigin: string) =
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(aOrigin), fileUrl(bOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)

proc makeFakeDirenv(scratch, logPath: string): string =
  ## A fake ``direnv`` that records each ``allow <dir>`` invocation to
  ## ``logPath`` (one absolute dir per line) and exits 0. The auto-trust
  ## pass invokes it as ``direnv allow <dir>``; argv[1] is "allow" and
  ## argv[2] is the directory.
  let path = scratch / "fake-direnv.sh"
  writeFile(path,
    "#!/bin/sh\n" &
    "if [ \"$1\" = \"allow\" ]; then\n" &
    "  echo \"$2\" >> " & q(logPath) & "\n" &
    "fi\n" &
    "exit 0\n")
  when not defined(windows):
    setFilePermissions(path, {fpUserExec, fpUserRead, fpUserWrite,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  result = path

proc logLines(logPath: string): seq[string] =
  if not fileExists(logPath):
    return @[]
  for line in readFile(logPath).splitLines():
    if line.strip().len > 0:
      result.add(line.strip())

proc samePathInLog(lines: seq[string]; target: string): bool =
  let want = absolutePath(target)
  for line in lines:
    if absolutePath(line) == want:
      return true
  false

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    aOrigin, bOrigin: string
    aSeed, bSeed: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra12-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.aOrigin = result.scratch / "origin-lib-a.git"
  result.bOrigin = result.scratch / "origin-lib-b.git"
  result.aSeed = result.scratch / "seed-lib-a"
  result.bSeed = result.scratch / "seed-lib-b"
  # lib-a SHIPS an .envrc; lib-b does NOT.
  discard seedOrigin(gitBin, result.aOrigin, result.aSeed, "dev",
    withEnvrc = true)
  discard seedOrigin(gitBin, result.bOrigin, result.bSeed, "dev",
    withEnvrc = false)
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  writeManifest(result.workspaceRoot, result.aOrigin, result.bOrigin)
  # The workspace/host root gets its OWN .envrc (the org-root hook).
  writeFile(result.workspaceRoot / ".envrc", "export RA12_ROOT=1\n")

proc readInitReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" / "init-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc readPullReport(workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "workspace" / "pull-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

suite "RA-12 — auto-trust shell hooks after clone":

  test "t_workspace_clone_auto_trusts_per_repo_envrc":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- init half ----
      block initHalf:
        let fx = setupFixture(gitBin, "init")
        defer: removeDir(fx.scratch)
        let logPath = fx.scratch / "init-allow.log"
        let fakeDirenv = makeFakeDirenv(fx.scratch, logPath)

        let init = runShell(shellCommand(@[
          fx.reproBin, "workspace", "init", "myproject",
          "--workspace-root=" & fx.workspaceRoot,
        ], @[("REPRO_DIRENV_BIN", fakeDirenv)]))
        if init.code != 0:
          checkpoint("init output: " & init.output)
        check init.code == 0

        # Both repos materialised; lib-a ships an .envrc, lib-b does not.
        check dirExists(fx.workspaceRoot / "lib-a")
        check dirExists(fx.workspaceRoot / "lib-b")
        check fileExists(fx.workspaceRoot / "lib-a" / ".envrc")
        check not fileExists(fx.workspaceRoot / "lib-b" / ".envrc")

        # The fake direnv was `allow`-ed for the workspace root AND lib-a,
        # but NOT lib-b (no .envrc there).
        let lines = logLines(logPath)
        check samePathInLog(lines, fx.workspaceRoot)
        check samePathInLog(lines, fx.workspaceRoot / "lib-a")
        check not samePathInLog(lines, fx.workspaceRoot / "lib-b")

        # The report records the same outcome structurally.
        let report = readInitReport(fx.workspaceRoot)
        check report["autoTrust"]["activatorAvailable"].getBool()
        var trustedDirs: seq[string]
        for e in report["autoTrust"]["entries"]:
          check e["status"].getStr() == "trusted"
          trustedDirs.add(absolutePath(e["dir"].getStr()))
        check absolutePath(fx.workspaceRoot) in trustedDirs
        check absolutePath(fx.workspaceRoot / "lib-a") in trustedDirs
        check absolutePath(fx.workspaceRoot / "lib-b") notin trustedDirs

      # ---- pull half (the other entry point) ----
      block pullHalf:
        let fx = setupFixture(gitBin, "pull")
        defer: removeDir(fx.scratch)
        let logPath = fx.scratch / "pull-allow.log"
        let fakeDirenv = makeFakeDirenv(fx.scratch, logPath)

        let pull = runShell(shellCommand(@[
          fx.reproBin, "workspace", "pull", "myproject",
          "--workspace-root=" & fx.workspaceRoot,
        ], @[("REPRO_DIRENV_BIN", fakeDirenv)]))
        if pull.code != 0:
          checkpoint("pull output: " & pull.output)
        check pull.code == 0

        let lines = logLines(logPath)
        check samePathInLog(lines, fx.workspaceRoot)
        check samePathInLog(lines, fx.workspaceRoot / "lib-a")
        check not samePathInLog(lines, fx.workspaceRoot / "lib-b")

        let report = readPullReport(fx.workspaceRoot)
        check report["autoTrust"]["activatorAvailable"].getBool()

      # ---- graceful-skip half: no activator available ----
      block skipHalf:
        let fx = setupFixture(gitBin, "skip")
        defer: removeDir(fx.scratch)
        let logPath = fx.scratch / "skip-allow.log"
        # Point the seam at a NON-EXISTENT path → resolveDirenvBin returns
        # empty → the whole pass is skipped gracefully.
        let missing = fx.scratch / "does-not-exist-direnv"

        let init = runShell(shellCommand(@[
          fx.reproBin, "workspace", "init", "myproject",
          "--workspace-root=" & fx.workspaceRoot,
        ], @[("REPRO_DIRENV_BIN", missing)]))
        if init.code != 0:
          checkpoint("skip-half init output: " & init.output)
        # init still SUCCEEDS despite the absent activator.
        check init.code == 0
        # No auto-trust happened: the log was never written.
        check not fileExists(logPath)

        # The report records the skip — not available, no entries, no error.
        let report = readInitReport(fx.workspaceRoot)
        check not report["autoTrust"]["activatorAvailable"].getBool()
        check report["autoTrust"]["skipReason"].getStr().len > 0
        check report["autoTrust"]["entries"].len == 0

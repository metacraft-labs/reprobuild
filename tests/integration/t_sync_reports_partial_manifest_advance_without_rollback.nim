## RA-11 — partial-failure policy: a ``pull`` that advances the manifest
## repo and then hits a later failing step does NOT roll the manifest
## repo back. It reports the before→after manifest SHAs and stops,
## leaving the partial state for a manual rerun.
##
## Fixture (all hermetic local repos):
##
##   1. A bare manifest-host repo seeded with a project that declares ONE
##      participating repo ``lib-x`` whose remote points at an
##      UNREACHABLE ``file://`` URL (a path that does not exist). The
##      workspace uses composer mode (``[[manifest]]`` ``url``) so the
##      manifest repo itself is a refreshable layer.
##   2. The layer is pre-cloned into the workspace's
##      ``.repo/manifests-0-<sanitized>`` directory at the FIRST manifest
##      commit.
##   3. The bare manifest-host is then advanced by a SECOND commit. So
##      when ``pull`` runs, its manifest-refresh step fast-forwards the
##      in-tree layer from commit#1 → commit#2 (the manifest ADVANCES).
##   4. ``lib-x`` is missing locally, so ``pull``'s clone step runs and
##      FAILS (unreachable origin).
##
## Assertions:
##   * ``pull`` exits non-zero (a step failed).
##   * The manifest layer checkout's HEAD is STILL at commit#2 — NOT
##     rolled back to commit#1.
##   * The pull report's ``manifestLayers`` entry records
##     ``beforeSha == commit#1`` and ``afterSha == commit#2`` (the
##     explicit before→after report) and ``manifestStopped == true``.
##
## Falsifiability:
##   - If ``pull`` rolled the manifest back on failure, the layer HEAD
##     would be commit#1 (assertion fails) and ``afterSha`` would equal
##     ``beforeSha``.
##   - If ``pull`` did not advance the manifest at all, ``afterSha`` would
##     equal ``beforeSha`` and ``manifestStopped`` would be false.
##   - If the failing clone did not actually fail, the exit code would be
##     0.
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
    " config user.name \"RA11 Tester\"")

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

# Project manifest: declares ``lib-x`` whose remote is an unreachable URL
# so the pull's clone step fails.
proc projectTomlBody(unreachableUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"x-origin\"\nfetch = \"" & unreachableUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-x.toml\",\n]\n"

const libXTomlBody = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-x"
path = "lib-x"
remote = "x-origin"
revision = "main"
"""

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

proc writeWorkspaceTomlWithLayer(workspaceRoot, layerUrl: string) =
  let dotRepo = workspaceRoot / ".repo"
  createDir(dotRepo)
  let body =
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"myproject\"\nbranch = \"main\"\n\n" &
    "[[manifest]]\n" &
    "url = \"" & layerUrl & "\"\n" &
    "visibility = \"public\"\nbranch = \"main\"\n"
  writeFile(dotRepo / "workspace.toml", body)

suite "RA-11 — partial manifest advance is reported, never rolled back":

  test "t_sync_reports_partial_manifest_advance_without_rollback":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra11-partial-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # An unreachable participating-repo origin (path does not exist) so
      # the pull's clone step fails.
      let unreachable = fileUrl(scratch / "does-not-exist-origin.git")

      # 1. Seed the manifest-host bare with commit#1.
      let manifestBare = scratch / "bare-manifest.git"
      seedBareWithFiles(gitBin, scratch, manifestBare, [
        ("projects/myproject.toml", projectTomlBody(unreachable)),
        ("repos/lib-x.toml", libXTomlBody),
      ])
      let layerUrl = fileUrl(manifestBare)

      # 2. Workspace + workspace.toml declaring the manifest layer; clone
      #    the bare into the canonical layer dir at commit#1.
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      writeWorkspaceTomlWithLayer(workspaceRoot, layerUrl)
      # The composer/refresh naming for layer 0 is
      # ``manifests-0-<sanitized-url>``; recover it from a probe by asking
      # git where the in-tree checkout would live. We mirror the sanitizer
      # by cloning into a deterministic directory and pointing the
      # workspace.toml at it — but the production code derives the dir from
      # the URL. Use the same convention: clone into the dir refresh
      # reports. Easiest hermetic route: clone into every plausible name is
      # fragile, so instead drive the FIRST pull to materialise the layer,
      # then advance, then the SECOND pull does the advance+fail.
      #
      # First pull: materialises the layer at commit#1 (composer clones it),
      # and fails on the unreachable lib-x clone.
      let firstPull = runShell(shellCommand(@[
        reproBin, "workspace", "pull",
        "--workspace-root=" & workspaceRoot,
      ]))
      # The layer now exists in .repo/manifests-0-*. Locate it.
      var layerDir = ""
      for kind, path in walkDir(workspaceRoot / ".repo"):
        if kind == pcDir and path.lastPathPart.startsWith("manifests-0-"):
          layerDir = path
      check layerDir.len > 0
      let commit1 = headSha(gitBin, layerDir)

      # 3. Advance the bare manifest-host by commit#2.
      let seedWork = scratch / "seed-bare-manifest.git"
      removeDir(seedWork)
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(manifestBare)) &
        " " & q(seedWork))
      gitConfig(gitBin, seedWork)
      writeFile(seedWork / "repos" / "lib-y.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-y\"\npath = \"lib-y\"\nrevision = \"main\"\n")
      discard requireGit(q(gitBin) & " -C " & q(seedWork) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(seedWork) &
        " commit -m \"second manifest commit\"")
      discard requireGit(q(gitBin) & " -C " & q(seedWork) &
        " push origin main")
      let commit2 = requireGit(q(gitBin) & " -C " & q(seedWork) &
        " rev-parse HEAD").strip()
      check commit2 != commit1

      # 4. Second pull: manifest-refresh advances the layer commit#1 →
      #    commit#2, then the lib-x clone fails. The manifest MUST stay at
      #    commit#2 (no rollback).
      let secondPull = runShell(shellCommand(@[
        reproBin, "workspace", "pull",
        "--workspace-root=" & workspaceRoot,
      ]))
      check secondPull.code != 0  # a later step failed

      # The manifest layer was ADVANCED and NOT rolled back.
      check headSha(gitBin, layerDir) == commit2

      let reportPath = workspaceRoot / ".repro" / "workspace" /
        "pull-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)

      # before→after SHAs are reported explicitly on the manifest layer.
      var foundAdvance = false
      for layer in report["manifestLayers"]:
        if layer["beforeSha"].getStr() == commit1 and
            layer["afterSha"].getStr() == commit2:
          foundAdvance = true
      check foundAdvance

      # The no-rollback stop flag is set: the manifest advanced and a later
      # step failed, so the partial state is kept for a rerun.
      check report["manifestStopped"].getBool()

      # The failing repo is recorded as failed.
      var libXFailed = false
      for entry in report["repos"]:
        if entry["path"].getStr() == "lib-x" and
            entry["outcome"].getStr() == "failed":
          libXFailed = true
      check libXFailed

      discard firstPull

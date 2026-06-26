## RA-18 — copyfile / linkfile materialization after init + sync.
##
## A repo fragment declares one ``copyfile`` (copy) and one ``linkfile``
## (symlink) directive (inline-table-array syntax under ``[repo]``; the
## pinned TOML deserializer does not support nested ``[[repo.copyfile]]``
## array-of-tables — see Workspace-Manifests.md). The test proves, hermetically
## (local ``git init --bare`` upstreams, all under one tempdir, no network):
##
##   1. After ``repro workspace init`` clones the repo, the copyfile dest
##      exists at the WORKSPACE ROOT with the src content (a real copy) and
##      the linkfile dest is a SYMLINK pointing at the repo-relative src.
##   2. ``repro workspace sync`` is idempotent: re-running it leaves both
##      dests correct (still a copy + still a symlink).
##   3. After the upstream src changes AND the repo fast-forwards on sync,
##      the copyfile dest tracks the NEW content (re-applied post-checkout).
##
## Falsifiability:
##   * The copy assertion compares exact byte content, so a no-op
##     materialization (or one that never ran) fails the content check.
##   * The symlink assertion requires ``symlinkExists`` AND that the link
##     resolves to the in-repo src — a plain copy in place of a symlink
##     fails ``symlinkExists``.
##   * The tracking assertion changes the upstream content and requires the
##     post-sync copy to differ from the original; a materialization that
##     only ran once (at init) leaves the stale content and fails.
##
## Skip rule: only when ``git`` is missing from PATH.

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

# ---- bare-repo seed fixture ----------------------------------------------

proc gitConfig(gitBin, workPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA-18 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath, configBody: string;
                   branch = "main"): string =
  ## Seed a bare origin holding ``build/config.default.toml`` (the copyfile
  ## src) and ``scripts/dev.sh`` (the linkfile src). Returns the HEAD SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  gitConfig(gitBin, workPath)
  createDir(workPath / "build")
  createDir(workPath / "scripts")
  writeFile(workPath / "build" / "config.default.toml", configBody)
  writeFile(workPath / "scripts" / "dev.sh", "#!/bin/sh\necho dev\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc advanceOrigin(gitBin, workPath, configBody: string;
                   branch = "main"): string =
  ## Change the copyfile src content upstream and push, so a subsequent
  ## sync fast-forwards the workspace clone onto the new content.
  writeFile(workPath / "build" / "config.default.toml", configBody)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m advance")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib.toml\",\n]\n"

const libFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
copyfile = [{ src = "build/config.default.toml", dest = "config.toml" }]
linkfile = [{ src = "scripts/dev.sh", dest = "dev.sh" }]
"""

# ---- fixture --------------------------------------------------------------

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libOrigin: string
    seedWork: string

proc setupFixture(gitBin, slug, configBody: string): Fixture =
  result.scratch = createTempDir("repro-ra18-copy-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libOrigin = result.scratch / "origin-lib.git"
  result.seedWork = result.scratch / "seed-lib"
  discard seedGitOrigin(gitBin, result.libOrigin, result.seedWork, configBody)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(result.libOrigin)))
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragmentToml)
  result.workspaceRoot = workspaceRoot

proc runInit(fx: Fixture): tuple[code: int; output: string] =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "init", "myproject",
    "--workspace-root=" & fx.workspaceRoot]))

proc runSync(fx: Fixture): tuple[code: int; output: string] =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fx.workspaceRoot]))

suite "RA-18 — copyfile / linkfile materialization":

  test "copyfile copies and linkfile symlinks after init, idempotent, tracks revision":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "happy", "version = 1\n")
      defer: removeDir(fx.scratch)

      # --- init: clones + materializes ---
      let initRes = runInit(fx)
      if initRes.code != 0:
        checkpoint("init output: " & initRes.output)
      check initRes.code == 0
      check dirExists(fx.workspaceRoot / "lib" / ".git")

      let copyDest = fx.workspaceRoot / "config.toml"
      let linkDest = fx.workspaceRoot / "dev.sh"
      let srcCopy = fx.workspaceRoot / "lib" / "build" / "config.default.toml"
      let srcLink = fx.workspaceRoot / "lib" / "scripts" / "dev.sh"

      # copyfile is a real copy with the src content (NOT a symlink).
      check fileExists(copyDest)
      check not symlinkExists(copyDest)
      check readFile(copyDest) == "version = 1\n"
      check readFile(copyDest) == readFile(srcCopy)

      # linkfile is a symlink pointing at the in-repo src.
      check symlinkExists(linkDest)
      check sameFile(linkDest, srcLink)
      check readFile(linkDest) == "#!/bin/sh\necho dev\n"

      # init-report records the materialized entries.
      let initReport = parseFile(fx.workspaceRoot / ".repro" / "workspace" /
        "init-report.json")
      check initReport["materialized"].len == 2

      # --- sync (idempotent): both dests still correct ---
      let syncRes = runSync(fx)
      if syncRes.code != 0:
        checkpoint("sync output: " & syncRes.output)
      check syncRes.code == 0
      check fileExists(copyDest)
      check not symlinkExists(copyDest)
      check readFile(copyDest) == "version = 1\n"
      check symlinkExists(linkDest)
      check sameFile(linkDest, srcLink)

      let syncReport = parseFile(fx.workspaceRoot / ".repro" / "workspace" /
        "sync-report.json")
      check syncReport["materialized"].len == 2
      for m in syncReport["materialized"]:
        check m["status"].getStr() == "materialized"

      # --- upstream changes + re-sync: the copy tracks the new content ---
      discard advanceOrigin(gitBin, fx.seedWork, "version = 2\n")
      let syncRes2 = runSync(fx)
      if syncRes2.code != 0:
        checkpoint("sync2 output: " & syncRes2.output)
      check syncRes2.code == 0
      # The clone fast-forwarded onto the advanced tip, and the post-checkout
      # materialization re-copied the now-changed src.
      check readFile(srcCopy) == "version = 2\n"
      check readFile(copyDest) == "version = 2\n"

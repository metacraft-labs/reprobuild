## RA-5 — `repro workspace shared-clones [root|list|rewire]`.
##
## Covers the operator-facing inspection / repair surface:
##
##   * ``root``   — prints the resolved cache root (honoring the
##                  ``REPRO_WORKSPACE_CLONES`` override).
##   * ``list``   — read-only per-repo wiring view (bare present? wired?).
##   * ``rewire`` — idempotently retrofits an existing workspace: it
##                  populates the shared bare and writes the alternates
##                  entry into an already-checked-out repo that lacks it.
##                  A second ``rewire`` is a no-op (``rewired=false``).
##
## Falsifiability: ``rewire`` flips ``wired`` from false→true and writes
## a real ``objects/info/alternates`` file (asserted on disk); a re-run
## reports ``rewired=false`` (idempotence). Hermetic local upstream; skip
## only when ``git`` is missing.

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
  currentSourcePath().parentDir.parentDir.parentDir

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
    " config user.name \"RA5 Tester\"")
  writeFile(workPath / "README.md", "ra5 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc projectToml(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"ra5proj\"\n" &
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
"""

proc seedWorkspace(scratch, libUrl: string): string =
  let workspaceRoot = scratch / "ws"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "ra5proj.toml", projectToml(libUrl))
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragmentToml)
  workspaceRoot

suite "RA-5 — repro workspace shared-clones":

  test "test_ra5_shared_clones_root_list_rewire":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra5-sc-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let origin = scratch / "origin-lib.git"
      discard seedGitOrigin(gitBin, origin, scratch / "seed-lib")
      let libUrl = fileUrl(origin)

      let cacheDir = scratch / "clones-cache"
      let env = @[("REPRO_WORKSPACE_CLONES", cacheDir)]
      let ws = seedWorkspace(scratch, libUrl)

      # --- root: prints the override path verbatim. -------------------
      let rootRes = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "root",
        "--workspace-root=" & ws,
      ], env))
      check rootRes.code == 0
      check rootRes.output.strip() == cacheDir

      # Pre-clone the repo into the workspace WITHOUT alternates so the
      # repo is "checked out but unwired" — exactly what rewire repairs.
      discard requireGit(q(gitBin) & " clone --branch main " & q(libUrl) &
        " " & q(ws / "lib"))
      let altPath = ws / "lib" / ".git" / "objects" / "info" / "alternates"
      check not fileExists(altPath)

      # --- list: read-only; reports unwired + no bare yet. ------------
      let listRes = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      check listRes.code == 0
      let listReport = parseJson(listRes.output)
      check listReport["repos"].len == 1
      check listReport["repos"][0]["wired"].getBool() == false
      # list does no network work → bare not yet populated.
      check not fileExists(altPath)

      # --- rewire: populates the bare + writes the alternates. --------
      let rewireRes = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "rewire", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      if rewireRes.code != 0:
        checkpoint("rewire output: " & rewireRes.output)
      check rewireRes.code == 0
      let rewireReport = parseJson(rewireRes.output)
      check rewireReport["repos"][0]["wired"].getBool() == true
      check rewireReport["repos"][0]["rewired"].getBool() == true

      # On-disk proof: the alternates file now points at the shared bare.
      check fileExists(altPath)
      let bare = rewireReport["repos"][0]["sharedBarePath"].getStr()
      check (bare / "objects") in readFile(altPath)

      # --- rewire again: idempotent (already wired → rewired=false). ---
      let rewire2 = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "rewire", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      check rewire2.code == 0
      let report2 = parseJson(rewire2.output)
      check report2["repos"][0]["wired"].getBool() == true
      check report2["repos"][0]["rewired"].getBool() == false

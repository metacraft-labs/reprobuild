## M13 — End-to-end test for the workspace branch metadata.
##
## Runs the compiled ``repro`` binary against a hermetic two-repo
## project. Asserts:
##
##   1. ``repro workspace init`` writes the active branch into
##      ``.repo/workspace.toml`` under ``[workspace].branch``. The
##      branch value is the resolver's ``trunk`` field (the manifest's
##      documented default branch — ``main`` in this fixture).
##   2. ``repro workspace status`` (without a positional project)
##      still works: the metadata-only workspace.toml written by init
##      supplies the project name to the dispatch helper, and the
##      reported ``activeBranch`` comes from the M13 metadata field
##      (not the M12 live-HEAD heuristic).
##   3. Re-running ``repro workspace init`` on the same workspace is
##      idempotent — the recorded branch survives intact.
##
## Skip rule: ``git`` missing on PATH (same convention as M9 / M10 /
## M11 / M12).

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

# ---- repro binary build ---------------------------------------------------

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

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M13 Tester\"")
  writeFile(workPath / "README.md", "M13 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

# ---- manifest TOML strings ------------------------------------------------

proc projectTomlWithRemotes(libAUrl, libBUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

# ---- fixture builder ------------------------------------------------------

type
  M13Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string): M13Fixture =
  result.scratch = createTempDir("repro-m13-" & slug & "-", "")
  result.reproBin = reproBinary()

  let libAOrigin = result.scratch / "origin-lib-a.git"
  let libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, libAOrigin,
    result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, libBOrigin,
    result.scratch / "seed-lib-b")
  result.libAOrigin = libAOrigin
  result.libBOrigin = libBOrigin

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectTomlWithRemotes(
      fileUrl(libAOrigin),
      fileUrl(libBOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  result.workspaceRoot = workspaceRoot

# ---- the suite -------------------------------------------------------------

suite "M13 — workspace branch survives init and status":

  test "test_m13_init_records_trunk_as_active_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "init-records")
      defer: removeDir(fx.scratch)

      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # The metadata-only workspace.toml must now exist with the
      # resolver's trunk recorded as the active branch.
      let tomlPath = fx.workspaceRoot / ".repo" / "workspace.toml"
      check fileExists(tomlPath)

      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "main"

      let parsed = readWorkspaceLocal(tomlPath)
      check parsed.workspace.project == "myproject"
      check parsed.workspace.branch.isSome
      check parsed.workspace.branch.get() == "main"
      # No manifest layers were declared by the user, so M9 init must
      # have written a metadata-only workspace.toml (no [[manifest]])
      # — which dispatch helpers detect via
      # ``isCompositionalWorkspaceToml`` to route the workspace
      # through the M6 single-project resolver.
      check parsed.manifest.len == 0
      check isCompositionalWorkspaceToml(fx.workspaceRoot) == false

  test "test_m13_status_reads_active_branch_from_metadata":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "status-reads")
      defer: removeDir(fx.scratch)

      # Step 1: init creates the workspace and records the branch.
      let initRes = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check initRes.code == 0

      # Step 2: status without an explicit project. The metadata-only
      # workspace.toml supplies the project name to the dispatcher,
      # and the activeBranch field reflects M13's stored value
      # rather than the M12 live-HEAD heuristic.
      let statusRes = runShell(shellCommand(@[
        fx.reproBin, "workspace", "status",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if statusRes.code != 0:
        checkpoint("status output: " & statusRes.output)
      check statusRes.code == 0

      let reportPath = fx.workspaceRoot / ".repo" / ".." / ".repro" /
        "workspace" / "status-report.json"
      let normReportPath = fx.workspaceRoot / ".repro" / "workspace" /
        "status-report.json"
      check fileExists(normReportPath)
      let report = parseFile(normReportPath)
      check report["project"].getStr() == "myproject"
      check report["activeBranch"].getStr() == "main"

      # Now overwrite the recorded branch with a value that does NOT
      # match any live repo HEAD. If status were still consulting the
      # M12 heuristic first, it would report the live-HEAD value
      # ("main"); the M13 contract requires status to return the
      # stored value.
      writeWorkspaceBranch(fx.workspaceRoot,
        project = "myproject", branch = "synthetic-branch-not-on-disk")

      let statusRes2 = runShell(shellCommand(@[
        fx.reproBin, "workspace", "status",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check statusRes2.code == 0
      let report2 = parseFile(normReportPath)
      check report2["activeBranch"].getStr() == "synthetic-branch-not-on-disk"

  test "test_m13_init_is_idempotent_for_branch_metadata":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "idempotent")
      defer: removeDir(fx.scratch)

      let res1 = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res1.code == 0
      let firstBytes = readFile(
        fx.workspaceRoot / ".repo" / "workspace.toml")

      # Second invocation must NOT clobber the metadata. The
      # workspace.toml bytes round-trip identically when the
      # resolver's trunk hasn't changed (the writer is
      # deterministic).
      let res2 = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res2.code == 0
      let secondBytes = readFile(
        fx.workspaceRoot / ".repo" / "workspace.toml")
      check firstBytes == secondBytes

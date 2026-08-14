## M14 / WV-6 — ``repro branch`` (show form) reports the recorded branch.
##
## The M13 metadata is the single source of truth for the active workspace
## branch, and the no-argument ``repro branch`` is the read-only query over it.
##
##   1. After the branch is created in place (``repro switch -b <name>``, the
##      verb that performs that operation), ``repro branch`` reports ``<name>``
##      in both its text line and its report document, with an EMPTY per-repo
##      array — it is a query, not a plan.
##   2. On a freshly initialised workspace with no branch recorded, it falls
##      back to the manifest trunk rather than inventing one.
##
## The former third case here — ``repro branch <name>`` creating a branch
## WITHOUT switching onto it — tested a retired verb and is gone. A
## workspace-wide branch nothing is standing on is not a state any other
## command can act on, so creating one is now inseparable from switching
## (``repro switch -b``); that verb's own suite,
## ``t_switch_new_branch_marks_feature_branch``, covers both the metadata
## write and the dirty-sibling refusal this file used to assert.

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

# Teardown uses ``repro_test_support.removeDirEventually``. A local copy used
# to live here and retried for two seconds, which is the wrong medicine: the
# failure is not only git closing files, it is also Windows' MAX_PATH — the
# engine action-cache records under a scratch root exceed 260 characters and
# ``FindFirstFileW`` silently refuses to enumerate them, so no amount of
# retrying empties the directory. The shared helper escalates to the ``\\?\``
# form, so keeping a private one here just reintroduced the bug.

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M14 Tester\"")
  writeFile(workPath / "README.md", "M14 fixture\n")
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
  M14MetaFixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string): M14MetaFixture =
  result.scratch = createTempDir("repro-m14-meta-" & slug & "-", "")
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
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectTomlWithRemotes(
      fileUrl(libAOrigin),
      fileUrl(libBOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  result.workspaceRoot = workspaceRoot

proc runInit(fx: M14MetaFixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "init", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc runBranchShow(fx: M14MetaFixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "branch", "--write-report",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc runBranchCreate(fx: M14MetaFixture; name: string): CmdResult =
  # WV-5/WV-6: creating a workspace-wide branch in place is `repro switch -b`.
  # `repro branch` now takes a destination PATH and produces a new workspace.
  runShell(shellCommand(@[
    fx.reproBin, "switch", "--write-report", name, "-b",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: M14MetaFixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "branch-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite -------------------------------------------------------------

suite "M14 — repro branch records metadata round-trip":

  test "test_m14_show_form_returns_new_branch_after_create":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "show-after-create")
      defer: removeDirEventually(fx.scratch)

      check runInit(fx).code == 0
      check runBranchCreate(fx, "feature-show").code == 0

      let showRes = runBranchShow(fx)
      if showRes.code != 0:
        checkpoint("output: " & showRes.output)
      check showRes.code == 0
      # The text renderer prints ``workspace branch: <name>``.
      check "workspace branch: feature-show" in showRes.output

      # The JSON report (always written) carries the same value.
      let report = readReport(fx)
      check report["form"].getStr() == "show"
      check report["branch"].getStr() == "feature-show"
      check report["recordedBranch"].getStr() == "feature-show"
      check report["exitCode"].getInt() == 0
      # Show form leaves the per-repo array empty — it's a read-only
      # query, not a plan.
      check report["repos"].len == 0

  test "test_m14_show_form_returns_trunk_on_freshly_initialised_workspace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "show-after-init")
      defer: removeDirEventually(fx.scratch)

      # ``workspace init`` records the resolver's ``trunk`` (``main``
      # in this fixture) as the active branch. ``repro branch``
      # without a positional must return that recorded value
      # WITHOUT ever consulting the live-HEAD heuristic.
      check runInit(fx).code == 0

      let showRes = runBranchShow(fx)
      if showRes.code != 0:
        checkpoint("output: " & showRes.output)
      check showRes.code == 0
      check "workspace branch: main" in showRes.output

      let report = readReport(fx)
      check report["form"].getStr() == "show"
      check report["branch"].getStr() == "main"
      check report["recordedBranch"].getStr() == "main"
      check report["exitCode"].getInt() == 0

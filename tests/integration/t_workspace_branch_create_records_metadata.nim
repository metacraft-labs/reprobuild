## M14 — ``repro branch`` metadata round-trip.
##
## Verifies the M13 metadata is the single source of truth for the
## active workspace branch across the ``repro branch`` command's two
## forms:
##
##   1. A successful ``repro branch <name>`` writes ``<name>`` into
##      ``[workspace].branch`` of ``.repo/workspace.toml``. The bytes
##      land via the M13 ``writeWorkspaceBranch`` writer; a re-read
##      through ``readWorkspaceBranch`` returns the new value.
##   2. After the create form, the show form (``repro branch`` with
##      no positional) returns the new value.
##   3. On a workspace where ``workspace init`` recorded ``main`` as
##      the active branch, the show form returns ``main`` before any
##      ``repro branch <name>`` ever runs.
##
## Skip rule: ``git`` missing on PATH (same convention as M9–M13).

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

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m14-branch-metadata-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

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
  result.reproBin = compileRepro(result.scratch)

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

proc runInit(fx: M14MetaFixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "init", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc runBranchShow(fx: M14MetaFixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "branch",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc runBranchCreate(fx: M14MetaFixture; name: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "branch", name,
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: M14MetaFixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "branch-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite -------------------------------------------------------------

suite "M14 — repro branch records metadata round-trip":

  test "test_m14_create_writes_branch_into_workspace_toml":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "create-writes")
      defer: removeDir(fx.scratch)

      # Init clones both repos and records ``main`` (the resolver's
      # trunk) as the active branch.
      let initRes = runInit(fx)
      check initRes.code == 0
      let initialRecorded = readWorkspaceBranch(fx.workspaceRoot)
      check initialRecorded.isSome
      check initialRecorded.get() == "main"

      # Create a new branch across the workspace.
      let createRes = runBranchCreate(fx, "feature-metadata")
      if createRes.code != 0:
        checkpoint("output: " & createRes.output)
      check createRes.code == 0

      # M13 reader returns the new value.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-metadata"

      # The workspace.toml on disk carries the new value under
      # ``[workspace].branch``, in the canonical M13 serializer
      # form. The file is still a metadata-only workspace.toml (no
      # ``[[manifest]]`` entries) because we initialised in
      # single-project mode.
      let tomlPath = fx.workspaceRoot / ".repo" / "workspace.toml"
      let parsed = readWorkspaceLocal(tomlPath)
      check parsed.workspace.project == "myproject"
      check parsed.workspace.branch.isSome
      check parsed.workspace.branch.get() == "feature-metadata"
      check parsed.manifest.len == 0
      check isCompositionalWorkspaceToml(fx.workspaceRoot) == false

      # The JSON report exposes the same value via
      # ``recordedBranch``.
      let report = readReport(fx)
      check report["form"].getStr() == "create"
      check report["branch"].getStr() == "feature-metadata"
      check report["recordedBranch"].getStr() == "feature-metadata"
      check report["exitCode"].getInt() == 0

  test "test_m14_show_form_returns_new_branch_after_create":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "show-after-create")
      defer: removeDir(fx.scratch)

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
      defer: removeDir(fx.scratch)

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

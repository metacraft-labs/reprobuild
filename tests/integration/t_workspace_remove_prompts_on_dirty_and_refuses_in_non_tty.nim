## RA-9 — `repro remove <repo>` destructive-command safety.
##
## Black-box: drives the compiled ``repro`` binary against a hermetic
## two-repo workspace via ``execCmdEx`` (so stdin is NON-TTY by nature).
## The core safety property is that a destructive ``remove`` of a DIRTY
## repo, run in a non-interactive context WITHOUT ``--force``, refuses
## cleanly (non-zero, naming ``--force``) and discards NOTHING — it never
## hangs waiting on a prompt that can't be answered.
##
## Sub-cases (each its own ``test_ra9_*`` block):
##
##   1. ``test_ra9_remove_dirty_non_tty_without_force_refuses_intact``
##      The core safety property: dirty repo, non-TTY, no ``--force`` →
##      exit 2, message names ``--force``, the working tree + the dirty
##      file + the project declaration are LEFT INTACT.
##   2. ``test_ra9_remove_dirty_with_force_performs_removal``
##      The same dirty repo WITH ``--force`` → the working tree is removed
##      and the include declaration is dropped from the project TOML.
##   3. ``test_ra9_remove_clean_repo_allowed_without_force``
##      A clean repo removes without a prompt (nothing to discard).
##   4. ``test_ra9_remove_dry_run_previews_per_repo_effect_no_mutation``
##      ``--dry-run`` enumerates the per-repo effect and mutates nothing.
##
## Skip rule: ``git`` missing on PATH (same convention as the M9–M16 and
## RA suites).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
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

# ---- fixtures -------------------------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main") =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA9 Tester\"")
  writeFile(workPath / "README.md", "RA9 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA9 Tester\"")

proc projectTomlWith2Remotes(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
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

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    projectFile: string
    originA: string
    originB: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra9-remove-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.originA = result.scratch / "origin-lib-a.git"
  result.originB = result.scratch / "origin-lib-b.git"
  seedGitOrigin(gitBin, result.originA, result.scratch / "seed-lib-a")
  seedGitOrigin(gitBin, result.originB, result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  result.projectFile = manifestsRoot / "projects" / "lib-a.toml"
  writeFile(result.projectFile,
    projectTomlWith2Remotes(fileUrl(result.originA), fileUrl(result.originB)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)

  # Clone both repos into the workspace.
  cloneInto(gitBin, result.originA, workspaceRoot / "lib-a")
  cloneInto(gitBin, result.originB, workspaceRoot / "lib-b")

  # Metadata-only workspace.toml so the project resolves without `init`.
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")
  result.workspaceRoot = workspaceRoot

proc makeDirty(repoPath: string) =
  writeFile(repoPath / "uncommitted.txt", "local work that must not vanish\n")

proc invokeRemove(fx: Fixture; extra: seq[string]): tuple[code: int; output: string] =
  var parts = @[q(fx.reproBin), "remove"]
  for e in extra: parts.add(q(e))
  parts.add("--workspace-root=" & q(fx.workspaceRoot))
  runCmd(parts.join(" "))

proc projectStillIncludes(fx: Fixture; fragment: string): bool =
  readFile(fx.projectFile).contains(fragment)

# ---- the suite ------------------------------------------------------------

suite "RA-9 — repro remove destructive-command safety":

  test "test_ra9_remove_dirty_non_tty_without_force_refuses_intact":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty-refuse")
      defer: removeDir(fx.scratch)

      let dirtyRepo = fx.workspaceRoot / "lib-b"
      makeDirty(dirtyRepo)
      check fileExists(dirtyRepo / "uncommitted.txt")

      # Non-TTY (execCmdEx), no --force, dirty target → REFUSE.
      let res = invokeRemove(fx, @["lib-b"])
      check res.code != 0
      check res.code == 2
      # The message names the opt-out flag so the operator knows the remedy.
      check res.output.contains("--force")
      # Core safety property: NOTHING discarded — the dirty working tree,
      # the dirty file, and the project declaration are all intact.
      check dirExists(dirtyRepo)
      check fileExists(dirtyRepo / "uncommitted.txt")
      check fileExists(dirtyRepo / ".git" / "config")
      check projectStillIncludes(fx, "repos/lib-b.toml")
      check projectStillIncludes(fx, "repos/lib-a.toml")

  test "test_ra9_remove_dirty_with_force_performs_removal":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty-force")
      defer: removeDir(fx.scratch)

      let dirtyRepo = fx.workspaceRoot / "lib-b"
      makeDirty(dirtyRepo)
      check dirExists(dirtyRepo)

      # --force opts out of the prompt → the removal proceeds.
      let res = invokeRemove(fx, @["lib-b", "--force"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      # The working tree (and its object store under .git) is gone.
      check not dirExists(dirtyRepo)
      # The declaration was dropped from the project TOML — lib-b's include
      # is gone, lib-a's remains.
      check not projectStillIncludes(fx, "repos/lib-b.toml")
      check projectStillIncludes(fx, "repos/lib-a.toml")
      # The OTHER repo is untouched.
      check dirExists(fx.workspaceRoot / "lib-a")

  test "test_ra9_remove_clean_repo_allowed_without_force":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean")
      defer: removeDir(fx.scratch)

      let cleanRepo = fx.workspaceRoot / "lib-b"
      check dirExists(cleanRepo)

      # Clean tree: nothing to discard, so no --force is needed.
      let res = invokeRemove(fx, @["lib-b"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      check not dirExists(cleanRepo)
      check not projectStillIncludes(fx, "repos/lib-b.toml")
      check projectStillIncludes(fx, "repos/lib-a.toml")

  test "test_ra9_remove_dry_run_previews_per_repo_effect_no_mutation":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dry-run")
      defer: removeDir(fx.scratch)

      let target = fx.workspaceRoot / "lib-b"
      makeDirty(target)

      # --dry-run with --json: enumerate the per-repo effect, mutate nothing.
      let res = invokeRemove(fx, @["lib-b", "--dry-run", "--json"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      # The JSON report names the per-repo effect. ``execCmdEx`` merges
      # stdout+stderr, and the preview lines go to stderr BEFORE the JSON
      # object on stdout, so slice from the first ``{``.
      let braceIdx = res.output.find('{')
      check braceIdx >= 0
      let parsed = parseJson(res.output[braceIdx .. ^1])
      check parsed["repos"].len == 1
      check parsed["repos"][0]["name"].getStr() == "lib-b"
      check parsed["repos"][0]["path"].getStr() == "lib-b"
      check parsed["repos"][0]["effect"].getStr() == "would_remove"
      check parsed["repos"][0]["dirty"].getBool() == true
      check parsed["declarationChanged"].getBool() == false
      # Nothing mutated: the tree, the dirty file, and the declaration stay.
      check dirExists(target)
      check fileExists(target / "uncommitted.txt")
      check projectStillIncludes(fx, "repos/lib-b.toml")

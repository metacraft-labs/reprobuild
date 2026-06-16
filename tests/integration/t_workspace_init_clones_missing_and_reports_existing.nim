## M9 — ``repro workspace init <project>``.
##
## Integration test for the new subcommand. The CLI dispatcher in
## ``libs/repro_cli_support/src/repro_cli_support.nim`` routes
## ``repro workspace init`` to ``runWorkspaceInitCommand``, which:
##
##   1. Resolves the named project (or variant) via the M6 / M7 / M8
##      surfaces.
##   2. Walks the resulting ``ResolvedProject``. Missing repos are
##      scheduled as ``bakWorkspaceVcs.clone`` actions; existing repos
##      are inspected via the M2 observation-only ``headShaQuery`` and
##      classified as ``up-to-date`` or ``divergence``.
##   3. Emits a structured stdout report AND writes
##      ``<workspaceRoot>/.repro/workspace/init-report.json``.
##   4. Returns one of three exit codes — 0 (no divergences AND all
##      clones succeeded), 1 (at least one clone failed), 2 (there
##      were divergences and we deliberately did NOT auto-modify them).
##
## Fixture: two hermetic local bare git repos (the same pattern the
## M2 / M3 / M8 tests use). The bare repos stand in for the
## ``[[remote]].fetch`` URLs the project manifest declares. The whole
## directory tree (bare origins + workspace + manifest TOMLs) lives
## under a single ``createTempDir`` root and is removed by ``defer``.
##
## Skip rule: only when ``git`` is missing from PATH (same convention as
## M2 / M3 / M8).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

# ---- repro binary build ---------------------------------------------------

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## Tiny shell wrapper for the seed-fixture git calls. We use a fresh
  ## helper rather than the ``repro_test_support`` ``requireSuccess`` so
  ## the helpers stay independent: the seed code uses raw shell strings
  ## because that's the pattern every other workspace-VCS fixture
  ## follows.
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  ## Walk up from this test file to the reprobuild repo root. Mirrors
  ## the convention every other integration test uses: the binary's
  ## source tree sits four directories above ``tests/integration/<x>``.
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
  ## Build a local bare git repo with one commit on ``branch``. Returns
  ## the SHA of that commit (so the test can compare against it inside
  ## the workspace clone). Same shape as M2 / M3 / M8 seeds.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M9 Tester\"")
  writeFile(workPath / "README.md", "M9 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  ## Pre-clone a bare origin into the workspace so the M9 dispatcher
  ## sees the repo as ``existing`` rather than ``missing``. Mirrors the
  ## file:// pattern the executor itself uses.
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"M9 Tester\"")

proc appendLocalCommit(gitBin, repoPath: string): string =
  ## Add a fresh local-only commit so the working tree HEAD diverges
  ## from the manifest-pinned tip. Returns the resulting HEAD SHA so
  ## the divergence-case assertion can compare against the
  ## ``init-report.json`` ``observed`` field directly.
  writeFile(repoPath / "local-only.txt", "diverged\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add local-only.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"local-only divergence\"")
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

# ---- manifest TOML strings ------------------------------------------------

proc projectTomlWithRemotes(libAUrl, libBUrl: string): string =
  ## Build a project manifest whose ``[[remote]]`` table maps the two
  ## per-fragment remote names directly to the fixture's bare-repo
  ## ``file://`` URLs. The fragments pin ``revision = "main"`` so the
  ## M2 ``git clone --branch main`` succeeds on every fresh case; the
  ## divergence check consults ``refs/remotes/origin/main`` to detect
  ## a local checkout that has drifted ahead of the manifest pin.
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
  M9Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libBOrigin: string
    libASha: string
    libBSha: string

proc setupFixture(gitBin, slug: string): M9Fixture =
  result.scratch = createTempDir("repro-m9-" & slug & "-", "")
  result.reproBin = reproBinary()

  let libAOrigin = result.scratch / "origin-lib-a.git"
  let libBOrigin = result.scratch / "origin-lib-b.git"
  result.libASha = seedGitOrigin(gitBin, libAOrigin,
    result.scratch / "seed-lib-a")
  result.libBSha = seedGitOrigin(gitBin, libBOrigin,
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

proc readReport(fixture: M9Fixture): JsonNode =
  let reportPath = fixture.workspaceRoot / ".repro" / "workspace" /
    "init-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite -------------------------------------------------------------

suite "M9 — repro workspace init":

  test "test_m9_init_clones_two_missing_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clone-missing")
      defer: removeDir(fx.scratch)

      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      check dirExists(fx.workspaceRoot / "lib-a" / ".git")
      check dirExists(fx.workspaceRoot / "lib-b" / ".git")

      # The cloned working trees must carry the bare origin's HEAD SHA.
      let libAHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-a") & " rev-parse HEAD").strip()
      check libAHead == fx.libASha
      let libBHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-b") & " rev-parse HEAD").strip()
      check libBHead == fx.libBSha

      let report = readReport(fx)
      check report["project"].getStr() == "myproject"
      check report["cloned"].len == 2
      check report["upToDate"].len == 0
      check report["divergences"].len == 0
      var paths: seq[string]
      for entry in report["cloned"]:
        paths.add(entry["path"].getStr())
      check "lib-a" in paths
      check "lib-b" in paths

  test "test_m9_init_reports_existing_up_to_date":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "existing-uptodate")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libAOrigin, fx.workspaceRoot / "lib-a")
      cloneInto(gitBin, fx.libBOrigin, fx.workspaceRoot / "lib-b")

      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["cloned"].len == 0
      check report["upToDate"].len == 2
      check report["divergences"].len == 0

      var observedHeads: seq[string]
      for entry in report["upToDate"]:
        observedHeads.add(entry["headSha"].getStr())
      check fx.libASha in observedHeads
      check fx.libBSha in observedHeads

  test "test_m9_init_reports_divergence_without_modifying":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "divergence")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libAOrigin, fx.workspaceRoot / "lib-a")
      cloneInto(gitBin, fx.libBOrigin, fx.workspaceRoot / "lib-b")
      # Add a divergent commit to lib-a only. lib-b stays at its manifest
      # pin so we can assert exactly one divergence and one up-to-date.
      let divergentHead = appendLocalCommit(gitBin,
        fx.workspaceRoot / "lib-a")

      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res.code == 2

      # lib-a working tree was NOT touched by the dispatcher — the
      # post-init HEAD must still be the locally-introduced commit.
      let postHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-a") & " rev-parse HEAD").strip()
      check postHead == divergentHead

      let report = readReport(fx)
      check report["cloned"].len == 0
      check report["upToDate"].len == 1
      check report["divergences"].len == 1

      let upToDate = report["upToDate"][0]
      check upToDate["path"].getStr() == "lib-b"
      check upToDate["headSha"].getStr() == fx.libBSha

      let div0 = report["divergences"][0]
      check div0["path"].getStr() == "lib-a"
      check div0["expected"].getStr() == fx.libASha
      check div0["observed"].getStr() == divergentHead

  test "test_m9_init_unknown_project_errors":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "unknown")
      defer: removeDir(fx.scratch)

      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "nonexistent",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res.code == 1
      # Error message embeds the on-disk file paths with the host
      # separator (forward slash on POSIX, backslash on Windows), so
      # match through Nim's ``/`` operator which adapts to the host.
      check ("projects" / "nonexistent.toml") in res.output
      check ("variants" / "nonexistent.toml") in res.output

  test "test_m9_init_no_workspace_root_uses_cwd":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "cwd-default")
      defer: removeDir(fx.scratch)

      # Drop the explicit --workspace-root and rely on the dispatcher's
      # ``getCurrentDir()`` fallback.
      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "myproject",
      ]), cwd = fx.workspaceRoot)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      check dirExists(fx.workspaceRoot / "lib-a" / ".git")
      check dirExists(fx.workspaceRoot / "lib-b" / ".git")
      let report = readReport(fx)
      check report["cloned"].len == 2
      check report["upToDate"].len == 0
      check report["divergences"].len == 0

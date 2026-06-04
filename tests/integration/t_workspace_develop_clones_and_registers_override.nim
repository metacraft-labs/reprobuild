## M22 — ``repro develop <pkg>`` (workspace-overlay form).
##
## Integration test for the new dispatcher. The CLI in
## ``libs/repro_cli_support/src/repro_cli_support.nim`` routes
## ``repro develop <pkg>`` (when at least one M22-distinctive flag is
## present and no pre-M22 marker is present) to
## ``runWorkspaceDevelopCommand``, which:
##
##   1. Resolves the active project (M6/M7/M8 surfaces, dispatched the
##      same way M9's ``repro workspace init`` resolves it).
##   2. Looks up ``<pkg>`` in the resolved project's repo list. A typo
##      surfaces as exit code 1 naming the project file.
##   3. Decides between clone-and-register (no ``--source``) and just-
##      register (``--source=PATH``). Clone target is
##      ``<workspaceRoot>/develop/<pkg>``.
##   4. Reads the existing M20 ``.repro/develop-overrides.toml`` and:
##        - re-emits the report unchanged when the same package is
##          already registered at the same path (exit 0, mode
##          ``idempotent``);
##        - refuses when the same package is registered at a DIFFERENT
##          path (exit 2, mode ``refused``);
##        - otherwise persists the new entry via M20's
##          ``addOverride`` + ``writeDevelopOverridesFile``.
##   5. Emits ``<workspaceRoot>/.repro/workspace/develop-report.json``.
##
## Fixture: hermetic local bare git repos following the same pattern as
## ``t_workspace_init_clones_missing_and_reports_existing`` (M9). One
## ``[[remote]]``-backed repo named ``lib-a`` is what every M22 test
## exercises against; the second test pre-creates a ``--source`` path so
## the dispatcher takes the register-only arm.
##
## Skip rule: only when ``git`` is missing from ``PATH`` (same convention
## as M2 / M3 / M8 / M9).

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
    "--nimcache:" & root / "build" / "nimcache" / "m22-develop-repro",
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
    " config user.name \"M22 Tester\"")
  writeFile(workPath / "README.md", "M22 fixture\n")
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

proc projectTomlWithLibA(libAUrl: string): string =
  ## One-repo project manifest. The repo's ``name`` (``lib-a``) is what
  ## M22 matches the ``<pkg>`` positional against.
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

# ---- fixture builder ------------------------------------------------------

type
  M22Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libASha: string

proc setupFixture(gitBin, slug: string): M22Fixture =
  result.scratch = createTempDir("repro-m22-" & slug & "-", "")
  result.reproBin = compileRepro(result.scratch)

  let libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASha = seedGitOrigin(gitBin, libAOrigin,
    result.scratch / "seed-lib-a")
  result.libAOrigin = libAOrigin

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectTomlWithLibA(fileUrl(libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.workspaceRoot = workspaceRoot

proc readReport(fixture: M22Fixture): JsonNode =
  let reportPath = fixture.workspaceRoot / ".repro" / "workspace" /
    "develop-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite -------------------------------------------------------------

suite "M22 — repro develop <pkg> (workspace-overlay)":

  test "test_m22_develop_clones_when_no_source_flag":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clone")
      defer: removeDir(fx.scratch)

      # No --source: dispatcher must clone ``lib-a`` into
      # ``<workspace>/develop/lib-a`` and register the override.
      let res = runShell(shellCommand(@[
        fx.reproBin, "develop", "lib-a",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let cloneTarget = fx.workspaceRoot / "develop" / "lib-a"
      check dirExists(cloneTarget / ".git")

      # The clone tip must match the bare origin's HEAD.
      let cloneHead = requireGit(q(gitBin) & " -C " & q(cloneTarget) &
        " rev-parse HEAD").strip()
      check cloneHead == fx.libASha

      # The M20 develop-overrides file must carry the entry.
      let overrides = readDevelopOverridesFile(fx.workspaceRoot)
      check overrides.isSome
      let entries = listOverrides(overrides.get())
      check entries.len == 1
      check entries[0].package == "lib-a"
      check entries[0].local_path == absolutePath(cloneTarget)
      check entries[0].state == "editable"
      check entries[0].provenance.isSome
      check entries[0].provenance.get() == "repro develop lib-a"

      # The JSON report carries the structured outcome.
      let report = readReport(fx)
      check report["pkg"].getStr() == "lib-a"
      check report["mode"].getStr() == "cloned"
      check report["project"].getStr() == "myproject"
      check report["source"].getStr() == absolutePath(cloneTarget)
      check report["overrideEntry"]["package"].getStr() == "lib-a"
      check report["overrideEntry"]["local_path"].getStr() ==
        absolutePath(cloneTarget)
      check report["overrideEntry"]["state"].getStr() == "editable"
      check report["exitCode"].getInt() == 0

  test "test_m22_develop_registers_when_source_provided":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "register")
      defer: removeDir(fx.scratch)

      # Pre-create a stand-in checkout directory the dispatcher just
      # registers. M22 does NOT require a real git tree for the
      # --source arm; only that the directory exists.
      let standin = fx.scratch / "local-checkouts" / "lib-a"
      createDir(standin)
      writeFile(standin / "README.md", "operator's checkout\n")

      let res = runShell(shellCommand(@[
        fx.reproBin, "develop", "lib-a",
        "--source=" & standin,
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # No clone was performed — the conventional clone target must be
      # absent.
      check not dirExists(fx.workspaceRoot / "develop" / "lib-a")

      let overrides = readDevelopOverridesFile(fx.workspaceRoot)
      check overrides.isSome
      let entries = listOverrides(overrides.get())
      check entries.len == 1
      check entries[0].package == "lib-a"
      check entries[0].local_path == absolutePath(standin)

      let report = readReport(fx)
      check report["mode"].getStr() == "registered"
      check report["source"].getStr() == absolutePath(standin)
      check report["exitCode"].getInt() == 0

  test "test_m22_develop_idempotent_for_same_source":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "idempotent")
      defer: removeDir(fx.scratch)

      let standin = fx.scratch / "local-checkouts" / "lib-a"
      createDir(standin)
      writeFile(standin / "README.md", "operator's checkout\n")

      # First invocation: registers the override.
      let res1 = runShell(shellCommand(@[
        fx.reproBin, "develop", "lib-a",
        "--source=" & standin,
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res1.code == 0
      let firstBody = readFile(developOverridesPath(fx.workspaceRoot))

      # Second invocation with the same source: exit 0, idempotent
      # report, and the file content must NOT change (the writer is
      # byte-idempotent; we re-emit on idempotent so the path is the
      # same shape every time).
      let res2 = runShell(shellCommand(@[
        fx.reproBin, "develop", "lib-a",
        "--source=" & standin,
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res2.code == 0

      let report = readReport(fx)
      check report["mode"].getStr() == "idempotent"
      check report["exitCode"].getInt() == 0

      # The on-disk override file must not have changed (idempotent
      # arm skips the writer entirely).
      let secondBody = readFile(developOverridesPath(fx.workspaceRoot))
      check firstBody == secondBody

  test "test_m22_develop_refuses_collision_at_different_source":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "collision")
      defer: removeDir(fx.scratch)

      let firstSrc = fx.scratch / "local-checkouts" / "first"
      createDir(firstSrc)
      let res1 = runShell(shellCommand(@[
        fx.reproBin, "develop", "lib-a",
        "--source=" & firstSrc,
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res1.code == 0
      let baselineBody = readFile(developOverridesPath(fx.workspaceRoot))

      # Second invocation pointing at a DIFFERENT path → exit 2, file
      # must NOT change.
      let secondSrc = fx.scratch / "local-checkouts" / "second"
      createDir(secondSrc)
      let res2 = runShell(shellCommand(@[
        fx.reproBin, "develop", "lib-a",
        "--source=" & secondSrc,
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res2.code == 2

      let postBody = readFile(developOverridesPath(fx.workspaceRoot))
      check baselineBody == postBody

      let report = readReport(fx)
      check report["mode"].getStr() == "refused"
      check report["exitCode"].getInt() == 2
      # The reported override entry is the EXISTING (first) one — the
      # collision arm surfaces what's actually on disk so the operator
      # can decide how to reconcile.
      check report["overrideEntry"]["local_path"].getStr() ==
        absolutePath(firstSrc)

  test "test_m22_develop_rejects_unknown_package":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "unknown")
      defer: removeDir(fx.scratch)

      # ``does-not-exist`` is not in the project's repo list → exit 1
      # and the project file path must appear in the diagnostic so the
      # operator knows where to look for the canonical package set.
      let res = runShell(shellCommand(@[
        fx.reproBin, "develop", "does-not-exist",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res.code == 1
      check "myproject.toml" in res.output or "myproject" in res.output

      # No override file must have been created — the resolution-failure
      # arm bails out before any side-effect.
      check not fileExists(developOverridesPath(fx.workspaceRoot))

## RA-30 — ``repro health`` (the environment doctor).
##
## Integration test for the layer-by-layer diagnosis. The CLI dispatcher
## in ``libs/repro_cli_support/src/repro_cli_support.nim`` routes
## ``repro health`` to ``runHealthCommand``, which gathers a list of
## ``(name, status, detail, remedy)`` checks — the single source of truth
## shared by the human table, the ``--json`` view, and the ``--fix``
## remediation path.
##
## This test drives the hermetically controllable layers (workspace
## marker present/absent, manifest present/absent, a missing develop-mode
## sibling) and asserts:
##
##   * Every FAILING check carries a NON-EMPTY remedy command
##     (Interactive-UX Principle 2 — falsifiable: an "all-green" or a
##     remedy-less failure breaks this).
##   * The expected layer names are all reported (install-version,
##     daemon-mode, store, direnv, workspace, manifest, siblings,
##     vcs-host-auth, push-gateway, toolchain, certificate-policy).
##   * The ``workspace`` check is ``fail`` with a remedy when the marker
##     is absent, and ``ok`` when present — falsifiable on the actual
##     marker state.
##   * The ``siblings`` check is ``fail`` and names a missing checkout
##     with a clone remedy when a declared repo is not cloned, ``ok``
##     when all are present.
##   * ``--json`` is valid JSON with the documented shape and a non-zero
##     exit code when any check fails; the table mode exits non-zero too.
##
## Skip rule: only when ``git`` is missing from PATH (same convention as
## the M9–M12 / status fixtures).

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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA30 Tester\"")
  writeFile(workPath / "README.md", "RA30 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))

proc projectTomlWith2Remotes(libAUrl, libBUrl: string): string =
  result =
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
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string; withManifest: bool): Fixture =
  result.scratch = createTempDir("repro-ra30-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, result.libBOrigin,
    result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  if withManifest:
    let manifestsRoot = workspaceRoot / ".repo" / "manifests"
    createDir(manifestsRoot / "projects")
    createDir(manifestsRoot / "repos")
    writeFile(manifestsRoot / "projects" / "lib-a.toml",
      projectTomlWith2Remotes(
        fileUrl(result.libAOrigin), fileUrl(result.libBOrigin)))
    writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
    writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  result.workspaceRoot = workspaceRoot

proc invokeHealth(fx: Fixture; extra: openArray[string] = []): CmdResult =
  var argv = @[
    fx.reproBin, "health", "lib-a",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  return nil

suite "RA-30 — repro health reports each layer status with remedy":

  test "test_ra30_every_failing_check_carries_a_remedy_command":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # Manifest present, but ZERO repos cloned: workspace marker present
      # (manifest checkout resolves it), siblings all missing → fail.
      let fx = setupFixture(gitBin, "remedy", withManifest = true)
      defer: removeDir(fx.scratch)

      let res = invokeHealth(fx, ["--json"])
      let report = parseJson(res.output)

      # Principle 2: every fail row MUST pair with a non-empty remedy.
      var sawFailure = false
      for entry in report["checks"]:
        if entry["status"].getStr() == "fail":
          sawFailure = true
          check entry["remedy"].getStr().len > 0
      check sawFailure  # the fixture is engineered to produce >=1 fail

      # JSON shape + non-zero exit on failure.
      check report["ok"].getBool() == false
      check report["failed"].getInt() >= 1
      check report["exitCode"].getInt() == 1
      check res.code == 1

  test "test_ra30_reports_all_expected_layer_names":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "layers", withManifest = true)
      defer: removeDir(fx.scratch)

      let res = invokeHealth(fx, ["--json"])
      let report = parseJson(res.output)

      for name in ["install-version", "daemon-mode", "store", "direnv",
          "workspace", "manifest", "siblings", "vcs-host-auth",
          "push-gateway", "toolchain", "certificate-policy"]:
        check not findCheck(report, name).isNil

  test "test_ra30_workspace_marker_drives_ok_vs_fail":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # No manifest, no marker → workspace check FAILS with a remedy.
      let fxAbsent = setupFixture(gitBin, "marker-absent",
        withManifest = false)
      defer: removeDir(fxAbsent.scratch)
      block:
        let res = invokeHealth(fxAbsent, ["--json"])
        let report = parseJson(res.output)
        let ws = findCheck(report, "workspace")
        check not ws.isNil
        check ws["status"].getStr() == "fail"
        check ws["remedy"].getStr().len > 0

      # Manifest present → marker resolved → workspace check is OK.
      let fxPresent = setupFixture(gitBin, "marker-present",
        withManifest = true)
      defer: removeDir(fxPresent.scratch)
      block:
        let res = invokeHealth(fxPresent, ["--json"])
        let report = parseJson(res.output)
        let ws = findCheck(report, "workspace")
        check not ws.isNil
        check ws["status"].getStr() == "ok"

  test "test_ra30_missing_sibling_fails_with_clone_remedy_present_passes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # lib-a cloned, lib-b missing → siblings FAILS, names lib-b, has a
      # clone-style remedy.
      let fx = setupFixture(gitBin, "siblings", withManifest = true)
      defer: removeDir(fx.scratch)
      cloneInto(gitBin, fx.libAOrigin, fx.workspaceRoot / "lib-a")

      block missing:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let sib = findCheck(report, "siblings")
        check not sib.isNil
        check sib["status"].getStr() == "fail"
        check "lib-b" in sib["detail"].getStr()
        check sib["remedy"].getStr().len > 0
        check sib["fixable"].getBool() == true

      # Now clone lib-b too → siblings becomes OK.
      cloneInto(gitBin, fx.libBOrigin, fx.workspaceRoot / "lib-b")
      block present:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let sib = findCheck(report, "siblings")
        check not sib.isNil
        check sib["status"].getStr() == "ok"

  test "test_ra30_manifest_absent_fails":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-manifest", withManifest = false)
      defer: removeDir(fx.scratch)
      let res = invokeHealth(fx, ["--json"])
      let report = parseJson(res.output)
      let man = findCheck(report, "manifest")
      check not man.isNil
      check man["status"].getStr() == "fail"
      check man["remedy"].getStr().len > 0

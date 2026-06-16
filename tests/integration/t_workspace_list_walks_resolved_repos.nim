## M12 — ``repro workspace list``.
##
## Integration test for the read-only list subcommand. The CLI
## dispatcher in ``libs/repro_cli_support/src/repro_cli_support.nim``
## routes ``repro workspace list`` to ``runWorkspaceListCommand``,
## which:
##
##   1. Resolves the named project / variant via the M6 surface (or
##      composes layers via M8 when ``.repo/workspace.toml`` is
##      present). Single-project / M6 path exercised here.
##   2. Walks the resulting ``ResolvedProject.repos`` and emits the
##      declared (name, path, remote, revision) tuples plus the
##      ``manifestLayer`` / ``visibility`` fields M8 stamps.
##   3. Emits ``<workspaceRoot>/.repro/workspace/list-report.json``;
##      exits 0 on success, 1 on resolver failure.
##
## Unlike ``status``, list does NO live VCS observation — the repos
## need not even exist on disk. The fixture therefore skips the
## clone step entirely.
##
## Skip rule: the fixture needs ``git`` only to compile the ``repro``
## binary's auxiliary tooling (the M2 query module still links into
## the binary even when this subcommand never invokes it). We retain
## the same skip-if-no-git rule the other M9-M12 tests use for
## consistency.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

# ---- manifest TOML strings ------------------------------------------------

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" & libCUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
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

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "lib-c-origin"
revision = "main"
"""

# ---- fixture builder ------------------------------------------------------

type
  M12ListFixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(slug: string): M12ListFixture =
  result.scratch = createTempDir("repro-m12-list-" & slug & "-", "")
  result.reproBin = reproBinary()

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectTomlWith3Remotes(
      fileUrl(result.scratch / "origin-lib-a.git"),
      fileUrl(result.scratch / "origin-lib-b.git"),
      fileUrl(result.scratch / "origin-lib-c.git")))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-c.toml", libCFragmentToml)
  result.workspaceRoot = workspaceRoot

proc invokeList(fx: M12ListFixture;
                project = "myproject";
                extra: openArray[string] = []): CmdResult =
  var argv = @[
    fx.reproBin, "workspace", "list", project,
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc readReport(fx: M12ListFixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "list-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc findRepo(repos: JsonNode; name: string): JsonNode =
  for entry in repos:
    if entry["name"].getStr() == name:
      return entry
  return nil

# ---- the suite -------------------------------------------------------------

suite "M12 — repro workspace list (walks resolved repos)":

  test "test_m12_list_emits_declared_repo_tuples":
    let fx = setupFixture("declared-tuples")
    defer: removeDir(fx.scratch)

    let res = invokeList(fx)
    if res.code != 0:
      checkpoint("output: " & res.output)
    check res.code == 0

    let report = readReport(fx)
    check report["exitCode"].getInt() == 0
    check report["project"].getStr() == "myproject"
    check report["trunk"].getStr() == "main"
    check report["defaultRevision"].getStr() == "main"
    check report["repos"].len == 3

    let libA = findRepo(report["repos"], "lib-a")
    let libB = findRepo(report["repos"], "lib-b")
    let libC = findRepo(report["repos"], "lib-c")
    check not libA.isNil
    check not libB.isNil
    check not libC.isNil

    check libA["path"].getStr() == "lib-a"
    check libA["remote"].getStr() == "lib-a-origin"
    check libA["revision"].getStr() == "main"
    check libA["vcs"].getStr() == "git"
    # Single-project mode: no manifest layer attached, visibility
    # defaults to "public" (the M6 resolver's default for
    # ``WorkspaceVisibility``).
    check libA["manifestLayer"].getStr() == ""
    check libA["visibility"].getStr() == "public"

    check libB["path"].getStr() == "lib-b"
    check libB["remote"].getStr() == "lib-b-origin"
    check libB["revision"].getStr() == "main"
    check libC["path"].getStr() == "lib-c"
    check libC["remote"].getStr() == "lib-c-origin"
    check libC["revision"].getStr() == "main"

  test "test_m12_list_json_mode_emits_parseable_payload":
    let fx = setupFixture("json-mode")
    defer: removeDir(fx.scratch)

    let res = invokeList(fx, extra = ["--json"])
    check res.code == 0

    # ``--json`` prints the report payload to stdout. The fixture
    # captures both stdout and stderr; the JSON object starts at the
    # first ``{`` so any preceding log lines are tolerated.
    let braceIdx = res.output.find('{')
    check braceIdx >= 0
    let payload = res.output[braceIdx .. ^1]
    let parsed = parseJson(payload)
    check parsed["project"].getStr() == "myproject"
    check parsed["repos"].len == 3
    # Same content as the on-disk report.
    let onDisk = readReport(fx)
    check parsed["repos"].len == onDisk["repos"].len
    var disk: seq[string]
    for entry in onDisk["repos"]: disk.add(entry["name"].getStr())
    var stdoutRepos: seq[string]
    for entry in parsed["repos"]: stdoutRepos.add(entry["name"].getStr())
    check disk == stdoutRepos

  test "test_m12_list_unknown_project_exits_1":
    let fx = setupFixture("unknown")
    defer: removeDir(fx.scratch)

    let res = invokeList(fx, project = "does-not-exist")
    check res.code == 1
    # The dispatcher's stderr branch prints "repro workspace list:
    # error:" prefix before re-raising the structured ValueError.
    check res.output.contains("repro workspace list: error:")
    check res.output.contains("does-not-exist")

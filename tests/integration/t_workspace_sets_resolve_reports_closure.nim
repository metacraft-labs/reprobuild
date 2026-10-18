## `repro workspace projects resolve <name>...` / `repro workspace sets
## resolve <name>...` — the resolved participating repo set of a REQUESTED set
## of projects, printed as data.
##
## `resolveProjectSet` already computed this closure (it is what `enable`
## validates a prospective set with), but no command printed it: `projects list`
## names no repos, `repos list --set=` takes one name and prints raw fragments,
## and `sync <p>… --dry-run` is scoped to the ACTIVE set, so a defined but
## not-enabled project contributed nothing to its plan. See CLI/workspace.md
## §"`repro workspace projects`" (`resolve`) and the Union Rules in
## Workspace-And-Develop-Mode.md.
##
## Fixture (hermetic): a workspace root that carries `projects/` and `repos/`
## directly (the native flat manifest layout). It is deliberately NOT a git
## checkout: resolution answers from the manifests alone, and needing a git
## identity would make the read-only command fail where `list` succeeds.
##
##   * `alpha` includes `repos/alpha-only.toml` and `repos/shared.toml`.
##   * `beta`  includes `repos/shared.toml` and `repos/beta-only.toml`.
##   * `gamma` includes `repos/shared-pinned.toml`, which declares the SAME
##     checkout path `shared` at a different revision.
##   * The active set is `[alpha]` only.
##
## Asserted:
##   1. `projects resolve alpha beta --json` exits 0 with schema
##      `reprobuild.workspace-set-resolve.v1`, status `resolved`, `requested`
##      and `primary` as given, and repos in union order
##      [alpha-only, shared, beta-only] — `shared` exactly once, and
##      `beta-only` present although `beta` is NOT enabled here. Each entry
##      carries name / path / remote / fetchUrl (composed from the remote's
##      fetch base) / revision / branch / vcs.
##   2. `sets resolve` is the same command and prints the same document.
##   3. It is read-only: the workspace tree is byte-identical afterwards and
##      no repo was checked out.
##   4. A conflict over one checkout path exits 1 and is reported AS DATA:
##      status `conflict`, the path, both sources, `fields` naming
##      `revision`, an empty `repos`, and a message that names the path and
##      both sources without attributing the conflict to the active-set
##      record (`.repro/workspace.toml`). Without `--json` the same
##      diagnostic goes to stderr.
##   5. An unknown name exits 1 with status `error`; no name, or an unknown
##      flag, is a usage error (exit 2).
##   6. The human form prints one tab-separated line per repo:
##      name, path, fetchUrl, revision.
##   7. A repeated name counts once.
##
## No mocks: the real `repro` binary runs against real manifest files on the
## real filesystem, and the active set is written through the real state
## writer.

import std/[algorithm, json, os, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_workspace_manifests

const
  ResolveSchema = "reprobuild.workspace-set-resolve.v1"
  FetchBase = "https://git.example.invalid/acme"

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc repoFragment(name, path, revision: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & path & "\"\n" &
    "remote = \"acme\"\n" &
    "revision = \"" & revision & "\"\n"

proc projectFile(name: string; includes: openArray[string]): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name & "\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"acme\"\nfetch = \"" & FetchBase & "\"\n\n" &
    "includes = [\n"
  for inc in includes:
    result.add("  \"" & inc & "\",\n")
  result.add("]\n")

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(slug: string): Fixture =
  result.scratch = createTempDir("repro-sets-resolve-" & slug & "-", "")
  result.reproBin = reproBinary()
  let root = result.scratch / "workspace"
  createDir(root / "projects")
  createDir(root / "repos")
  writeFile(root / "repos" / "alpha-only.toml",
    repoFragment("alpha-only", "alpha-only", "main"))
  writeFile(root / "repos" / "beta-only.toml",
    repoFragment("beta-only", "beta-only", "main"))
  writeFile(root / "repos" / "shared.toml",
    repoFragment("shared", "shared", "main"))
  # The same checkout path at a different revision: the PS-4 conflict.
  writeFile(root / "repos" / "shared-pinned.toml",
    repoFragment("shared", "shared", "v2"))
  writeFile(root / "projects" / "alpha.toml",
    projectFile("alpha", ["repos/alpha-only.toml", "repos/shared.toml"]))
  writeFile(root / "projects" / "beta.toml",
    projectFile("beta", ["repos/shared.toml", "repos/beta-only.toml"]))
  writeFile(root / "projects" / "gamma.toml",
    projectFile("gamma", ["repos/shared-pinned.toml"]))
  # Only `alpha` is enabled, so anything `beta` contributes can only have come
  # from the manifests, never from the active set.
  writeWorkspaceProjects(root, @["alpha"])
  result.workspaceRoot = root

proc resolveArgv(fx: Fixture; args: openArray[string]): seq[string] =
  result = @[fx.reproBin]
  for a in args: result.add(a)
  result.add("--workspace-root=" & fx.workspaceRoot)

proc runSplit(fx: Fixture; args: openArray[string]): CmdSplitResult =
  # Run from the scratch dir, OUTSIDE the workspace, so only the explicit
  # `--workspace-root=` can name it.
  runShellSplit(shellCommand(resolveArgv(fx, args)), cwd = fx.scratch)

proc treeSnapshot(root: string): seq[string] =
  ## Every path under `root` with its size and mtime — enough to see a file
  ## created, removed or rewritten by a command that claims to be read-only.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                              pcLinkToDir}):
    let info = getFileInfo(path, followSymlink = false)
    result.add(relativePath(path, root) & "\t" & $info.size & "\t" &
      $info.lastWriteTime.toUnix & "." & $info.lastWriteTime.nanosecond)
  result.sort()

proc repoNames(doc: JsonNode): seq[string] =
  for entry in doc["repos"]:
    result.add(entry["name"].getStr)

suite "workspace sets resolve — the closure of a requested set, as data":

  test "t_workspace_sets_resolve_reports_union_closure":
    let fx = setupFixture("union")
    defer: removeDir(fx.scratch)

    let before = treeSnapshot(fx.workspaceRoot)
    let res = runSplit(fx, ["ws", "projects", "resolve", "alpha", "beta",
      "--json"])
    if res.code != 0:
      checkpoint("stdout: " & res.stdout & "\nstderr: " & res.stderr)
    check res.code == 0
    let doc = parseJson(res.stdout)
    check doc["schema"].getStr == ResolveSchema
    check doc["workspaceRoot"].getStr == fx.workspaceRoot
    check doc["status"].getStr == "resolved"
    check doc["requested"] == %*["alpha", "beta"]
    check doc["primary"].getStr == "alpha"
    check doc["conflict"].kind == JNull
    check doc["error"].kind == JNull
    # Union order: alpha's repos first-seen, then beta's previously-unseen
    # ones. `shared` is declared identically by both, so it merges silently
    # into ONE entry; `beta-only` appears although `beta` is not enabled.
    check repoNames(doc) == @["alpha-only", "shared", "beta-only"]
    for entry in doc["repos"]:
      let name = entry["name"].getStr
      check entry["path"].getStr == name
      check entry["remote"].getStr == "acme"
      check entry["fetchUrl"].getStr == FetchBase & "/" & name
      check entry["revision"].getStr == "main"
      check entry.hasKey("branch")
      check entry["vcs"].getStr == "git"

    # Read-only: nothing written, nothing checked out.
    check treeSnapshot(fx.workspaceRoot) == before
    for name in ["alpha-only", "shared", "beta-only"]:
      check not dirExists(fx.workspaceRoot / name)
    check readWorkspaceProjects(fx.workspaceRoot) == @["alpha"]

  test "t_workspace_sets_resolve_is_the_projects_resolve_alias":
    let fx = setupFixture("alias")
    defer: removeDir(fx.scratch)

    let viaProjects = runSplit(fx, ["ws", "projects", "resolve", "alpha",
      "beta", "--json"])
    let viaSets = runSplit(fx, ["ws", "sets", "resolve", "alpha", "beta",
      "--json"])
    check viaProjects.code == 0
    check viaSets.code == 0
    check parseJson(viaSets.stdout) == parseJson(viaProjects.stdout)

  test "t_workspace_sets_resolve_dedups_repeated_names":
    let fx = setupFixture("dedup")
    defer: removeDir(fx.scratch)

    let res = runSplit(fx, ["ws", "sets", "resolve", "beta", "alpha", "beta",
      "--json"])
    check res.code == 0
    let doc = parseJson(res.stdout)
    check doc["requested"] == %*["beta", "alpha"]
    check doc["primary"].getStr == "beta"
    check repoNames(doc) == @["shared", "beta-only", "alpha-only"]

  test "t_workspace_sets_resolve_reports_conflict_as_data":
    let fx = setupFixture("conflict")
    defer: removeDir(fx.scratch)

    let before = treeSnapshot(fx.workspaceRoot)
    let res = runSplit(fx, ["ws", "projects", "resolve", "alpha", "gamma",
      "--json"])
    check res.code == 1
    let doc = parseJson(res.stdout)
    check doc["schema"].getStr == ResolveSchema
    check doc["status"].getStr == "conflict"
    check doc["primary"].getStr == "alpha"
    check doc["repos"].len == 0
    check doc["error"].kind == JNull
    let conflict = doc["conflict"]
    check conflict["path"].getStr == "shared"
    check conflict["sources"] == %*["alpha", "gamma"]
    check conflict["fields"] == %*["revision"]
    check conflict["message"].getStr.contains("checkout path 'shared'")
    check conflict["message"].getStr.contains("revision (main vs v2)")
    check conflict["message"].getStr.contains("'alpha'")
    check conflict["message"].getStr.contains("'gamma'")
    # `resolve` does not read the active-set record, so the diagnostic must
    # not attribute the conflict to it (the `[<file>] at key ...` prefix that
    # `enable`'s refusal carries names `.repro/workspace.toml`).
    check not conflict["message"].getStr.contains("workspace.toml")
    check treeSnapshot(fx.workspaceRoot) == before

    # Without --json the refusal is a diagnostic on stderr, still exit 1.
    let human = runSplit(fx, ["ws", "projects", "resolve", "alpha", "gamma"])
    check human.code == 1
    check human.stdout.len == 0
    check human.stderr.contains("repro workspace projects resolve: ")
    check human.stderr.contains("checkout path 'shared'")
    check not human.stderr.contains("workspace.toml")

  test "t_workspace_sets_resolve_error_and_usage_exits":
    let fx = setupFixture("errors")
    defer: removeDir(fx.scratch)

    let unknown = runSplit(fx, ["ws", "sets", "resolve", "alpha", "nosuch",
      "--json"])
    check unknown.code == 1
    let doc = parseJson(unknown.stdout)
    check doc["status"].getStr == "error"
    check doc["conflict"].kind == JNull
    check doc["repos"].len == 0
    check doc["error"].getStr.contains("nosuch")

    # The first name failing leaves no resolved primary to report.
    let unknownFirst = runSplit(fx, ["ws", "sets", "resolve", "nosuch",
      "--json"])
    check unknownFirst.code == 1
    check parseJson(unknownFirst.stdout)["primary"].getStr == ""

    let noNames = runSplit(fx, ["ws", "sets", "resolve", "--json"])
    check noNames.code == 2
    let badFlag = runSplit(fx, ["ws", "projects", "resolve", "alpha",
      "--bogus"])
    check badFlag.code == 2
    check badFlag.stderr.contains("--bogus")

  test "t_workspace_sets_resolve_human_lines":
    let fx = setupFixture("human")
    defer: removeDir(fx.scratch)

    let res = runSplit(fx, ["ws", "projects", "resolve", "alpha", "beta"])
    if res.code != 0:
      checkpoint("stdout: " & res.stdout & "\nstderr: " & res.stderr)
    check res.code == 0
    check res.stdout.strip.splitLines == @[
      "alpha-only\talpha-only\t" & FetchBase & "/alpha-only\tmain",
      "shared\tshared\t" & FetchBase & "/shared\tmain",
      "beta-only\tbeta-only\t" & FetchBase & "/beta-only\tmain",
    ]

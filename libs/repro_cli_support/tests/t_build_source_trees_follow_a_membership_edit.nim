## The source trees a build reads (`buildSourceTrees`, the volatile-path
## fold's scope beside the build's own roots) follow the workspace's declared
## membership, including after an edit in the same process.
##
## The membership is resolved once per process and kept until a document it
## is read from changes. Kept by size and modification time, an edit that
## renamed a member to a path of the same length within one timestamp tick
## was not seen, and the member's new checkout was left out of the scope: a
## read there under a volatile prefix is dropped silently. The case writes
## such an edit and puts the old modification time back, which is that tick.
##
## NO MOCKS: a real workspace layout on disk and the CLI's own derivation.

import std/[os, tempfiles, times, unittest]

import repro_cli_support

proc writeFragment(ws, name, path: string) =
  writeFile(ws / "repos" / (name & ".toml"),
    "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & path & "\"\n" &
    "remote = \"origin\"\nmainline = \"main\"\n")

proc writeWorkspace(ws, libPath: string) =
  createDir(ws / ".repro")
  createDir(ws / "projects")
  createDir(ws / "repos")
  createDir(ws / "app")
  writeFile(ws / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nbranch = \"main\"\n")
  writeFile(ws / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n\n" &
    "[[remote]]\nname = \"origin\"\nfetch = \"https://example.invalid/\"\n\n" &
    "includes = [\n  \"repos/app.toml\",\n  \"repos/lib.toml\",\n]\n")
  writeFragment(ws, "app", "app")
  writeFragment(ws, "lib", libPath)

suite "the source trees a build reads":
  test "a member moved to a path of the same length, in the same tick, is seen":
    let ws = normalizedPath(createTempDir("repro-source-trees-", ""))
    defer: removeDir(ws)
    writeWorkspace(ws, "libs/aaa")
    # A whole second, so that putting it back below is exact: the call that
    # sets it keeps microseconds only, and a stamp on the modification time
    # would see the nanoseconds it dropped as an edit.
    let fragment = ws / "repos" / "lib.toml"
    let stamp = fromUnix(1_700_000_000)
    setLastModificationTime(fragment, stamp)
    let first = buildSourceTrees(ws / "app")
    checkpoint($first)
    check ws in first
    check ws / "libs" / "aaa" in first

    let before = getFileSize(fragment)
    # Only the fragment changes: every other document keeps its stamp.
    writeFragment(ws, "lib", "libs/bbb")
    setLastModificationTime(fragment, stamp)
    check getFileSize(fragment) == before
    check getLastModificationTime(fragment) == stamp

    let second = buildSourceTrees(ws / "app")
    checkpoint($second)
    check ws / "libs" / "bbb" in second
    check ws / "libs" / "aaa" notin second

  test "a project with no workspace around it has no membership to resolve":
    let project = normalizedPath(createTempDir("repro-source-trees-bare-", ""))
    defer: removeDir(project)
    check buildSourceTrees(project).len == 0

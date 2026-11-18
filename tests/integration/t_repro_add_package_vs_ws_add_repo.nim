## `repro add` / `repro remove` edit the package dependencies of the current
## project's `repro.nim`; `repro ws add` / `repro ws remove` manage workspace
## repositories, and top-level `repro add|remove` refuse the
## workspace-repository flags instead of acting on the wrong layer.
##
## The cases:
##
##   1. `repro add "openssl >=3.3 <4.0" --build` writes exactly one
##      `buildDeps:` section into `repro.nim` (the resulting text is asserted
##      whole); `--dry-run` prints the diff and leaves the file byte-identical;
##      a second add is a no-op; `repro remove openssl` restores the original
##      bytes.
##   2. The scope flags pick the section (`uses:` by default, an existing
##      section is extended in place, `--native-build`, `--runtime`); two of
##      them, an argument no entry can express, and a second constraint for a
##      package already there are refused without writing. `name@constraint`
##      writes the same entry as `name constraint`.
##   3. A file declaring two packages needs `--package`.
##   4. The lock step: the edit leaves `repro.lock` untouched, validates it
##      offline (no lock / unreadable / stale for the named package /
##      consistent / undecided after a remove) and names
##      `repro lock refresh <dir>`, the command that re-solves it.
##   4a. The project's `repro.nim` is looked for no higher than the enclosing
##      repository or workspace root: inside a nested repository without one,
##      the enclosing directory's `repro.nim` is NOT edited (positive control:
##      without the `.git` marker it is).
##   4b. A package name that is also a declared workspace repository gets a
##      `note:` (add) or a `tip:` naming `repro ws remove` (remove).
##   5. THE NEGATIVE CONTROL. `repro add foo --remote=https://example/foo.git`
##      exits 2 with `error:` and a `tip:` naming exactly `repro ws add foo
##      --remote=https://example/foo.git`, and leaves every file of a scratch
##      workspace (its `repro-workspace.toml`, manifests and `repro.nim`)
##      byte-identical. A build in which the flag reached the old
##      repository-adding path exits 0 and writes the manifests, and fails
##      here. Every other workspace-repository flag of `repro add` and `repro
##      remove` is refused the same way.
##   6. `repro ws add` (develop) and `repro workspace repos add` leave
##      byte-identical `repos/<repo>.toml` and `projects/<project>.toml` in two
##      identical workspaces, for a project written with `includes` and for
##      one written with neither array; `repro ws remove` and `repro
##      workspace repos remove` then leave byte-identical project files.
##      `repro ws remove` matches an `includes` entry by the path it resolves
##      to, so `./repos/lib.toml` is dropped too.
##
## MOCKS: none. The real `build/bin/repro` runs as a subprocess against real
## files, with HOME and the XDG directories pointed into the scratch
## directory; case 6 uses real local bare git origins and a real git manifest
## repository. `https://example/foo.git` is never contacted: the command
## refuses before reading anything.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Scratch = object
  dir, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.dir = createTempDir("repro-add-pkg-", "")
  result.home = createTempDir("repro-add-pkg-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    ("REPRO_WORKSPACE_CONFIG", ""), ("REPRO_DEFAULT_PROJECTS", ""),
    ("GIT_TERMINAL_PROMPT", "0"),
    # `repro workspace repos add` commits into the scratch manifest repo.
    ("GIT_AUTHOR_NAME", "Tester"), ("GIT_AUTHOR_EMAIL", "t@example.invalid"),
    ("GIT_COMMITTER_NAME", "Tester"),
    ("GIT_COMMITTER_EMAIL", "t@example.invalid")]

proc dispose(s: Scratch) =
  removeDir(s.dir)
  removeDir(s.home)

proc run(s: Scratch; cwd: string; argv: openArray[string]): tuple[code: int;
         output: string] =
  let res = runShell(shellCommand(@[reproBinary()] & @argv, s.env),
    cwd = cwd, timeoutMs = 180_000)
  checkpoint("repro " & argv.join(" ") & " (in " & cwd & ") -> exit " &
    $res.code & "\n" & res.output)
  (res.code, res.output)

proc snapshot(dir: string): seq[(string, string)] =
  ## Every file under ``dir`` with its bytes, sorted by path.
  for path in walkDirRec(dir, relative = true):
    result.add((path, readFile(dir / path)))
  result.sort()

const original = """import reprobuild

package hello:
  ## The program.
  uses:
    "nim >=2.2 <3.0"

  executable hello:
    discard
"""

proc projectDir(s: Scratch; text = original; lock = ""): string =
  result = s.dir / "project"
  createDir(result)
  writeFile(result / "repro.nim", text)
  if lock.len > 0:
    writeFile(result / "repro.lock", lock)

suite "repro add / remove: package dependencies of repro.nim":

  test "add --build writes the section; --dry-run, twice, and remove":
    let s = newScratch()
    defer: s.dispose()
    let dir = s.projectDir()
    let recipe = dir / "repro.nim"

    let preview = s.run(dir, ["add", "openssl >=3.3 <4.0", "--build",
      "--dry-run"])
    check preview.code == 0
    check readFile(recipe) == original
    check "+  buildDeps:" in preview.output
    check "+    \"openssl >=3.3 <4.0\"" in preview.output
    check "was not written" in preview.output

    let added = s.run(dir, ["add", "openssl >=3.3 <4.0", "--build"])
    check added.code == 0
    let expected = """import reprobuild

package hello:
  ## The program.
  buildDeps:
    "openssl >=3.3 <4.0"
  uses:
    "nim >=2.2 <3.0"

  executable hello:
    discard
"""
    check readFile(recipe) == expected

    let again = s.run(dir, ["add", "openssl >=3.3 <4.0", "--build"])
    check again.code == 0
    check "nothing to change" in again.output
    check readFile(recipe) == expected
    # Unconstrained, it is the same package already there.
    check s.run(dir, ["add", "openssl", "--build"]).code == 0
    check readFile(recipe) == expected
    # A different constraint is the author's to change, not this command's.
    let other = s.run(dir, ["add", "openssl >=3.0", "--build"])
    check other.code == 1
    check "another constraint" in other.output
    check readFile(recipe) == expected

    let removePreview = s.run(dir, ["remove", "openssl", "--dry-run"])
    check removePreview.code == 0
    check "-    \"openssl >=3.3 <4.0\"" in removePreview.output
    check readFile(recipe) == expected

    let removed = s.run(dir, ["remove", "openssl"])
    check removed.code == 0
    check readFile(recipe) == original
    let absent = s.run(dir, ["remove", "openssl"])
    check absent.code == 1
    check "is not a dependency" in absent.output
    check readFile(recipe) == original

  test "the scope flags pick the section":
    let s = newScratch()
    defer: s.dispose()
    let dir = s.projectDir()
    let recipe = dir / "repro.nim"

    # Default: `uses:`, extended in place after its last entry.
    check s.run(dir, ["add", "zlib@>=1.3"]).code == 0
    check readFile(recipe) == original.replace(
      "    \"nim >=2.2 <3.0\"\n",
      "    \"nim >=2.2 <3.0\"\n    \"zlib >=1.3\"\n")
    check s.run(dir, ["remove", "zlib"]).code == 0
    check readFile(recipe) == original

    for (flag, section) in [("--native-build", "nativeBuildDeps"),
                            ("--runtime", "runtimeDeps"),
                            ("--build", "buildDeps")]:
      check s.run(dir, ["add", "curl", flag]).code == 0
      check readFile(recipe) == original.replace("  ## The program.\n",
        "  ## The program.\n  " & section & ":\n    \"curl\"\n")
      check s.run(dir, ["remove", "curl"]).code == 0
      check readFile(recipe) == original

    # Refused without writing: two sections, and arguments no entry can
    # express.
    for argv in [@["add", "curl", "--build", "--runtime"],
                 @["add", "curl@latest"], @["add", "curl@"],
                 @["add", "cu\"rl"], @["add", "curl >=x.y.z"],
                 @["add"], @["remove", "curl >=1"]]:
      let res = s.run(dir, argv)
      check res.code == 2
      check "error:" in res.output
      check readFile(recipe) == original

  test "a file with two packages needs --package":
    let s = newScratch()
    defer: s.dispose()
    let two = """import reprobuild

package a:
  executable a:
    discard

package b:
  executable b:
    discard
"""
    let dir = s.projectDir(two)
    let recipe = dir / "repro.nim"
    let ambiguous = s.run(dir, ["add", "zlib"])
    check ambiguous.code == 2
    check "--package" in ambiguous.output
    check readFile(recipe) == two
    check s.run(dir, ["add", "zlib", "--package=nope"]).code == 1
    check s.run(dir, ["add", "zlib", "--package=b"]).code == 0
    check readFile(recipe) == two.replace("package b:\n",
      "package b:\n  uses:\n    \"zlib\"\n")
    check s.run(dir, ["remove", "zlib", "--package=b"]).code == 0
    check readFile(recipe) == two

  test "the lock is validated offline and never written":
    let s = newScratch()
    defer: s.dispose()
    proc lockOf(packages: openArray[(string, string)]): string =
      var items: seq[string]
      for (name, version) in packages:
        items.add("{ name = \"" & name & "\", version = \"" & version &
          "\", source = \"" & name & "\", selection = \"selected\" }")
      "schema = \"reprobuild.solved-graph-lock.v3\"\n\n[lock]\n" &
        "platform = \"amd64-linux\"\noptimal = false\n" &
        "inputs_digest = \"fixture\"\nvariants = []\n" &
        "packages = [" & items.join(", ") & "]\ndeps = []\n"
    let without = lockOf([("nim", "2.2.4")])
    let dir = s.projectDir(lock = without)
    let refresh = "repro lock refresh " & quoteShell(dir)
    let stale = s.run(dir, ["add", "zlib >=1.3"])
    check stale.code == 0
    check ("repro.lock is stale for `uses:` of package 'hello': it " &
      "resolves no package for zlib; re-solve it with: " & refresh) in
      stale.output
    check readFile(dir / "repro.lock") == without
    let removedStale = s.run(dir, ["remove", "zlib"])
    check removedStale.code == 0
    check "repro.lock is consistent with `uses:`" in removedStale.output
    let with = lockOf([("nim", "2.2.4"), ("zlib", "1.3.1")])
    writeFile(dir / "repro.lock", with)
    let consistent = s.run(dir, ["add", "zlib >=1.3"])
    check consistent.code == 0
    check "repro.lock is consistent with `uses:` of package 'hello'" in
      consistent.output
    check refresh in consistent.output
    let undecided = s.run(dir, ["remove", "zlib"])
    check undecided.code == 0
    check "repro.lock still resolves zlib 1.3.1" in undecided.output
    check readFile(dir / "repro.lock") == with

  test "the project's repro.nim is looked for within its repository":
    let s = newScratch()
    defer: s.dispose()
    let outer = s.projectDir()
    let inner = outer / "vendor" / "lib"
    createDir(inner / ".git")
    let refused = s.run(inner, ["add", "zlib"])
    check refused.code == 1
    check "no repro.nim" in refused.output
    check "tip:" in refused.output
    check readFile(outer / "repro.nim") == original
    removeDir(inner / ".git")
    # Positive control: without the marker the ancestor's recipe is found.
    let found = s.run(inner, ["add", "zlib", "--dry-run"])
    check found.code == 0
    check "+    \"zlib\"" in found.output
    check readFile(outer / "repro.nim") == original
    createDir(inner / ".repro")
    # A workspace root marker stops the search the same way.
    writeFile(inner / ".repro" / "workspace-state.toml",
      "schema = \"reprobuild.workspace.state.v1\"\n\n" &
      "[workspace]\nproject = \"demo\"\n")
    let atRoot = s.run(inner, ["add", "zlib"])
    check atRoot.code == 1
    check "no repro.nim" in atRoot.output
    check readFile(outer / "repro.nim") == original

  test "the edit names the lock refresh and leaves repro.lock alone":
    let s = newScratch()
    defer: s.dispose()
    let lock = "# a lock the edit must not touch\n"
    let dir = s.projectDir(lock = lock)
    # From a subdirectory: the project is the nearest ancestor's repro.nim.
    createDir(dir / "src")
    let added = s.run(dir / "src", ["add", "zlib"])
    check added.code == 0
    check ("repro lock refresh " & quoteShell(dir)) in added.output
    check readFile(dir / "repro.lock") == lock
    check s.run(dir, ["remove", "zlib"]).code == 0
    check readFile(dir / "repro.lock") == lock
    removeFile(dir / "repro.lock")
    let unlocked = s.run(dir, ["add", "zlib"])
    check unlocked.code == 0
    check "no repro.lock" in unlocked.output
    check not fileExists(dir / "repro.lock")

suite "top-level repro add / remove refuse workspace-repository flags":

  proc workspaceFixture(s: Scratch): string =
    ## A workspace with a settings file, a project, a fragment and a
    ## `repro.nim` at its root: everything the refused command could touch.
    result = s.dir / "ws"
    createDir(result / "projects")
    createDir(result / "repos")
    createDir(result / ".repro")
    writeFile(result / "repro-workspace.toml",
      "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
      "[develop]\norg_urls = [\"https://example/\"]\n")
    writeFile(result / "projects" / "demo.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "includes = [\n  \"repos/app.toml\",\n]\n\n" &
      "[project]\nname = \"demo\"\n\n" &
      "[[remote]]\nname = \"origin\"\nfetch = \"https://example\"\n")
    writeFile(result / "repos" / "app.toml",
      "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"app\"\n" &
      "path = \"app\"\nremote = \"origin\"\nmainline = \"main\"\n")
    writeFile(result / ".repro" / "workspace-state.toml",
      "schema = \"reprobuild.workspace.state.v1\"\n\n" &
      "[workspace]\nproject = \"demo\"\n")
    writeFile(result / "repro.nim", original)

  test "--remote names the exact repro ws add command and changes nothing":
    let s = newScratch()
    defer: s.dispose()
    let ws = s.workspaceFixture()
    let before = snapshot(ws)
    let res = s.run(ws, ["add", "foo", "--remote=https://example/foo.git"])
    check res.code == 2
    check "error:" in res.output
    check "tip:" in res.output
    check "repro ws add foo --remote=https://example/foo.git" in res.output
    check snapshot(ws) == before
    check not dirExists(ws / "foo")
    # The form the repository verb could complete offline (a binary
    # dependency is recorded, never cloned), and so the one that would write
    # the project manifest if the flag reached it.
    let binary = s.run(ws, ["add", "foo", "--remote=https://example/foo.git",
      "--binary"])
    check binary.code == 2
    check ("repro ws add foo --remote=https://example/foo.git --binary") in
      binary.output
    check snapshot(ws) == before

  test "every other workspace-repository flag is refused the same way":
    let s = newScratch()
    defer: s.dispose()
    let ws = s.workspaceFixture()
    let before = snapshot(ws)
    for (flag, carried) in [("--no-membership", "--no-membership"),
        ("--develop", "--develop"), ("--binary", "--binary"),
        ("--no-develop", "--binary"), ("--revision=main", "--revision=main"),
        ("--depends-of=app", "--depends-of=app"),
        ("--workspace-root=" & ws, "--workspace-root=" & ws),
        ("--tool-provisioning=path", "--tool-provisioning=path"),
        ("--json", "--json")]:
      let res = s.run(ws, ["add", "foo", flag, "--dry-run"])
      check res.code == 2
      check "error:" in res.output
      check ("tip: to add the workspace repository, run: repro ws add foo " &
        quoteShell(carried) & " --dry-run") in res.output
      check snapshot(ws) == before
    # A package flag is not carried into the workspace command.
    let mixed = s.run(ws, ["add", "foo", "--develop", "--build"])
    check mixed.code == 2
    check "repro ws add foo --develop\n" in mixed.output
    check "--build" in mixed.output
    for (flag, carried) in [("--force", "--force"), ("--yes", "--force"),
        ("--json", "--json"),
        ("--workspace-root=" & ws, "--workspace-root=" & ws),
        ("--tool-provisioning=path", "--tool-provisioning=path")]:
      let res = s.run(ws, ["remove", "app", flag])
      check res.code == 2
      check "error:" in res.output
      check ("tip: to remove the workspace repository, run: repro ws remove " &
        "app " & quoteShell(carried)) in res.output
      check snapshot(ws) == before
    check not dirExists(ws / "foo")

  test "a package name that is a workspace repository is pointed at ws":
    let s = newScratch()
    defer: s.dispose()
    let ws = s.workspaceFixture()
    let before = snapshot(ws)
    let rm = s.run(ws, ["remove", "app"])
    check rm.code == 1
    check "is not a dependency" in rm.output
    check "tip: 'app' is a repository of this workspace" in rm.output
    check "run: repro ws remove app" in rm.output
    check snapshot(ws) == before
    let add = s.run(ws, ["add", "app", "--dry-run"])
    check add.code == 0
    check "note: 'app' is also a repository of this workspace" in add.output
    check "`repro ws add` manages workspace repositories" in add.output
    check snapshot(ws) == before
    # Negative control: a package that is no repository gets neither.
    let plain = s.run(ws, ["remove", "zstd"])
    check plain.code == 1
    check "repository of this workspace" notin plain.output

suite "repro ws add / remove declare repositories as workspace repos add":

  proc gitOk(args: openArray[string]; cwd = "") =
    let res = execCmdEx(quoteShellCommand(@["git"] & @args),
      workingDir = cwd)
    if res.exitCode != 0:
      checkpoint("git " & args.join(" ") & ":\n" & res.output)
    doAssert res.exitCode == 0

  proc seedOrigin(s: Scratch): string =
    ## A bare origin at `<scratch>/org/lib` with one commit on `main`; the org
    ## directory's URL is the project's `org` remote.
    let origin = s.dir / "org" / "lib"
    let work = s.dir / "seed"
    gitOk(["init", "-q", "--bare", "-b", "main", origin])
    gitOk(["init", "-q", "-b", "main", work])
    writeFile(work / "README.md", "lib\n")
    gitOk(["-C", work, "add", "README.md"])
    gitOk(["-C", work, "-c", "user.email=t@example.invalid", "-c",
      "user.name=Tester", "commit", "-q", "-m", "seed"])
    gitOk(["-C", work, "push", "-q", origin, "main"])
    fileUrl(origin)

  proc workspace(s: Scratch; name, orgUrl: string; includes: bool): string =
    result = s.dir / name
    createDir(result / "projects")
    createDir(result / "repos")
    createDir(result / ".repro")
    writeFile(result / "projects" / "demo.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      (if includes: "includes = [\n  \"repos/app.toml\",\n]\n\n" else: "") &
      "[project]\nname = \"demo\"\n\n" &
      "[[remote]]\nname = \"org\"\nfetch = \"" & orgUrl & "\"\n")
    writeFile(result / "repos" / "app.toml",
      "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"app\"\n" &
      "path = \"app\"\nremote = \"org\"\nmainline = \"main\"\n")
    writeFile(result / ".repro" / "workspace-state.toml",
      "schema = \"reprobuild.workspace.state.v1\"\n\n" &
      "[workspace]\nproject = \"demo\"\n")
    writeFile(result / ".gitignore", ".repro/\nlib/\nworkspace-projects.md\n")
    gitOk(["init", "-q", "-b", "main", result])
    gitOk(["-C", result, "add", "-A"])
    gitOk(["-C", result, "-c", "user.email=t@example.invalid", "-c",
      "user.name=Tester", "commit", "-q", "-m", "fixture"])

  test "the same fragment and project edits, both edge spellings":
    if findExe("git").len == 0:
      skip("git is not on PATH; this case clones from a local origin")
    else:
      for includes in [true, false]:
        let s = newScratch()
        defer: s.dispose()
        let url = s.seedOrigin()
        let orgUrl = url[0 ..< url.rfind('/')]
        let viaWs = s.workspace("via-ws", orgUrl, includes)
        let viaRepos = s.workspace("via-repos", orgUrl, includes)
        let projectBefore = readFile(viaWs / "projects" / "demo.toml")

        let wsAdd = s.run(viaWs, ["ws", "add", "lib", "--remote=" & url,
          "--develop", "--revision=main", "--workspace-root=" & viaWs])
        check wsAdd.code == 0
        check dirExists(viaWs / "lib" / ".git")
        let reposAdd = s.run(viaRepos, ["workspace", "repos", "add", "lib",
          "--remote=" & url, "--mainline=main", "--project=demo",
          "--workspace-root=" & viaRepos])
        check reposAdd.code == 0

        let fragment = readFile(viaWs / "repos" / "lib.toml")
        check fragment == readFile(viaRepos / "repos" / "lib.toml")
        check fragment == "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
          "[repo]\nname = \"lib\"\npath = \"lib\"\nremote = \"org\"\n" &
          "mainline = \"main\"\n"
        let project = readFile(viaWs / "projects" / "demo.toml")
        check project == readFile(viaRepos / "projects" / "demo.toml")
        check project != projectBefore
        if includes:
          check "\"repos/lib.toml\"" in project
          check "member_repos" notin project
        else:
          check "member_repos" in project
          check "includes" notin project

        let wsRemove = s.run(viaWs, ["ws", "remove", "lib",
          "--workspace-root=" & viaWs])
        check wsRemove.code == 0
        check not dirExists(viaWs / "lib")
        let reposRemove = s.run(viaRepos, ["workspace", "repos", "remove",
          "lib", "--workspace-root=" & viaRepos])
        check reposRemove.code == 0
        let after = readFile(viaWs / "projects" / "demo.toml")
        check after == readFile(viaRepos / "projects" / "demo.toml")
        check "lib" notin after
        # The fragment is a reusable declaration: both keep it.
        check fileExists(viaWs / "repos" / "lib.toml")
        check fileExists(viaRepos / "repos" / "lib.toml")

  test "ws remove drops an includes entry spelled as another path":
    if findExe("git").len == 0:
      skip("git is not on PATH; this case clones from a local origin")
    else:
      let s = newScratch()
      defer: s.dispose()
      let url = s.seedOrigin()
      let orgUrl = url[0 ..< url.rfind('/')]
      let ws = s.workspace("dotted", orgUrl, includes = true)
      check s.run(ws, ["ws", "add", "lib", "--remote=" & url, "--develop",
        "--revision=main", "--workspace-root=" & ws]).code == 0
      let project = ws / "projects" / "demo.toml"
      let added = readFile(project)
      check "\"repos/lib.toml\"" in added
      writeFile(project, added.replace("\"repos/lib.toml\"",
        "\"./repos/lib.toml\""))
      let removed = s.run(ws, ["ws", "remove", "lib",
        "--workspace-root=" & ws])
      check removed.code == 0
      let after = readFile(project)
      check "lib.toml" notin after
      check "\"repos/app.toml\"" in after

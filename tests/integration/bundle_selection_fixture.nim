## Shared fixture for the tests of bundles of a workspace selection: a
## workspace with three repositories whose builds each produce an output
## carrying a marker unique to the repository, and helpers to build them,
## run the `repro` under test, unpack a bundle half and compare trees.
##
## Not a test (no `t_` prefix), so the suite generator never compiles it on
## its own. The tests that import it are
## `t_selection_bundle_contains_only_the_selection`,
## `t_a_bundle_says_when_a_project_pins_an_upstream_nim`,
## `t_bad_bundles_are_refused_before_writing`,
## `t_manifest_is_readable_without_import` and
## `t_bundle_restores_on_a_plain_machine_without_rebuilding`.
##
## Everything is real: the built `repro`, real Git checkouts, the engine's
## monitor and action cache, GNU tar and zstd for the bundle halves. Nothing
## is mocked.

import std/[algorithm, hashes, json, os, osproc, posix, streams, strtabs,
  strutils, tables]

import library_cache_sharing_fixture

export library_cache_sharing_fixture

const
  Repos* = ["alpha", "beta", "gamma"]
  PairProject* = "pair"
    ## A selection of two of the three: `alpha` and `beta`.
  AllProject* = "all"
    ## Every repository.

proc markerOf*(repo: string): string =
  ## The marker every artefact of `repo` carries: its package name, its
  ## source file's name and bytes, its output's name and bytes, and so its
  ## records and the blobs the engine stores for it. An identifier, so it
  ## can be the package name.
  "marker" & repo & "7f3e"

proc produceEdge*(repo: string): string = repo & "-produce"

proc outputRel*(repo: string): string = "out" / ("out-" & markerOf(repo) & ".txt")

proc run(cmd: string; cwd: string) =
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(OSError, "`" & cmd & "` failed in " & cwd &
      " (exit " & $res.exitCode & "):\n" & res.output)

proc gitInit(dir: string; origin = "") =
  let g = "git -c user.email=fixture@example.invalid -c user.name=fixture " &
    "-c commit.gpgsign=false "
  run("git init -q -b main", dir)
  run(g & "add -A", dir)
  run(g & "commit -q -m fixture", dir)
  if origin.len > 0:
    run("git remote add origin " & quoteShell(origin), dir)

const
  DslExportName* = "dslexport"
    ## With `writeWorkspace(dslExport = true)`, a directory of the workspace
    ## root's own checkout whose `repro.nim` exports one constant, and which
    ## beta's recipe imports through `dslDeps:` (resolved at compile time as
    ## `<beta>/../dslexport`).
  DslExportSymbol* = "dslexportGreeting"

proc writeRepo(dir, repo: string; dslDeps = false) =
  let marker = markerOf(repo)
  createDir(dir / "src")
  writeFile(dir / "src" / ("in-" & marker & ".txt"), "source " & marker & "\n")
  writeFile(dir / ".gitignore", "out/\n.repro/\n")
  # One monitored action: copy the source to the output and append a line,
  # so the output's bytes carry the marker and differ from the source's.
  writeFile(dir / "repro.nim", """import std/os
import repro_project_dsl

package MARKER:
  build:
    let root = activeProviderProjectRoot()
    let src = root / "src/in-MARKER.txt"
    let outp = root / "OUTREL"
    createDir(outp.parentDir)
    let a = buildAction(id = "EDGE",
      call = inlineExecCall(@["sh", "-c",
        "cat \"$1\" > \"$2\"; echo produced-MARKER >> \"$2\"", "sh", src, outp],
        root),
      inputs = @[src], outputs = @[outp],
      dependencyPolicy = automaticMonitorPolicy())
    defaultBuildAction(a)
""".multiReplace(("MARKER", marker),
    ("OUTREL", outputRel(repo)), ("EDGE", produceEdge(repo))) &
    (if not dslDeps: ""
     else:
       # The use is under `reproInterfaceMode`, the one compile that resolves
       # `dslDeps:`: an import the resolution dropped fails that compile.
       "  dslDeps:\n    \"" & DslExportName & "\"\n" &
       "  when defined(reproInterfaceMode):\n" &
       "    const imported = " & DslExportSymbol & "\n" &
       "    static: doAssert imported.len > 0\n"))
  gitInit(dir, "https://example.invalid/" & repo)

proc writeWorkspace*(ws: string; dslExport = false) =
  ## The workspace root (a Git checkout holding the manifests) with projects
  ## `pair` (alpha, beta) and `all` (alpha, beta, gamma), and the three
  ## repositories checked out beside the manifests. With `dslExport`, the
  ## root also holds `DslExportName`, and beta's recipe imports it with
  ## `dslDeps:`, a compile-time resolution through the engine.
  createDir(ws / "projects")
  createDir(ws / "repos")
  createDir(ws / "url-prefixes")
  writeFile(ws / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n[workspace]\n" &
    "mainline = \"main\"\n")
  writeFile(ws / ".gitignore", "/.repro/\n/alpha/\n/beta/\n/gamma/\n")
  writeFile(ws / "url-prefixes" / "acme.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
    "name = \"acme\"\nurl = \"https://example.invalid\"\n")
  for (name, members) in [(PairProject, @["alpha", "beta"]),
                          (AllProject, @Repos)]:
    var list: seq[string]
    for m in members: list.add("\"" & m & "\"")
    writeFile(ws / "projects" / (name & ".toml"),
      "schema = \"reprobuild.workspace.project.v1\"\n\nmember_repos = [" &
      list.join(", ") & "]\n\n[project]\nname = \"" & name & "\"\n")
  for repo in Repos:
    writeFile(ws / "repos" / (repo & ".toml"),
      "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" &
      repo & "\"\npath = \"" & repo & "\"\nurl_prefix = \"acme\"\n" &
      "mainline = \"main\"\n")
  if dslExport:
    createDir(ws / DslExportName)
    writeFile(ws / DslExportName / "repro.nim",
      "const " & DslExportSymbol & "* = \"from the workspace root\"\n")
  gitInit(ws, "https://example.invalid/ws")
  createDir(ws / ".repro")
  writeFile(ws / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
    "project = \"pair\"\nprojects = [\"pair\"]\n")
  for repo in Repos:
    writeRepo(ws / repo, repo, dslDeps = dslExport and repo == "beta")

proc reproEnv*(host: SharedHost;
               extra: openArray[(string, string)] = []): StringTableRef =
  ## The invoking environment with the host's store root, no remote cache,
  ## and `extra` on top.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.startsWith("REPRO_BINARY_CACHE_") or key == "LD_PRELOAD":
      continue
    result[key] = value
  result["REPRO_STORE_ROOT"] = host.storeRoot
  result["REPROBUILD_ACTION_CACHE_ROOT"] = host.actionCacheRoot
  result["REPRO_CACHE_DISABLE"] = "1"
  for (key, value) in extra:
    result[key] = value

proc repro*(host: SharedHost; args: openArray[string]; cwd: string;
            extra: openArray[(string, string)] = []):
    tuple[code: int, output: string] =
  ## Run the `repro` under test; stdout and stderr together.
  let p = startProcess(reproBinary(), workingDir = cwd, args = args,
    env = reproEnv(host, extra), options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()

proc reproStdout*(host: SharedHost; args: openArray[string]; cwd: string;
                  extra: openArray[(string, string)] = []):
    tuple[code: int, stdout, stderr: string] =
  ## Run the `repro` under test, keeping stdout (a JSON report) apart.
  let errPath = host.scratch / "stderr.txt"
  let p = startProcess("/bin/sh", workingDir = cwd,
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errPath),
      reproBinary()] & @args,
    env = reproEnv(host, extra), options = {})
  result.stdout = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()
  result.stderr = (if fileExists(errPath): readFile(errPath) else: "")
  if fileExists(errPath): removeFile(errPath)

proc buildRepos*(host: var SharedHost; ws: string;
                 repos: openArray[string]): seq[BuildRun] =
  ## Build each repository against the host's store and action cache, with
  ## the portable identity on: the engine then also keeps the compiled
  ## project provider and the interface it extracts as content-keyed blobs
  ## under the action-cache root, each carrying the package name (the
  ## marker). Each build must succeed and execute its produce edge.
  for repo in repos:
    let run = host.build(ws / repo, portable = true, provisioning = "path")
    if run.code != 0 or not run.launched(produceEdge(repo)):
      raise newException(OSError, "the fixture build of " & repo &
        " failed or did not execute " & produceEdge(repo) & " (exit " &
        $run.code & "):\n" & run.output & "\n" & allEngineReasons(run))
    result.add(run)

proc partsOf*(halfDir, manifestName: string): seq[string] =
  let manifest = parseJson(readFile(halfDir / manifestName))
  for p in manifest["parts"]:
    result.add(halfDir / p["file"].getStr())

proc unpackHalf*(halfDir, manifestName, dest: string) =
  ## Decompress a half's parts and unpack its tar into `dest` (member paths
  ## are relative to `/`, so `dest` stands in for `/`). Only for inspecting
  ## what a half carries; a real restore is `repro bundle restore`.
  createDir(dest)
  var cat = "cat"
  for part in partsOf(halfDir, manifestName):
    cat.add(" " & quoteShell(part))
  run("set -o pipefail; " & cat & " | zstd -q -dc --long=27 | tar -x -C " &
    quoteShell(dest) & " -f -", dest)

proc halfStreamBytes*(halfDir, manifestName: string): string =
  ## The whole decompressed tar stream of a half: names and bytes of every
  ## member, for a search that cannot miss a member by its kind.
  var cat = "cat"
  for part in partsOf(halfDir, manifestName):
    cat.add(" " & quoteShell(part))
  let res = execCmdEx("set -o pipefail; " & cat & " | zstd -q -dc --long=27")
  if res.exitCode != 0:
    raise newException(OSError, "decompressing " & halfDir & " failed")
  res.output

proc filesContaining*(root, needle: string): seq[string] =
  ## Every regular file under `root` whose path or bytes contain `needle`,
  ## relative to `root`, sorted.
  if not dirExists(root):
    return
  for path in walkDirRec(root, yieldFilter = {pcFile}, relative = true,
                         skipSpecial = true):
    if needle in path or needle in readFile(root / path):
      result.add(path)
  result.sort()

proc halfDir*(bundleDir, halfKey: string): string =
  ## The directory of one half of a workspace bundle (`nix`, `sources`,
  ## `native_store`), from its `latest.json`.
  for kind, sysDir in walkDir(bundleDir):
    if kind == pcDir and fileExists(sysDir / "latest.json"):
      let latest = parseJson(readFile(sysDir / "latest.json"))
      if latest["halves"].hasKey(halfKey):
        return bundleDir / latest["halves"][halfKey]["dir"].getStr()
  raise newException(IOError, "no " & halfKey & " half in " & bundleDir)

proc snapshot*(roots: openArray[string]): OrderedTable[string, string] =
  ## Every path under `roots` (the roots too, or `absent`) with its kind,
  ## mode, size, mtime and bytes or link target: two equal snapshots mean
  ## the trees are byte-identical and nothing was added or removed.
  for root in roots:
    var st: Stat
    if lstat(root.cstring, st) != 0:
      result[root] = "absent"
      continue
    var paths = @[root]
    if S_ISDIR(st.st_mode):
      for p in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
          pcLinkToDir}, skipSpecial = false):
        paths.add(p)
    paths.sort()
    for p in paths:
      var s: Stat
      if lstat(p.cstring, s) != 0:
        result[p] = "vanished"
        continue
      var desc = "mode=" & toOct(int(s.st_mode), 7) & " size=" &
        $int64(s.st_size) & " mtime=" & $int64(s.st_mtim.tv_sec) & "." &
        $int64(s.st_mtim.tv_nsec)
      if S_ISLNK(s.st_mode):
        desc.add(" -> " & expandSymlink(p))
      elif S_ISREG(s.st_mode):
        let bytes = readFile(p)
        desc.add(" bytes=" & $bytes.len & ":" & $hash(bytes))
      result[p] = desc

proc snapshotDiff*(a, b: OrderedTable[string, string]): string =
  ## A readable account of how two snapshots differ, "" when they do not.
  var lines: seq[string]
  for p, d in a:
    if p notin b: lines.add("removed " & p)
    elif b[p] != d: lines.add("changed " & p & ": " & d & " -> " & b[p])
  for p, d in b:
    if p notin a: lines.add("added " & p)
  lines.join("\n")

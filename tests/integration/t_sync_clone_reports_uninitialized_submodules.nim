## A clone made by a workspace verb REPORTS the git submodules it left
## uninitialised.
##
## Contract (CLI/sync.md § "A cloned repository's own submodules are not
## initialised"): every verb that clones a participating repository —
## ``repro sync``, ``--to=<role>``, ``repro workspace pull``, and the
## materialization phase of ``repro workspace enable``, ``repro workspace
## init`` and the ``repro branch ../<dir>`` fork — clones a participating repository and nothing nested in it. The
## repository's own ``.gitmodules`` submodules stay uninitialised, exactly as
## after a plain ``git clone``. That must not be silent: a fresh clone with
## uninitialised submodules looks complete and fails later in a build, far
## from the command that made it. So each repository THIS RUN cloned whose
## submodules are not initialised is named, in text with the remedy
## ``git -C <path> submodule update --init --recursive``, and in ``--json``
## as ``submodulesUninitialized: [{path, uninitialized}]``. The notice does
## not change the exit code.
##
## The regression it pins: ``repro ws enable codetracer`` cloned codetracer
## with all 36 of its submodules uninitialised, said nothing, and the first
## build failed two minutes later on a missing grammar file.
##
## Fixture (hermetic, real git, no mocks): local bare upstreams for
##   * ``sub-one`` / ``sub-two`` — plain repos used as submodule sources;
##   * ``parent`` — declares both as submodules (``libs/one``, ``libs/two``);
##   * ``plain`` — no ``.gitmodules`` at all;
##   * ``already`` — also declares a submodule, but is checked out BEFORE the
##     run (without its submodule), so it is the "already on disk" case.
## Project ``alpha`` holds ``already``; project ``beta`` holds ``parent`` and
## ``plain``. The workspace starts with ``[alpha]`` enabled.
##
## Negative cases, each asserted: a cloned repo without ``.gitmodules`` is not
## reported; a repo already on disk with uninitialised submodules is not
## reported; ``--dry-run`` reports nothing. The submodules themselves are
## left uninitialised (reporting must not turn into initialising).
##
## Local ``file://`` submodule sources need ``protocol.file.allow=always`` for
## ``git submodule add`` since git 2.38.1; the FIXTURE passes it, the code
## under test never needs it, because it only reads local state.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string): string =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitIdentity(gitBin, workPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Submodule Tester\"")

proc seedOrigin(gitBin, originPath, workPath: string;
                submodules: openArray[(string, string)] = []) =
  ## A bare ``originPath`` with one commit on ``main``. Each
  ## ``(path, sourceUrl)`` in ``submodules`` is added with ``git submodule
  ## add``, so the commit carries both the ``.gitmodules`` entry and the
  ## gitlink — the shape a real superproject has.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitIdentity(gitBin, workPath)
  writeFile(workPath / "README.md", "submodule-notice fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  for (path, url) in submodules:
    discard requireGit(q(gitBin) & " -C " & q(workPath) &
      " -c protocol.file.allow=always submodule --quiet add " & q(url) & " " &
      q(path))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push -q origin main")

proc remoteBlock(name, url: string): string =
  "[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url & "\"\n\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "mainline = \"main\"\n"

proc projectFile(name, remotes: string; includes: openArray[string]): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name & "\"\n\n" & remotes & "includes = [\n"
  for inc in includes:
    result.add("  \"" & inc & "\",\n")
  result.add("]\n")

type
  Fixture = object
    scratch: string
    reproBin: string
    gitBin: string
    workspaceRoot: string

proc setupFixture(gitBin, slug: string; preCloneAlready = true;
                  enabled: seq[string] = @["alpha"]): Fixture =
  result.scratch = createTempDir("repro-submodule-notice-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.gitBin = gitBin
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")

  for name in ["sub-one", "sub-two"]:
    seedOrigin(gitBin, result.scratch / ("origin-" & name & ".git"),
      result.scratch / ("seed-" & name))
  let subOne = fileUrl(result.scratch / "origin-sub-one.git")
  let subTwo = fileUrl(result.scratch / "origin-sub-two.git")

  var remotes = ""
  for name in ["parent", "plain", "already"]:
    let origin = result.scratch / ("origin-" & name & ".git")
    let seed = result.scratch / ("seed-" & name)
    case name
    of "parent":
      seedOrigin(gitBin, origin, seed,
        [("libs/one", subOne), ("libs/two", subTwo)])
    of "already":
      seedOrigin(gitBin, origin, seed, [("vendor/one", subOne)])
    else:
      seedOrigin(gitBin, origin, seed)
    remotes.add(remoteBlock(name & "-origin", fileUrl(origin)))
    writeFile(workspaceRoot / "repos" / (name & ".toml"),
      repoFragment(name, name & "-origin"))

  writeFile(workspaceRoot / "projects" / "alpha.toml",
    projectFile("alpha", remotes, ["repos/already.toml"]))
  writeFile(workspaceRoot / "projects" / "beta.toml",
    projectFile("beta", remotes, ["repos/parent.toml", "repos/plain.toml"]))

  writeWorkspaceProjects(workspaceRoot, enabled)
  if preCloneAlready:
    # Already on disk, with its submodule uninitialised: the owner's state,
    # which no run may report.
    discard requireGit(q(gitBin) & " clone -q " &
      q(fileUrl(result.scratch / "origin-already.git")) & " " &
      q(workspaceRoot / "already"))
  result.workspaceRoot = workspaceRoot

proc runRepro(fx: Fixture; args: openArray[string]): CmdResult =
  var argv = @[fx.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

proc runReproSplit(fx: Fixture; args: openArray[string]): CmdSplitResult =
  var argv = @[fx.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShellSplit(shellCommand(argv))

proc jsonDocument(stdoutText: string): JsonNode =
  ## The JSON document on stdout. ``enable`` prints the recorded active set
  ## (one project per line) before the materialization phase's document, so
  ## parse from the first line that opens an object.
  let lines = stdoutText.splitLines()
  for i, line in lines:
    if line.startsWith("{"):
      return parseJson(lines[i .. ^1].join("\n"))
  checkpoint("no JSON document on stdout:\n" & stdoutText)
  raise newException(ValueError, "no JSON document on stdout")

proc remedy(fx: Fixture; repo: string): string =
  "git -C " & quoteShell(fx.workspaceRoot / repo) &
    " submodule update --init --recursive"

proc uninitializedCount(fx: Fixture; repo: string): int =
  ## Independent of the code under test: count git's own ``-`` markers.
  let status = requireGit(q(fx.gitBin) & " -C " &
    q(fx.workspaceRoot / repo) & " submodule status")
  for line in status.splitLines():
    if line.startsWith("-"):
      inc result

proc noticeLines(output: string): seq[string] =
  for line in output.splitLines():
    if "submodule update --init" in line:
      result.add(line)

proc checkParentEntryOnly(doc: JsonNode) =
  check doc.hasKey("submodulesUninitialized")
  if doc.hasKey("submodulesUninitialized"):
    let entries = doc["submodulesUninitialized"]
    check entries.kind == JArray
    check entries.len == 1
    if entries.len == 1:
      check entries[0]["path"].getStr() == "parent"
      check entries[0]["uninitialized"].getInt() == 2

suite "a sync clone reports the submodules it left uninitialised":

  test "enable names a cloned repo with uninitialised submodules and the remedy":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "enable-text")
    defer: removeDir(fx.scratch)
    let res = runRepro(fx, ["workspace", "enable", "beta"])
    checkpoint(res.output)
    # A notice, not a failure.
    check res.code == 0
    check dirExists(fx.workspaceRoot / "parent" / ".git")
    check dirExists(fx.workspaceRoot / "plain" / ".git")
    let notices = noticeLines(res.output)
    check notices.len == 1
    if notices.len == 1:
      check "parent" in notices[0]
      check "2 " in notices[0]
      check remedy(fx, "parent") in notices[0]
    # Negative: neither the clone with no .gitmodules nor the repo that was
    # already on disk (itself carrying an uninitialised submodule) is named.
    check remedy(fx, "plain") notin res.output
    check remedy(fx, "already") notin res.output
    # Reported, not acted on: the submodules are still uninitialised.
    check uninitializedCount(fx, "parent") == 2
    check uninitializedCount(fx, "already") == 1

  test "enable --json carries submodulesUninitialized":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "enable-json")
    defer: removeDir(fx.scratch)
    let res = runReproSplit(fx, ["workspace", "enable", "beta", "--json"])
    checkpoint(res.stdout)
    checkpoint(res.stderr)
    check res.code == 0
    let doc = jsonDocument(res.stdout)
    check doc["exitCode"].getInt() == 0
    checkParentEntryOnly(doc)

  test "enable --write-report persists submodulesUninitialized":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "enable-report")
    defer: removeDir(fx.scratch)
    let res = runRepro(fx, ["workspace", "enable", "beta", "--write-report"])
    checkpoint(res.output)
    check res.code == 0
    let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
      "sync-report.json"
    check fileExists(reportPath)
    if fileExists(reportPath):
      checkParentEntryOnly(parseFile(reportPath))

  test "enable --dry-run clones nothing and reports nothing":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "enable-dry")
    defer: removeDir(fx.scratch)
    let res = runRepro(fx, ["workspace", "enable", "beta", "--dry-run"])
    checkpoint(res.output)
    check res.code == 0
    check not dirExists(fx.workspaceRoot / "parent")
    check noticeLines(res.output).len == 0
    let js = runReproSplit(fx, ["workspace", "enable", "beta", "--dry-run",
      "--json"])
    checkpoint(js.stdout)
    check js.code == 0
    let doc = jsonDocument(js.stdout)
    check doc.hasKey("submodulesUninitialized")
    if doc.hasKey("submodulesUninitialized"):
      check doc["submodulesUninitialized"].len == 0

  test "a plain sync that clones a missing repo reports it":
    let gitBin = findExe("git")
    require gitBin.len > 0
    # Both projects enabled, only ``already`` on disk: ``repro sync`` itself
    # is the verb that clones ``parent`` and ``plain``.
    let fx = setupFixture(gitBin, "sync", enabled = @["alpha", "beta"])
    defer: removeDir(fx.scratch)
    let res = runRepro(fx, ["sync"])
    checkpoint(res.output)
    check res.code == 0
    let notices = noticeLines(res.output)
    check notices.len == 1
    if notices.len == 1:
      check remedy(fx, "parent") in notices[0]
    check remedy(fx, "plain") notin res.output
    check remedy(fx, "already") notin res.output
    # A second sync clones nothing, so it reports nothing — even though
    # ``parent``'s submodules are still uninitialised.
    let again = runReproSplit(fx, ["sync", "--json"])
    checkpoint(again.stdout)
    check again.code == 0
    let doc = jsonDocument(again.stdout)
    check doc.hasKey("submodulesUninitialized")
    if doc.hasKey("submodulesUninitialized"):
      check doc["submodulesUninitialized"].len == 0

  test "sync --mainline that clones a missing repo reports it":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "mainline", enabled = @["alpha", "beta"])
    defer: removeDir(fx.scratch)
    let dry = runRepro(fx, ["sync", "--mainline", "--dry-run"])
    checkpoint(dry.output)
    check dry.code == 0
    check noticeLines(dry.output).len == 0
    let res = runReproSplit(fx, ["sync", "--mainline", "--json"])
    checkpoint(res.stdout)
    checkpoint(res.stderr)
    check res.code == 0
    let doc = jsonDocument(res.stdout)
    checkParentEntryOnly(doc)
    removeDir(fx.workspaceRoot / "parent")
    let text = runRepro(fx, ["sync", "--mainline"])
    checkpoint(text.output)
    check text.code == 0
    let notices = noticeLines(text.output)
    check notices.len == 1
    if notices.len == 1:
      check remedy(fx, "parent") in notices[0]

  test "workspace init reports the repos it cloned":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "init", enabled = @["beta"])
    defer: removeDir(fx.scratch)
    let res = runRepro(fx, ["workspace", "init", "beta"])
    checkpoint(res.output)
    check res.code == 0
    let notices = noticeLines(res.output)
    check notices.len == 1
    if notices.len == 1:
      check remedy(fx, "parent") in notices[0]
    check remedy(fx, "plain") notin res.output
    # Re-running init on the now-complete workspace clones nothing and so
    # reports nothing.
    let again = runReproSplit(fx, ["workspace", "init", "beta", "--json"])
    checkpoint(again.stdout)
    check again.code == 0
    let doc = jsonDocument(again.stdout)
    check doc.hasKey("submodulesUninitialized")
    if doc.hasKey("submodulesUninitialized"):
      check doc["submodulesUninitialized"].len == 0
    # The JSON shape of a cloning init is pinned by a FRESH workspace, not by
    # deleting the checkouts and re-running init here: a re-run is served from
    # init's action cache and does not recreate a deleted checkout at all (a
    # separate defect, recorded on its own), so it would test that instead.
    let fresh = setupFixture(gitBin, "init-json", enabled = @["beta"])
    defer: removeDir(fresh.scratch)
    let js = runReproSplit(fresh, ["workspace", "init", "beta", "--json"])
    checkpoint(js.stdout)
    checkpoint(js.stderr)
    check js.code == 0
    checkParentEntryOnly(jsonDocument(js.stdout))

  test "workspace pull reports the repos it cloned":
    let gitBin = findExe("git")
    require gitBin.len > 0
    # Both projects enabled, only ``already`` on disk: ``pull``'s clone arm
    # materializes ``parent`` and ``plain``; ``already`` is converged in place.
    let fx = setupFixture(gitBin, "pull", enabled = @["alpha", "beta"])
    defer: removeDir(fx.scratch)
    let res = runRepro(fx, ["workspace", "pull"])
    checkpoint(res.output)
    check res.code == 0
    let notices = noticeLines(res.output)
    check notices.len == 1
    if notices.len == 1:
      check "workspace pull" in notices[0]
      check remedy(fx, "parent") in notices[0]
    check remedy(fx, "plain") notin res.output
    check remedy(fx, "already") notin res.output
    check uninitializedCount(fx, "parent") == 2
    # ``pull`` has no ``--json``; its document is the written report.
    let pullReport = fx.workspaceRoot / ".repro" / "build" / "reports" /
      "pull-report.json"
    # A second pull clones nothing, so its report lists nothing.
    let again = runRepro(fx, ["workspace", "pull", "--write-report"])
    checkpoint(again.output)
    check again.code == 0
    check noticeLines(again.output).len == 0
    check fileExists(pullReport)
    if fileExists(pullReport):
      let doc = parseFile(pullReport)
      check doc.hasKey("submodulesUninitialized")
      if doc.hasKey("submodulesUninitialized"):
        check doc["submodulesUninitialized"].len == 0
    # The report of a cloning pull, on a fresh workspace (see the init case for
    # why not by deleting a checkout and re-running).
    let fresh = setupFixture(gitBin, "pull-report", enabled = @["alpha", "beta"])
    defer: removeDir(fresh.scratch)
    let js = runRepro(fresh, ["workspace", "pull", "--write-report"])
    checkpoint(js.output)
    check js.code == 0
    let freshReport = fresh.workspaceRoot / ".repro" / "build" / "reports" /
      "pull-report.json"
    check fileExists(freshReport)
    if fileExists(freshReport):
      checkParentEntryOnly(parseFile(freshReport))

  test "a branch fork reports the member repos it cloned":
    let gitBin = findExe("git")
    require gitBin.len > 0
    # The fork form clones the workspace ROOT repo, so the source here is a
    # real clone of a root repo carrying the manifests. Its ``parent`` has its
    # submodules INITIALISED; the fork's fresh clone of it does not, which is
    # exactly the silent difference the notice exists for.
    let fx = setupFixture(gitBin, "fork", preCloneAlready = false,
      enabled = @["beta"])
    defer: removeDir(fx.scratch)
    let rootSeed = fx.scratch / "seed-root"
    discard requireGit(q(gitBin) & " init -q -b main " & q(rootSeed))
    gitIdentity(gitBin, rootSeed)
    copyDir(fx.workspaceRoot / "projects", rootSeed / "projects")
    copyDir(fx.workspaceRoot / "repos", rootSeed / "repos")
    discard requireGit(q(gitBin) & " -C " & q(rootSeed) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(rootSeed) & " commit -q -m root")
    let rootBare = fx.scratch / "origin-root.git"
    discard requireGit(q(gitBin) & " clone -q --bare " & q(rootSeed) & " " &
      q(rootBare))
    let source = fx.scratch / "source"
    discard requireGit(q(gitBin) & " clone -q " & q(fileUrl(rootBare)) & " " &
      q(source))
    gitIdentity(gitBin, source)
    for name in ["parent", "plain"]:
      discard requireGit(q(gitBin) & " -c protocol.file.allow=always clone -q " &
        "--recurse-submodules " &
        q(fileUrl(fx.scratch / ("origin-" & name & ".git"))) & " " &
        q(source / name))
    writeWorkspaceProjects(source, @["beta"])
    writeWorkspaceBranch(source, project = "beta", branch = "main")
    let srcFx = Fixture(scratch: fx.scratch, reproBin: fx.reproBin,
      gitBin: gitBin, workspaceRoot: source)
    check uninitializedCount(srcFx, "parent") == 0
    let dest = fx.scratch / "forked"
    let res = runShell(shellCommand([fx.reproBin, "branch", "--write-report",
      dest, "--workspace-root=" & source]))
    checkpoint(res.output)
    check res.code == 0
    let destFx = Fixture(scratch: fx.scratch, reproBin: fx.reproBin,
      gitBin: gitBin, workspaceRoot: dest)
    check dirExists(dest / "parent" / ".git")
    check uninitializedCount(destFx, "parent") == 2
    let notices = noticeLines(res.output)
    check notices.len == 1
    if notices.len == 1:
      check "workspace branch" in notices[0]
      check remedy(destFx, "parent") in notices[0]
    check remedy(destFx, "plain") notin res.output
    let reportPath = dest / ".repro" / "build" / "reports" / "branch-report.json"
    check fileExists(reportPath)
    if fileExists(reportPath):
      checkParentEntryOnly(parseFile(reportPath))

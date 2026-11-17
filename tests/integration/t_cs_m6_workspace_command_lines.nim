## The workspace and publication commands (`workspace`/`ws` with every
## subcommand, `sync`, `pull`, `branch`, `switch`, `push`, `check`, `hooks`,
## `lock`, `locking`, `gateway`, `add`, `remove`) take their command lines
## from repro's description: each answers `--help` (and `repro help
## <command>`) from its declarations, a command line the description does not
## accept is a usage error (exit 2) naming the command, retired spellings
## stay unknown, and a command line it accepts reaches the command with the
## values it gave.
##
## The arms, and what makes each one evidence:
##
##   1. Help. Every command and subcommand of the group prints its generated
##      usage on stdout and exits 0 through `<command> --help`, `<command>
##      -h` and `help <command>`, and through the `help` words the old
##      parsers answered (`hooks help`, `branch help`, `switch help`, `ws
##      sets help`, ...). The internal flags of `workspace lock` stay out of
##      the help. Before this group moved, `repro hooks protocol --help` was
##      refused and `repro workspace status --help` was an unsupported flag,
##      so the arm can fail.
##   2. Usage errors. Unknown flags, a missing subcommand, extra arguments:
##      each exits 2 and names the command. The retired spellings (`sync
##      --groups`, `branch --from-mainlines`, `branch
##      <name> --checkout`, `workspace start|branch|project`, `checkout`,
##      `co`, `workspace projects add --default`, workspace `--report`,
##      `--manifest-layer-root`) are refused as unknown, and the retired
##      `--from-mainlines` names its replacement, under `branch`, `workspace
##      new` and `ws new` alike.
##   3. The managed hooks' handshake. `hooks protocol --require=2` answers
##      `2`; the contract token of a body this build installs is serviced
##      (exit 0) and a foreign one is refused with exit 3 (the status the
##      bodies tell apart); a wrong or missing `--require`, or a flag this
##      build does not know, fails with neither 0 nor 3. The tokens come from
##      bodies installed by this binary into a scratch repository.
##   4. Values reach the command (in process, through the same generated
##      parser the engine uses): the dispatch shape the hook bodies write
##      (`hooks dispatch <hook> --protocol=2 --repo-root R --refs-file F --
##      <git args>`, `--phase=P --dispatcher-displaced=D`), the repo
##      selectors (repeatable and comma-separated), the role flags, the
##      `--write-report[=PATH]` forms, and the commands' own refusals of
##      contradictions (two roles, `--rebase` with `--merge`, `--fetch` with
##      `--no-fetch`, `check` without `--mode`).
##
## No mocks: the real `build/bin/repro` runs as a subprocess, in an empty
## directory with a fresh HOME and XDG directories, and arm 4 runs the
## generated parser in process. Every command line here fails before it
## would change anything, only prints help, or (arm 3) installs hooks into a
## scratch repository. Nothing is fetched, pushed or published.

import std/[options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

import repro_cli_support/cli_program

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-ws-cli-cwd-", "")
  result.home = createTempDir("repro-ws-cli-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    # A workspace the calling shell names must not reach these lines.
    ("REPRO_WORKSPACE_CONFIG", ""), ("REPRO_DEFAULT_PROJECTS", ""),
    ("REPROBUILD_REPRO", ""),
    # The hooks this binary installs are run by the `repro` on PATH, which
    # must be this build for its own hooks to be serviced (arm 3).
    ("PATH", reproBinary().parentDir & PathSep & getEnv("PATH"))]

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc run(s: Scratch; argv: openArray[string]): tuple[code: int,
         output: string] =
  let res = runShell(shellCommand(@[reproBinary()] & @argv, s.env),
    cwd = s.cwd, timeoutMs = 120_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code & "\n" &
    res.output)
  (res.code, res.output)

proc entriesUnder(dir: string): seq[string] =
  for entry in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}):
    result.add(entry)

var parsedCommand: ReproCommandLine

proc parsed(argv: openArray[string]): int =
  ## ``argv`` through the generated parser, in process; the configuration
  ## it selects is left in ``parsedCommand``.
  parsedCommand = ReproCommandLine()
  runReproArgs(argv, proc (conf: ReproCommandLine): int =
    parsedCommand = conf
    0)

const GroupCommands = [
  @["workspace"], @["workspace", "restore"], @["workspace", "init"],
  @["workspace", "bootstrap"], @["workspace", "enable"],
  @["workspace", "disable"], @["workspace", "sets"],
  @["workspace", "sets", "list"], @["workspace", "sets", "resolve"],
  @["workspace", "sets", "add"], @["workspace", "sets", "remove"],
  @["workspace", "projects"], @["workspace", "repos"],
  @["workspace", "repos", "list"], @["workspace", "repos", "add"],
  @["workspace", "repos", "remove"], @["workspace", "status"],
  @["workspace", "lock"], @["workspace", "list"],
  @["workspace", "manifests"], @["workspace", "branch-roles"],
  @["workspace", "forall"], @["workspace", "shared-clones"],
  @["workspace", "sync"], @["workspace", "pull"], @["workspace", "new"],
  @["workspace", "switch"], @["workspace", "provision"],
  @["workspace", "migrate"], @["workspace", "migrate-locks"],
  @["workspace", "publish-evidence"], @["ws", "sync"], @["sync"], @["pull"],
  @["branch"], @["switch"], @["push"], @["check"], @["hooks"],
  @["hooks", "ensure"], @["hooks", "reinstall"], @["hooks", "uninstall"],
  @["hooks", "protocol"], @["hooks", "dispatch"], @["hooks", "cache-push"],
  @["lock"], @["lock", "list"], @["lock", "solve"], @["lock", "refresh"],
  @["lock", "update"], @["lock", "validate"], @["lock", "diff"],
  @["lock", "explain"], @["locking"], @["locking", "explain"],
  @["locking", "adopt-manifest"], @["gateway"], @["gateway", "pre-receive"],
  @["gateway", "post-receive"], @["gateway", "migrate"], @["add"],
  @["remove"]]

suite "the workspace and publication command lines":

  test "every command of the group answers help from its declarations":
    let s = newScratch()
    defer: s.dispose()
    var lines: seq[(seq[string], string)] = @[]
    for path in GroupCommands:
      let shown = if path[0] == "ws": @["workspace"] & path[1 .. ^1]
                  else: path
      let usage = "Usage: repro " & shown.join(" ")
      lines.add((path & @["--help"], usage))
      lines.add((path & @["-h"], usage))
      lines.add((@["help"] & path, usage))
    # The `help` words the old parsers answered.
    lines.add((@["hooks", "help"], "Usage: repro hooks"))
    lines.add((@["branch", "help"], "Usage: repro branch"))
    lines.add((@["switch", "help"], "Usage: repro switch"))
    lines.add((@["workspace", "sets", "help"], "Usage: repro workspace sets"))
    lines.add((@["workspace", "repos", "help"],
      "Usage: repro workspace repos"))
    lines.add((@["workspace", "bootstrap", "help"],
      "Usage: repro workspace bootstrap"))
    lines.add((@["workspace", "provision", "help"],
      "Usage: repro workspace provision"))
    # `--help` wins over the words around it.
    lines.add((@["sync", "--only", "a", "--help"], "Usage: repro sync"))
    lines.add((@["hooks", "dispatch", "pre-push", "--help"],
      "Usage: repro hooks dispatch"))
    for (argv, usage) in lines:
      let res = s.run(argv)
      check res.code == 0
      check usage in res.output
    # The internal flags stay out of the help; the shown ones are in it.
    let lockHelp = s.run(["workspace", "lock", "--help"]).output
    check "--record-store-root" in lockHelp
    check "--trigger-repo" notin lockHelp
    check "--sha" notin lockHelp
    let syncHelp = s.run(["sync", "--help"]).output
    for flag in ["--to", "--mainline", "--only", "--except", "--filter",
        "--tags", "--dry-run", "--rebase", "--merge", "--force-sync",
        "--write-report", "--no-write-report", "--jobs"]:
      check flag in syncHelp
    check s.cwd.entriesUnder().len == 0

  test "a command line the description does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    let lines = [
      (@["sync", "--bogus"], "repro sync"),
      (@["workspace", "sync", "--bogus"], "repro workspace sync"),
      (@["ws", "status", "--bogus"], "repro workspace status"),
      (@["pull", "a", "b"], "repro pull"),
      (@["branch", "a", "b"], "repro branch"),
      (@["switch", "--bogus"], "repro switch"),
      (@["push", "--bogus"], "repro push"),
      (@["check", "--bogus"], "repro check"),
      (@["check", "--mode=pre-commit"], "repro check"),
      (@["hooks"], "repro hooks"),
      (@["hooks", "frob"], "repro hooks"),
      (@["hooks", "ensure", "--bogus"], "repro hooks ensure"),
      (@["hooks", "dispatch"], "repro hooks dispatch"),
      (@["hooks", "dispatch", "pre-push", "--bogus"], "repro hooks dispatch"),
      (@["hooks", "cache-push", "extra"], "repro hooks cache-push"),
      (@["workspace"], "repro workspace"),
      (@["workspace", "forall", "--bogus"], "repro workspace forall"),
      (@["workspace", "enable", "--bogus"], "repro workspace enable"),
      (@["workspace", "sets", "frob"], "repro workspace sets"),
      (@["workspace", "repos", "remove", "x", "--remote=u"],
        "repro workspace repos remove"),
      (@["workspace", "branch-roles", "--jobs=3"],
        "repro workspace branch-roles"),
      (@["lock"], "repro lock"),
      (@["lock", "frob"], "repro lock"),
      (@["lock", "validate", "--provisioning"], "repro lock validate"),
      (@["lock", "solve", "--repin=a"], "repro lock solve"),
      (@["locking"], "repro locking"),
      (@["gateway"], "repro gateway"),
      (@["gateway", "frob"], "repro gateway"),
      (@["gateway", "migrate", "--bogus"], "repro gateway migrate"),
      (@["add", "--bogus"], "repro add"),
      (@["remove", "a", "b"], "repro remove"),
      # Retired spellings stay unknown.
      (@["sync", "--groups=a"], "repro sync"),
      (@["sync", "--report"], "repro sync"),
      (@["check", "--mode=pre-push", "--report=x"], "repro check"),
      (@["workspace", "status", "--report"], "repro workspace status"),
      (@["hooks", "ensure", "--report"], "repro hooks ensure"),
      (@["push", "--report"], "repro push"),
      (@["branch", "../x", "--checkout"], "repro branch"),
      (@["branch", "../x", "--from-mainlines"], "repro branch"),
      (@["workspace", "start", "b"], "repro workspace"),
      (@["workspace", "branch"], "repro workspace"),
      (@["workspace", "project", "new", "p"], "repro workspace"),
      (@["workspace", "projects", "add", "p", "--default"],
        "repro workspace projects add"),
      (@["workspace", "lock", "--manifest-layer-root=x"],
        "repro workspace lock"),
      (@["checkout", "b"], "repro"),
      (@["co", "b"], "repro")]
    for (argv, command) in lines:
      let res = s.run(argv)
      check res.code == 2
      check command in res.output
    # The retired `--from-mainlines` names its replacement under every
    # spelling of the command: `workspace new` (and `ws new`) is `branch`
    # under another name.
    for (argv, command) in [
        (@["branch", "../x", "--from-mainlines"], "repro branch"),
        (@["workspace", "new", "../x", "--from-mainlines"],
          "repro workspace new"),
        (@["ws", "new", "../x", "--from-mainlines"],
          "repro workspace new")]:
      let retired = s.run(argv)
      check retired.code == 2
      check ("unknown flag '--from-mainlines' for '" & command & "'") in
        retired.output
      check "`--from=mainline`" in retired.output
      check "`--mainline`" in retired.output
    check s.cwd.entriesUnder().len == 0
    check not dirExists(s.cwd.parentDir / "x")

  test "the managed hooks' contract handshake":
    let s = newScratch()
    defer: s.dispose()
    let ok = s.run(["hooks", "protocol", "--require=2"])
    check ok.code == 0
    check ok.output.strip() == "2"
    check s.run(["hooks", "protocol", "--require=2",
      "--require-source-component"]).code == 0
    for argv in [@["hooks", "protocol", "--require=3"],
        @["hooks", "protocol"],
        @["hooks", "protocol", "--require=2", "--bogus"],
        @["hooks", "protocol", "--require", "2"]]:
      let res = s.run(argv)
      check res.code notin [0, 3]
    # The tokens of the bodies this build installs.
    let git = findExe("git")
    if git.len == 0:
      skip("git not on PATH; this case installs hooks into a repository")
    else:
      let repo = s.home / "repo"
      createDir(repo)
      check execCmdEx(quoteShellCommand([git, "init", "-q", repo])).exitCode == 0
      let installed = s.run(["hooks", "ensure", "--vcs", repo])
      check installed.code == 0
      var tokens: seq[string]
      for hook in ["pre-commit", "pre-push", "post-commit", "post-merge",
          "post-checkout"]:
        let body = readFile(repo / ".git" / "hooks" / (hook & ".repro-managed"))
        let at = body.find("reprobuild.managed-hook.v1." & hook & ".")
        check at >= 0
        var token = ""
        var i = at
        while i < body.len and body[i] notin {' ', '"', ')', '\n', '\''}:
          token.add(body[i])
          inc i
        tokens.add(token)
      check tokens.len == 5
      for token in tokens:
        let res = s.run(["hooks", "protocol", "--require=2",
          "--hook-contract=" & token])
        check res.code == 0
      let foreign = s.run(["hooks", "protocol", "--require=2",
        "--hook-contract=reprobuild.managed-hook.v1.pre-push.0000000000000000"])
      check foreign.code == 3

  test "the values the description accepts reach the command":
    # The dispatch shape the managed hook bodies write.
    check parsed(["hooks", "dispatch", "pre-push", "--protocol=2",
      "--repo-root", "/r", "--refs-file", "/f", "--", "origin",
      "file:///remote"]) == 0
    block:
      let d = parsedCommand.hooks.dispatch
      check d.hookName == "pre-push"
      check d.protocol == some("2")
      check d.repoRoot == "/r"
      check d.refsFile == "/f"
      check d.hookArgs == @["origin", "file:///remote"]
      check d.phase == "refresh"
    check parsed(["hooks", "dispatch", "pre-commit", "--repo-root", "/r",
      "--phase=certificate-gate", "--dispatcher-displaced=1", "--", "--x"]) == 0
    block:
      let d = parsedCommand.hooks.dispatch
      check d.phase == "certificate-gate"
      check d.dispatcherDisplaced == "1"
      check d.hookArgs == @["--x"]
      check d.protocol.isNone
    check parsed(["hooks", "cache-push", "--repo-root", "/r",
      "--workspace-name", "w"]) == 0
    check parsedCommand.hooks.cachePush.repoRoot == "/r"
    check parsedCommand.hooks.cachePush.workspaceName == "w"
    check parsed(["hooks", "protocol", "--require=2",
      "--hook-contract=tok"]) == 0
    check parsedCommand.hooks.protocol.require == "2"
    check parsedCommand.hooks.protocol.hookContract == some("tok")
    # The selectors: repeatable and comma-separated; `--except` and `--to`
    # keep their spellings.
    check parsed(["sync", "--only", "a,b", "--only=c", "--except", "x",
      "--tags=t,-u", "--filter", "g*", "--to=unstable", "-j", "3",
      "--jobs-network=2", "--dry-run", "--write-report", "p1", "p2"]) == 0
    block:
      let c = parsedCommand.sync
      check c.only == @["a", "b", "c"]
      check c.exceptRepos == @["x"]
      check c.tags == @["t", "-u"]
      check c.filter == @["g*"]
      check c.toRole == @["unstable"]
      check c.jobs == some(3)
      check c.jobsNetwork == some(2)
      check c.dryRun
      check c.writeReport == some("")
      check c.projects == @["p1", "p2"]
    check parsed(["ws", "sync", "--write-report=/tmp/r.json", "--mainline",
      "--no-rebase-on-force-push", "--yes"]) == 0
    block:
      let c = parsedCommand.workspace.sync
      check c.writeReport == some("/tmp/r.json")
      check c.mainline
      check not c.rebaseOnForcePush
      check c.yes
    check parsed(["sync", "--force"]) == 0
    check parsedCommand.sync.yes
    check parsed(["branch", "../f", "--from=unstable", "--projects=a,b",
      "--projects", "c", "--no-fetch"]) == 0
    block:
      let c = parsedCommand.branch.call
      check c.path == "../f"
      check c.fromRole == @["unstable"]
      check c.projects == @["a", "b", "c"]
      check c.noFetch
    check parsed(["switch", "-b", "feat", "--no-fetch"]) == 0
    check parsedCommand.switch.call.newBranch
    check parsedCommand.switch.call.branch == "feat"
    check parsed(["workspace", "repos", "add", "r", "--remote=u",
      "--branch=main", "--set=a", "--project=b", "-m", "desc"]) == 0
    block:
      let c = parsedCommand.workspace.repos.add
      check c.mainline == @["main"]
      check c.set == @["a"]
      check c.project == @["b"]
      check c.message == "desc"
    check parsed(["workspace", "forall", "-c", "git status", "--quiet"]) == 0
    check parsedCommand.workspace.forall.command == "git status"
    check parsed(["lock", "refresh", "d", "--repin=a,b", "--lowest",
      "--registry", "r1", "--registry=r2"]) == 0
    block:
      let c = parsedCommand.lock.refresh
      check c.projectDir == "d"
      check c.repin == @["a,b"]
      check c.lowest
      check c.registry == @["r1", "r2"]
    check parsed(["add", "r", "--remote=u", "--no-develop"]) == 0
    check parsedCommand.add.binary
    check parsed(["remove", "r", "--yes"]) == 0
    check parsedCommand.remove.force

  test "contradictions are refused by the commands":
    let s = newScratch()
    defer: s.dispose()
    # Two different roles are a usage error (exit 2) naming both.
    let roles = s.run(["sync", "--to=unstable", "--mainline", "--dry-run"])
    check roles.code == 2
    check "two roles" in roles.output
    check s.run(["workspace", "branch-roles", "--filter=a",
      "--filter=b"]).code == 2
    # The command's own refusals (exit 1).
    let flavors = s.run(["sync", "--rebase", "--merge", "--dry-run"])
    check flavors.code == 1
    check "--rebase and --merge" in flavors.output
    let fetches = s.run(["switch", "b", "--fetch", "--no-fetch"])
    check fetches.code == 1
    check "--fetch and --no-fetch" in fetches.output
    let noMode = s.run(["check"])
    check noMode.code == 1
    check "requires --mode=pre-push" in noMode.output
    check s.run(["lock", "diff", "one"]).code == 2
    check s.run(["lock", "solve", "--lowest", "--highest"]).code == 2
    check s.cwd.entriesUnder().len == 0

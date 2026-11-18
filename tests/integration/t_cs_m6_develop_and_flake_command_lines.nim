## `repro develop` and the three `repro flake` verbs take their command lines
## from repro's description: each answers `--help` (and `repro help
## <command>`) from its declarations, a command line the description does not
## accept is a usage error (exit 2) naming the command, the commands' own
## refusals keep their exit codes, and a command line the description accepts
## reaches the command with the values it gave.
##
## The two families share one declaration of the develop-set selection
## (`--all`, `--direct`, `--indirect`, `--transitive-of`, `--project`,
## `--tag`, `--filter`, `--only`, `--except`, `--tier`, `--at`,
## `--lock-store`, `--strict`), and both read it into the same typed
## selection.
##
## The arms, and what makes each one evidence:
##
##   1. Help. `develop`, `flake` and each flake verb print their generated
##      usage on stdout and exit 0 through `--help`, `-h` and `help
##      <command>`; the help of `develop` and of a flake verb lists the
##      shared selection flags. Before the two moved, their arguments were
##      handed to their own parsers unparsed, so the arm can fail.
##   2. Usage errors (exit 2, naming the command): an unknown flag, a stray
##      word, a bare `flake`, an unknown verb, an invalid
##      `--tool-provisioning` value, the flags the flake verbs never used
##      (`--into`, `--reset`, `--dry-run`, `--list`); `develop --drop`'s own
##      usage refusals (a selector beside it, no dependency named).
##   3. The commands' own refusals, which keep their exit codes: `develop`
##      exits 1 for two different selection modes, a one-valued selector
##      given twice, an unknown tier, `--list` with `--reset`, a flag of
##      another form (`--source` in the set form, `--json` in the target
##      form, `--strict` in the overlay form) and a missing target; the flake
##      verbs exit 2 with nothing on stdout for an unusable selection, and
##      `override-status --applied` with a selector is refused as
##      contradictory (the probe the dev shell's drift report runs).
##   4. Values reach the commands (in process, through the same generated
##      parser the engine uses), in the shapes the callers write: CI's
##      `develop --all --only=<names> --reset --into=<dir>`, `develop --list
##      --json`, `develop <dependency> --into=PATH`, `develop <target>
##      --tool-provisioning=nix -- <command>`, the foreign-environment
##      capture's `flake override-args --all --json --workspace-root=R
##      --flake=F`, and `flake override-status --applied -- <vector>`.
##
## No mocks: the real `build/bin/repro` runs as a subprocess, in an empty
## directory with a fresh HOME and XDG directories, and arm 4 runs the
## generated parser in process. Every command line here is refused before it
## would change anything or only prints help: nothing is cloned, fetched or
## written.

import std/[options, os, strutils, tempfiles, unittest]

import repro_test_support

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
  result.cwd = createTempDir("repro-develop-cli-cwd-", "")
  result.home = createTempDir("repro-develop-cli-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    # A workspace the calling shell names must not reach these lines.
    ("REPRO_WORKSPACE_CONFIG", ""), ("REPRO_DEFAULT_PROJECTS", ""),
    ("REPROBUILD_REPRO", "")]

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

proc runStdout(s: Scratch; argv: openArray[string]): tuple[code: int,
               stdout: string] =
  ## Like ``run``, with stdout alone: `sh` discards the command's stderr.
  let res = runShell(shellCommand(@["sh", "-c", "\"$@\" 2>/dev/null", "sh",
    reproBinary()] & @argv, s.env), cwd = s.cwd, timeoutMs = 120_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code &
    "; stdout:\n" & res.output)
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

const
  Commands = [@["develop"], @["flake"], @["flake", "override-args"],
    @["flake", "refresh-lock"], @["flake", "override-status"]]
  SelectionFlags = ["--all", "--direct", "--indirect", "--transitive-of",
    "--project", "--tag", "--filter", "--only", "--except", "--tier", "--at",
    "--lock-store", "--strict"]

suite "the develop and flake command lines":

  test "each command answers help from its declarations":
    let s = newScratch()
    defer: s.dispose()
    for path in Commands:
      let usage = "Usage: repro " & path.join(" ")
      for argv in [path & @["--help"], path & @["-h"], @["help"] & path]:
        let res = s.run(argv)
        check res.code == 0
        check usage in res.output
    # `--help` wins over the words around it.
    check s.run(["develop", "--all", "--drop=x", "--help"]).code == 0
    let developHelp = s.run(["develop", "--help"]).output
    for flag in SelectionFlags:
      check flag in developHelp
    for flag in ["--list", "--list-overrides", "--drop", "--dry-run",
        "--into", "--reset", "--source", "--project-root", "--cmake",
        "--cmake-binary", "--work-root", "--write-report"]:
      check flag in developHelp
    let statusHelp = s.run(["flake", "override-status", "--help"]).output
    for flag in SelectionFlags:
      check flag in statusHelp
    check "--applied" in statusHelp
    check "--record-downgrade" in
      s.run(["flake", "refresh-lock", "--help"]).output
    check s.cwd.entriesUnder().len == 0

  test "a command line the description does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    let lines = [
      (@["develop", "--bogus"], "repro develop"),
      (@["develop", "a", "b"], "repro develop"),
      (@["develop", "--tool-provisioning=bogus", "x"], "repro develop"),
      (@["flake"], "repro flake"),
      (@["flake", "frob"], "repro flake"),
      (@["flake", "override-args", "--bogus"], "repro flake override-args"),
      (@["flake", "override-args", "stray"], "repro flake override-args"),
      # The flags the flake verbs took and never used.
      (@["flake", "override-args", "--into=x"], "repro flake override-args"),
      (@["flake", "override-args", "--reset"], "repro flake override-args"),
      (@["flake", "refresh-lock", "--dry-run"], "repro flake refresh-lock"),
      (@["flake", "override-status", "--list"],
        "repro flake override-status"),
      (@["flake", "refresh-lock", "--applied"], "repro flake refresh-lock"),
      (@["flake", "override-args", "--record-downgrade"],
        "repro flake override-args")]
    for (argv, command) in lines:
      let res = s.run(argv)
      check res.code == 2
      check command in res.output
    # `develop --drop`'s own usage refusals.
    let selector = s.run(["develop", "--drop=x", "--all"])
    check selector.code == 2
    check "takes no selector" in selector.output
    check "'--all'" in selector.output
    let noName = s.run(["develop", "--drop="])
    check noName.code == 2
    check "name the dependency" in noName.output
    check s.cwd.entriesUnder().len == 0

  test "the commands' own refusals keep their exit codes":
    let s = newScratch()
    defer: s.dispose()
    let developLines = [
      (@["develop", "--all", "--direct"], "two different selection modes"),
      (@["develop", "--transitive-of=a", "--transitive-of=b"],
        "two different selection modes"),
      (@["develop", "--all", "--filter=a", "--filter=b"],
        "given twice with different values"),
      (@["develop", "--all", "--at=r1", "--at", "r2"],
        "given twice with different values"),
      (@["develop", "--all", "--tier=bogus"], "names no locking tier"),
      (@["develop", "--all", "--lock-store=nokind"], "is malformed"),
      (@["develop", "--list", "--reset"], "cannot be combined with --reset"),
      (@["develop", "--all", "--source=x"],
        "set-form argument: --source"),
      (@["develop", "--all", "tgt"], "set-form argument: tgt"),
      (@["develop", "x", "--json", "--into=p"],
        "unsupported develop flag: --json"),
      (@["develop", "x", "--source=s", "--strict"],
        "workspace-overlay form: --strict"),
      (@["develop", "--source=s"], "requires a package name"),
      (@["develop"], "missing develop target")]
    for (argv, needle) in developLines:
      let res = s.run(argv)
      check res.code == 1
      check "repro develop: error: " in res.output
      check needle in res.output
    # The flake verbs: an unusable selection is a refusal, exit 2, with
    # nothing on stdout (`.envrc` splices stdout into `use flake`).
    let modes = s.runStdout(["flake", "override-args", "--all", "--direct"])
    check modes.code == 2
    check modes.stdout.strip().len == 0
    check "two different selection modes" in
      s.run(["flake", "override-args", "--all", "--direct"]).output
    # The dev shell's capability probe: `--applied` with a selector is
    # contradictory, exit 2, before any flake is read.
    let probeFlake = s.home / "no-flake"
    createDir(probeFlake)
    let probe = s.run(["flake", "override-status", "--applied",
      "--only=__probe__", "--flake=" & probeFlake])
    check probe.code == 2
    check "contradictory" in probe.output
    check "--only=__probe__" in probe.output
    # A vector after `--` without `--applied` would be read by nothing.
    let unread = s.run(["flake", "override-status", "--flake=" & probeFlake,
      "--", "--override-input", "a", "path:/x"])
    check unread.code == 2
    check "`--applied` was not given" in unread.output
    check s.cwd.entriesUnder().len == 0

  test "the values the description accepts reach the commands":
    # CI's provisioning shape.
    check parsed(["develop", "--all", "--only=a,b", "--reset",
      "--into=../siblings"]) == 0
    block:
      let c = parsedCommand.develop
      check c.all
      check c.only == @["a,b"]
      check c.reset
      check c.into == some("../siblings")
      check c.target == ""
      check c.command.len == 0
    check parsed(["develop", "--list", "--json", "--at", "abc",
      "--lock-store=git-checkout:/p", "--lock-store", "team:git-notes:/q",
      "--tier=public,team", "--except", "x", "--except=y", "--project=p",
      "--tag", "t", "--filter=g*", "--strict", "--workspace-root", "/w",
      "--tool-provisioning=path"]) == 0
    block:
      let c = parsedCommand.develop
      check c.list and c.json and c.strict
      check c.at == @["abc"]
      check c.lockStore == @["git-checkout:/p", "team:git-notes:/q"]
      check c.tier == @["public,team"]
      check c.exceptNames == @["x", "y"]
      check c.project == @["p"]
      check c.tag == @["t"]
      check c.filter == @["g*"]
      check c.workspaceRoot == some("/w")
      check c.toolProvisioning == "path"
    check parsed(["develop", "dep", "--into=/co"]) == 0
    check parsedCommand.develop.target == "dep"
    check parsedCommand.develop.into == some("/co")
    check parsed(["develop", "tgt", "--tool-provisioning=nix",
      "--work-root=.repro", "--", "make", "-j4", "--"]) == 0
    block:
      let c = parsedCommand.develop
      check c.target == "tgt"
      check c.toolProvisioning == "nix"
      check c.workRoot == some(".repro")
      check c.command == @["make", "-j4", "--"]
    check parsed(["develop", "--cmake", "src", "--cmake-binary=/cm",
      "--tool-provisioning=path", "--", "ninja"]) == 0
    check parsedCommand.develop.cmake
    check parsedCommand.develop.cmakeBinary == some("/cm")
    check parsed(["develop", "pkg", "--source", "/s", "--write-report"]) == 0
    check parsedCommand.develop.source == some("/s")
    check parsedCommand.develop.writeReport == some("")
    check parsed(["develop", "--drop=a,b", "--drop", "c",
      "--project-root=/p"]) == 0
    check parsedCommand.develop.drop == @["a,b", "c"]
    check parsedCommand.develop.projectRoot == "/p"
    check parsed(["develop", "--transitive-of", "gtk", "--filter", "g*"]) == 0
    check parsedCommand.develop.transitiveOf == @["gtk"]
    # The foreign-environment capture's shape.
    check parsed(["flake", "override-args", "--all", "--json",
      "--workspace-root=/w", "--flake=/f"]) == 0
    block:
      let c = parsedCommand.flake.overrideArgs
      check c.all and c.json
      check c.workspaceRoot == "/w"
      check c.flake == "/f"
      check c.stripSuffix.isNone
    check parsed(["flake", "refresh-lock", "--only", "a", "--flake", "/f",
      "--current-repo=/r", "--record-downgrade", "--strip-suffix="]) == 0
    block:
      let c = parsedCommand.flake.refreshLock
      check c.only == @["a"]
      check c.flake == "/f"
      check c.currentRepo == "/r"
      check c.recordDowngrade
      check c.stripSuffix == some("")
    # The dev shell's drift report: the vector after `--`, verbatim.
    check parsed(["flake", "override-status", "--applied", "--",
      "--override-input", "a-src", "path:/x", "--json"]) == 0
    block:
      let c = parsedCommand.flake.overrideStatus
      check c.applied
      check not c.json
      check c.appliedArgs == @["--override-input", "a-src", "path:/x",
        "--json"]

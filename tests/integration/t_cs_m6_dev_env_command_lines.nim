## The development-environment commands (`exec`, `run`, `shell` with `shell
## hook`, `allow`, `deny`, `dev-env`, `up`, `down`, `dev`, `hcr`, `prompt`
## with `prompt init`) take their command lines from repro's description:
## each answers `--help` (and `repro help <command>`) from its declarations,
## a command line the description does not accept is a usage error (exit 2)
## naming the command, and a command line it accepts reaches the command
## with the values it gave, the words after `--` exactly as written.
##
## The arms, and what makes each one evidence:
##
##   1. Help. Every command and subcommand of the group prints its generated
##      usage on stdout and exits 0, through `<command> --help`, `<command>
##      -h` and `help <command>`, and `prompt init help`. The internal
##      `--lock-slice` stays out of the help. Before this group moved, `repro
##      allow --help` trusted a directory named `--help`, `repro hcr --help`
##      and `repro dev-env export --help` were errors, so the arm can fail.
##   2. `allow` and `deny` with `--help`, `-h` or as `help`'s topic change no
##      trust record: the scratch configuration directory stays empty. The
##      positive control trusts and revokes a directory (one whose name
##      starts with `-`, written after `--`), so the arm sees the records it
##      checks for.
##   3. Usage errors. Unknown flags, a flag of one command given to another
##      (`down --ready-timeout`, `up --stop-timeout`), a missing or unknown
##      subcommand, a missing or extra argument, a value that is not a
##      number: each exits 2 and names the command, and nothing is written
##      to the scratch directories.
##   4. The words after `--` (in process, through the same generated parser
##      the engine uses): `exec`'s command and `run`'s arguments are every
##      word after the first `--`, a flag-like word, `--help` and a later
##      `--` included, and none before it; the selector and target stay
##      apart from them. A flag whose value is the word `--` (`--work-root
##      --`, `--work-root=--`) takes it, and the separator is the next `--`.
##   5. Values reach the command. Each check depends on a parsed value: the
##      shell hook embedding `--repro-bin`; the shells' names in any letter
##      case and an unknown one refused by the command; `dev-env export
##      --project-root` naming the untrusted directory it refuses to
##      activate; `dev-env deactivate` reading the manifest it was given;
##      `prompt --workspace-root` and `--format` rendering that workspace;
##      `up --http`, `--ready-timeout`, `down --stop-timeout` and `dev
##      --debounce-ms` checked by the commands with their own messages; `hcr`
##      naming the input it cannot find; `exec` resolving the selector it was
##      given.
##
## No mocks: the real `build/bin/repro` runs as a subprocess, in an empty
## directory with a fresh HOME and XDG directories (the trust records live
## under `$XDG_CONFIG_HOME/repro/allow`), and arm 4 runs the generated parser
## in process. Every command line here either fails before it would change
## anything, only reads, or writes under the scratch directories (`allow`
## and `deny` in arm 2). No session or service is started.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

import repro_cli_support/cli_program

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc entriesUnder(dir: string): seq[string] =
  for entry in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}):
    result.add(entry)

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-cs-m6-g5-cwd-", "")
  result.home = createTempDir("repro-cs-m6-g5-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    # The trust and activation markers a calling shell may carry must not
    # reach these command lines.
    ("REPRO_DEV_ENV_AUTO_ALLOW", "0"), ("__REPRO_WARNED", ""),
    ("__REPRO_APPLIED", ""), ("__REPRO_ACTIVE_MANIFEST", "")]

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

proc trustRecords(s: Scratch): seq[string] =
  let dir = s.home / "config" / "repro" / "allow"
  if dirExists(dir):
    for path in walkDir(dir):
      result.add(readFile(path.path))

var parsedCommand: ReproCommandLine

proc parsed(argv: openArray[string]): int =
  ## ``argv`` through the generated parser, in process; the configuration
  ## it selects is left in ``parsedCommand``.
  parsedCommand = ReproCommandLine()
  runReproArgs(argv, proc (conf: ReproCommandLine): int =
    parsedCommand = conf
    0)

const GroupCommands = [@["exec"], @["run"], @["shell"], @["shell", "hook"],
  @["allow"], @["deny"], @["dev-env"], @["dev-env", "export"],
  @["dev-env", "deactivate"], @["up"], @["down"], @["dev"], @["hcr"],
  @["hcr", "coordinate"], @["hcr", "prepare-object"], @["prompt"],
  @["prompt", "init"]]

suite "CS-M6: the development-environment command lines":

  test "every command of the group answers help from its declarations":
    let s = newScratch()
    defer: s.dispose()
    var lines: seq[(seq[string], string)] = @[]
    for path in GroupCommands:
      let usage = "Usage: repro " & path.join(" ")
      lines.add((path & @["--help"], usage))
      lines.add((path & @["-h"], usage))
      lines.add((@["help"] & path, usage))
    lines.add((@["prompt", "init", "help"], "Usage: repro prompt init"))
    # `--help` wins over the words around it, but not over `--`'s.
    lines.add((@["exec", "sel", "--help", "--", "true"], "Usage: repro exec"))
    lines.add((@["dev-env", "export", "bash", "--allow-stale", "-h"],
      "Usage: repro dev-env export"))
    for (argv, usage) in lines:
      let res = s.run(argv)
      check res.code == 0
      check usage in res.output
    let execHelp = s.run(["exec", "--help"]).output
    check "--activity" in execHelp
    check "--dev-env-stats" in execHelp
    check "--lock-slice" notin execHelp       # internal
    check "--print-env" in s.run(["shell", "--help"]).output
    check "hook" in s.run(["shell", "--help"]).output
    check "--repro-bin" in s.run(["shell", "hook", "--help"]).output
    check "--pre-activation-env" in s.run(["dev-env", "export", "-h"]).output
    check "--stop-timeout" in s.run(["down", "--help"]).output
    check "--ready-timeout" notin s.run(["down", "--help"]).output
    check "--debounce-ms" in s.run(["dev", "--help"]).output
    check "--debounce-ms" notin s.run(["up", "--help"]).output
    check "--all-code" in s.run(["hcr", "prepare-object", "--help"]).output
    check "--workspace-root" in s.run(["prompt", "--help"]).output
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "allow and deny answer help without touching a trust record":
    let s = newScratch()
    defer: s.dispose()
    for verb in ["allow", "deny"]:
      for argv in [@[verb, "--help"], @[verb, "-h"], @["help", verb],
                   @[verb, "some-dir", "--help"]]:
        let res = s.run(argv)
        check res.code == 0
        check ("Usage: repro " & verb) in res.output
    check trustRecords(s).len == 0
    check entriesUnder(s.home).len == 0
    check entriesUnder(s.cwd).len == 0
    # The positive control: the records the checks above look for are
    # written and removed where they are looked for. A directory whose name
    # starts with `-` is written after `--`.
    let allowed = s.run(["allow", "--", "-dash-dir"])
    check allowed.code == 0
    let records = trustRecords(s)
    check records.len == 1
    if records.len == 1:
      # A record's first line is the trusted directory (the recipe digest
      # follows it).
      check records[0].splitLines()[0].endsWith("/-dash-dir")
    let denied = s.run(["deny", "--", "-dash-dir"])
    check denied.code == 0
    check "Denied/removed repro dev-env trust for:" in denied.output
    check trustRecords(s).len == 0
    let again = s.run(["deny", "-dash-dir-never-trusted-only-after-dashes"])
    check again.code == 2
    check trustRecords(s).len == 0

  test "a command line the description does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    for (argv, names) in [
        (@["exec", "sel", "extra", "--", "true"],
          "unexpected argument 'extra' for 'repro exec'"),
        (@["exec", "sel", "extra"],
          "unexpected argument 'extra' for 'repro exec'"),
        (@["exec", "--bogus", "--", "true"], "'repro exec'"),
        (@["exec", "--activity"], "'repro exec'"),
        (@["run", "a", "b"], "unexpected argument 'b' for 'repro run'"),
        (@["run", "a", "--verbose"], "'repro run'"),
        (@["shell", "--bogus"], "'repro shell'"),
        (@["shell", "a", "b"], "'repro shell'"),
        (@["shell", "hook"], "'repro shell hook'"),
        (@["shell", "hook", "bash", "zsh"], "'repro shell hook'"),
        (@["shell", "hook", "bash", "--print-env=json"],
          "'repro shell hook'"),
        (@["allow", "a", "b"], "'repro allow'"),
        (@["allow", "--bogus"], "'repro allow'"),
        (@["deny", "a", "b"], "'repro deny'"),
        (@["dev-env"], "'repro dev-env' needs a subcommand"),
        (@["dev-env", "frob"], "unknown subcommand 'frob' for 'repro dev-env'"),
        (@["dev-env", "export"], "'repro dev-env export'"),
        (@["dev-env", "export", "bash", "--bogus"],
          "'repro dev-env export'"),
        (@["dev-env", "export", "bash", "zsh"], "'repro dev-env export'"),
        (@["dev-env", "deactivate"], "'repro dev-env deactivate'"),
        (@["dev-env", "deactivate", "m.rollback.json", "--project-root=x"],
          "'repro dev-env deactivate'"),
        (@["up", "--stop-timeout=5"], "'repro up'"),
        (@["up", "--debounce-ms=5"], "'repro up'"),
        (@["up", "--ready-timeout=soon"], "'repro up'"),
        (@["up", "a", "b"], "'repro up'"),
        (@["down", "--ready-timeout=5000"], "'repro down'"),
        (@["down", "--foreground"], "'repro down'"),
        (@["down", "--http=127.0.0.1:0"], "'repro down'"),
        (@["down", "--http-allow-remote"], "'repro down'"),
        (@["down", "--replace"], "'repro down'"),
        (@["down", "--debounce-ms=5"], "'repro down'"),
        (@["dev", "--stop-timeout=5"], "'repro dev'"),
        (@["dev", "--debounce-ms=x"], "'repro dev'"),
        (@["hcr"], "'repro hcr' needs a subcommand"),
        (@["hcr", "frob"], "unknown subcommand 'frob' for 'repro hcr'"),
        (@["hcr", "coordinate", "--bogus"], "'repro hcr coordinate'"),
        (@["hcr", "coordinate", "--project"], "'repro hcr coordinate'"),
        (@["hcr", "prepare-object", "stray"], "'repro hcr prepare-object'"),
        (@["hcr", "prepare-object", "--all-code=maybe"],
          "'repro hcr prepare-object'"),
        (@["prompt", "--bogus"], "'repro prompt'"),
        (@["prompt", "stray"], "'repro prompt'"),
        (@["prompt", "init"], "'repro prompt init'"),
        (@["prompt", "init", "bash", "zsh"], "'repro prompt init'")]:
      let res = s.run(argv)
      check res.code == 2
      check names in res.output
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "the words after -- reach the command exactly as written":
    # `exec`: the command is every word after the first `--`; a flag-like
    # word, `--help` and a later `--` are the command's.
    check parsed(["exec", "--", "sh", "-c", "echo --help", "--help", "--",
      "-x", ""]) == 0
    check parsedCommand.command == ReproCommandLineCommand.exec
    check parsedCommand.exec.selector == ""
    check parsedCommand.exec.command == @["sh", "-c", "echo --help",
      "--help", "--", "-x", ""]
    check parsed(["exec", "--activity", "a,b", "proj", "--work-root=w",
      "--", "ls", "-la"]) == 0
    check parsedCommand.exec.selector == "proj"
    check parsedCommand.exec.activity == @["a,b"]
    check parsedCommand.exec.workRoot == "w"
    check parsedCommand.exec.command == @["ls", "-la"]
    # A command word alone after `--` is not the selector.
    check parsed(["exec", "--", "ls"]) == 0
    check parsedCommand.exec.selector == ""
    check parsedCommand.exec.command == @["ls"]
    # No `--`: no command (the command refuses that itself).
    check parsed(["exec", "proj"]) == 0
    check parsedCommand.exec.command.len == 0
    # `run`: the target and the program's arguments stay apart.
    check parsed(["run", "--choose", "task:fmt", "--", "--check", "--",
      "x y"]) == 0
    check parsedCommand.command == ReproCommandLineCommand.run
    check parsedCommand.run.choose
    check parsedCommand.run.target == "task:fmt"
    check parsedCommand.run.args == @["--check", "--", "x y"]
    check parsed(["run", "--", "a"]) == 0
    check parsedCommand.run.target == ""
    check parsedCommand.run.args == @["a"]
    # A word before `--` never joins them.
    check parsed(["run", "t", "u", "--", "a"]) == 2
    # A flag whose value is the word `--` takes it, as getopt does, in
    # every spelling; the separator is the next `--`.
    check parsed(["exec", "--work-root", "--", "--", "ls", "-la"]) == 0
    check parsedCommand.exec.workRoot == "--"
    check parsedCommand.exec.selector == ""
    check parsedCommand.exec.command == @["ls", "-la"]
    check parsed(["exec", "--work-root=--", "proj", "--", "ls"]) == 0
    check parsedCommand.exec.workRoot == "--"
    check parsedCommand.exec.selector == "proj"
    check parsedCommand.exec.command == @["ls"]
    check parsed(["run", "--activity", "--", "t", "--", "a"]) == 0
    check parsedCommand.run.activity == @["--"]
    check parsedCommand.run.target == "t"
    check parsedCommand.run.args == @["a"]
    # Taken as the value, that `--` separates nothing: the next word is the
    # selector and there is no command (which the command refuses itself).
    check parsed(["exec", "--work-root", "--", "ls"]) == 0
    check parsedCommand.exec.workRoot == "--"
    check parsedCommand.exec.selector == "ls"
    check parsedCommand.exec.command.len == 0
    # The other commands keep their positionals: `shell hook` is the
    # subcommand, any other word the selector.
    check parsed(["shell", "hook", "fish"]) == 0
    check parsedCommand.shell.command == ReproCommandLineShellCommand.hook
    check parsedCommand.shell.hook.shell == "fish"
    check parsed(["shell", "./hook", "--print-env", "json"]) == 0
    check parsedCommand.shell.command == ReproCommandLineShellCommand.call
    check parsedCommand.shell.call.selector == "./hook"
    check parsedCommand.shell.call.printEnv == some("json")

  test "the values the description accepts reach the command":
    let s = newScratch()
    defer: s.dispose()
    for (argv, code, message) in [
        (@["shell", "hook", "bash", "--repro-bin=/opt/x/bin/repro"], 0,
          "/opt/x/bin/repro"),
        (@["shell", "hook", "--repro-bin", "/opt/y/repro", "ZSH"], 0,
          "/opt/y/repro"),
        (@["shell", "hook", "nu"], 0, "__repro_shell_hook"),
        (@["shell", "hook", "tcsh"], 2, "repro shell hook: unsupported shell"),
        (@["dev-env", "export", "tcsh"], 2,
          "repro dev-env export: unsupported shell: tcsh"),
        (@["dev-env", "export", "--project-root", s.cwd, "Fish"], 0,
          "is not allowed/trusted"),
        (@["dev-env", "deactivate", s.home / "absent.rollback.json",
          "--shell=pwsh"], 1, "repro dev-env deactivate:"),
        (@["dev-env", "deactivate", "m.rollback.json", "--shell=tcsh"], 2,
          "unsupported shell: tcsh"),
        (@["up", "--http=0.0.0.0:7000"], 1, "refusing --http 0.0.0.0:7000"),
        (@["up", "--ready-timeout=0"], 1,
          "--ready-timeout must be a positive number of milliseconds"),
        (@["dev", "--ready-timeout", "-5"], 1,
          "--ready-timeout must be a positive number of milliseconds"),
        (@["down", "--stop-timeout=0"], 1,
          "--stop-timeout must be a positive number of milliseconds"),
        (@["dev", "--debounce-ms=-1"], 1, "--debounce-ms must be non-negative"),
        (@["hcr", "prepare-object", "--input", s.home / "absent.o"], 1,
          "--input does not exist: " & s.home / "absent.o"),
        (@["hcr", "coordinate", "--project=" & s.home / "absent"], 1,
          "--project does not exist: " & s.home / "absent"),
        (@["exec", "--"], 2, "repro exec: no command after `--`"),
        (@["exec", "no-such-project", "--", "true"], 1,
          "no-such-project"),
        (@["prompt", "init", "ZSH"], 0, "__repro_prompt"),
        (@["prompt", "init", "tcsh"], 2,
          "repro prompt init: unsupported shell 'tcsh'")]:
      let res = s.run(argv)
      check res.code == code
      check message in res.output
    # The untrusted directory `dev-env export` named is the one it was given.
    check ("dev-env directory " & s.cwd & " is not allowed") in s.run(
      ["dev-env", "export", "bash", "--project-root=" & s.cwd]).output

    # `prompt`: outside a workspace it prints nothing; a `--workspace-root`
    # is used as given, and `--format` renders it.
    check s.run(["prompt"]).output.strip() == ""
    let ws = s.home / "ws"
    createDir(ws / ".repro")
    writeFile(ws / ".repro" / "workspace-state.toml",
      "schema = \"reprobuild.workspace.state.v1\"\n" &
      "[workspace]\nproject = \"demo\"\nbranch = \"feat-cs-m6\"\n")
    let json = s.run(["prompt", "--workspace-root", ws, "--format=json"])
    check json.code == 0
    check "\"branch\":\"feat-cs-m6\"" in json.output
    let tmpl = s.run(["prompt", "--format", "<{branch}>",
      "--workspace-root=" & ws])
    check tmpl.code == 0
    check "<feat-cs-m6>" in tmpl.output
    # Used as given: a directory below the workspace is not one.
    check s.run(["prompt", "--workspace-root=" & ws / ".repro"]).output.strip() == ""
    check trustRecords(s).len == 0
    check entriesUnder(s.cwd).len == 0

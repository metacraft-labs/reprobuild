## `repro shell`: which of its modes an invocation asks for, and whether
## that mode may run where it was started.
##
## `repro shell` has four modes over the same development environment:
##
## * print (`--print-env=<format>`): render the environment's activation
##   script and spawn nothing;
## * inline command (`-c <command>`): run `<command>` through the selected
##   shell, as `<shell> -c <command>`, inside the activated environment;
## * direct command (`-- <command> [args...]`): run the command itself inside
##   the activated environment, exactly as `repro exec -- <command>` does;
## * spawn (none of the above): start an interactive shell.
##
## The modes exclude each other, so naming two of them is a usage error
## rather than one silently winning. `--shell` selects the shell that spawn
## and inline-command mode start; with a direct command no shell is started,
## so it is refused there too instead of being ignored.
##
## Spawn mode is interactive. Started with a standard input that is not a
## terminal (a pipe, `/dev/null`, a CI step, an agent's tool call) the shell
## either exits at once on end-of-file or waits for input nobody will send,
## and the caller cannot tell either outcome from a working environment. So
## spawn mode refuses to start in that case, and the refusal names the two
## commands a non-interactive caller wants instead. The decision is taken
## here, from facts the caller passes in, before anything is resolved or
## built, so the refusal is immediate and testable without a terminal.
##
## Everything here is pure: no global state, no I/O. The caller checks the
## terminal (`stdin_terminal.stdinIsTerminal`, which is not plain `isatty` on
## Windows) and writes the lines out.

import std/strutils

type
  ShellInvocationMode* = enum
    ## What a `repro shell` invocation asks for.
    simSpawn          ## Start an interactive shell.
    simPrintEnv       ## `--print-env=<format>`: print, spawn nothing.
    simInlineCommand  ## `-c <command>`: `<shell> -c <command>`.
    simDirectCommand  ## `-- <command> [args...]`: the command itself.

  ShellInvocation* = object
    ## The mode an invocation asks for, or the usage error that refuses it.
    mode*: ShellInvocationMode
    usageError*: string
      ## Non-empty when the flags contradict each other; the invocation is
      ## then refused (exit 2) and nothing is resolved.

const
  ShellUsageExitCode* = 2
    ## The exit status of a refused `repro shell` invocation: a usage error,
    ## or spawn mode without a terminal on standard input.

proc shellInvocationOf*(printEnv, inlineCommand, directCommand,
                        shellGiven: bool): ShellInvocation =
  ## The mode named by the flags given: `printEnv` (`--print-env`),
  ## `inlineCommand` (`-c`), `directCommand` (a command after `--`) and
  ## `shellGiven` (`--shell`). At most one of the first three may be given.
  if inlineCommand and directCommand:
    return ShellInvocation(mode: simInlineCommand, usageError:
      "`-c <command>` and `-- <command>` both name a command; give one: " &
      "`-c` runs it through the shell, `--` runs it directly")
  if printEnv and inlineCommand:
    return ShellInvocation(mode: simPrintEnv, usageError:
      "`--print-env` prints the environment and runs nothing, so it " &
      "cannot be combined with `-c <command>`")
  if printEnv and directCommand:
    return ShellInvocation(mode: simPrintEnv, usageError:
      "`--print-env` prints the environment and runs nothing, so it " &
      "cannot be combined with `-- <command>`")
  if directCommand and shellGiven:
    return ShellInvocation(mode: simDirectCommand, usageError:
      "`-- <command>` runs the command directly, without a shell, so " &
      "`--shell` has no effect; use `-c <command>` to run it through that " &
      "shell")
  if printEnv:
    ShellInvocation(mode: simPrintEnv)
  elif inlineCommand:
    ShellInvocation(mode: simInlineCommand)
  elif directCommand:
    ShellInvocation(mode: simDirectCommand)
  else:
    ShellInvocation(mode: simSpawn)

proc shellSpawnRefusal*(mode: ShellInvocationMode;
                        stdinIsTerminal: bool): seq[string] =
  ## The diagnostic lines (`error:`, then `tip:`) refusing interactive spawn
  ## mode when standard input is not a terminal, or nothing when the mode may
  ## run. Only spawn mode is refused: printing and running one command need
  ## no terminal.
  if mode != simSpawn or stdinIsTerminal:
    return @[]
  @["error: `repro shell` starts an interactive shell, and standard " &
      "input is not a terminal; refusing to start one",
    "tip: to run a command in the development environment, use " &
      "`repro exec -- <command>` (or `repro shell -c <command>`); to " &
      "inspect the environment, use `repro shell --print-env=<format>` " &
      "(`posix`, `fish`, `powershell` or `json`)"]

proc inlineCommandArgv*(shellPath, command: string): seq[string] =
  ## The argv that runs `command` through `shellPath`. A POSIX shell (and
  ## fish, nushell) takes `-c`; on Windows `cmd.exe` takes `/c` and
  ## PowerShell `-Command`, recognised by the executable's name.
  # Split on both separators, not the host's only: the name decides the
  # spelling, wherever the path was written.
  let slash = max(shellPath.rfind('/'), shellPath.rfind('\\'))
  var lower = shellPath[slash + 1 .. ^1].toLowerAscii()
  if lower.endsWith(".exe"):
    lower.setLen(lower.len - 4)
  case lower
  of "cmd":
    @[shellPath, "/c", command]
  of "pwsh", "powershell":
    @[shellPath, "-Command", command]
  else:
    @[shellPath, "-c", command]

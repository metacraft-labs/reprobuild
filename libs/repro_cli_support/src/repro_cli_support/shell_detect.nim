## The shells `repro hooks` acts on, and which of them are installed.
##
## One detector for every hook that targets "each shell found": shell
## completion (`hooks ensure --shell-autocomplete`) today, and the native
## shell integration (`--shell` without a name) when it detects shells too.
##
## A shell is detected when its executable is on `PATH`, or, for a
## system-wide install, when `/etc/shells` lists it (shells(5): the login
## shells the administrator installed, which a user's `PATH` may not reach).
## The detector reads `PATH` and that one file. It never starts a shell: a
## shell's startup files can print, prompt, hang or change the machine, and
## none of that may happen as a side effect of finding out that it exists.
##
## The executables: `bash`, `zsh`, `fish`, `pwsh` (PowerShell 7 and later)
## and, on Windows, `powershell` (Windows PowerShell 5.1). Each PowerShell is
## reported separately because each has its own profiles.

import std/[os, strutils]

type
  NativeShellKind* = enum
    ## A shell family `repro hooks` writes for.
    nskBash
    nskZsh
    nskFish
    nskPowerShell

  DetectedShell* = object
    ## One installed shell.
    kind*: NativeShellKind
    command*: string      ## the executable's name: `bash`, ..., `pwsh`,
                          ## `powershell`
    executable*: string   ## where it was found: a `PATH` entry's file, or
                          ## the `/etc/shells` line naming it

proc nativeShellName*(shell: NativeShellKind): string =
  ## The name `repro` uses for the shell in its output and block ids.
  case shell
  of nskBash: "bash"
  of nskZsh: "zsh"
  of nskFish: "fish"
  of nskPowerShell: "powershell"

const
  ShellCommands = [("bash", nskBash), ("zsh", nskZsh), ("fish", nskFish),
                   ("pwsh", nskPowerShell)]
    ## The executables looked for on every platform.

proc shellCommands(windows: bool): seq[(string, NativeShellKind)] =
  result = @ShellCommands
  if windows:
    result.add(("powershell", nskPowerShell))

proc findOnPath(command, pathEnv: string; windows: bool): string =
  ## The first file named `command` (with an executable extension on
  ## Windows) in a directory of `pathEnv`, or "".
  let names =
    if windows: @[command & ".exe", command & ".cmd", command & ".bat",
                  command]
    else: @[command]
  for dir in pathEnv.split(if windows: ';' else: ':'):
    if dir.len == 0:
      continue
    for name in names:
      let candidate = dir / name
      if fileExists(candidate):
        when defined(windows):
          return candidate
        else:
          try:
            if fpUserExec in getFilePermissions(candidate) or
                fpGroupExec in getFilePermissions(candidate) or
                fpOthersExec in getFilePermissions(candidate):
              return candidate
          except OSError:
            discard
  ""

proc etcShellsEntries*(content: string): seq[string] =
  ## The shell paths `/etc/shells` lists: every line that is not blank and
  ## not a `#` comment, trimmed (shells(5)).
  for raw in content.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    result.add(line)

proc detectShells*(pathEnv: string; etcShells = "";
                   windows = defined(windows)): seq[DetectedShell] =
  ## The installed shells, in the order bash, zsh, fish, pwsh, powershell,
  ## each once. `pathEnv` is the `PATH` to search. `etcShells`, when not
  ## empty, is a `/etc/shells` file whose entries also count (a missing or
  ## unreadable file counts as empty). No shell is started.
  var listed: seq[string] = @[]
  if etcShells.len > 0 and fileExists(etcShells):
    try:
      listed = etcShellsEntries(readFile(etcShells))
    except IOError, OSError:
      listed = @[]
  for (command, kind) in shellCommands(windows):
    var found = findOnPath(command, pathEnv, windows)
    if found.len == 0:
      for entry in listed:
        if extractFilename(entry) == command:
          found = entry
          break
    if found.len > 0:
      result.add DetectedShell(kind: kind, command: command,
        executable: found)

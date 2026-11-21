## When the native shell integration (`repro hooks ensure --shell`) stands
## down because direnv already manages the directory.
##
## A bare `repro hooks ensure` installs both the direnv `.envrc` block and
## the native shell hook. Both activate the same development environment, so
## in a directory whose environment direnv has loaded the native hook does
## nothing: the environment is activated once, by direnv.
##
## The signal is direnv's own. When direnv has loaded an `.envrc` (or
## `.env`) into a shell, it exports `DIRENV_DIR`: the directory holding that
## file, prefixed with `-`, beside `DIRENV_FILE` (the file) and
## `DIRENV_DIFF` (what loading it changed). direnv's man pages do not list
## these variables; they are set in `Load` in direnv's `internal/cmd/rc.go`
## (https://github.com/direnv/direnv/blob/master/internal/cmd/rc.go:
## `newEnv[DIRENV_DIR] = "-" + filepath.Dir(rc.path)`), and unset again when
## direnv unloads. direnv keeps an `.envrc` loaded in every subdirectory of
## the directory that holds it, so `DIRENV_DIR` naming the current
## directory or one of its ancestors is the first half of the rule.
##
## `DIRENV_DIR` alone is not enough: direnv sets it for a BLOCKED `.envrc`
## too (one not `direnv allow`ed), whose contents it never ran (measured with
## direnv 2.37.1: after `direnv: error … is blocked`, `DIRENV_DIR` and
## `DIRENV_FILE` name that file and `DIRENV_DIFF` adds only direnv's own
## variables), and a process inherits it from whatever shell started it,
## whether or not direnv is hooked into, or even installed in, the new one.
## So the second half asks direnv itself: `direnv status`, run in the
## directory with the shell's environment, prints `Loaded RC allowed N` for
## the RC that `DIRENV_FILE` describes (`formatRC` in direnv's
## `internal/cmd/cmd_status.go`,
## https://github.com/direnv/direnv/blob/master/internal/cmd/cmd_status.go).
## direnv 2.33.0 and later print the `AllowStatus` number there (0 allowed,
## 1 not allowed, 2 denied; `internal/cmd/rc.go`); earlier releases printed
## the boolean `true` or `false` (`func (rc *RC) Allowed() bool` up to
## v2.32.3). The native hook stands down only when that RC is allowed, that
## is, when direnv really ran it. When `direnv status` cannot be run (direnv
## is not on `PATH`), fails, or prints no such line (no RC loaded), the native
## hook does NOT stand down: nothing shows that direnv activated anything, and
## activating a second time is the lesser failure than activating nothing.
##
## The existence of an `.envrc` is deliberately NOT the signal: an `.envrc`
## direnv has not loaded (not allowed, or direnv not hooked into this shell)
## activates nothing, and standing down there would leave the user with no
## environment at all.
##
## The hook templates make that variable current before asking: where
## direnv's own shell hook is loaded (bash and zsh `_direnv_hook`, fish
## `__direnv_export_eval`), the native hook runs it first, so a `cd` into a
## directory direnv manages is seen as such even before the next prompt.
## PowerShell needs no such step: direnv's PowerShell hook runs from
## `LocationChangedAction`, inside `Set-Location`, before the native hook.

import std/os
from std/strutils import startsWith, toLowerAscii, splitLines, strip,
  parseInt

proc direnvLoadedDir*(direnvDirValue: string): string =
  ## The directory a `DIRENV_DIR` value names: the value without direnv's
  ## leading `-`. "" when the value names none.
  var dir = direnvDirValue
  if dir.startsWith("-"):
    dir = dir[1 .. ^1]
  if dir.len == 0 or not dir.isAbsolute:
    return ""
  dir

proc comparable(path: string): string =
  ## `path` normalised for comparison: no trailing separator, and on
  ## Windows `/` as `\` and case folded (its file systems are
  ## case-insensitive).
  result = normalizedPath(path)
  when defined(windows):
    result = result.toLowerAscii()
  while result.len > 1 and result[^1] in {DirSep, AltSep}:
    result.setLen(result.len - 1)

proc isSameOrBelow(dir, ancestor: string): bool =
  let d = comparable(dir)
  let a = comparable(ancestor)
  if d == a:
    return true
  let prefix = if a.len > 0 and a[^1] in {DirSep, AltSep}: a else: a & DirSep
  d.startsWith(prefix)

proc resolved(path: string): string =
  ## `path` with its symlinks resolved, or `path` when it cannot be.
  try:
    expandFilename(path)
  except OSError:
    path

proc direnvManagesDirectory*(direnvDirValue, cwd: string): bool =
  ## Whether direnv has loaded an environment that covers `cwd`: the
  ## directory `DIRENV_DIR` (``direnvDirValue``) names is `cwd` or one of its
  ## ancestors. Both the paths as given and with symlinks resolved are
  ## compared, since a shell's `$PWD` keeps the links it was entered through.
  let loaded = direnvLoadedDir(direnvDirValue)
  if loaded.len == 0 or cwd.len == 0:
    return false
  isSameOrBelow(cwd, loaded) or
    isSameOrBelow(resolved(cwd), resolved(loaded))

proc loadedRcAllowed*(statusText: string): int =
  ## The `N` of the `Loaded RC allowed N` line of `direnv status` output
  ## (0: allowed, 1: not allowed, 2: denied; direnv before 2.33.0 printed
  ## `true` for 0 and `false` for 1), or -1 when there is no such line
  ## (nothing loaded, or not `direnv status` output) or it holds anything
  ## else.
  const prefix = "Loaded RC allowed "
  for raw in statusText.splitLines():
    let line = raw.strip()
    if line.startsWith(prefix):
      let value = line[prefix.len .. ^1].strip()
      case value
      of "true": return 0
      of "false": return 1
      else:
        try:
          let n = parseInt(value)
          return (if n >= 0: n else: -1)
        except ValueError:
          return -1
  -1

type
  DirenvStatusRunner* = proc (cwd: string): tuple[ok: bool; output: string]
    ## Runs `direnv status` in `cwd` with the caller's environment; `ok` is
    ## false when it could not be run or exited non-zero.

proc nativeShellStandsDown*(cwd: string;
                            env: proc (name: string): string;
                            direnvStatus: DirenvStatusRunner): bool =
  ## Whether the native shell hook stands down in `cwd`: direnv's
  ## `DIRENV_DIR` (read through `env`) covers `cwd`, AND `direnv status`
  ## reports the loaded RC allowed. `direnvStatus` runs only when the first
  ## half holds, so a directory direnv does not cover costs no process.
  if not direnvManagesDirectory(env("DIRENV_DIR"), cwd):
    return false
  let status = direnvStatus(cwd)
  status.ok and loadedRcAllowed(status.output) == 0

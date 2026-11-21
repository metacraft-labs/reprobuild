## When the native shell hook stands down for direnv
## (`repro_cli_support/direnv_stand_down`): the decision and its parsing.
##
## The rule has two halves, and both must hold: direnv's `DIRENV_DIR` names
## the directory or an ancestor, AND `direnv status` reports the loaded RC
## allowed. The e2e gate `t_e2e_native_shell_hooks` drives the real direnv
## (2.37.1 in the dev shell) through bash, zsh and fish. This test pins what
## that gate cannot reach with one direnv binary:
##
## * the `direnv status` output of direnv before 2.33.0, which printed
##   `Loaded RC allowed true|false` where later releases print the
##   `AllowStatus` number; the sample lines are copied from the format string
##   of `formatRC` in direnv's `internal/cmd/cmd_status.go` (unchanged from
##   v2.32.3 to master);
## * a `direnv status` that cannot be run (direnv not on `PATH`), and one
##   that exits non-zero.
##
## Test double, justified: `nativeShellStandsDown` takes the `direnv status`
## runner as a parameter, and these cases pass closures that return fixed
## output instead of running a direnv. An old direnv cannot be installed
## beside the dev shell's, and "not on PATH" is the absence of a binary, so a
## real process cannot produce these inputs. The closures also count their
## calls, which is how the test shows that no process is started where
## `DIRENV_DIR` does not cover the directory.

import std/[os, unittest]

import repro_cli_support/direnv_stand_down

const
  NewAllowed = "direnv exec path /bin/direnv\n" &
    "Loaded RC path /p/my project/.envrc\n" &
    "Loaded watch: \".envrc\" - 2026-11-21T10:00:00Z\n" &
    "Loaded RC allowed 0\n" &
    "Loaded RC allowPath /x/allow/abc\n" &
    "Found RC path /p/my project/.envrc\n" &
    "Found RC allowed 0\n"
  NewBlocked = "Loaded RC path /p/.envrc\nLoaded RC allowed 1\n" &
    "Found RC allowed 1\n"
  NewDenied = "Loaded RC path /p/.envrc\nLoaded RC allowed 2\n"
  OldAllowed = "Loaded RC path /p/.envrc\nLoaded RC allowed true\n"
  OldBlocked = "Loaded RC path /p/.envrc\nLoaded RC allowed false\n" &
    "Found RC allowed false\n"
  NothingLoaded = "direnv exec path /bin/direnv\n" &
    "No .envrc or .env loaded\n" &
    "Found RC path /p/.envrc\nFound RC allowed 0\n"

proc root(): string =
  when defined(windows): r"C:\p" else: "/p"

proc envWith(direnvDir: string): proc (name: string): string =
  result = proc (name: string): string =
    if name == "DIRENV_DIR": direnvDir else: ""

suite "direnv stand-down":

  test "Loaded RC allowed: both number and boolean spellings":
    check loadedRcAllowed(NewAllowed) == 0
    check loadedRcAllowed(NewBlocked) == 1
    check loadedRcAllowed(NewDenied) == 2
    check loadedRcAllowed(OldAllowed) == 0
    check loadedRcAllowed(OldBlocked) == 1
    # Only the Loaded line counts, never the Found one.
    check loadedRcAllowed(NothingLoaded) == -1
    check loadedRcAllowed("") == -1
    check loadedRcAllowed("Loaded RC allowed maybe\n") == -1
    check loadedRcAllowed("Loaded RC allowed -3\n") == -1
    check loadedRcAllowed("Loaded RC allowed 0\r\n") == 0

  test "DIRENV_DIR covers the directory and its descendants only":
    let r = root()
    check direnvLoadedDir("-" & r) == r
    check direnvLoadedDir("-") == ""
    check direnvLoadedDir("-relative/dir") == ""
    check direnvManagesDirectory("-" & r / "my project", r / "my project")
    check direnvManagesDirectory("-" & r / "my project",
      r / "my project" / "sub dir")
    check not direnvManagesDirectory("-" & r / "my project",
      r / "my project-a")
    check not direnvManagesDirectory("-" & r / "a", r / "b")
    check not direnvManagesDirectory("", r)

  test "stands down only when direnv reports the loaded RC allowed":
    let r = root()
    var calls = 0
    proc runner(ok: bool; output: string): DirenvStatusRunner =
      result = proc (cwd: string): tuple[ok: bool; output: string] =
        inc calls
        (ok: ok, output: output)
    let covered = envWith("-" & r)
    check nativeShellStandsDown(r / "sub", covered, runner(true, NewAllowed))
    check nativeShellStandsDown(r, covered, runner(true, OldAllowed))
    check not nativeShellStandsDown(r, covered, runner(true, NewBlocked))
    check not nativeShellStandsDown(r, covered, runner(true, NewDenied))
    check not nativeShellStandsDown(r, covered, runner(true, OldBlocked))
    check not nativeShellStandsDown(r, covered, runner(true, NothingLoaded))
    # direnv not on PATH, or failing: DIRENV_DIR alone (inherited, perhaps)
    # does not stand the hook down.
    check not nativeShellStandsDown(r, covered, runner(false, ""))
    check not nativeShellStandsDown(r, covered, runner(false, NewAllowed))
    check calls == 8
    # Not covered: direnv status is never asked.
    calls = 0
    check not nativeShellStandsDown(r, envWith(""), runner(true, NewAllowed))
    check not nativeShellStandsDown(r, envWith("-" & r / "other"),
      runner(true, NewAllowed))
    check calls == 0

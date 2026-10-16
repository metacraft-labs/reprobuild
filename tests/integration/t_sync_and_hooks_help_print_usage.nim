## ``repro sync --help`` and ``repro hooks ensure --help`` print usage.
##
## Both used to be refused by their flag parsers ("unsupported `repro
## workspace sync` flag: --help", "unsupported hooks flag: --help") and exit
## non-zero. The CLI's convention (``wantsHelp``) is that an explicit help
## request prints to stdout and exits 0, so a script or an operator can ask
## any verb how to call it.
##
## No mocks: the real ``build/bin/repro`` is run as a subprocess, in an empty
## directory, so the help path is proven not to need a workspace. The check
## that help did NOT fall through to the verb itself is that nothing was
## written to that directory.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "sync and hooks help":

  test "t_sync_and_hooks_help_print_usage":
    let repro = reproBinary()
    let empty = createTempDir("repro-help-", "")
    defer: removeDir(empty)
    for (argv, expected) in [
        (@["sync", "--help"], "usage: repro sync"),
        (@["sync", "-h"], "usage: repro sync"),
        (@["workspace", "sync", "--help"], "usage: repro sync"),
        (@["ws", "sync", "--help"], "usage: repro sync"),
        (@["hooks", "ensure", "--help"], "usage: repro hooks"),
        (@["hooks", "--help"], "usage: repro hooks")]:
      var cmd = @[repro]
      cmd.add(argv)
      cmd.add("--workspace-root=" & empty)
      let res = runShell(shellCommand(cmd))
      checkpoint(argv.join(" ") & " -> exit " & $res.code & "\n" & res.output)
      check res.code == 0
      check expected in res.output
      check "unsupported" notin res.output
    var leftovers: seq[string]
    for entry in walkDir(empty):
      leftovers.add(entry.path)
    check leftovers.len == 0

## RA-6 — `repro completion <shell>` emits a non-empty completion script.
##
## Like `repro prompt init`, the completion command prints a snippet for the
## user to `source`; it mutates nothing. The script is the thin one generated
## from repro's command-line description: it asks `repro __complete <shell>`
## for the candidates, so it names that entry point rather than listing any
## command itself. This checks that each supported shell gets a non-empty
## script that does, that the entry point answers with commands the
## description declares, and that an unsupported shell is a usage error
## (exit 2) naming the shell.

import std/[os, strutils, unittest]

import repro_test_support

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc completion(reproBin, shell: string): CmdResult =
  runShell(shellCommand(@[reproBin, "completion", shell]))

suite "RA-6 — repro completion (emits shell script)":

  test "test_ra6_completion_bash_zsh_fish_non_empty_and_reference_repro":
    let reproBin = reproBinary()
    for shell in ["bash", "zsh", "fish", "powershell"]:
      let res = completion(reproBin, shell)
      if res.code != 0:
        checkpoint(shell & " output: " & res.output)
      check res.code == 0
      check res.output.len > 0
      check res.output.contains("repro")
      # The script asks the binary; it lists no command of its own.
      check res.output.contains("__complete")
      check not res.output.contains("workspace")

  test "test_cs_m6_completion_entry_offers_declared_commands":
    let reproBin = reproBinary()
    let res = runShell(shellCommand(@[reproBin, "__complete", "fish", "wor"]))
    checkpoint(res.output)
    check res.code == 0
    check res.output.contains("workspace\t")
    # An internal namespace is never offered at the root.
    let root = runShell(shellCommand(@[reproBin, "__complete", "fish", "in"]))
    check root.code == 0
    check not root.output.contains("internal")

  test "test_ra6_completion_unsupported_shell_exits_2":
    let reproBin = reproBinary()
    let res = completion(reproBin, "tcsh")
    check res.code == 2
    check res.output.contains("'tcsh'")

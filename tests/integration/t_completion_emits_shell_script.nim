## RA-6 — `repro completion <shell>` emits a non-empty completion script.
##
## Like `repro prompt init`, the completion command prints a snippet for the
## user to `source`; it mutates nothing. Light test: the emitted snippet is
## non-empty and references `repro` for bash/zsh/fish; an unsupported shell
## fails with exit 2.

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
    for shell in ["bash", "zsh", "fish"]:
      let res = completion(reproBin, shell)
      if res.code != 0:
        checkpoint(shell & " output: " & res.output)
      check res.code == 0
      check res.output.len > 0
      check res.output.contains("repro")
      # Each script references the workspace command surface.
      check res.output.contains("workspace")

  test "test_ra6_completion_unsupported_shell_exits_2":
    let reproBin = reproBinary()
    let res = completion(reproBin, "tcsh")
    check res.code == 2
    check res.output.contains("unsupported shell")

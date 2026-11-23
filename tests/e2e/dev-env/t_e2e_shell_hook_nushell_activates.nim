## The Nushell hook must activate a dev environment in the shell it runs in.
##
## Regression: the hook ran ``repro dev-env export nushell`` and threw the
## output away, so entering a project changed nothing and
## ``__REPRO_PROJECT_ROOT`` was never set. Nushell cannot evaluate a string as
## code at run time, so the export is a NUON operation list that the hook
## parses with ``from nuon`` and applies in its own scope.
##
## No mocks: a real ``nu`` runs the hook rendered by the real ``repro shell
## hook nushell``, which calls the real ``repro dev-env export`` (through the
## counting shim that forwards to it) against a fixture project. ``nu`` is
## part of the dev shell (flake.nix), so its absence fails the test rather
## than skipping it.

import std/[os, strutils, unittest]

import repro_test_support
import shell_hook_helper

proc snapshot(output, tag: string): seq[string] =
  ## The ``NAME=value`` lines the nu script printed between the tag markers.
  let beginMarker = "__BEGIN_" & tag & "__"
  let endMarker = "__END_" & tag & "__"
  let s = output.find(beginMarker)
  let e = output.find(endMarker)
  doAssert s >= 0 and e > s, "missing snapshot " & tag & " in:\n" & output
  for line in output[s + beginMarker.len ..< e].splitLines():
    if line.strip().len > 0:
      result.add(line.strip())

proc value(lines: seq[string]; name: string): string =
  for line in lines:
    if line.startsWith(name & "="):
      return line[name.len + 1 .. ^1]
  doAssert false, "no " & name & " in " & $lines

suite "e2e_shell_hook_nushell_activates":
  test "nushell_hook_activates_on_cd_in_and_restores_on_cd_out":
    let nu = findExe("nu")
    doAssert nu.len > 0, "nu must be on PATH (it is part of the dev shell, flake.nix)"
    let c = prepareShellHookCase("repro-nushell-hook")
    defer:
      try: removeDir(c.tempRoot)
      except CatchableError: discard

    let hookPath = c.tempRoot / "hook.nu"
    writeFile(hookPath, renderHookForCase(c, "nushell"))
    let outside = c.tempRoot / "outside"
    createDir(outside)
    # Every observation goes through ``snap``; the spawn counter is the
    # number of bytes the shim has been appended to.
    let scriptPath = c.tempRoot / "scenario.nu"
    writeFile(scriptPath,
      "source '" & hookPath & "'\n" &
      "def snap [tag: string] {\n" &
      "  print $'__BEGIN_($tag)__'\n" &
      "  for v in [FIXTURE_MODE AUX_VALUE __REPRO_APPLIED __REPRO_PROJECT_ROOT] {\n" &
      "    print $'($v)=(if ($env | columns | any {|c| $c == $v }) { $env | get $v } else { \"\" })'\n" &
      "  }\n" &
      "  print $'PATH=($env.PATH | str join (char esep))'\n" &
      "  print $'SPAWNS=(open --raw $env.REPRO_M76_SHIM_COUNTER | into binary | bytes length)'\n" &
      "  print $'__END_($tag)__'\n" &
      "}\n" &
      "snap before\n" &
      "cd '" & c.projectRoot & "'\n" &
      "__repro_shell_hook\n" &
      "snap entered\n" &
      "__repro_shell_hook\n" &
      "__repro_shell_hook\n" &
      "snap repeated\n" &
      "cd '" & outside & "'\n" &
      "__repro_shell_hook\n" &
      "snap left\n")
    let env = c.baselineEnvForBash()
    let res = runShell(shellCommand(@[nu, "--no-config-file", scriptPath],
      env.envEntries), c.tempRoot)
    if res.code != 0:
      echo res.output
    check res.code == 0

    let before = snapshot(res.output, "before")
    let entered = snapshot(res.output, "entered")
    let repeated = snapshot(res.output, "repeated")
    let left = snapshot(res.output, "left")

    # The variables the project sets are visible, and the hook's root guard
    # (the project root) is set: the two things the discarded export lost.
    check entered.value("FIXTURE_MODE") == "dev"
    check entered.value("AUX_VALUE") == "alpha"
    check entered.value("__REPRO_APPLIED").len > 0
    check entered.value("__REPRO_PROJECT_ROOT") == c.projectRoot
    check entered.value("PATH").startsWith("tools/bin" & ":")
    check entered.value("SPAWNS") != before.value("SPAWNS")

    # Inside the active project the root guard short-circuits: no spawn.
    check repeated.value("SPAWNS") == entered.value("SPAWNS")
    check repeated.value("FIXTURE_MODE") == "dev"

    # Leaving restores the shell's own environment.
    check left.value("FIXTURE_MODE") == ""
    check left.value("__REPRO_APPLIED") == ""
    check left.value("__REPRO_PROJECT_ROOT") == ""
    check left.value("PATH") == before.value("PATH")

  test "nushell_hook_survives_an_untrusted_directory_and_empty_output":
    # An untrusted project root makes ``dev-env export`` print the warning
    # operations once and then NOTHING (``__REPRO_WARNED`` marks it warned).
    # ``from nuon`` turns empty output into ``nothing``, which the hook must
    # treat as an empty operation list rather than abort on a type error.
    let nu = findExe("nu")
    doAssert nu.len > 0, "nu must be on PATH (it is part of the dev shell, flake.nix)"
    let c = prepareShellHookCase("repro-nushell-hook-untrusted")
    defer:
      try: removeDir(c.tempRoot)
      except CatchableError: discard

    let hookPath = c.tempRoot / "hook.nu"
    writeFile(hookPath, renderHookForCase(c, "nushell"))
    let scriptPath = c.tempRoot / "scenario.nu"
    writeFile(scriptPath,
      "source '" & hookPath & "'\n" &
      "hide-env REPRO_DEV_ENV_AUTO_ALLOW\n" &
      "cd '" & c.projectRoot & "'\n" &
      "__repro_shell_hook\n" &
      "print $'WARNED=($env.__REPRO_WARNED? | default \"\")'\n" &
      "__repro_shell_hook\n" &
      "print $'ACTIVE=($env.__REPRO_APPLIED? | default \"\")'\n" &
      "print 'REACHED-END'\n")
    let res = runShell(shellCommand(@[nu, "--no-config-file", scriptPath],
      c.baselineEnvForBash().envEntries), c.tempRoot)
    if res.code != 0:
      echo res.output
    check res.code == 0
    check res.output.contains("is not allowed/trusted")
    check res.output.contains("WARNED=" & c.projectRoot)
    check res.output.contains("ACTIVE=\n") or res.output.contains("ACTIVE=\r\n")
    check res.output.contains("REACHED-END")

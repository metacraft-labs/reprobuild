## Windows command-runner regression coverage: long commands are routed
## through a PowerShell script with an argv array instead of a single cmd.exe
## command line. cmd.exe truncates around 8191 characters; Nim does not accept
## `@file` response arguments here, so the script must preserve the real argv.

import std/[strutils, unittest]

import repro_interface_artifacts

suite "Windows long command script planning":

  test "script invokes executable with argv array and sink redirection":
    let script = powerShellRunCommandScript(
      @[
        r"C:\tools\nim\bin\nim.exe",
        "c",
        "--path:" & r"D:\metacraft\reprobuild\libs\repro_core\src",
        "--define:reproInterfaceMode",
        r"C:\Users\zahary\repro-interface-extract\extract_runner.nim",
      ],
      r"C:\Users\zahary\repro-runcommand-long.log")

    check "$ErrorActionPreference = 'Continue'" in script
    check "PSNativeCommandUseErrorActionPreference" in script
    check "$exe = 'C:\\tools\\nim\\bin\\nim.exe'" in script
    check "'c'," in script
    check "'--path:D:\\metacraft\\reprobuild\\libs\\repro_core\\src'," in script
    check "'--define:reproInterfaceMode'," in script
    check "'C:\\Users\\zahary\\repro-interface-extract\\extract_runner.nim'" in script
    check "& $exe @argv > 'C:\\Users\\zahary\\repro-runcommand-long.log' 2>&1" in script
    check "exit $LASTEXITCODE" in script

  test "script preserves quotes apostrophes and empty arguments":
    let script = powerShellRunCommandScript(
      @[
        "tool.exe",
        "",
        "--define:name=\"two words\"",
        "owner's path",
      ],
      "sink.log")

    check "  ''," in script
    check "'--define:name=\"two words\"'," in script
    check "'owner''s path'" in script

  when defined(windows):
    test "runCommand on Windows captures merged stdout and stderr directly":
      let res = runCommand(@["cmd.exe", "/c", "echo hello from test & echo stderr from test 1>&2"])
      check res.exitCode == 0
      check "hello from test" in res.output
      check "stderr from test" in res.output

    test "runCommand executes long command line without truncation":
      var args = @["cmd.exe", "/c", "echo start"]
      for i in 1..200:
        args.add("arg" & $i)
      args.add("& echo end")
      let res = runCommand(args)
      check res.exitCode == 0
      check "start" in res.output
      check "end" in res.output

when defined(windows):
  suite "Windows command failure reports name what died":

    # ReproOS campaign (reprobuild `reproos` cd65cae1, 2026-10-07): from
    # 2026-09-18 `repro build .#apps` reported
    # `command failed (-1073740791): ...nim.exe c ...` -- a CET shadow-stack
    # fast fail (0xC0000409) of the launcher pwsh.exe, not of nim, which never
    # ran. The campaign's fix named the launcher in the report. On `agents`,
    # runCommand no longer has a launcher: it starts the command itself with
    # CreateProcessW (0162837ed), so the reported status IS the command's,
    # and `commandFailure` names an NTSTATUS crash as a crash
    # (`abnormalTerminationName`). The launcher note was therefore dropped at
    # the merge; this case keeps the campaign's evidence -- the exact status
    # from that report -- and, unlike the dropped cases, drives a REAL failing
    # runCommand rather than the formatting helper.
    test "the CET fast-fail status is reported as a crash, not as a number":
      var message = ""
      try:
        discard runCommand(@["cmd.exe", "/d", "/c", "exit /b -1073740791"])
      except OSError as e:
        message = e.msg
      check message.startsWith("command terminated abnormally (")
      check "0xC0000409" in message
      check "command failed (-1073740791)" notin message

    test "an ordinary failing status is not called a crash":
      var message = ""
      try:
        discard runCommand(@["cmd.exe", "/d", "/c", "exit /b 1"])
      except OSError as e:
        message = e.msg
      check message.startsWith("command failed (1)")
      check "abnormally" notin message

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

suite "Windows command failure reports name the launcher":

  test "the launcher whose exit status is reported is named":
    # runCommand never starts the command itself on Windows; it starts
    # cmd.exe or PowerShell, and the status it reports is theirs. The
    # 2026-09-18..10-05 `.#apps` blocker was reported as `nim.exe` failing
    # with -1073740791 while `pwsh.exe` -- the launcher -- was the process
    # that died, and nim had never started.
    let note = windowsLauncherNote(
      r"C:\pwsh\pwsh.exe -File C:\Temp\repro-runcommand-1.ps1", -1073740791)
    check note.startsWith("\n(run through ")
    check r"C:\pwsh\pwsh.exe -File C:\Temp\repro-runcommand-1.ps1" in note
    check "the exit status is the launcher's" in note
    check "0xC0000409" in note
    check "NTSTATUS" in note

  test "an ordinary nonzero status is not called an NTSTATUS":
    let note = windowsLauncherNote(r"cmd.exe /c C:\Temp\x.cmd", 1)
    check r"cmd.exe /c C:\Temp\x.cmd" in note
    check "NTSTATUS" notin note

  test "no launcher, nothing to say":
    check windowsLauncherNote("", -1073740791) == ""

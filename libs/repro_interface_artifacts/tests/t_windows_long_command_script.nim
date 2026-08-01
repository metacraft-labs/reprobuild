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

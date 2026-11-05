## Windows command-runner regression coverage: long commands are routed
## through a PowerShell script with an argv array instead of a single cmd.exe
## command line. cmd.exe truncates around 8191 characters; Nim does not accept
## `@file` response arguments here, so the script must preserve the real argv.
##
## The suite "SDK search-path reassertion leaves the command line" covers the
## pure half of `splitSearchPathReassertion`: which arguments leave a `nim c`
## command, what the NimScript that replaces them says, and every shape it
## refuses to move. That nim reaches the same search path from the split form
## is checked with the real compiler in
## `tests/integration/t_compiler_scratch_isolation.nim`. No mocks: the helper
## is a pure function of its argv.

import std/[os, strutils, unittest]

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

proc sdkRoot(name: string): string =
  ## An absolute directory on the host's own syntax: the helper moves only
  ## absolute roots.
  when defined(windows): r"C:\sdk root\libs\" & name & r"\src"
  else: "/sdk root/libs/" & name & "/src"

const Module = "\x00main-module\x00"

proc protectedCommand(kept, reasserted: openArray[string]): seq[string] =
  ## The shape `protectSdkCompilePaths` leaves: options, the kept roots in
  ## their order, then every reasserted root's exclusion followed by its
  ## re-add, then the main module and its run arguments.
  result = @["nim", "c", "--define:reproInterfaceMode"]
  for root in kept:
    result.add("--path:" & root)
  result.add("--nimcache:")
  for root in reasserted:
    result.add("--excludePath:" & root)
  for root in reasserted:
    result.add("--path:" & root)
  result.add(Module)
  result.add("--path:after-the-module-is-a-run-argument")

suite "SDK search-path reassertion leaves the command line":

  test "the reassertion pairs move to the script; everything else stays in order":
    let kept = @[sdkRoot("consumer"), "relative/recipe/dir"]
    let reasserted = @[sdkRoot("repro_core"), sdkRoot("repro_hash")]
    let logical = protectedCommand(kept, reasserted)
    let launch = splitSearchPathReassertion(logical, Module)
    check launch.movedArguments == 4
    check launch.argv == @["nim", "c", "--define:reproInterfaceMode",
      "--path:" & kept[0], "--path:" & kept[1], "--nimcache:", Module,
      "--path:after-the-module-is-a-run-argument"]
    # The script replays EVERY search-path operation before the module, in
    # the logical order: the kept roots too (that is what makes the second
    # command-line pass a no-op), never a run argument.
    check launch.script.startsWith(NimSearchPathScriptHeader)
    let body = launch.script[NimSearchPathScriptHeader.len .. ^1]
    check body ==
      "switch(\"path\", " & kept[0].escape & ")\n" &
      "switch(\"path\", " & kept[1].escape & ")\n" &
      "switch(\"excludePath\", " & reasserted[0].escape & ")\n" &
      "switch(\"excludePath\", " & reasserted[1].escape & ")\n" &
      "switch(\"path\", " & reasserted[0].escape & ")\n" &
      "switch(\"path\", " & reasserted[1].escape & ")\n"
    check "after-the-module" notin launch.script

  test "the launch command no longer grows with the number of SDK roots":
    # 116 roots of an installed SDK at the depth measured in the GM1w gate:
    # the logical command is over Windows' 32,767-character limit, the launch
    # command is the kept part only.
    let prefix = when defined(windows):
        r"C:\Users\someone\AppData\Local\Temp\gm1w-pkg-0000\x b\reprobuild-0.2.19-windows-x86_64\share\repro\source\libs\"
      else:
        "/home/someone/.local/share/repro/reprobuild-0.2.19-linux-x86_64/share/repro/source/libs/"
    var reasserted: seq[string]
    for i in 0 ..< 116:
      reasserted.add(prefix & "library_number_" & $i & "_with_a_reasonably_long_name" &
        DirSep & "src")
    let logical = protectedCommand(@[sdkRoot("consumer")], reasserted)
    let launch = splitSearchPathReassertion(logical, Module)
    checkpoint("logical " & $commandLineLength(logical) & ", launch " &
      $commandLineLength(launch.argv))
    check commandLineLength(logical) > 32_767
    check commandLineLength(launch.argv) < 300
    check launch.movedArguments == 2 * reasserted.len
    for root in reasserted:
      check ("--path:" & root) notin launch.argv
      check ("switch(\"path\", " & root.escape & ")") in launch.script

  test "any spelling nim accepts is recognised as a search-path operation":
    let a = sdkRoot("a")
    let b = sdkRoot("b")
    let logical = @["nim", "c", "-p:" & b, "--exclude_path=" & a,
      "--PATH:" & a, Module]
    let launch = splitSearchPathReassertion(logical, Module)
    check launch.argv == @["nim", "c", "-p:" & b, Module]
    check ("switch(\"path\", " & b.escape & ")") in launch.script
    check ("switch(\"excludePath\", " & a.escape & ")") in launch.script

  test "bytes outside printable ASCII survive the script literal":
    let odd = sdkRoot("quote\" back\\slash ünïcödé 'tick'")
    let logical = protectedCommand(newSeq[string](), [odd])
    let launch = splitSearchPathReassertion(logical, Module)
    check launch.movedArguments == 2
    let line = "switch(\"path\", " & odd.escape & ")"
    check line in launch.script
    # `escape` output is a Nim literal; `unescape` is its inverse.
    check odd.escape.unescape == odd
    for ch in launch.script:
      check ch == '\n' or ch in {' ' .. '~'}

  test "a command without a reassertion is launched as it is":
    let logical = protectedCommand([sdkRoot("one"), sdkRoot("two")],
      newSeq[string]())
    let launch = splitSearchPathReassertion(logical, Module)
    check launch.argv == logical
    check launch.script == ""
    check launch.movedArguments == 0

  test "no module argument: nothing is moved":
    let logical = protectedCommand(newSeq[string](), [sdkRoot("x")])
    let launch = splitSearchPathReassertion(logical, "\x00other\x00")
    check launch.argv == logical
    check launch.script == ""

  test "shapes the equivalence is not argued for move nothing":
    let a = sdkRoot("a")
    let b = sdkRoot("b")
    let refused = @[
      # An exclusion that is not re-added has a real first-pass effect.
      @["nim", "c", "--path:" & b, "--excludePath:" & a, Module],
      # Re-added before it is excluded.
      @["nim", "c", "--path:" & a, "--excludePath:" & a, Module],
      # A root excluded twice.
      @["nim", "c", "--excludePath:" & a, "--excludePath:" & a,
        "--path:" & a, Module],
      # A reasserted root that is also on the command line elsewhere.
      @["nim", "c", "--path:" & a, "--excludePath:" & a, "--path:" & a,
        Module],
      @["nim", "c", "--excludePath:" & a, "--path:" & a, "--path:" & a,
        Module],
      # A reasserted pair next to an unpaired exclusion of another root.
      @["nim", "c", "--excludePath:" & a, "--path:" & a,
        "--excludePath:" & b, Module],
      # Values the script would resolve differently: `$` substitution (and
      # `$config` names the script's directory there), a leading quote
      # (NimScript unescapes it), a relative reasserted root.
      @["nim", "c", "--excludePath:$nim/lib", "--path:$nim/lib", Module],
      @["nim", "c", "--path:$projectdir/x", "--excludePath:" & a,
        "--path:" & a, Module],
      @["nim", "c", "--excludePath:\"" & a, "--path:\"" & a, Module],
      @["nim", "c", "--excludePath:relative/root", "--path:relative/root",
        Module],
      @["nim", "c", "--excludePath:" & a & "\x00", "--path:" & a & "\x00",
        Module],
    ]
    for logical in refused:
      let launch = splitSearchPathReassertion(logical, Module)
      checkpoint(logical.join(" | "))
      check launch.argv == logical
      check launch.script == ""
      check launch.movedArguments == 0

  test "the script sits beside the main module, named as nim looks for it":
    when defined(windows):
      check nimSearchPathScriptPath(r"C:\slot-0\extract_runner_0123.nim") ==
        r"C:\slot-0\extract_runner_0123.nims"
    else:
      check nimSearchPathScriptPath("/slot-0/extract_runner_0123.nim") ==
        "/slot-0/extract_runner_0123.nims"

  test "a value nim splits off at the first separator keeps the rest":
    # `--path:C:\x` -- the drive colon is part of the value, not a separator.
    let root = sdkRoot("with:colon=and equals")
    let launch = splitSearchPathReassertion(
      @["nim", "c", "--excludePath:" & root, "--path:" & root, Module],
      Module)
    check launch.movedArguments == 2
    check ("switch(\"path\", " & root.escape & ")") in launch.script
    check launch.argv == @["nim", "c", Module]

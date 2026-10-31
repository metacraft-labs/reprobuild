## The MSVC developer-environment activation starts no telemetry PowerShell,
## so it writes nothing into the user's home.
##
## WHAT BROKE. On Windows the engine captures the MSVC developer environment
## by running ``VsDevCmd.bat`` and then ``set`` in a ``cmd.exe`` that inherits
## the engine's environment (``invokeVsDevCmd``). It does this for every action
## that inherits the host's PATH, the ``repro home`` profile compile edge
## among them. Unless ``VSCMD_SKIP_SENDTELEMETRY`` is set, ``VsDevCmd.bat``
## runs
##
##   START "" /B powershell.exe -NoProfile -Command "& {... Send-VsDevShellTelemetry ...}"
##
## (VS 2022 ``Common7\Tools\VsDevCmd.bat``, the "Send Telemetry if user's VS
## is opted-in" block), a detached Windows PowerShell. Windows PowerShell
## resolves its known folders from the inherited ``%USERPROFILE%`` and
## creates ``%USERPROFILE%\AppData\Roaming`` when it is missing, even with
## ``APPDATA`` pointing elsewhere. Every ``repro home facts``, ``repro home
## apply --plan`` and refused ``repro home apply`` therefore created that
## directory in the home it was only reading, which the gm11 refusal gates
## catch as "HOME changed" (reprobuild-pm issue
## 2026-10-23-windows-home-commands-create-appdata-roaming-under-userprofile;
## found with Process Monitor on eli-pc: the creator was
## ``powershell.exe -NoProfile -Command "... Send-VsDevShellTelemetry ..."``,
## a child of the activation's ``cmd.exe``).
##
## WHAT IS ASSERTED.
##   1. ``vsDevCmdChildEnv`` gives the activation shell
##      ``VSCMD_SKIP_SENDTELEMETRY`` with a non-empty value (``VsDevCmd.bat``
##      tests ``if "%VSCMD_SKIP_SENDTELEMETRY%"==""``), and
##      ``vsDevCmdInjectedNames`` reports it as added.
##   2. A value the user already set, under any letter case, is kept as it is
##      and not reported as added.
##   3. The added variable does not reach the captured activation table, so
##      the environment layered over actions is the same as before the fix;
##      a user-set one is captured as before.
##   4. (Windows, with Visual Studio installed) end to end: the real
##      ``activateMsvcDevEnv`` run with ``USERPROFILE`` pointing at an empty
##      directory leaves that directory empty, also after the time a detached
##      PowerShell needs to start. On a Windows host without Visual Studio the
##      activation does not run ``VsDevCmd.bat`` at all, and the case says so
##      and skips. On Linux and macOS there is no activation; the case does
##      not exist there, and runs on eli-pc (recorded as a Verification entry
##      of the Gradual Nix migration milestones).
##
## The one stand-in, and why: cases 1-3 render ``cmd.exe``'s ``set`` with
## ``cmdSetDump`` (one ``NAME=VALUE`` line per variable, value verbatim) and
## model ``VsDevCmd.bat`` with ``vsDevCmdActivate``, because neither exists on
## the Linux and macOS hosts this suite also runs on. Case 4 uses neither.

import std/[algorithm, strutils, tables, unittest]
when defined(windows):
  import std/os
  import repro_test_support/reasoned_skip

import repro_platform

proc cmdSetDump(env: openArray[(string, string)]): string =
  ## ``cmd.exe``'s ``set``: one ``NAME=VALUE`` line per variable, the value
  ## written verbatim, names sorted case-insensitively.
  var sorted = @env
  sorted.sort(proc (a, b: (string, string)): int =
    cmp(a[0].toUpperAscii, b[0].toUpperAscii))
  for (name, value) in sorted:
    result.add(name & "=" & value & "\r\n")

proc vsDevCmdActivate(shellEnv: openArray[(string, string)]):
    seq[(string, string)] =
  ## What ``VsDevCmd.bat`` does to the shell it runs in: add its variables.
  ## Everything the shell was started with passes through to ``set``.
  result = @shellEnv
  result.add(("VCToolsInstallDir", r"C:\BuildTools\VC\Tools\MSVC\14.44\"))
  result.add(("VSINSTALLDIR", r"C:\BuildTools\"))

proc lookup(env: openArray[(string, string)]; name: string): seq[string] =
  ## Every value ``env`` gives ``name``, names compared case-insensitively.
  for (k, v) in env:
    if cmpIgnoreCase(k, name) == 0:
      result.add(v)

proc parentEnv(): seq[(string, string)] =
  @[("Path", r"C:\Windows\System32"), ("SystemRoot", r"C:\Windows"),
    ("USERPROFILE", r"C:\Users\someone")]

suite "MSVC activation starts no telemetry PowerShell":
  test "the activation shell is told to skip VsDevCmd's telemetry":
    let parent = parentEnv()
    let shellEnv = vsDevCmdChildEnv(parent)
    check shellEnv.lookup("VSCMD_SKIP_SENDTELEMETRY") == @["1"]
    check vsDevCmdInjectedNames(parent) == @["VSCMD_SKIP_SENDTELEMETRY"]
    # Everything the parent set still reaches the shell, unchanged.
    for (name, value) in parent:
      check shellEnv.lookup(name) == @[value]

  test "a value the user set is kept and not reported as added":
    for spelling in ["VSCMD_SKIP_SENDTELEMETRY", "vscmd_skip_sendtelemetry"]:
      var parent = parentEnv()
      parent.add((spelling, "yes"))
      let shellEnv = vsDevCmdChildEnv(parent)
      check shellEnv.lookup("VSCMD_SKIP_SENDTELEMETRY") == @["yes"]
      check vsDevCmdInjectedNames(parent).len == 0

  test "the added variable stays out of the captured activation table":
    let parent = parentEnv()
    let lines = parseCmdSetOutput(cmdSetDump(
      vsDevCmdActivate(vsDevCmdChildEnv(parent))))
    let table = msvcEnvTableFromSetLines(lines, vsDevCmdInjectedNames(parent))
    for key in table.keys:
      check cmpIgnoreCase(key, "VSCMD_SKIP_SENDTELEMETRY") != 0
    check table["VCToolsInstallDir"] == r"C:\BuildTools\VC\Tools\MSVC\14.44\"
    check table["USERPROFILE"] == r"C:\Users\someone"

  test "a user-set value is captured as before":
    var parent = parentEnv()
    parent.add(("VSCMD_SKIP_SENDTELEMETRY", "yes"))
    let lines = parseCmdSetOutput(cmdSetDump(
      vsDevCmdActivate(vsDevCmdChildEnv(parent))))
    let table = msvcEnvTableFromSetLines(lines, vsDevCmdInjectedNames(parent))
    check table["VSCMD_SKIP_SENDTELEMETRY"] == "yes"

  when defined(windows):
    test "the real activation leaves an empty USERPROFILE empty":
      # The activation is cached per process, so this must be its first call
      # in this test binary, made with the sandboxed USERPROFILE in place.
      let home = getTempDir() / ("repro-msvc-home-" & $getCurrentProcessId())
      createDir(home)
      let savedProfile = getEnv("USERPROFILE")
      putEnv("USERPROFILE", home)
      var devEnv: MsvcDevEnv
      try:
        devEnv = activateMsvcDevEnv()
      finally:
        putEnv("USERPROFILE", savedProfile)
      if not devEnv.available:
        skip("no Visual Studio install with VC tools on this host, so " &
          "VsDevCmd.bat is never run and nothing can be spawned")
      else:
        # The telemetry PowerShell was started detached (``START /B``): give
        # it the time it takes to start and create its folders (well under a
        # second in the eli-pc Process Monitor trace) before looking.
        sleep(5000)
        var entries: seq[string] = @[]
        for kind, path in walkDir(home, relative = true):
          entries.add(path)
        checkpoint("entries created under USERPROFILE: " & $entries)
        check entries.len == 0
      try: removeDir(home) except CatchableError, OSError: discard

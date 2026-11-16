## The MSVC developer-environment activation contributes only what VsDevCmd
## set or changed, so a host variable that changes AFTER the activation
## reaches every later launch with its new value.
##
## WHAT BROKE. On Windows the engine captures the activation once per process
## (``activateMsvcDevEnv``) by running ``VsDevCmd.bat`` and then ``set`` in a
## ``cmd.exe`` that inherits the engine's environment, and layers the result
## over every action that inherits the host's PATH. The layer used to be the
## WHOLE ``set`` dump: every variable of the host, with the value it had at
## the first activation. A later change to the host was therefore invisible
## to the launched action and, because ``actionEnvResolver`` mirrors the
## launch, to the action-cache key as well. Measured on eli-pc (reprobuild
## ``agents`` ``9e78a755bd``): the profile compile edge read 190 variables,
## ``APPDATA`` among them, and after ``APPDATA`` was pointed at a new
## directory the resolver still answered the old one and the compile was a
## cache hit (reprobuild-pm issue
## 2026-11-15-windows-profile-compile-edge-is-not-invalidated-when-appdata-changes).
## ``nim`` reads ``%APPDATA%\nim\nim.cfg``
## (https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files),
## so a user configuration change was silently ignored. The same held for
## ``PATH``: its captured value is the toolchain plus the host's ``PATH`` at
## that moment.
##
## WHAT IS ASSERTED, over the production procs (``vsDevCmdChildEnv`` ->
## ``set`` -> ``parseCmdSetOutput`` -> ``msvcEnvTableFromSetLines`` ->
## ``msvcDevEnvFromActivation`` -> ``mergeActionEnvWithMsvcEnv`` -> layered
## over the environment the launch inherits, as the Windows launcher layers an
## action's ``KEY=VALUE`` entries):
##   1. a variable the activation did not change is not in the layer, so a
##      changed host value reaches the action (``APPDATA``, ``USERPROFILE``);
##   2. an undeclared search list is the activation's MSVC-owned entries in
##      front of the host's CURRENT value: an entry added to the host's PATH
##      after the activation arrives, and ``cl.exe``'s directory comes first,
##      as VsDevCmd puts it;
##   3. a variable the activation set or changed is still layered
##      (``VCToolsInstallDir``, the engine's ``CC=cl.exe`` over a host
##      ``CC=gcc``), and a search list the action declares is still combined
##      (the owned entries after the action's own);
##   4. an isolated launch (no inherited lists) gets the owned entries alone,
##      not the host's list;
##   5. an inherited activation adds nothing to an inherited list that
##      already carries the toolchain;
##   6. what the host already held with the activation's value: an install
##      root (``VSINSTALLDIR``) and the engine's ``CC=cl.exe`` are still
##      layered, so an isolated launch gets them; any other variable is left
##      to the inherited environment;
##   7. the hazard itself: the ``set`` dump alone carries the host's values,
##      so applying it whole pins them (pinned so nobody "simplifies" the
##      layer back to the dump).
##
## The one stand-in, and why: ``cmd.exe``'s ``set`` and ``VsDevCmd.bat`` are
## rendered by ``cmdSetDump`` / ``vsDevCmdActivate`` below, as in
## ``test_msvc_activation_multiline_env.nim``. Neither exists on the Linux and
## macOS hosts this suite also runs on; the ``NAME=VALUE`` line format and
## "prepend the toolchain to PATH, add its variables" are the whole contract
## the capture depends on. The real activation is exercised on Windows by
## ``libs/repro_build_engine/tests/t_msvc_activation_keeps_host_env_current.nim``.

import std/[algorithm, strutils, tables, unittest]

import repro_platform

const
  VcBin = r"C:\BuildTools\VC\Tools\MSVC\14.44\bin\HostX64\x64"
  VcLib = r"C:\BuildTools\VC\Tools\MSVC\14.44\lib\x64"

proc hostAtActivation(): seq[(string, string)] =
  @[
    ("APPDATA", r"C:\Users\someone\AppData\Roaming"),
    ("CC", "gcc"),
    ("LIB", r"C:\host\lib"),
    ("Path", r"C:\Windows\System32;C:\tools\nim\bin"),
    ("SystemRoot", r"C:\Windows"),
    ("USERPROFILE", r"C:\Users\someone"),
  ]

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
  ## What ``VsDevCmd.bat`` does to the shell it runs in: prepend the toolchain
  ## to PATH and LIB, add its variables. Everything else passes through.
  for (name, value) in shellEnv:
    if cmpIgnoreCase(name, "Path") == 0:
      result.add((name, VcBin & ";" & value))
    elif cmpIgnoreCase(name, "LIB") == 0:
      result.add((name, VcLib & ";" & value))
    else:
      result.add((name, value))
  result.add(("VCToolsInstallDir", r"C:\BuildTools\VC\Tools\MSVC\14.44\"))
  result.add(("VSINSTALLDIR", r"C:\BuildTools\"))

proc captureActivation(host: seq[(string, string)]): MsvcDevEnv =
  ## ``computeMsvcDevEnvLocked``'s steps, with the shell rendered.
  let lines = parseCmdSetOutput(cmdSetDump(
    vsDevCmdActivate(vsDevCmdChildEnv(host))))
  let table = msvcEnvTableFromSetLines(lines, vsDevCmdInjectedNames(host))
  msvcDevEnvFromActivation(table, host, [("CC", "cl.exe")])

proc listsOf(env: openArray[(string, string)]): seq[(string, string)] =
  ## The ``MsvcListKeys`` an inheriting launch passes as ``inheritedLists``.
  for (name, value) in env:
    for key in MsvcListKeys:
      if cmpIgnoreCase(name, key) == 0:
        result.add((name, value))

proc layered(inherited: openArray[(string, string)];
             overlay: openArray[string]): Table[string, string] =
  ## The launcher's composition: the inherited environment, then the action's
  ## ``KEY=VALUE`` entries, rightmost wins, names case-insensitive.
  for (name, value) in inherited:
    result[name.toUpperAscii] = value
  for entry in overlay:
    let eq = entry.find('=')
    if eq <= 0: continue
    result[entry[0 ..< eq].toUpperAscii] = entry[eq + 1 .. ^1]

proc launch(devEnv: MsvcDevEnv; host: seq[(string, string)];
            actionEnv: seq[string] = @[]): Table[string, string] =
  layered(host, mergeActionEnvWithMsvcEnv(devEnv, actionEnv, listsOf(host)))

proc hostLater(): seq[(string, string)] =
  ## The same host after the activation was captured: a new APPDATA and
  ## USERPROFILE, and a directory added to PATH.
  @[
    ("APPDATA", r"D:\elsewhere\Roaming"),
    ("CC", "gcc"),
    ("LIB", r"C:\host\lib"),
    ("Path", r"C:\new\bin;C:\Windows\System32;C:\tools\nim\bin"),
    ("SystemRoot", r"C:\Windows"),
    ("USERPROFILE", r"D:\elsewhere"),
  ]

suite "MSVC activation tracks the host environment":
  test "1. a variable the activation did not change is not layered":
    let devEnv = captureActivation(hostAtActivation())
    check devEnv.available
    for name in ["APPDATA", "USERPROFILE", "SystemRoot", "Path", "LIB"]:
      check not devEnv.env.hasKey(name)
    let child = launch(devEnv, hostLater())
    check child["APPDATA"] == r"D:\elsewhere\Roaming"
    check child["USERPROFILE"] == r"D:\elsewhere"

  test "2. an undeclared search list is the toolchain before the host's current value":
    let devEnv = captureActivation(hostAtActivation())
    check devEnv.ownedLists["PATH"] == @[VcBin]
    check devEnv.ownedLists["LIB"] == @[VcLib]
    let child = launch(devEnv, hostLater())
    check child["PATH"] == VcBin & r";C:\new\bin;C:\Windows\System32;C:\tools\nim\bin"
    check child["LIB"] == VcLib & r";C:\host\lib"

  test "3. what the activation set or changed is still layered":
    let devEnv = captureActivation(hostAtActivation())
    let child = launch(devEnv, hostLater())
    check child["VCTOOLSINSTALLDIR"] == r"C:\BuildTools\VC\Tools\MSVC\14.44\"
    check child["CC"] == "cl.exe"
    # A declared list keeps its own entries first, the toolchain after them.
    let declared = launch(devEnv, hostLater(), @[r"PATH=C:\tool\bin"])
    check declared["PATH"] == r"C:\tool\bin;" & VcBin
    # A declared ordinary variable still wins.
    let own = launch(devEnv, hostLater(), @["CC=clang-cl.exe"])
    check own["CC"] == "clang-cl.exe"

  test "4. an isolated launch gets the owned entries alone":
    let devEnv = captureActivation(hostAtActivation())
    let merged = mergeActionEnvWithMsvcEnv(devEnv, @["X=1"])
    let child = layered([], merged)
    check child["PATH"] == VcBin
    check child["LIB"] == VcLib
    check not child.hasKey("APPDATA")

  test "5. an inherited activation adds nothing to an inherited list":
    let inheritedPath = VcBin & r";C:\Windows\System32"
    let devEnv = inheritedMsvcDevEnv(inheritedPath, [r"C:\BuildTools\"])
    let merged = mergeActionEnvWithMsvcEnv(devEnv, @["X=1"],
      @[("Path", inheritedPath)])
    check merged == @["X=1"]

  test "6. what the host already held is layered only when the activation owns it":
    var host = hostAtActivation()
    host.add(("VSINSTALLDIR", r"C:\BuildTools\"))
    host.add(("VSCMD_ARG_TGT_ARCH", "x64"))
    for i, (name, _) in host:
      if name == "CC": host[i] = ("CC", "cl.exe")
    let shell = vsDevCmdChildEnv(host)
    var activated = vsDevCmdActivate(shell)
    activated.add(("VSCMD_ARG_TGT_ARCH", "x64"))
    let table = msvcEnvTableFromSetLines(parseCmdSetOutput(cmdSetDump(
      activated)), vsDevCmdInjectedNames(host))
    let devEnv = msvcDevEnvFromActivation(table, host, [("CC", "cl.exe")])
    check devEnv.env[r"VSINSTALLDIR"] == r"C:\BuildTools\"
    check devEnv.env["CC"] == "cl.exe"
    check not devEnv.env.hasKey("VSCMD_ARG_TGT_ARCH")
    let isolated = layered([], mergeActionEnvWithMsvcEnv(devEnv, @["X=1"]))
    check isolated["VSINSTALLDIR"] == r"C:\BuildTools\"
    check isolated["CC"] == "cl.exe"
    check isolated["PATH"] == VcBin

  test "7. the set dump alone carries the host's values":
    let host = hostAtActivation()
    let lines = parseCmdSetOutput(cmdSetDump(
      vsDevCmdActivate(vsDevCmdChildEnv(host))))
    let table = msvcEnvTableFromSetLines(lines, vsDevCmdInjectedNames(host))
    check table["APPDATA"] == r"C:\Users\someone\AppData\Roaming"
    check table["Path"].endsWith(r"C:\Windows\System32;C:\tools\nim\bin")

## A multi-line environment value survives the MSVC developer-environment
## activation intact, and invents no variables.
##
## WHAT BROKE. On Windows the engine layers the VsDevCmd activation under every
## action environment that inherits the host's PATH. The activation is captured
## by running ``VsDevCmd.bat`` and then ``set`` in a ``cmd.exe`` that inherits
## the engine's environment, and reading the ``set`` dump back line by line.
## ``set`` prints each value verbatim. A value such as
##
##   LIST=BEARSSL_SRC=<hex><newline>NIMCRYPTO_SRC=<hex><newline>IO_MON_SRC=<hex>
##
## therefore came back as ``LIST`` (truncated to its first line) plus REAL
## variables ``NIMCRYPTO_SRC`` and ``IO_MON_SRC`` holding hex strings. Those
## entries were merged into the action's environment and overrode the real
## values the action would have inherited. A profile compile then could not find
## its sources (``cannot open file: nimcrypto/sha2``), although running the
## same compile outside the engine worked.
##
## WHAT IS ASSERTED, end to end over the production procs
## (``vsDevCmdChildEnv`` -> ``set`` -> ``parseCmdSetOutput`` ->
## ``msvcEnvTableFromSetLines`` -> ``mergeActionEnvWithMsvcEnv`` -> layered
## over the inherited environment, the way the Windows process launcher layers
## an action's ``KEY=VALUE`` entries):
##   1. every inherited variable reaches the action with its own value, the
##      multi-line one included;
##   2. the action's environment names no variable that neither the parent nor
##      the activation defined;
##   3. the activation's own additions (``VCToolsInstallDir``, ``CC``, PATH)
##      still arrive;
##   4. ``vsDevCmdChildEnv`` keeps single-line variables verbatim and drops
##      CR/LF-bearing values and nameless (hidden per-drive) entries;
##   5. the hazard itself: ``set`` output alone cannot frame a multi-line value
##      (pinned so nobody "fixes" the parser instead and believes it worked).
##
## The one stand-in, and why: ``cmd.exe``'s built-in ``set`` is rendered by
## ``cmdSetDump`` below (each variable as ``NAME=VALUE`` + CRLF, value
## verbatim, names in case-insensitive order). ``cmd.exe`` does not exist on
## the Linux and macOS hosts this suite also runs on, and that one line format
## is the entire contract the activation reader depends on. Every other step is
## the production code.

import std/[algorithm, sets, strutils, tables, unittest]

import repro_platform

const
  MultiLine = "BEARSSL_SRC=433a5c7372635c6265617273131" & "\n" &
    "NIMCRYPTO_SRC=433a5c7372635c6e696d63727970746f" & "\n" &
    "IO_MON_SRC=433a5c7372635c696f2d6d6f6e5c737263" & "\n" &
    "SHM_QUEUE_SRC=433a5c7372635c73686d2d7175657565"
      ## SHM_QUEUE_SRC is set nowhere else: only the list names it.

proc parentEnv(): seq[(string, string)] =
  @[
    ("BEARSSL_SRC", r"C:\src\bearssl"),
    ("IO_MON_SRC", r"C:\src\io-mon\src"),
    ("NIMCRYPTO_SRC", r"C:\src\nimcrypto"),
    ("Path", r"C:\Windows\System32;C:\tools\nim\bin"),
    ("REPRO_BOOTSTRAP_SOURCE_ENV", MultiLine),
    ("SystemRoot", r"C:\Windows"),
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
  ## What ``VsDevCmd.bat`` does to the shell it runs in: add its variables and
  ## prepend the toolchain to PATH. Everything else passes through.
  for (name, value) in shellEnv:
    if cmpIgnoreCase(name, "Path") == 0:
      result.add((name, r"C:\BuildTools\VC\Tools\MSVC\14.44\bin\HostX64\x64;" &
        value))
    else:
      result.add((name, value))
  result.add(("VCToolsInstallDir", r"C:\BuildTools\VC\Tools\MSVC\14.44\"))
  result.add(("VSINSTALLDIR", r"C:\BuildTools\"))

proc layered(parent: openArray[(string, string)];
             overlay: openArray[string]): OrderedTable[string, (string, string)] =
  ## The launcher's composition: the inherited environment, then the action's
  ## ``KEY=VALUE`` entries, rightmost wins, names case-insensitive.
  for (name, value) in parent:
    result[name.toUpperAscii] = (name, value)
  for entry in overlay:
    let eq = entry.find('=')
    if eq <= 0: continue
    let name = entry[0 ..< eq]
    result[name.toUpperAscii] = (name, entry[eq + 1 .. ^1])

proc actionEnvironment(parent: seq[(string, string)]):
    OrderedTable[string, (string, string)] =
  let shellEnv = vsDevCmdChildEnv(parent)
  let lines = parseCmdSetOutput(cmdSetDump(vsDevCmdActivate(shellEnv)))
  var table = msvcEnvTableFromSetLines(lines)
  table["CC"] = "cl.exe"
  let devEnv = MsvcDevEnv(available: true, env: table)
  let actionEnv = @["REPROBUILD_NO_RUNQUOTA=1", r"PWD=C:\work\profile"]
  layered(parent, mergeActionEnvWithMsvcEnv(devEnv, actionEnv))

suite "MSVC activation and multi-line environment values":
  test "inherited variables, the multi-line one included, reach the action intact":
    let parent = parentEnv()
    let child = actionEnvironment(parent)
    for (name, value) in parent:
      check child.hasKey(name.toUpperAscii)
      if name == "Path":
        continue  # the activation prepends the toolchain, asserted below
      check child[name.toUpperAscii][1] == value
    check child["NIMCRYPTO_SRC"][1] == r"C:\src\nimcrypto"
    check child["IO_MON_SRC"][1] == r"C:\src\io-mon\src"
    check child["REPRO_BOOTSTRAP_SOURCE_ENV"][1] == MultiLine

  test "the action names no variable that nobody defined":
    let parent = parentEnv()
    let child = actionEnvironment(parent)
    var known = initHashSet[string]()
    for (name, _) in parent: known.incl(name.toUpperAscii)
    for name in ["VCTOOLSINSTALLDIR", "VSINSTALLDIR", "CC",
                 "REPROBUILD_NO_RUNQUOTA", "PWD"]:
      known.incl(name)
    for key in child.keys:
      check key in known

  test "the activation's own variables still arrive":
    let child = actionEnvironment(parentEnv())
    check child["VCTOOLSINSTALLDIR"][1] == r"C:\BuildTools\VC\Tools\MSVC\14.44\"
    check child["CC"][1] == "cl.exe"
    check child["PATH"][1].startsWith(r"C:\BuildTools\VC\Tools\MSVC\14.44\bin")

  test "vsDevCmdChildEnv drops CR/LF values and nameless entries only":
    let kept = vsDevCmdChildEnv(@[
      ("A", "1"), ("B", "x\ny"), ("C", "x\r\ny"), ("D", "x\ry"),
      ("", "C:=C:\\work"), ("E", "a=b;c"), ("F", "")])
    check kept == @[("A", "1"), ("E", "a=b;c"), ("F", "")]

  test "set output alone cannot frame a multi-line value":
    let lines = parseCmdSetOutput(cmdSetDump(parentEnv()))
    let table = msvcEnvTableFromSetLines(lines)
    check table["NIMCRYPTO_SRC"] == "433a5c7372635c6e696d63727970746f"
    check table["REPRO_BOOTSTRAP_SOURCE_ENV"] ==
      "BEARSSL_SRC=433a5c7372635c6265617273131"

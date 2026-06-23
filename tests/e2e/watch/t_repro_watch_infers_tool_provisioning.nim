## CLI/watch.md — ``repro watch`` infers tool provisioning instead of
## hard-requiring ``--tool-provisioning`` on the command line.
##
## Per the spec, ``repro watch`` / ``repro watch <target>`` work without a
## mandatory ``--tool-provisioning`` flag: the mode resolves the same way
## ``repro build`` resolves it — explicit flag → ``REPRO_TOOL_PROVISIONING``
## env → the project's ``defaultToolProvisioning`` (resolved per build cycle).
## HCR stays optional (off unless ``--hcr`` / ``--hcr-target`` is passed).
##
## This is a lightweight regression test: it runs ``repro watch`` in an empty
## directory (no project), so it does not need runquotad or a real build. The
## point is purely that the command gets PAST the old hard-requirement gate —
## it must NOT emit "repro watch requires --tool-provisioning", and it must
## enter the watch/build path (cycle 1) before failing on the absent project.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support

proc reproRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 1:
    if fileExists(dir / "Justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "cannot locate reprobuild repo root")

proc reproBinary(): string =
  requireBinary(reproRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "CLI/watch: repro watch infers tool provisioning":

  test "repro watch without --tool-provisioning clears the old hard requirement":
    let repro = reproBinary()
    let dir = createTempDir("repro-watch-noprov-", "")
    defer: removeDir(dir)
    # No --tool-provisioning flag, no REPRO_TOOL_PROVISIONING env.
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      if k != "REPRO_TOOL_PROVISIONING":
        env[k] = v
    let res = execCmdEx(
      quoteShell(repro) & " watch . --max-cycles=1 --daemon=off",
      workingDir = dir, env = env)
    # Must NOT reject on the old hard requirement.
    check "requires --tool-provisioning" notin res.output
    # Must have entered the watch/build path (mode unspecified, HCR off) and
    # then failed only because there is no project in the temp dir.
    check "tool-provisioning=unspecified" in res.output
    check "hcr=disabled" in res.output
    check ("cycle 1 start" in res.output) or ("module not found" in res.output)

  test "REPRO_TOOL_PROVISIONING env is honoured by watch (no CLI flag)":
    let repro = reproBinary()
    let dir = createTempDir("repro-watch-envprov-", "")
    defer: removeDir(dir)
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      env[k] = v
    env["REPRO_TOOL_PROVISIONING"] = "path"
    let res = execCmdEx(
      quoteShell(repro) & " watch . --max-cycles=1 --daemon=off",
      workingDir = dir, env = env)
    check "requires --tool-provisioning" notin res.output
    # The env tier resolved the mode to ``path`` before the build cycle.
    check "tool-provisioning=path" in res.output

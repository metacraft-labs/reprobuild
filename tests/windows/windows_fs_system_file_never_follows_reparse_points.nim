## The Windows ``fs.systemFile`` write never follows a reparse point and
## never lands under a directory an ordinary user can take over.
##
## ``${PROGRAMDATA}`` lets every local user create folders, so a junction
## planted under it redirected the elevated write, which opened the path
## by name and followed every link on it. Each case plants the attack the
## spec names and checks that the driver refuses it and that the file
## behind the link is byte-identical.
##
## ``PROGRAMDATA`` is pointed at a fresh directory for the run, which is
## what the driver's allowlist reads (``programDataRoot``), so the real
## ``%ProgramData%`` is never touched. The fleet's Windows job runs as
## NETWORK SERVICE, not as an administrator, so the folders the test
## creates pass the trust check as the writer's own (the writer-SID
## exemption), not as an administrator's. Creating a file symbolic link
## needs ``SeCreateSymbolicLinkPrivilege`` or Developer Mode; a host
## without either fails that case at ``mklink`` rather than skipping it.
##
## *Mocking.* None: real junctions, symbolic links and DACLs on NTFS, the
## real driver, ``mklink`` and ``icacls`` to plant them.

import std/[os, osproc, strutils, unittest]

import repro_elevation/errors
import repro_elevation/fixture_driver
import repro_elevation/operations
import repro_elevation/posix_system_driver
import repro_elevation/windows_nofollow_write

when not defined(windows):
  {.error: "a Windows-only test: run it on Windows".}

let root = getTempDir() / ("repro-fssf-" & $getCurrentProcessId())
let pd = root / "ProgramData"
let outside = root / "outside"
createDir(pd)
createDir(outside / "dir")
writeFile(outside / "victim", "victim\n")
putEnv("PROGRAMDATA", pd)

proc sh(cmd: string): string =
  ## Run ``cmd`` through ``cmd.exe``; its output, failing the test on a
  ## non-zero exit (a plant that did not happen proves nothing).
  let (output, code) = execCmdEx("cmd /c " & cmd)
  doAssert code == 0, cmd & " exited " & $code & ": " & output
  output

proc sysFile(path, content: string; destroy = false): PrivilegedOperation =
  PrivilegedOperation(kind: pokFsSystemFile, address: "fs.systemFile:" & path,
    sfPath: path, sfContent: content, sfDestroy: destroy)

proc refusal(op: PrivilegedOperation): string =
  ## The driver's refusal message, or "" when it wrote.
  try:
    discard applyFsSystemFile(FixtureContext(), op)
    ""
  except EProtocol as e:
    e.msg

suite "fs.systemFile on Windows":
  test "a plain write lands with its directories, and a rewrite replaces it":
    check refusal(sysFile(pd / "app" / "sub" / "a.conf", "hello\n")) == ""
    check readFile(pd / "app" / "sub" / "a.conf") == "hello\n"
    check refusal(sysFile(pd / "app" / "sub" / "a.conf", "again\n")) == ""
    check readFile(pd / "app" / "sub" / "a.conf") == "again\n"
    var others: seq[string]
    for f in walkDir(pd / "app" / "sub"):
      if f.path != pd / "app" / "sub" / "a.conf": others.add(f.path)
    check others.len == 0

  test "a junction as a directory on the path is refused, naming it":
    discard sh("mklink /J \"" & pd / "linked" & "\" \"" & outside / "dir" & "\"")
    let why = refusal(sysFile(pd / "linked" / "x.conf", "redirected\n"))
    check "reparse point" in why
    check "linked" in why
    check not fileExists(outside / "dir" / "x.conf")

  test "a symbolic link as the file is refused and its target is untouched":
    createDir(pd / "app2")
    discard sh("mklink \"" & pd / "app2" / "leaf.conf" & "\" \"" &
               outside / "victim" & "\"")
    let why = refusal(sysFile(pd / "app2" / "leaf.conf", "redirected\n"))
    check "reparse point" in why
    check readFile(outside / "victim") == "victim\n"
    check symlinkExists(pd / "app2" / "leaf.conf")

  test "a folder whose DACL lets Everyone take it over is refused":
    createDir(pd / "open")
    discard sh("icacls \"" & pd / "open" & "\" /grant *S-1-1-0:(OI)(CI)F")
    let why = refusal(sysFile(pd / "open" / "x.conf", "content\n"))
    check "S-1-1-0" in why
    check not fileExists(pd / "open" / "x.conf")

  proc explicitAces(f: string): seq[string] =
    ## The ACE lines ``icacls`` prints for ``f`` that are not inherited
    ## (no ``(I)``): locale-independent, unlike the principal names.
    for line in sh("icacls \"" & f & "\"").splitLines():
      if ":(" in line and "(I)" notin line:
        result.add(line.strip())

  test "a rewrite keeps an administrator's restrictive DACL":
    let f = pd / "acl" / "kept.conf"
    check refusal(sysFile(f, "one\n")) == ""
    # The operator's restriction: no inheritance; SYSTEM, Administrators
    # and the writer. The writer is named because the CI job runs as
    # NETWORK SERVICE, not as an administrator, and a restriction without
    # it would lock the writer itself out (in production the broker is
    # SYSTEM or an elevated administrator, which the first two cover).
    discard sh("icacls \"" & f & "\" /inheritance:r /grant:r " &
               "*S-1-5-18:(F) *S-1-5-32-544:(F) *" & writerSid() & ":(F)")
    let before = explicitAces(f)
    check before.len >= 2   # 2 when the writer is SYSTEM or an admin
    check refusal(sysFile(f, "two\n")) == ""
    check readFile(f) == "two\n"
    check explicitAces(f) == before

  test "a rewrite drops a DACL that lets someone else change the file":
    let f = pd / "acl" / "loose.conf"
    check refusal(sysFile(f, "one\n")) == ""
    discard sh("icacls \"" & f & "\" /grant *S-1-1-0:(W)")
    check explicitAces(f).len == 1
    check refusal(sysFile(f, "two\n")) == ""
    check readFile(f) == "two\n"
    check explicitAces(f).len == 0

  test "destroy removes the file, and never through a junction":
    let f = pd / "gone.conf"
    check refusal(sysFile(f, "x\n")) == ""
    check refusal(sysFile(f, "", destroy = true)) == ""
    check not fileExists(f)
    writeFile(outside / "dir" / "kept.conf", "kept\n")
    discard sh("mklink /J \"" & pd / "linked2" & "\" \"" & outside / "dir" & "\"")
    let why = refusal(sysFile(pd / "linked2" / "kept.conf", "", destroy = true))
    check "reparse point" in why
    check readFile(outside / "dir" / "kept.conf") == "kept\n"

  test "destroy of a junction removes the junction, not what it points at":
    writeFile(outside / "dir" / "inside.conf", "inside\n")
    discard sh("mklink /J \"" & pd / "leafjunction" & "\" \"" & outside / "dir" & "\"")
    check refusal(sysFile(pd / "leafjunction", "", destroy = true)) == ""
    check not dirExists(pd / "leafjunction")
    check readFile(outside / "dir" / "inside.conf") == "inside\n"

  test "destroy under a folder that does not exist is already done":
    check refusal(sysFile(pd / "never" / "made.conf", "", destroy = true)) == ""

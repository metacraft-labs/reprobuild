## The plan-only write allowlist of the add-on anywhere gate
## (``plan_only_writes.nim``; Anywhere Safety Contract §5, add-on
## exception): a file written to ``/var/tmp``, ``/root`` or ``/var/lib``
## during the plan-only run is unexplained, the disclosed SSH writes are
## not, and the allowlist cannot be widened by a lookalike path.
##
## Positive control for the gate step "without --expect-plan it prints the
## plan and leaves nothing": the listing is produced by the REAL
## ``listWritesScript`` run by a real shell against a real directory tree
## (mount enumeration replaced by the one directory, the only part that
## needs a guest), so a script that listed nothing would fail here.
## No mocks.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import ./plan_only_writes

suite "plan-only writes outside the fingerprint are refused":
  test "the three files of the issue's reproduction are unexplained":
    check unexplainedWrites("/var/tmp/repro-anywhere-left\n" &
      "/root/.repro-anywhere-left\n/var/lib/repro-anywhere-left/x\n") ==
      @["/var/tmp/repro-anywhere-left", "/root/.repro-anywhere-left",
        "/var/lib/repro-anywhere-left/x"]

  test "the disclosed SSH writes are allowed":
    check unexplainedWrites("/var/log\n/var/log/wtmp\n/var/log/lastlog\n" &
      "/var/log/auth.log\n/var/log/journal\n" &
      "/var/log/journal/abc/system.journal\n").len == 0

  test "a lookalike path is not allowed":
    check unexplainedWrites("/var/log/journal-x\n/var/log/wtmp.evil\n" &
      "/var/logs/auth.log\n/var/lib/var/log/wtmp\n").len == 4

  test "the listing script sees a new file and a chmod, not an untouched one":
    let dir = createTempDir("repro-planwrites-", "")
    defer: removeDir(dir)
    writeFile(dir / "old", "x")
    writeFile(dir / "chmodded", "x")
    sleep(1500)
    let since = $epochTime()
    sleep(1500)
    writeFile(dir / "new", "x")
    setFilePermissions(dir / "chmodded", {fpUserRead, fpUserWrite, fpUserExec})
    # The script's mount enumeration is the only guest-specific part.
    let script = listWritesScript(since).replace(DiskBackedMountsScript,
                                                 "echo " & quoteShell(dir))
    check script != listWritesScript(since)
    let (o, rc) = execCmdEx("bash -c " & quoteShell(script))
    check rc == 0
    let seen = o.splitLines()
    check (dir / "new") in seen
    check (dir / "chmodded") in seen
    check (dir / "old") notin seen
    check unexplainedWrites(o).len >= 2

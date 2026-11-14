## The hardening floor after the A9 review's round 14 (ReproOS Add-On Mode
## spec §10.1 and §13 decisions 144 to 146; reprobuild-pm issues
## 2026-11-14-floor-*):
##
## - a hold is written with every step checked (``writeHoldFile``): a write
##   the file system refuses raises, where Nim's ``writeFile`` left an empty
##   file and raised nothing; an empty or truncated hold is never in the
##   way of the revert's own (``holdInTheWay``);
## - §13 decision 144: a floored unit rendered with floor version 5 is
##   ordered after the boot re-assertion; version 4 renders as it did;
## - §13 decision 145: a remade directory is bounded from the run's start
##   (``InactiveExitTimestamp``), so a tree made during ``ExecStartPre=``
##   or before a oneshot's last ``ExecStart=`` is refused;
## - §13 decision 146: a writable place spelled with a specifier counts by
##   its literal prefix.
##
## Falsifying builds, each red here: ``hold-written-unchecked``,
## ``floored-not-after-reassert``, ``recreated-bound-from-main-start``,
## ``writable-specifier-resolved``.
##
## *Mocking.* The full file system is a file-size limit (setrlimit(2),
## ``RLIMIT_FSIZE``) on this process, which makes write(2) fail with
## ``EFBIG`` the way a full file system makes it fail with ``ENOSPC``;
## the VM gate fills a real tmpfs. A ``SystemdView`` stands for one
## ``systemctl show``, as in rounds 12 and 13.

import std/[os, posix, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_infra/start_holds
import repro_addon/addon_apply
import repro_addon/effective_floor

const
  Start = 1_800_000_000_000_000_000'i64
  Prefix = "/repro/store/prefixes/svc/1.0"

var SIGXFSZ {.importc, header: "<signal.h>".}: cint
var RLIMIT_FSIZE {.importc, header: "<sys/resource.h>".}: cint

proc withFileSizeLimit(limit: int; body: proc ()) =
  ## Runs ``body`` with ``RLIMIT_FSIZE`` at ``limit`` bytes (and SIGXFSZ
  ## ignored, so write(2) fails with EFBIG instead of killing the process).
  var old: RLimit
  doAssert getrlimit(RLIMIT_FSIZE, old) == 0
  discard signal(SIGXFSZ, SIG_IGN)
  var lim = old
  lim.rlim_cur = limit
  doAssert setrlimit(RLIMIT_FSIZE, lim) == 0
  try: body()
  finally: discard setrlimit(RLIMIT_FSIZE, old)

suite "a hold is written with every step checked":
  test "a write the file system refuses raises, and leaves no hold":
    let d = createTempDir("a9r14w-", "")
    defer: removeDir(d)
    let p = d / RevertHoldName
    var raised = false
    withFileSizeLimit(16, proc () =
      try: writeHoldFile(p, RevertHoldText)
      except OSError: raised = true)
    check raised
    check not fileExists(p) or readFile(p) == RevertHoldText
  test "a hold written in full reads back as written":
    let d = createTempDir("a9r14w-", "")
    defer: removeDir(d)
    writeHoldFile(d / RevertHoldName, RevertHoldText)
    check readFile(d / RevertHoldName) == RevertHoldText
    for k, f in walkDir(d): check not f.endsWith(".tmp")
  test "an empty or truncated hold is never in the way; other text is":
    let d = createTempDir("a9r14w-", "")
    defer: removeDir(d)
    let p = d / RevertHoldName
    check not holdInTheWay(p)
    writeFile(p, "")
    check not holdInTheWay(p)
    writeFile(p, RevertHoldText[0 ..< 20])
    check not holdInTheWay(p)
    writeFile(p, RevertHoldText)
    check not holdInTheWay(p)
    writeFile(p, "[Unit]\nDescription=the operator's\n")
    check holdInTheWay(p)

suite "§13 decision 144: floored units wait for the boot re-assertion":
  proc rendered(version: string): string =
    let p = parseAddOnUserProfile("systemd.systemUnit {\n  name = \"a.service\"\n" &
      "  content = \"[Unit]\nDescription=x\n\n[Service]\nUser=a\nExecStart=" &
      Prefix & "/bin/svc\n\n[Install]\nWantedBy=multi-user.target\n\"\n}\n")
    var r = p.resources[0]
    for x in p.resources:
      if x.kind == srkSystemdSystemUnit and x.suName == "a.service": r = x
    r.suFloorVersion = version
    renderedSystemUnitContent(r)
  test "floor version 5 orders the unit after the re-assertion, in [Unit]":
    let t = rendered("")
    check FloorVersion == "5"
    check "[Unit]\n" & FloorBootOrdering & "\n" in t
  test "floor version 4 renders as its engines stored it, without it":
    check FloorBootOrdering notin rendered("4")
    check rendered("4") & "" != rendered("5")

suite "§13 decision 145: bounded from the run's start":
  let created = {"/var/lib/a": CreatedDir(unit: "a.service", invocation: "I0")}.toTable
  proc verdict(btime, mainStart: int64): string =
    systemdRecreated("/var/lib/a", "a.service", ["/var/lib/a"], created, false,
      SystemdView(dynamicUid: -1, owner: 1000, btime: btime, invocationId: "I1",
                  invocationStart: Start, mainStart: mainStart))
  # A tree made well into the pre-start phase: past the tolerance from
  # the run's start, before the main process.
  let late = Start + RunStartToleranceNs + 1_000_000_000'i64
  test "a tree made during a long ExecStartPre= is refused":
    check "after the unit's last run began" in
      verdict(late, late + 3_000_000_000'i64)
  test "and one made before a oneshot's last ExecStart=":
    check verdict(late, late + 1_000_000_000'i64).len > 0
  test "a directory made as the run begins is accepted":
    check verdict(Start + 30_000_000, Start + 6_000_000_000'i64) == ""

suite "§13 decision 146: a specifier place counts by its literal prefix":
  test "the prefix stops at the component holding the first specifier":
    check literalPrefix("/run/a9q/%i") == "/run/a9q"
    check literalPrefix("/run/a9q/x%i/y") == "/run/a9q"
    check literalPrefix("/run/a9q/100%%/z") == "/run/a9q/100%%/z"
    check literalPrefix("/run/a9q") == "/run/a9q"
  test "a template's RuntimeDirectory=<stem>/%i covers the listener below /run/<stem>/":
    let w = floorWritablePlaces(serviceDirectives(
      "[Service]\nRuntimeDirectory=a9q/%i\nReadWritePaths=/srv/%n/data\n"))
    check "/run/a9q" in w
    check "/srv" in w
    check listenerRefusal("a9q.socket", "/run/a9q/sub/x/control", "a9q.service", w).len > 0

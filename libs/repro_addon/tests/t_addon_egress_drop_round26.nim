## The egress check's drop directory cannot stop or spin the shipping unit
## (ReproOS Add-On Mode spec §13 decision 188; A11 round 26).
##
## * Anything in the drop directory the harvest cannot hand over -- a
##   directory, a link, a FIFO, an oversize file, a stray name -- is moved
##   aside unread into ``<drop>-rejected`` and reported, so it no longer
##   keeps the directory non-empty for the path unit's
##   ``DirectoryNotEmpty=``.
## * A regular entry the outbox write failed for stays, and the harvest
##   records how many stayed; the shipping run counts them for its backoff,
##   so the path unit restarts it at a bounded pace, not at once for ever.
## * A drop directory that cannot be opened (a link or a file in its place)
##   is reported and does not fail the harvest step, so the outbox still
##   ships.
## * Uninstall counts the drop entries not yet moved as queued records.
##
## Falsifying builds: ``egress-drop-leaves-dirs`` (the directory case),
## ``ship-backoff-ignores-drop`` (the failing-write case),
## ``harvest-failure-fails-step`` (the link case) and
## ``uninstall-ignores-drop`` (the uninstall case).
##
## No mocks: real directories, files, links and FIFOs, the harvest's and the
## shipping run's own code, and uninstall's own ``shipAndConfirm`` with no
## sink configuration (so nothing is reached over the network).

import std/[os, posix, strutils, unittest]

import repro_addon/evidence_ship
import repro_addon/record_dir
import repro_addon/uninstall

let root = getTempDir() / ("addon-drop-r26-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc site(name: string): ShipSite =
  let base = root / name
  createDir(base / "evidence")
  createDir(base / "state")
  ShipSite(confPath: base / "no-evidence.conf", stateDir: base / "state",
           outbox: base / "state" / "outbox",
           dropDir: base / "evidence" / "egress-drop")

proc entries(dir: string): seq[string] =
  for kind, p in walkDir(dir): result.add(extractFilename(p))

suite "the drop directory cannot stop or spin the shipping unit (round 26)":
  test "a planted directory, link, FIFO and stray name are moved aside":
    let s = site("aside")
    createDir(s.dropDir / "planted.evr")
    writeFile(s.dropDir / "planted.evr" / "inner", "x")
    createSymlink("/etc/hostname", s.dropDir / "link.evr")
    check mkfifo(cstring(s.dropDir / "fifo.evr"), 0o600) == 0
    writeFile(s.dropDir / "stray.txt", "x")
    writeFile(s.dropDir / "0001-ok.evr", "an entry")
    let h = harvestDropEntries(s.dropDir, s.outbox, s.stateDir)
    checkpoint $h
    check h.moved == 1
    check entries(s.dropDir).len == 0
    check entries(dropAsideDir(s.dropDir)).len == 4
    check h.asideNames.len == 4
    check readFile(s.outbox / "0001-ok.evr") == "an entry"

  test "an entry the outbox write fails for stays, and counts for the backoff":
    let s = site("left")
    createDir(s.dropDir)
    writeFile(s.dropDir / "0001-ok.evr", "an entry")
    # The outbox's place is taken by a file: every write into it fails.
    writeFile(s.outbox, "not a directory")
    let h = harvestDropEntries(s.dropDir, s.outbox, s.stateDir)
    check h.moved == 0 and h.left.len == 1
    check entries(s.dropDir) == @["0001-ok.evr"]
    check readFile(dropLeftPath(s.stateDir)).strip() == "1"
    # The shipping run's view: its own outbox empty, the drop entry left.
    var unitView = s
    unitView.outbox = root / "left" / "unit-outbox"
    check shipRunWait(unitView, 300) > 0

  test "a link in place of the drop directory is reported, not a failed step":
    let s = site("linked")
    createDir(root / "linked" / "elsewhere")
    writeFile(root / "linked" / "elsewhere" / "x.evr", "not the drop's")
    createSymlink(root / "linked" / "elsewhere", s.dropDir)
    check runHarvest(s, "h") == 0
    check fileExists(root / "linked" / "elsewhere" / "x.evr")
    check not dirExists(s.outbox) or entries(s.outbox).len == 0

  test "uninstall counts drop entries not yet moved as queued":
    let s = site("uninstall")
    createDir(s.dropDir)
    writeFile(s.dropDir / "0001-ok.evr", "an entry")
    let r = shipAndConfirm(s, "h")
    checkpoint r.why
    check not r.ok
    check r.why.startsWith("1 record(s) still queued")

removeDir(root)

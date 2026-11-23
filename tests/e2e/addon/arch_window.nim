## The rolling-base replay window of the Arch test bed (milestone AR6; spec
## ReproOS-Add-On-Mode §7.9, §12.1; §13 decision 91).
##
## On Arch every ``pacman -Syu`` is a small release upgrade. The gates that
## replay them under a running add-on step a guest through **14 consecutive
## daily Arch Linux Archive dates** chosen so that the window contains one
## systemd major bump and one glibc upgrade. The window is a pin of the test
## bed: the first date and the two package versions it crosses are the
## constants below, changed only by a commit.
##
## *How the window was chosen* (2026-11-23, from each date's ``core.db`` at
## ``archive.archlinux.org/repos/<date>/core/os/x86_64/core.db``):
##
## - systemd 262 reached ``core`` between 2026-09-24 (261.3-1) and
##   2026-09-25 (262-1); glibc moved from 2.44+r24+g16be1518495f-1 to
##   2.44+r50+g1848099f063e-1 between 2026-09-27 and 2026-09-28; pacman is
##   7.1.0.r9.g54d9411-2 on every date of the window, inside the matrix's
##   pacman 7.
## - The window is 2026-09-20 .. 2026-10-03: five dates before the systemd
##   bump, eight after the glibc upgrade. Both majors (261, 262) are at or
##   above the matrix's systemd 258, so the shipped matrix accepts every
##   date; the unsupported-major gate's test matrix admits only 261.
## - The earlier candidates were rejected: systemd 259 reached ``core`` on
##   2025-12-20 and glibc did not move until 2026-01-11 (22 days); systemd
##   258 is the matrix's floor itself (257 before it is refused).
##
## The guests (``arch-btrfs-amd64``, ``arch-ext4-amd64``) are pinned to the
## cloud image's own date, 2026-11-01, which is later than the window: a gate
## first moves the guest back to the window's first date
## (``arch_testbed.moveBackRecipe``, as the old-systemd image is built) and
## reboots it, before the add-on is bootstrapped. Every package comes from
## the test bed's caching mirror of the archive (``snapshot_mirror``,
## ``archRoute``): a dated snapshot never changes, so a file is fetched from
## the archive once and every later run is served from the cache, and a
## transient archive failure is retried by the mirror (never cached).
##
## *Mocking.* None: real pacman against the real archive's snapshots, through
## a caching HTTP mirror that serves their bytes unchanged (pacman verifies
## every package's signature as usual).

import std/[json, os, strutils, tables, times]

import ./addon_testbed
import ./arch_testbed
import ./snapshot_mirror

const
  ArchWindowFirstDate* = "2026/09/20"
  ArchWindowDays* = 14
  ArchWindowSystemdBumpDate* = "2026/09/25"
  ArchWindowSystemdBefore* = "261.3-1"
  ArchWindowSystemdAfter* = "262-1"
  ArchWindowGlibcUpgradeDate* = "2026/09/28"
  ArchWindowGlibcBefore* = "2.44+r24+g16be1518495f-1"
  ArchWindowGlibcAfter* = "2.44+r50+g1848099f063e-1"
  ArchWindowPacman* = "7.1.0.r9.g54d9411-2"
  ArchWindowEarlierSystemdMajor* = 261
    ## The major the window starts with: what the unsupported-major gate's
    ## test matrix admits (``preflight.TestArchMatrixSeam``).
  MirrorStamp* = "20261123T000000Z"
    ## The mirror's timestamp, which the archive route does not read (its
    ## date is in the path); required by ``startSnapshotMirror``.

proc archWindowDates*(): seq[string] =
  ## The window's 14 dates, ``yyyy/mm/dd``, in order.
  var d = parse(ArchWindowFirstDate, "yyyy/MM/dd", utc())
  for i in 0 ..< ArchWindowDays:
    result.add(d.format("yyyy/MM/dd"))
    d = d + 1.days

proc windowPin*(): JsonNode =
  ## The pin as a gate record states it.
  %*{"firstDate": ArchWindowFirstDate, "days": ArchWindowDays,
     "dates": archWindowDates(),
     "systemdBump": {"date": ArchWindowSystemdBumpDate,
                     "from": ArchWindowSystemdBefore,
                     "to": ArchWindowSystemdAfter},
     "glibcUpgrade": {"date": ArchWindowGlibcUpgradeDate,
                      "from": ArchWindowGlibcBefore,
                      "to": ArchWindowGlibcAfter},
     "pacman": ArchWindowPacman}

const WindowPacmanFlags* = "--disable-download-timeout"
  ## pacman(8): no low-speed limit. The mirror answers a file it has not
  ## cached yet only once it has fetched the whole of it from the archive,
  ## which can take longer than pacman's default 10 s at under 1 byte/s
  ## (measured 2026-11-23: an 8.8 MiB ``extra.db``).

proc prewarm*(m: SnapshotMirror; dates: openArray[string];
              repos = ["core", "extra"]) =
  ## Fetch each date's repository databases into the mirror's cache before
  ## a guest asks for them (best effort; a failure is the guest's to see).
  for d in dates:
    for r in repos:
      try:
        discard m.fetchThrough(ArchMirrorPrefix & d & "/" & r &
          "/os/x86_64/" & r & ".db")
      except CatchableError:
        discard

proc mirrorRoot*(m: SnapshotMirror): string =
  ## The archive's root as a guest reaches it through the mirror.
  "http://" & GuestHostAddress & ":" & $m.port & ArchMirrorPrefix

proc pinToDate*(g: Guest; m: SnapshotMirror; date: string) =
  ## Point the guest's pacman at ``date`` of the archive through the mirror,
  ## and refuse the guest unless its effective configuration names exactly
  ## that (``requirePinnedPacman``).
  discard g.run("printf '%s\\n' " & quoteShell(mirrorlistLine(date,
    mirrorRoot(m))) & " > /etc/pacman.d/mirrorlist")
  g.requirePinnedPacman(archiveMirrorRule(mirrorRoot(m), date))

proc pacmanVersions*(g: Guest; names: openArray[string]): Table[string, string] =
  ## ``pacman -Q`` of ``names``: name -> version (absent ones left out).
  let o = g.exec("pacman -Q " & names.join(" ") & " 2>/dev/null").stdout
  for l in o.splitLines():
    let f = l.splitWhitespace()
    if f.len == 2: result[f[0]] = f[1]

proc moveToDate*(g: Guest; m: SnapshotMirror; date: string;
                 step: proc(name: string; ok: bool; detail: string)): bool =
  ## Move the guest back to ``date`` (every package, the keyring first) and
  ## reboot it into the result; a recorded step. Before the baseline.
  writeFile(g.runDir / "move-back.sh", moveBackRecipe(date, mirrorRoot(m),
                                                     WindowPacmanFlags))
  g.copyTo(g.runDir / "move-back.sh", "/root/arch-move-back.sh")
  let r = g.exec("bash /root/arch-move-back.sh > /root/arch-move-back.log " &
    "2>&1; rc=$?; tail -n 40 /root/arch-move-back.log; rm -f " &
    "/root/arch-move-back.sh /root/arch-move-back.log; exit $rc",
    timeoutSec = 3600)
  step("the guest is moved back to " & date & " of the archive",
       r.exitCode == 0, r.stdout & r.stderr)
  if r.exitCode != 0: return false
  g.rebootGuest()
  g.pinToDate(m, date)
  let v = g.pacmanVersions(["systemd", "glibc", "pacman"])
  step("after the reboot the guest runs " & date & "'s systemd",
       g.run("systemctl --version | head -1").contains(
         v.getOrDefault("systemd").split('-')[0].split('.')[0]),
       $v & "\n" & g.run("systemctl --version | head -1"))
  true

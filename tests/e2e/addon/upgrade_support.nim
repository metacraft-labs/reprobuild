## What milestone A10's gates share: a guest whose apt is served by the
## time-shifted snapshot mirror at a shifted clock, the two-service fixture
## that runs from a store closure, and the observations the gates make of
## it.
##
## *The fixture services* run from the store, not from the base: each is a
## ``systemd.systemUnit`` bound to an apt closure of ``busybox-static``
## (spec §8.3: ``BindReadOnlyPaths=<closure>/usr:/usr``), realised by the
## add-on into ``/repro/store`` from the same archive snapshot the guest
## upgrades from. That is what "the services are active from unchanged
## store paths" after a release upgrade can be measured on. The closure
## lock is computed here from the snapshot's ``InRelease`` and
## ``Packages.xz`` (both fetched over HTTPS from the snapshot service; the
## index is checked against the digest ``InRelease`` gives), and the
## ``.deb`` is seeded into the guest's closure cache from the mirror's
## cache, so the guest never fetches it from the snapshot service itself.
##
## *Mocking.* None (see ``snapshot_mirror.nim``).

import std/[os, osproc, strutils, tables, times]

import repro_dsl_stdlib/packages/apt_closure
import repro_dsl_stdlib/packages/apt_index

import ./addon_testbed
import ./snapshot_mirror

const
  WebPort* = 18081
  DocsPort* = 18082
  FixtureUnits* = ["repro-fixture-web.service", "repro-fixture-docs.service"]
  ProxyConf* = "/etc/apt/apt.conf.d/00repro-testbed-proxy"
  NonInteractiveApt* = "export DEBIAN_FRONTEND=noninteractive; " &
    "apt-get -y -o Dpkg::Options::=--force-confdef " &
    "-o Dpkg::Options::=--force-confold "
    ## How an unattended upgrade runs apt (unattended-upgrades passes the
    ## same two dpkg options): no prompt, the local conffile kept.

type
  ClosureFixture* = object
    lockText*: string
    debs*: seq[tuple[sha256, localPath: string]]

proc archiveOf*(b: BaseImage): tuple[url, suite, component: string] =
  ## The stock archive URL, suite and component the base installs from.
  case b.osId
  of "debian":
    ("http://deb.debian.org/debian",
     (if b.versionId == "12": "bookworm" else: "trixie"), "main")
  else:
    ("http://archive.ubuntu.com/ubuntu",
     (if b.versionId == "24.04": "noble" else: "resolute"), "main")

proc snapshotArchive(b: BaseImage; stamp: string): string =
  if b.osId == "debian": "https://snapshot.debian.org/archive/debian/" & stamp
  else: "https://snapshot.ubuntu.com/ubuntu/" & stamp

proc sha256File(p: string): string =
  execProcess("sha256sum " & quoteShell(p)).splitWhitespace()[0]

proc inReleaseSha(inRelease, path: string): string =
  ## The SHA256 the ``InRelease`` gives for ``path``.
  var inSha = false
  for l in inRelease.splitLines():
    if l.startsWith("SHA256:"):
      inSha = true
      continue
    if inSha:
      if not l.startsWith(" "): break
      let f = l.splitWhitespace()
      if f.len == 3 and f[2] == path: return f[0]
  ""

proc busyboxClosure*(m: SnapshotMirror; b: BaseImage): ClosureFixture =
  ## A lock for the ``busybox-static`` closure (no Essential set: the binary
  ## is static and needs nothing else) at the mirror's current timestamp.
  let (url, suite, comp) = archiveOf(b)
  let inRel = readFile(m.fetchThrough(url & "/dists/" & suite & "/InRelease"))
  let idxPath = comp & "/binary-" & b.debArch & "/Packages.xz"
  let want = inReleaseSha(inRel, idxPath)
  if want.len == 0:
    raise newException(TestBedError, "InRelease names no " & idxPath)
  let idxFile = m.fetchThrough(url & "/dists/" & suite & "/" & idxPath)
  if sha256File(idxFile) != want:
    raise newException(TestBedError, idxPath & " does not match InRelease")
  let (text, rc) = execCmdEx("xz -dc " & quoteShell(idxFile))
  if rc != 0: raise newException(TestBedError, "xz -dc failed: " & idxFile)
  let index = buildAptIndex(parsePackagesIndex(text))
  let members = resolveAptClosureRecords(index, @["busybox-static"],
                                         includeEssential = false)
  var inRelSha = ""
  block:
    var f = m.fetchThrough(url & "/dists/" & suite & "/InRelease")
    inRelSha = sha256File(f)
  let lock = buildAptClosureLock(snapshotArchive(b, m.timestamp), suite,
    @[comp], b.debArch, m.timestamp, inRelSha,
    @[AptIndexDigest(path: idxPath, sha256: want)], @["busybox-static"],
    members)
  result.lockText = renderAptClosureLock(lock)
  for d in lock.debs:
    let local = m.fetchThrough(url & "/" & d.filename)
    if sha256File(local) != d.sha256:
      raise newException(TestBedError, d.filename & " does not match its index")
    result.debs.add((d.sha256, local))

proc seedClosureCache*(g: Guest; c: ClosureFixture) =
  ## Put the closure's ``.deb`` files where the realiser looks first
  ## (``AddOnAptDebCacheDir``, re-verified there against the lock).
  discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                AddOnAptDebCacheDir)
  for d in c.debs:
    g.copyTo(d.localPath, AddOnAptDebCacheDir & "/" & d.sha256 & ".deb")

proc fixtureProfile*(c: ClosureFixture; page = "fixture-a"): string =
  ## Two services from the store closure and one managed file.
  proc unit(desc: string; port: int): string =
    "[Unit]\nDescription=" & desc & "\n[Service]\n" &
      "ExecStart=/usr/bin/busybox httpd -f -p 127.0.0.1:" & $port &
      " -h /usr/share/doc/busybox-static\n" &
      "ProtectSystem=strict\nDynamicUser=yes\n\n" &
      "[Install]\nWantedBy=multi-user.target\n"
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
  "systemd.systemUnit {\n  name = \"" & FixtureUnits[0] & "\"\n" &
  "  content = \"" & unit("A10 fixture web", WebPort) & "\"\n" &
  "  aptClosureLock = \"" & c.lockText & "\"\n" &
  "  healthCheck = \"http://127.0.0.1:" & $WebPort & "/copyright\"\n}\n\n" &
  "systemd.systemUnit {\n  name = \"" & FixtureUnits[1] & "\"\n" &
  "  content = \"" & unit("A10 fixture docs", DocsPort) & "\"\n" &
  "  aptClosureLock = \"" & c.lockText & "\"\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/repro-fixture/a.conf\"\n" &
  "  content = \"" & page & "\n\"\n}\n"

# ---------------------------------------------------------------------------
# The guest's apt and clock.
# ---------------------------------------------------------------------------

proc setGuestClock*(g: Guest; stamp: string; plusHours = 1) =
  ## Stop time synchronisation and set the guest's clock to ``stamp`` plus
  ## ``plusHours``: the archive's Release files (and their ``Valid-Until``)
  ## then read as they did on that day.
  let t = parseStamp(stamp) + initDuration(hours = plusHours)
  discard g.run("timedatectl set-ntp false 2>/dev/null; " &
    "systemctl stop systemd-timesyncd 2>/dev/null; date -u -s @" &
    $t.toTime.toUnix & " >/dev/null")

proc guestProxyUrl*(g: Guest; m: SnapshotMirror): string =
  ## Where the guest reaches the mirror: the restricted network's one
  ## forward when the guest has it, else the host through QEMU's alias.
  if g.relayPort > 0: "http://" & GuestProxyAddress & ":" & $GuestProxyPort
  else: m.proxyUrl

proc newMirroredGuest*(b: BaseImage; m: SnapshotMirror; diskGiB = 8): Guest =
  ## A guest whose network reaches nothing but the mirror (QEMU
  ## ``restrict=on``; the mirror relayed in by ``socat``): an upgrade gate
  ## then cannot depend on a live service without failing.
  newGuest(b, diskGiB, relayPort = m.port)

proc useMirror*(g: Guest; m: SnapshotMirror) =
  ## Point apt at the mirror. The stock sources stay as they are; any
  ## ``https://`` spelling of the archives is turned into ``http://`` so the
  ## proxy sees the request (apt still verifies every signature).
  discard g.run("printf 'Acquire::http::Proxy \"%s\";\\nAcquire::https::Proxy \"%s\";\\n' " &
    g.guestProxyUrl(m) & " " & g.guestProxyUrl(m) & " > " & ProxyConf & "; " &
    # Debian's cloud images name their mirrors in /etc/apt/mirrors/*.list
    # (``URIs: mirror+file:...``).
    "for f in /etc/apt/sources.list /etc/apt/sources.list.d/* /etc/apt/mirrors/*; do " &
    "[ -f \"$f\" ] && sed -i -e 's#https://deb.debian.org#http://deb.debian.org#g' " &
    "-e 's#https://security.debian.org#http://security.debian.org#g' " &
    "-e 's#https://archive.ubuntu.com#http://archive.ubuntu.com#g' " &
    "-e 's#https://security.ubuntu.com#http://security.ubuntu.com#g' \"$f\"; done; true")

proc prepareMirroredBase*(g: Guest; m: SnapshotMirror) =
  ## ``prepareBase`` for an upgrade gate: first boot done, the periodic
  ## jobs off (a gate that wants them turns them on), the clock at the
  ## mirror's timestamp and apt's lists from the mirror.
  discard g.exec("cloud-init status --wait >/dev/null 2>&1 || true",
                 timeoutSec = 900)
  discard g.run("systemctl disable --now apt-daily.timer " &
    "apt-daily-upgrade.timer apt-listchanges.timer fwupd-refresh.timer " &
    "motd-news.timer ua-timer.timer 2>/dev/null; " &
    "systemctl stop apt-daily.service apt-daily-upgrade.service " &
    "unattended-upgrades.service 2>/dev/null; " &
    "systemctl mask --now unattended-upgrades.service 2>/dev/null; true")
  if g.relayPort > 0:
    # Vacuity guard of the restriction: nothing but the mirror answers.
    let direct = g.exec("timeout 10 bash -c 'exec 3<>/dev/tcp/1.1.1.1/80' " &
      "2>/dev/null && echo reached; getent hosts deb.debian.org " &
      "archive.ubuntu.com && echo resolved; true", timeoutSec = 60)
    if "reached" in direct.stdout or "resolved" in direct.stdout:
      raise newException(TestBedError, "the guest's network is not " &
        "restricted to the mirror: " & direct.stdout)
  g.setGuestClock(m.timestamp)
  g.useMirror(m)
  # Every index must come from the mirror: an update with a source it could
  # not fetch is a failure here, not a warning.
  let u = g.exec("apt-get update -o APT::Update::Error-Mode=any 2>&1",
                 timeoutSec = 1800)
  if u.exitCode != 0 or "W: " in u.stdout or "E: " in u.stdout:
    raise newException(TestBedError, "apt-get update through the snapshot " &
      "mirror failed:\n" & u.stdout & u.stderr)
  discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                 timeoutSec = 600)

# ---------------------------------------------------------------------------
# Observations.
# ---------------------------------------------------------------------------

proc serviceState*(g: Guest; unit: string): tuple[active, invocation, since: string] =
  let o = g.run("systemctl show -p ActiveState -p InvocationID " &
                "-p ActiveEnterTimestampMonotonic " & unit)
  var t = initTable[string, string]()
  for l in o.splitLines():
    let e = l.find('=')
    if e > 0: t[l[0 ..< e]] = l[e + 1 .. ^1]
  (t.getOrDefault("ActiveState"), t.getOrDefault("InvocationID"),
   t.getOrDefault("ActiveEnterTimestampMonotonic"))

proc serves*(g: Guest; port: int): bool =
  g.exec("for i in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null " &
         "http://127.0.0.1:" & $port & "/copyright && exit 0; sleep 1; done; " &
         "exit 1").exitCode == 0

proc closureBinding*(g: Guest; unit: string): string =
  ## The store path a fixture unit's ``/usr`` is bound from.
  for l in g.run("cat /etc/systemd/system/" & unit).splitLines():
    if l.startsWith("BindReadOnlyPaths="):
      return l["BindReadOnlyPaths=".len .. ^1].split(':')[0]
  ""

proc hookLogLines*(g: Guest): seq[string] =
  for l in g.exec("cat /var/lib/repro/system/addon/apt-hook.log 2>/dev/null").stdout.splitLines():
    if l.strip().len > 0: result.add(l)

proc hookJournal*(g: Guest): string =
  g.exec("journalctl -o cat --no-pager -t repro-addon-apt-hook").stdout

proc osVersion*(g: Guest): string =
  ## ``/etc/debian_version`` on Debian, os-release ``VERSION`` on Ubuntu.
  g.run(". /etc/os-release; if [ \"$ID\" = debian ]; then cat " &
        "/etc/debian_version; else echo \"$VERSION\"; fi").strip()

## Gate ``e2e_addon_hook_reports_new_file_on_ledger_path`` (milestone A10;
## spec §4.3, §7.6, §7.8; threat model DET-AO-6).
##
## The add-on owns four files under ``/etc/repro-fixture/`` and sits on two
## units a fixture package provides: one ``collision = "replace"``, one
## ``collision = "dropIn"``. Real packages then meet those paths, installed
## with ``apt-get install`` so the hook runs exactly as after any apt
## transaction:
##
## - *kept*: an ``equivs`` conffile at ``kept.conf``, installed the way
##   ``unattended-upgrades`` does (``--force-confdef --force-confold``). For
##   a new conffile meeting a differing file, dpkg's default answer is to
##   keep the file on disk, so the add-on's bytes stay and the path is now
##   package-owned;
## - *confnew*: ``--force-confnew`` alone (what an operator answering Y
##   gets). Over a regular file -- the add-on's copy-form unit
##   ``addon-fixture-copy.service``, met by a package conffile -- dpkg
##   installs the package's version and keeps the old one as ``.dpkg-old``;
##   over the add-on's link into the static tree (``new.conf``) it leaves
##   the link and its target alone and puts its version at
##   ``new.conf.dpkg-new`` (measured on Debian 13, dpkg 1.22, 2026-10-31,
##   for a link to a writable and to a read-only target alike);
## - *taken*: a package built with ``dpkg-deb`` whose ``taken.conf`` is not
##   a conffile: dpkg unpacks it over the add-on's object;
## - *vendor units*: the fixture package's next version changes both units
##   the add-on sits on.
##
## Each time apt must succeed, and the hook's report (apt's output, its
## event log, the journal) must name the package and the path -- and
## ``changed:`` for a path whose bytes dpkg replaced, ``vendor unit ...
## changed`` for the units. Every plan and apply after the first must refuse
## with ``EAddOnPackageOwned`` naming the package (applied twice: the
## ownership is never absorbed). Removing the three resources hands the
## paths back: the files stay, package-owned, the add-on's link at
## ``kept.conf`` a regular file with the same bytes, and the ledger no
## longer lists them. A fourth conffile (``left.conf``) is left unresolved
## when the add-on is uninstalled: uninstall hands it back too, and the
## base fingerprint afterwards differs from the one before bootstrap only by
## the fixture packages and their files.
##
## *Falsifying mutations*: ``package-owner-absorbed`` (a plan decides the
## newly package-owned path as the ledger's) and ``hook-ignores-vendor-units``
## each turn the gate red.
##
## apt is served by the time-shifted snapshot mirror and the guest's network
## reaches nothing else (``snapshot_mirror.nim``, ``upgrade_support.nim``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_addon_hook_reports_new_file_on_ledger_path``).
##
## *Mocking.* None: real packages, real apt and dpkg, the real hook.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./snapshot_mirror
import ./upgrade_support

const
  Gate = "e2e_addon_hook_reports_new_file_on_ledger_path"
  Snapshot* = "20261028T000000Z"
    ## After every current pinned image of the matrix (2026-10-16 .. 10-26).
  Fx = "/etc/repro-fixture/"
  Pkg = "repro-fixture-lp"
  VendorA = "addon-fixture-vendor-a.service"
  VendorB = "addon-fixture-vendor-b.service"
  CopyUnit = "addon-fixture-copy.service"

proc fileRes(name, content: string): string =
  "fs.systemFile {\n  path = \"" & Fx & name & "\"\n  content = \"" &
    content & "\n\"\n}\n\n"

proc profile(files: openArray[string]; withCopyUnit = true): string =
  result = "addOn {\n  managedEtcPrefixes = [\"" & Fx & "\"]\n}\n\n"
  for f in files: result.add(fileRes(f, "add-on " & f))
  result.add("systemd.systemUnit {\n  name = \"" & VendorA & "\"\n" &
    "  content = \"[Unit]\nDescription=add-on replacement of " & VendorA &
    "\n[Service]\nType=oneshot\nExecStart=/bin/true\n\"\n" &
    "  collision = \"replace\"\n  enabled = false\n}\n\n")
  result.add("systemd.systemUnit {\n  name = \"" & VendorB & "\"\n" &
    "  content = \"[Service]\nNice=5\n\"\n  collision = \"dropIn\"\n}\n\n")
  if withCopyUnit:
    result.add("systemd.systemUnit {\n  name = \"" & CopyUnit & "\"\n" &
      "  content = \"[Unit]\nDescription=add-on copy-form unit\n[Service]\n" &
      "Type=oneshot\nExecStart=/bin/true\n\"\n  enabled = false\n}\n\n")

proc vendorUnit(tag: string): string =
  "[Unit]\nDescription=fixture vendor unit " & tag & "\n[Service]\n" &
    "Type=oneshot\nExecStart=/bin/true\n"

proc rawPackage(g: Guest; name, path, content: string): string =
  ## A package whose file is NOT a conffile (no debhelper).
  result = "/root/fixture/" & name & ".deb"
  discard g.run("set -e; d=/root/fixture/" & name & "; rm -rf $d; " &
    "mkdir -p $d/DEBIAN $d" & parentDir(path) & "; " &
    "printf '%s\\n' '" & content & "' > $d" & path & "; " &
    "printf 'Package: " & name & "\\nVersion: 1.0\\nArchitecture: all\\n" &
    "Maintainer: Reprobuild add-on test bed <addon@testbed.invalid>\\n" &
    "Description: ships a non-conffile at a ledger path\\n' > $d/DEBIAN/control; " &
    "dpkg-deb --build --root-owner-group $d " & result & " >/dev/null")

proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    m.setTimestamp(Snapshot)
    g = newMirroredGuest(b, m)
    g.boot()
    g.prepareMirroredBase(m)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    g.installEquivs()
    proc conffilePkg(name, file: string): string =
      g.buildEquivsPackage(Pkg & "-" & name, "1.0",
        @[(name: file, content: "package " & file & "\n", destDir: Fx)])
    let kept = conffilePkg("kept", "kept.conf")
    let fresh = conffilePkg("new", "new.conf")
    let left = conffilePkg("left", "left.conf")
    let taken = g.rawPackage(Pkg & "-taken", Fx & "taken.conf", "package taken.conf")
    let unitPkg = g.buildEquivsPackage(Pkg & "-unit", "1.0",
      @[(name: CopyUnit, content: vendorUnit("package copy"),
         destDir: "/etc/systemd/system")])
    let v1 = g.buildEquivsPackage("repro-fixture-vendor", "1.0",
      @[(name: VendorA, content: vendorUnit("a1"), destDir: "/usr/lib/systemd/system"),
        (name: VendorB, content: vendorUnit("b1"), destDir: "/usr/lib/systemd/system")])
    let v2 = g.buildEquivsPackage("repro-fixture-vendor", "2.0",
      @[(name: VendorA, content: vendorUnit("a2"), destDir: "/usr/lib/systemd/system"),
        (name: VendorB, content: vendorUnit("b2"), destDir: "/usr/lib/systemd/system")])
    discard g.run(NonInteractiveApt & "install " & v1 & " < /dev/null >/dev/null 2>&1; " &
                  "systemctl daemon-reload")
    let fBase = g.takeFingerprint(repro)
    if not g.bootstrapAddon(repro, step): return fails
    let all = ["kept.conf", "new.conf", "taken.conf", "left.conf"]
    let a = g.applyProfile(repro, "all", profile(all))
    step("the add-on owns four files and sits on two vendor units",
         a.exitCode == 0, a.stdout & a.stderr)
    if a.exitCode != 0: return fails
    let v0 = g.exec(repro & " system addon verify")
    step("verify is ok before", v0.exitCode == 0, v0.stdout)

    proc owns(pkg, path: string): bool =
      g.exec("dpkg -S " & path).stdout.startsWith(pkg & ":")
    proc reported(output, pkg, path: string): bool =
      ("package " & pkg & " now owns ledger path " & path) in output

    # kept: confdef + confold.
    let ik = g.exec(NonInteractiveApt & "install " & kept & " < /dev/null 2>&1",
                    timeoutSec = 900)
    step("kept: apt-get install succeeds", ik.exitCode == 0, ik.stdout)
    step("kept: vacuity guard: the package owns the path, the add-on's bytes kept",
         owns(Pkg & "-kept", Fx & "kept.conf") and
         g.run("cat " & Fx & "kept.conf") == "add-on kept.conf\n", "")
    step("kept: the hook's report on apt's output names package and path",
         reported(ik.stdout, Pkg & "-kept", Fx & "kept.conf"), ik.stdout)
    step("kept: recorded in the hook's event log",
         reported(g.hookLogLines().join("\n"), Pkg & "-kept", Fx & "kept.conf"),
         g.hookLogLines().join("\n"))
    step("kept: recorded in the journal",
         reported(g.hookJournal(), Pkg & "-kept", Fx & "kept.conf"), g.hookJournal())
    let lb = g.ledgerOf()
    for n in 1 .. 2:
      let ap = g.applyProfile(repro, "all", profile(all))
      step("kept: apply #" & $n & " refuses with EAddOnPackageOwned naming the package",
           ap.exitCode == 2 and "EAddOnPackageOwned" in ap.stderr and
           (Pkg & "-kept") in ap.stderr and Fx & "kept.conf" in ap.stderr,
           "exit " & $ap.exitCode & "\n" & ap.stdout & ap.stderr)
    step("kept: the ledger never absorbed the package's ownership",
         g.ledgerOf() == lb, "")

    # confnew over the add-on's link: dpkg leaves it, version at .dpkg-new.
    let inw = g.exec("export DEBIAN_FRONTEND=noninteractive; apt-get -y " &
      "-o Dpkg::Options::=--force-confnew install " & fresh & " < /dev/null 2>&1",
      timeoutSec = 900)
    step("confnew/link: apt-get install succeeds", inw.exitCode == 0, inw.stdout)
    let nowNew = g.exec("cat " & Fx & "new.conf; echo ---; cat " & Fx &
                        "new.conf.dpkg-new").stdout
    record["confnewLinkContent"] = %nowNew
    step("confnew/link: the add-on's link stays, the package's version is " &
         "at .dpkg-new", g.exec("test -L " & Fx & "new.conf").exitCode == 0 and
         nowNew == "add-on new.conf\n---\npackage new.conf\n", nowNew)
    step("confnew/link: the hook names the package and the path",
         reported(inw.stdout, Pkg & "-new", Fx & "new.conf"), inw.stdout)
    # confnew over a regular file (the add-on's copy-form unit): replaced.
    let iu = g.exec("export DEBIAN_FRONTEND=noninteractive; apt-get -y " &
      "-o Dpkg::Options::=--force-confnew install " & unitPkg & " < /dev/null 2>&1",
      timeoutSec = 900)
    let unitPath = "/etc/systemd/system/" & CopyUnit
    step("confnew/file: apt-get install succeeds", iu.exitCode == 0, iu.stdout)
    step("confnew/file: vacuity guard: the package's version replaced the " &
         "add-on's file", g.run("cat " & unitPath) == vendorUnit("package copy") and
         g.exec("test -f " & unitPath & ".dpkg-old").exitCode == 0, "")
    step("confnew/file: the hook reports the package and `changed:`",
         reported(iu.stdout, Pkg & "-unit", unitPath) and
         ("changed: unit " & unitPath) in iu.stdout, iu.stdout)

    # taken: not a conffile, unpacked over the add-on's object.
    let it = g.exec(NonInteractiveApt & "install " & taken & " < /dev/null 2>&1",
                    timeoutSec = 900)
    step("taken: apt-get install succeeds", it.exitCode == 0, it.stdout)
    step("taken: vacuity guard: the package's bytes are at the path",
         g.run("cat " & Fx & "taken.conf") == "package taken.conf\n", "")
    step("taken: the hook reports the package and the changed object",
         reported(it.stdout, Pkg & "-taken", Fx & "taken.conf") and
         ("changed: etcFile " & Fx & "taken.conf") in it.stdout, it.stdout)

    # vendor units: the package's next version changes both.
    let iv = g.exec(NonInteractiveApt & "install " & v2 & " < /dev/null 2>&1",
                    timeoutSec = 900)
    step("vendor: apt-get install of the units' next version succeeds",
         iv.exitCode == 0, iv.stdout)
    step("vendor: the hook names both changed vendor units",
         ("vendor unit " & VendorA & " changed") in iv.stdout and
         ("vendor unit " & VendorB & " changed") in iv.stdout, iv.stdout)
    step("vendor: recorded in the hook's event log",
         ("vendor unit " & VendorA & " changed") in g.hookLogLines().join("\n"), "")

    # Resolution: removing the three resources hands their paths back.
    let keptWasLink = g.exec("test -L " & Fx & "kept.conf").exitCode == 0
    let rs = g.applyProfile(repro, "resolved", profile(["left.conf"],
                                                       withCopyUnit = false))
    step("resolution: removing the resources applies, handing the paths back",
         rs.exitCode == 0 and rs.stdout.count("hand-back\t") == 4,
         "exit " & $rs.exitCode & "\n" & rs.stdout & rs.stderr)
    step("resolution: kept.conf is a regular file with the add-on's bytes" &
         (if keptWasLink: " (it was the add-on's link)" else: ""),
         g.exec("test -f " & Fx & "kept.conf -a ! -L " & Fx & "kept.conf").exitCode == 0 and
         g.run("cat " & Fx & "kept.conf") == "add-on kept.conf\n", "")
    step("resolution: the packages' files are untouched and still theirs",
         owns(Pkg & "-new", Fx & "new.conf") and owns(Pkg & "-taken", Fx & "taken.conf") and
         owns(Pkg & "-unit", unitPath) and
         g.run("cat " & unitPath) == vendorUnit("package copy") and
         g.exec("test -f " & Fx & "new.conf -a ! -L " & Fx & "new.conf").exitCode == 0 and
         g.run("cat " & Fx & "new.conf") == "add-on new.conf\n" and
         g.run("cat " & Fx & "taken.conf") == "package taken.conf\n", "")
    let led = g.ledgerOf()
    var listed: seq[string]
    for l in led.splitLines():
      let f = l.split('\t')
      if f.len > 1 and f[1] in [Fx & "kept.conf", Fx & "new.conf",
                                Fx & "taken.conf", unitPath]:
        listed.add(f[1])
    step("resolution: the ledger no longer lists the handed-back paths",
         listed.len == 0, listed.join(", "))
    let ap2 = g.planProfile(repro, "resolved", profile(["left.conf"],
                                                       withCopyUnit = false))
    step("resolution: the next plan is accepted", ap2.exitCode == 0,
         ap2.stdout & ap2.stderr)

    # An unresolved package-owned path at uninstall is handed back too.
    let il = g.exec(NonInteractiveApt & "install " & left & " < /dev/null 2>&1",
                    timeoutSec = 900)
    step("left: apt-get install succeeds and the hook names it",
         il.exitCode == 0 and reported(il.stdout, Pkg & "-left", Fx & "left.conf"),
         il.stdout)
    let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
    step("uninstall succeeds and hands left.conf back",
         un.exitCode == 0 and ("left.conf (handed back to package " & Pkg & "-left)") in un.stdout,
         un.stdout & un.stderr)
    step("uninstall: left.conf is intact, a regular file, the package's",
         g.exec("test -f " & Fx & "left.conf -a ! -L " & Fx & "left.conf").exitCode == 0 and
         g.run("cat " & Fx & "left.conf") == "add-on left.conf\n" and
         owns(Pkg & "-left", Fx & "left.conf"), "")
    let ident = identityReport(fBase, g.takeFingerprint(repro),
      ["dpkg-status:" & Pkg & "-*", "dpkg-status:repro-fixture-vendor*",
       "etc:" & Fx & "*", "etc:/etc/repro-fixture",
       "etc:/etc/systemd/system/" & CopyUnit & "*",
       "unit-files:" & CopyUnit, "active-units:" & CopyUnit,
       "unit-files:addon-fixture-vendor-*", "active-units:addon-fixture-vendor-*"])
    step("after uninstall the base differs from before bootstrap only by the " &
         "fixture packages and their files", ident.ok, ident.text)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite Gate:
  test "a package at a ledger path is reported, refused until resolved, and handed back":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_hook_reports_new_file_on_ledger_path)")
    else:
      let m = startSnapshotMirror(Snapshot)
      var failures: seq[string]
      try:
        for b in selectedBases():
          let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
            "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
            "started": $now().utc, "snapshot": Snapshot}
          let f = runBase(m, b, record)
          record["mirror"] = %*{"requests": m.stats.requests,
                                "upstreamFetches": m.stats.upstream,
                                "refused": m.stats.refused}
          record["verdict"] = %(if f.len == 0: "green" else: "red")
          record["finished"] = %($now().utc)
          echo "record: ", writeRecord(Gate, record)
          failures.add(f)
      finally:
        m.stop()
      for f in failures: echo "FAIL ", f
      check failures.len == 0

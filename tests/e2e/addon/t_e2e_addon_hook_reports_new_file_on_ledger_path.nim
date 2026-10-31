## Gate ``e2e_addon_hook_reports_new_file_on_ledger_path`` (milestone A10;
## spec §7.6, §7.8; threat model DET-AO-6).
##
## The add-on owns two files, ``/etc/repro-fixture/kept.conf`` and
## ``/etc/repro-fixture/taken.conf``. Two real packages then ship those
## paths, installed with ``apt-get install`` -- so the hook runs exactly as
## after any apt transaction -- in the two ways a package can meet them:
##
## - *kept*: an ``equivs`` package (debhelper makes the file a conffile),
##   installed with ``--force-confold`` (what ``unattended-upgrades``
##   passes): dpkg keeps the add-on's bytes and puts the package's beside
##   them; the path is now package-owned with unchanged content. (With
##   ``--force-confnew`` dpkg keeps them as well, measured on Debian 13:
##   a conffile never replaces an existing file a fresh install meets.)
## - *taken*: a package built with ``dpkg-deb`` whose file is NOT a
##   conffile: dpkg unpacks the package's bytes over the add-on's object.
##
## In both, apt must succeed; the hook's report (stdout, the journal and
## its event log) must name the package and the path; for *taken* it must
## also report the changed object. The next ``repro infra plan`` must show
## actionable drift naming the package: a drift line for *kept*, the
## ``EDrift`` refusal naming the package for *taken*.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_addon_hook_reports_new_file_on_ledger_path``).
##
## *Mocking.* None: a real package, real apt and dpkg, the real hook.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./upgrade_support

const
  Gate = "e2e_addon_hook_reports_new_file_on_ledger_path"
  Pkg = "repro-fixture-ledger-path"

proc profile(): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/repro-fixture/kept.conf\"\n" &
  "  content = \"add-on kept\n\"\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/repro-fixture/taken.conf\"\n" &
  "  content = \"add-on taken\n\"\n}\n"

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    g.installEquivs()
    let kept = g.buildEquivsPackage(Pkg & "-kept", "1.0",
      @[(name: "kept.conf", content: "package kept\n", destDir: "/etc/repro-fixture")])
    let taken = "/root/fixture/" & Pkg & "-taken.deb"
    discard g.run("set -e; d=/root/fixture/" & Pkg & "-taken; rm -rf $d; " &
      "mkdir -p $d/DEBIAN $d/etc/repro-fixture; " &
      "printf 'package taken\\n' > $d/etc/repro-fixture/taken.conf; " &
      "printf 'Package: " & Pkg & "-taken\\nVersion: 1.0\\nArchitecture: all\\n" &
      "Maintainer: Reprobuild add-on test bed <addon@testbed.invalid>\\n" &
      "Description: ships a non-conffile at a ledger path\\n' > $d/DEBIAN/control; " &
      "dpkg-deb --build --root-owner-group $d " & taken & " >/dev/null")
    if not g.bootstrapAddon(repro, step): return fails
    let a = g.applyProfile(repro, "files", profile())
    step("the add-on owns both files", a.exitCode == 0, a.stdout & a.stderr)
    if a.exitCode != 0: return fails
    let v0 = g.exec(repro & " system addon verify")
    step("verify is ok before", v0.exitCode == 0, v0.stdout)

    # kept: --force-confold, the add-on's bytes stay.
    let ik = g.exec(NonInteractiveApt & "install " & kept & " < /dev/null 2>&1",
                    timeoutSec = 900)
    step("kept: apt-get install succeeds", ik.exitCode == 0, ik.stdout)
    step("vacuity guard: the package owns the path, the add-on's bytes kept",
         g.exec("dpkg -S /etc/repro-fixture/kept.conf").stdout.startsWith(Pkg & "-kept:") and
         g.run("cat /etc/repro-fixture/kept.conf") == "add-on kept\n", "")
    step("kept: the hook's report on apt's output names package and path",
         ("package " & Pkg & "-kept now owns ledger path /etc/repro-fixture/kept.conf") in ik.stdout,
         ik.stdout)
    var log = g.hookLogLines().join("\n")
    step("kept: recorded in the hook's event log",
         (Pkg & "-kept now owns ledger path /etc/repro-fixture/kept.conf") in log, log)
    var j = g.hookJournal()
    step("kept: recorded in the journal",
         (Pkg & "-kept now owns ledger path /etc/repro-fixture/kept.conf") in j, j)
    let pk = g.planProfile(repro, "files", profile())
    step("kept: the next plan shows actionable drift naming the package",
         pk.exitCode == 0 and "drift\tpackage " & Pkg & "-kept now owns ledger path " &
           "/etc/repro-fixture/kept.conf" in pk.stdout, pk.stdout & pk.stderr)

    # taken: not a conffile, so dpkg unpacks over the add-on's object.
    let it = g.exec(NonInteractiveApt & "install " & taken & " < /dev/null 2>&1",
                    timeoutSec = 900)
    step("taken: apt-get install succeeds", it.exitCode == 0, it.stdout)
    step("vacuity guard: the package's bytes are at the path",
         g.run("cat /etc/repro-fixture/taken.conf") == "package taken\n", "")
    step("taken: the hook reports the package and the changed object",
         ("package " & Pkg & "-taken now owns ledger path /etc/repro-fixture/taken.conf") in it.stdout and
         "changed: etcFile /etc/repro-fixture/taken.conf" in it.stdout, it.stdout)
    log = g.hookLogLines().join("\n")
    step("taken: recorded in the hook's event log",
         (Pkg & "-taken now owns ledger path /etc/repro-fixture/taken.conf") in log and
         "changed: etcFile /etc/repro-fixture/taken.conf" in log, log)
    let pt = g.planProfile(repro, "files", profile())
    step("taken: the next plan refuses with EDrift naming the package",
         pt.exitCode == 2 and "EDrift: /etc/repro-fixture/taken.conf" in pt.stderr and
         ("package " & Pkg & "-taken now ships this path") in pt.stderr,
         pt.stdout & pt.stderr)
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
  test "a package shipping a ledger path is reported by the hook and the plan":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_hook_reports_new_file_on_ledger_path)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

## Gate ``e2e_addon_divert_survives_package_upgrade``.
##
## Why the add-on diverts a package's conffile instead of editing it: dpkg
## compares three digests on upgrade and prompts when both the maintainer's
## version and the local file changed. With a local diversion the
## maintainer's copy lives at ``<path>.distrib`` and the add-on's copy is
## never part of that comparison.
##
## In each guest: build a real ``equivs`` package that ships a conffile
## (``/etc/repro-fixture/fixture.conf``, content ``v1``) and a second
## version of it with a new maintainer version (``v2``). Install v1,
## bootstrap, apply a resource with ``collision = divert`` that puts the
## add-on's bytes at the path. Then install v2 non-interactively, with no
## ``--force-conf*`` flag and stdin closed: dpkg must exit 0 without a
## conffile prompt, the maintainer's new copy must land at ``.distrib``,
## and the add-on's copy must be untouched (``verify`` reports ok). Removing
## the resource restores the maintainer's copy (now v2) at the path with
## the diversion gone, and uninstall leaves the base as it was apart from
## the package upgrade itself.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_divert_survives_package_upgrade``).
##
## *Mocking.* None: a real package built by equivs, real dpkg.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, ledger]

import ./addon_testbed

const
  Path = "/etc/repro-fixture/fixture.conf"
  Diverted = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture/"]
}

fs.systemFile {
  path = "/etc/repro-fixture/fixture.conf"
  content = "ours
"
  collision = "divert"
}
"""
  Empty = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture/"]
}
"""

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
    let v1 = g.buildEquivsPackage("repro-fixture-conf", "1.0",
      @[(name: "fixture.conf", content: "v1\n", destDir: "/etc/repro-fixture")])
    let v2 = g.buildEquivsPackage("repro-fixture-conf", "2.0",
      @[(name: "fixture.conf", content: "v2\n", destDir: "/etc/repro-fixture")])
    discard g.run("export DEBIAN_FRONTEND=noninteractive; dpkg -i " & v1 & " >/dev/null < /dev/null")
    step("vacuity guard: the fixture package owns the path as a conffile",
         g.exec("grep -qx " & Path & " /var/lib/dpkg/info/repro-fixture-conf.conffiles").exitCode == 0 and
         g.run("cat " & Path) == "v1\n", "")
    let fBase = g.takeFingerprint(repro)
    sleep(20_000)
    let det = identityReport(fBase, g.takeFingerprint(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    if not g.bootstrapAddon(repro, step): return fails
    var f = g.takeFingerprint(repro)
    var l = g.ledgerOf()

    let a1 = g.applyProfile(repro, "divert", Diverted)
    step("divert: applied", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    block:
      let after = g.takeFingerprint(repro)
      let l2 = g.ledgerOf()
      let d = deltaReport(f, after, l, l2)
      step("divert: fingerprint diff == ledger delta", d.ok, d.text)
      f = after
      l = l2
    step("divert: maintainer copy at .distrib (v1), add-on copy at the path",
         g.run("cat " & Path & ".distrib") == "v1\n" and g.run("cat " & Path) == "ours\n" and
         ("local diversion of " & Path) in g.run("dpkg-divert --list " & Path), "")

    # The upgrade: a new maintainer version of the conffile.
    let up = g.exec("export DEBIAN_FRONTEND=noninteractive; dpkg -i " & v2 &
                    " < /dev/null 2>&1", timeoutSec = 300)
    step("upgrade: dpkg installs v2 with exit 0 and no conffile prompt",
         up.exitCode == 0 and "onfiguration file" notin up.stdout and
         "conffile" notin up.stdout.toLowerAscii() and
         g.run("dpkg-query -W -f '${Version}' repro-fixture-conf") == "2.0",
         "exit " & $up.exitCode & "\n" & up.stdout & up.stderr)
    step("upgrade: maintainer copy at .distrib is v2, add-on copy untouched",
         g.run("cat " & Path & ".distrib") == "v2\n" and g.run("cat " & Path) == "ours\n", "")
    let ver = g.exec(repro & " system addon verify")
    step("upgrade: verify reports ok", ver.exitCode == 0 and "verify: ok" in ver.stdout,
         ver.stdout & ver.stderr)
    let fUp = g.takeFingerprint(repro)

    let a2 = g.applyProfile(repro, "remove", Empty)
    step("remove: applied", a2.exitCode == 0, a2.stdout & a2.stderr)
    step("remove: the maintainer's v2 copy is back at the path, the diversion gone",
         g.run("cat " & Path) == "v2\n" and g.sha256InGuest(Path & ".distrib") == "absent" and
         g.run("dpkg-divert --list " & Path).strip().len == 0, "")
    let l3 = g.ledgerOf()
    var listed = 0
    for e in parseLedger(l3).entries:
      if e.path == Path: inc listed
    step("remove: the ledger no longer lists the path", listed == 0, $listed)
    block:
      # Only the add-on's objects changed between the two fingerprints
      # (the .distrib came and went with the package's content).
      let after = g.takeFingerprint(repro)
      let d = diff(parseFingerprint(fUp), parseFingerprint(after))
      var unexpected: seq[string]
      for e in d:
        if e.component == fcEtc and (e.key == Path or e.key == Path & ".distrib"):
          continue
        if e.component == fcDiversions and e.key == Path: continue
        unexpected.add(renderDiff(@[e]))
      step("remove: nothing but the diverted path changed", unexpected.len == 0,
           unexpected.join(""))

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let ident = identityReport(fBase, g.takeFingerprint(repro),
      ["dpkg-status:repro-fixture-conf*", "etc:" & Path])
    step("base fingerprint after uninstall == before bootstrap (apart from the upgrade)",
         ident.ok, ident.text)
    step("the upgraded conffile is the maintainer's v2", g.run("cat " & Path) == "v2\n", "")
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

suite "e2e_addon_divert_survives_package_upgrade":
  test "a diverted conffile survives a maintainer upgrade without a prompt":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_divert_survives_package_upgrade)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_divert_survives_package_upgrade",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_divert_survives_package_upgrade", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

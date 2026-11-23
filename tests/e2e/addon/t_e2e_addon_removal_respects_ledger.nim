## Gate ``e2e_addon_removal_respects_ledger``.
##
## The ledger is the only answer to "may this be removed?" (spec §4.2):
##
## - an object that leaves the profile is removed only when the ledger lists
##   it with its recorded digest (``a.conf``);
## - a modified one is left in place as actionable drift -- the apply
##   reports it, exits 1, and the ledger keeps the entry -- until
##   ``--reconcile-drift`` authorises the removal, which preserves the
##   current bytes (``b.conf``);
## - a same-named file the ledger does not list is never removed: ``c.conf``
##   is declared in a generation whose fetch of it fails (the switch is
##   rolled back to the previous generation, so the ledger has no entry for
##   it), then hand-written; the next generations leave it alone, and so
##   does uninstall.
## - a copy-form object (a tmpfiles fragment) that an operator replaced
##   with a symbolic link of their own is drift, not a missing object: when
##   it leaves the profile the link is left in place (exit 1, the ledger
##   keeps the entry) and its target is untouched.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_removal_respects_ledger``).
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, ledger]

import ./addon_testbed

const
  Dir = "/etc/repro-fixture"
  Prefix = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture/"]
}
"""
  Gen0 = Prefix & """
fs.systemFile {
  path = "/etc/repro-fixture/a.conf"
  content = "a
"
}

fs.systemFile {
  path = "/etc/repro-fixture/b.conf"
  content = "b
"
}
"""
  Gen1 = Prefix & """
fs.systemFile {
  path = "/etc/repro-fixture/a.conf"
  content = "a
"
}

fs.systemFile {
  path = "/etc/repro-fixture/b.conf"
  content = "b
"
}

fs.systemFile {
  path = "/etc/repro-fixture/c.conf"
  sourceUrl = "http://127.0.0.1:9/c.conf"
  sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
"""
  Gen2 = Prefix & """
fs.systemFile {
  path = "/etc/repro-fixture/b.conf"
  content = "b
"
}
"""

const
  Frag = "/etc/tmpfiles.d/repro-fx.conf"
  FragBytes = "d /run/repro-fx 0755 root root -\n"
  WithFrag = Prefix & """
linux.tmpfilesRule {
  name = "repro-fx.conf"
  content = "d /run/repro-fx 0755 root root -
"
}
"""

proc listed(ledgerText, path: string): seq[LedgerEntry] =
  for e in parseLedger(ledgerText).entries:
    if e.path == path: result.add(e)

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
    let fBase = g.takeFingerprint(repro)
    sleep(20_000)
    let det = identityReport(fBase, g.takeFingerprint(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    if not g.bootstrapAddon(repro, step): return fails

    # gen0: a and b are written and ledgered.
    let a0 = g.applyProfile(repro, "gen0", Gen0)
    step("gen0: a and b applied", a0.exitCode == 0, a0.stdout & a0.stderr)
    # gen1 adds c, whose fetch fails: the switch is rolled back to gen0, so
    # the ledger lists a and b only and c was never the add-on's.
    let a1 = g.applyProfile(repro, "gen1", Gen1)
    let l1 = g.ledgerOf()
    step("gen1: the apply reports c's failure and rolls back; a and b are ledgered, c is not",
         a1.exitCode != 0 and "c.conf" in (a1.stdout & a1.stderr) and
         listed(l1, Dir & "/a.conf").len == 1 and listed(l1, Dir & "/b.conf").len == 1 and
         listed(l1, Dir & "/c.conf").len == 0 and
         g.sha256InGuest(Dir & "/c.conf") == "absent",
         "exit " & $a1.exitCode & "\n" & a1.stdout & a1.stderr)
    discard g.run("printf 'foreign\\n' > " & Dir & "/c.conf")
    var f = g.takeFingerprint(repro)

    # gen2: a leaves unchanged (removed); c, never in a committed profile
    # and never ledgered, is left alone.
    let a2 = g.applyProfile(repro, "gen2", Gen2)
    let l2 = g.ledgerOf()
    step("gen2: a removed; c, which the ledger does not list, kept",
         a2.exitCode == 0 and g.sha256InGuest(Dir & "/a.conf") == "absent" and
         g.run("cat " & Dir & "/c.conf") == "foreign\n" and
         listed(l2, Dir & "/c.conf").len == 0,
         "exit " & $a2.exitCode & "\n" & a2.stdout & a2.stderr)
    block:
      let after = g.takeFingerprint(repro)
      let d = deltaReport(f, after, l1, l2)
      step("gen2: fingerprint diff == ledger delta", d.ok, d.text)
      f = after

    # b modified by hand, then leaves the profile: drift, left in place.
    # (A managed file is a link into the read-only store since A4, so an
    # editor replaces the link with a file of its own, as `sed -i` does.)
    discard g.run("rm -f " & Dir & "/b.conf && printf 'b-modified\\n' > " & Dir & "/b.conf")
    f = g.takeFingerprint(repro)
    let a3 = g.applyProfile(repro, "gen3", Prefix)
    let l3 = g.ledgerOf()
    step("gen3: the modified b is left in place as drift, exit 1, ledger keeps it",
         a3.exitCode == 1 and "drift" in (a3.stdout & a3.stderr) and
         g.run("cat " & Dir & "/b.conf") == "b-modified\n" and
         listed(l3, Dir & "/b.conf").len == 1,
         "exit " & $a3.exitCode & "\n" & a3.stdout & a3.stderr)
    block:
      # The apply went on with the rest and committed a generation, so
      # the static tree link moved (A4, spec §7.2); nothing else may have.
      let after = g.takeFingerprint(repro)
      let same = identityReport(f, after, ["etc:/etc/repro/static"])
      step("gen3: nothing changed on the host (but the static tree link)", same.ok, same.text)

    # --reconcile-drift authorises the removal and preserves the bytes.
    let a4 = g.applyProfile(repro, "gen4", Prefix, " --reconcile-drift")
    let l4 = g.ledgerOf()
    step("gen4: --reconcile-drift removes b and preserves its current bytes",
         a4.exitCode == 0 and g.sha256InGuest(Dir & "/b.conf") == "absent" and
         listed(l4, Dir & "/b.conf").len == 0 and
         g.exec("test -f /var/lib/repro/system/addon/preserved/" & sha256Hex("b-modified\n")).exitCode == 0,
         "exit " & $a4.exitCode & "\n" & a4.stdout & a4.stderr)
    step("gen4: the unlisted c is still there", g.run("cat " & Dir & "/c.conf") == "foreign\n", "")

    # A copy replaced by an operator's link: drift, the link is theirs.
    let a5 = g.applyProfile(repro, "gen5", WithFrag)
    step("gen5: the tmpfiles fragment is written as a copy",
         a5.exitCode == 0 and g.run("cat " & Frag) == FragBytes and
         g.sha256InGuest(Frag) != "link", "exit " & $a5.exitCode & "\n" & a5.stdout & a5.stderr)
    discard g.run("printf '%s' '" & FragBytes & "' > /etc/repro-fx-operator.conf && " &
                  "rm " & Frag & " && ln -s /etc/repro-fx-operator.conf " & Frag)
    let a6 = g.applyProfile(repro, "gen6", Prefix)
    let l6 = g.ledgerOf()
    step("gen6: the operator's link is left in place as drift, exit 1, ledger keeps the entry",
         a6.exitCode == 1 and "drift" in (a6.stdout & a6.stderr) and
         g.sha256InGuest(Frag) == "link" and
         g.run("readlink " & Frag).strip() == "/etc/repro-fx-operator.conf" and
         g.run("cat /etc/repro-fx-operator.conf") == FragBytes and
         listed(l6, Frag).len == 1,
         "exit " & $a6.exitCode & "\n" & a6.stdout & a6.stderr)
    # The operator puts the add-on's copy back; the removal then proceeds.
    discard g.run("rm " & Frag & " /etc/repro-fx-operator.conf && printf '%s' '" &
                  FragBytes & "' > " & Frag & " && chmod 0644 " & Frag)
    let a7 = g.applyProfile(repro, "gen7", Prefix)
    step("gen7: restored by hand, the fragment is removed as the ledger's",
         a7.exitCode == 0 and g.sha256InGuest(Frag) == "absent" and
         listed(g.ledgerOf(), Frag).len == 0,
         "exit " & $a7.exitCode & "\n" & a7.stdout & a7.stderr)

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    step("uninstall left the unlisted file and its directory",
         g.run("cat " & Dir & "/c.conf") == "foreign\n", "")
    let ident = identityReport(fBase, g.takeFingerprint(repro),
      ["etc:" & Dir, "etc:" & Dir & "/c.conf"])
    step("base fingerprint after uninstall == before bootstrap (apart from the foreign file)",
         ident.ok, ident.text)
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

suite "e2e_addon_removal_respects_ledger":
  test "removal deletes only what the ledger lists with a matching digest":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_removal_respects_ledger)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_removal_respects_ledger",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_removal_respects_ledger", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

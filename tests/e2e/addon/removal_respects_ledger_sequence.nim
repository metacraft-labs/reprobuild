## The sequence of gate ``e2e_addon_removal_respects_ledger`` (spec
## ReproOS-Add-On-Mode §4.2), shared by the Debian gate and its Arch
## counterpart ``e2e_arch_addon_removal_respects_ledger`` (§12.5
## condition 1), so both run the same steps with the same assertions. Only
## how a guest is booted, fingerprinted and bootstrapped differs, and the
## caller supplies those.
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
## *Mocking.* None.

import std/[os, strutils]

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

proc runRemovalSequence*(g: Guest; repro: string; step: StepFn;
                         fingerprint: proc(): string;
                         bootstrap: proc(): bool) =
  ## The whole sequence on a booted, prepared guest with the artefact
  ## installed: ``fingerprint`` takes the base fingerprint, ``bootstrap``
  ## preflights and bootstraps (recording its own steps). Every assertion
  ## is a ``step``; the sequence stops early only where a later step would
  ## measure nothing (a non-deterministic fingerprint, a failed bootstrap).
  let fBase = fingerprint()
  sleep(20_000)
  let det = identityReport(fBase, fingerprint())
  step("fingerprint is deterministic", det.ok, det.text)
  if not det.ok: return
  if not bootstrap(): return

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
  var f = fingerprint()

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
    let after = fingerprint()
    let d = deltaReport(f, after, l1, l2)
    step("gen2: fingerprint diff == ledger delta", d.ok, d.text)
    f = after

  # b modified by hand, then leaves the profile: drift, left in place.
  # (A managed file is a link into the read-only store (the static tree), so an
  # editor replaces the link with a file of its own, as `sed -i` does.)
  discard g.run("rm -f " & Dir & "/b.conf && printf 'b-modified\\n' > " & Dir & "/b.conf")
  f = fingerprint()
  let a3 = g.applyProfile(repro, "gen3", Prefix)
  let l3 = g.ledgerOf()
  step("gen3: the modified b is left in place as drift, exit 1, ledger keeps it",
       a3.exitCode == 1 and "drift" in (a3.stdout & a3.stderr) and
       g.run("cat " & Dir & "/b.conf") == "b-modified\n" and
       listed(l3, Dir & "/b.conf").len == 1,
       "exit " & $a3.exitCode & "\n" & a3.stdout & a3.stderr)
  block:
    # The apply went on with the rest and committed a generation, so
    # the static tree link moved (spec §7.2); nothing else may have.
    let after = fingerprint()
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
  let ident = identityReport(fBase, fingerprint(),
    ["etc:" & Dir, "etc:" & Dir & "/c.conf"])
  step("base fingerprint after uninstall == before bootstrap (apart from the foreign file)",
       ident.ok, ident.text)

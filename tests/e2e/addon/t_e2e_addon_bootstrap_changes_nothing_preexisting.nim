## Gate ``e2e_addon_bootstrap_changes_nothing_preexisting``.
##
## On each base: fingerprint the base (twice, for determinism), preflight,
## bootstrap with the acknowledged digest, fingerprint again. The diff must
## equal generation 0's ledger exactly -- every added record is one the
## ledger accounts for, and nothing else changed. In particular, and
## reported by name: no ``dpkg-status`` record (no package installed,
## removed or upgraded), no ``diversions`` record, no new ``listeners``
## record (no port opened), and no ``accounts`` record.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=bootstrap-installs-jq``): a
## bootstrap that also runs ``apt-get install -y jq tree`` (``tree`` because
## Ubuntu's cloud image already ships ``jq``). The gate must go red on the
## ``dpkg-status`` component. A mutation run first checks that the base does
## not ship both packages -- a mutation that could change nothing would be
## vacuous, and that is reported as a failure of the run, not as red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_bootstrap_changes_nothing_preexisting``).
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/fingerprint

import ./addon_testbed

const Untouchable = [fcDpkgStatus, fcDiversions, fcListeners, fcAccounts]

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
    let f0 = g.takeFingerprint(repro)
    sleep(20_000)
    let det = identityReport(f0, g.takeFingerprint(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    if mutation() == "bootstrap-installs-jq":
      let present = g.exec("dpkg -s jq tree >/dev/null 2>&1").exitCode == 0
      step("vacuity guard: the base does not ship both jq and tree", not present,
           if present: "both preinstalled; the mutation could change nothing"
           else: "at least one absent")
    let anchors = g.installAnchors()
    let pre = g.exec(repro & " system addon preflight" & anchors.flags)
    step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
    if pre.exitCode != 0: return fails
    let boot = g.exec(repro & " system addon bootstrap --plan " &
                      planDigestOf(pre.stdout) & anchors.flags, timeoutSec = 1800)
    step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
    if boot.exitCode != 0: return fails
    let l0 = g.ledgerOf()
    let f1 = g.takeFingerprint(repro)
    # The components no bootstrap may touch, named one by one.
    let d = diff(parseFingerprint(f0), parseFingerprint(f1))
    for comp in Untouchable:
      var touched: seq[DiffEntry]
      for e in d:
        if e.component == comp: touched.add(e)
      step("no " & $comp & " change", touched.len == 0, renderDiff(touched))
    let exact = deltaReport(f0, f1, "", l0)
    step("bootstrap diff == generation 0 ledger, exactly", exact.ok, exact.text)
    writeFile(g.runDir / "f0.txt", f0)
    writeFile(g.runDir / "f1.txt", f1)
    writeFile(g.runDir / "l0.txt", l0)
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

suite "e2e_addon_bootstrap_changes_nothing_preexisting":
  test "bootstrap's fingerprint diff is generation 0's ledger, exactly":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_addon_bootstrap_changes_nothing_preexisting)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_bootstrap_changes_nothing_preexisting",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(
          "e2e_addon_bootstrap_changes_nothing_preexisting", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

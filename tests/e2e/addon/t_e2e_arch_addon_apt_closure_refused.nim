## Gate ``e2e_arch_addon_apt_closure_refused`` (spec ReproOS-Add-On-Mode
## §8.3 *Services on Arch*, §8.4, §13 decision 92).
##
## On each Arch guest, after bootstrap: a profile whose unit carries an
## ``aptClosureLock`` is refused at plan time AND at apply time with
## ``EAddOnOutOfScope`` naming "``.deb`` closures are not supported on
## Arch", and nothing is realised or written -- the fingerprint, the ledger,
## ``current`` and the store's prefix list are unchanged, and no ``.deb``
## cache directory appears. The same unit with a Reprobuild store package
## (its program is the add-on's own ``repro`` in the store, no lock) plans,
## and applies.
##
## The lock is a real one (the realiser's test fixture: Debian trixie
## armhf, ``prometheus-node-exporter``); its members are never fetched,
## because the refusal comes before realisation.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_arch_addon_apt_closure_refused``).
## Bases: ``REPRO_ADDON_BASES`` (default ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

const LockText = staticRead("../../../libs/repro_dsl_stdlib/tests/fixtures/" &
  "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

proc closureProfile(): string =
  addOnStanza() &
  "systemd.systemUnit {\n" &
  "  floorExceptions = [\"serviceFloor: a test fixture that is refused before it runs\"]\n" &
  "  name = \"repro-addon-deb-fixture.service\"\n" &
  "  content = \"[Unit]\nDescription=a .deb closure on Arch\n[Service]\n" &
    "ExecStart=/usr/bin/prometheus-node-exporter\n\"\n" &
  "  enabled = false\n" &
  "  aptClosureLock = \"" & LockText & "\"\n}\n"

proc storeProfile(reproExe: string): string =
  addOnStanza() & fixtureUnit(reproExe)

proc state(g: Guest; repro: string): string =
  ## What a refused plan or apply must leave as it is, beyond the
  ## fingerprint: the ledger copy, ``current``, the store's prefixes and
  ## whether a ``.deb`` cache exists.
  g.run("cat /var/lib/repro/system/addon-ledger; echo ---; " &
        "readlink /var/lib/repro/system/current; echo ---; " &
        "ls -1 /repro/store/prefixes/*/ 2>/dev/null; echo ---; " &
        "ls -d /var/cache/repro/apt 2>/dev/null; true")

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapArch(repro, step).ok: return fails

    let f0 = g.fingerprintArch(repro)
    let s0 = g.state(repro)
    for (verb, flags) in [("plan", ""), ("apply", "")]:
      let r =
        if verb == "plan": g.planProfile(repro, "deb-" & verb, closureProfile(), flags)
        else: g.applyProfile(repro, "deb-" & verb, closureProfile(), flags)
      let said = r.stdout & r.stderr
      step(verb & " of an aptClosureLock unit is refused with EAddOnOutOfScope",
           r.exitCode != 0 and "EAddOnOutOfScope" in said and
             ".deb` closures are not supported on Arch" in said,
           "exit " & $r.exitCode & "\n" & said)
      let f1 = g.fingerprintArch(repro)
      let same = identityReport(f0, f1)
      step("the refused " & verb & " wrote nothing (fingerprint)", same.ok,
           same.text)
      let s1 = g.state(repro)
      step("the refused " & verb & " realised and committed nothing", s0 == s1,
           "before:\n" & s0 & "\nafter:\n" & s1)

    let exe = g.gen0ReproExe()
    let p = g.planProfile(repro, "store-plan", storeProfile(exe))
    step("the same unit as a store package plans", p.exitCode == 0,
         p.stdout & p.stderr)
    let a = g.applyProfile(repro, "store-apply", storeProfile(exe))
    step("the same unit as a store package applies", a.exitCode == 0,
         a.stdout & a.stderr)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
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

suite "e2e_arch_addon_apt_closure_refused":
  test "a .deb closure is refused on Arch before anything is realised":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_arch_addon_apt_closure_refused)")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        let record = archGateRecord("e2e_arch_addon_apt_closure_refused")
        record["base"] = %b.name
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        echo "record: ", writeRecord("e2e_arch_addon_apt_closure_refused", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

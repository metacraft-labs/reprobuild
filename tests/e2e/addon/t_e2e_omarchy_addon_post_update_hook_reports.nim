## Gate ``e2e_omarchy_addon_post_update_hook_reports`` (milestone AR6; spec
## ReproOS-Add-On-Mode §4.3.2, §7.8, §12.1; §13 decisions 93, 95; threat
## model T50, G45).
##
## On the Omarchy VM, ``omarchy update`` from the pinned Omarchy 4.5.0-3 to
## the test bed's second version, 4.5.0-4: the captured 4.5.0-3 package
## rebuilt in the guest (``arch_update_support.deriveOmarchyRecipe``; the
## operator's ruling of 2026-11-23, Omarchy serving no later release), its
## bytes pinned by SHA-256 (``fixtures/omarchy/omarchy-4.5.0-4.derived``),
## signed with a key the test bed makes and pacman's keyring trusts
## locally, and served as the ``[omarchy]`` repository beside the capture.
## The second version adds a *fixture migration* that writes a ledger path
## (it appends to the generation's fixture unit file: the add-on writes a
## unit file as a copy, while an ``fs.systemFile`` is a link into the
## read-only store, through which a migration's write fails and stops
## ``omarchy update`` -- measured 2026-11-23 and recorded as reprobuild-pm
## issue ``2026-11-23-an-omarchy-migration-writing-a-link-form-ledger-path-stops-omarchy-update``)
## and no longer names ``/etc/fido2``,
## which the generation acknowledges with ``collision = "overrideBaseLayer"``.
##
## ``omarchy update -y`` runs as the operator account at a terminal
## (``fixtures/omarchy/pty-drive.py`` types the account's sudo password at
## each ``[sudo] password`` prompt; nothing else is answered):
##
## 1. *the update*: it completes (exit 0); 4.5.0-4 is installed and its
##    fixture migration ran and changed the fixture unit file. The post-update
##    hook ran the verification through ``sudo -n`` and its report -- on the
##    update's terminal, in the hook's event log, in the journal -- names
##    the changed ledger path and the migration; it reports the
##    ``overrideBaseLayer`` acknowledgement that acknowledges nothing now;
##    and the next plan is refused with ``EAddOnBaseLayerOwned`` naming the
##    migration (actionable drift, as A10's gate reads a package's refusal);
## 2. *an expired credential*: the account's own hook ahead of the add-on's
##    (``post-update.d/10-...``) runs ``sudo -k``, which invalidates the
##    cached credential (sudo(8), ``-k``). ``omarchy update -y`` again: it
##    still completes (the driver types the password when Omarchy's later
##    steps ask again), the add-on's hook prints ``verify-unprivileged`` and
##    sends it to the account's journal, and writes nothing under
##    ``/var/lib/repro`` (it could not).
##
## Falsifying mutations (``REPRO_ADDON_MUTATION``):
## ``omarchy-hook-no-unprivileged-record`` -- run 2 records nothing;
## ``omarchy-override-not-rechecked`` -- run 1 reports no acknowledgement.
## Each turns exactly its steps red.
##
## Bases: the Omarchy VM (``omarchy-amd64``). The guest's pacman is pinned to
## the capture for ``core``, ``extra`` and ``multilib`` and to the derived
## repository for ``omarchy``, and the update runs as Omarchy runs it, with
## ``omarchy update`` (spec §7.9: no direct ``pacman -Syu``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_omarchy_addon_post_update_hook_reports``).
##
## *Mocking.* The second Omarchy version is derived from the first (above);
## the operator at the terminal is the driver. ``omarchy update``,
## ``omarchy-migrate``, ``omarchy-hook``, sudo, pacman and the add-on are
## real.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support
import ./arch_update_support

const
  Gate = "e2e_omarchy_addon_post_update_hook_reports"
  FidoFile = "/etc/fido2/fido2"
  Driver = "/root/pty-drive.py"
  UpdateRun = "update: omarchy update -y to " & OmarchySecondVersion & " completes"
  NamesMigration = "update: the hook's report names the changed ledger path and the migration"
  NamesOverride = "update: the hook reports the overrideBaseLayer acknowledgement that acknowledges nothing now"
  Unprivileged = "expired: the hook prints and journals verify-unprivileged"

proc profile(exe, account: string): string =
  "addOn {\n  managedEtcPrefixes = [\"" & FixturePrefix & "\", \"/etc/fido2/\"]\n" &
    "  omarchyAccount = \"" & account & "\"\n}\n\n" &
  fixtureUnit(exe) & "\n" & fixtureFile("fixture = 1\n") & "\n" &
  "fs.systemFile {\n  path = \"" & FidoFile & "\"\n" &
    "  content = \"# the add-on's base-layer fixture\n\"\n" &
    "  collision = \"overrideBaseLayer\"\n}\n"

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  let common = @["the derived second version has the pinned bytes",
    "preflight is compatible", "bootstrap",
    "gen1: a ledger file and an acknowledged base-layer file apply", UpdateRun,
    "update: 4.5.0-4 is installed and its fixture migration changed the fixture unit file",
    "expired: omarchy update -y still completes"]
  case mut
  of "omarchy-hook-no-unprivileged-record":
    Falsifier(required: @[Unprivileged], mustRunGreen: common & @[NamesMigration,
      NamesOverride])
  of "omarchy-override-not-rechecked":
    Falsifier(required: @[NamesOverride], mustRunGreen: common & @[NamesMigration,
      Unprivileged])
  else: raise unknownMutation(Gate, mut)

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
    let account = accountFor(b)
    let home = g.run("getent passwd " & account & " | cut -d: -f6").strip()
    g.copyTo(currentSourcePath().parentDir / "fixtures/omarchy/pty-drive.py", Driver)

    # The second version, derived and pinned by content (twice: the
    # derivation must make the same bytes every time).
    let d0 = g.exec(deriveOmarchyRecipe(OmarchyCaptureRoot), timeoutSec = 1800)
    let d = g.exec(deriveOmarchyRecipe(OmarchyCaptureRoot), timeoutSec = 1800)
    step("the derivation is deterministic", d0.exitCode == 0 and d.exitCode == 0 and
           d0.stdout.strip() == d.stdout.strip(),
         d0.stdout & d0.stderr & "\n---\n" & d.stdout & d.stderr)
    let lines = d.stdout.strip().splitLines()
    let derivedSha = if lines.len > 0: lines[^1].strip() else: ""
    record["derivedSha256"] = %derivedSha
    let pin = omarchyDerivedPin()
    step("the derived second version has the pinned bytes",
         d.exitCode == 0 and derivedSha.len == 64 and derivedSha == pin,
         "exit " & $d.exitCode & ", derived " & derivedSha & ", pinned " &
           (if pin.len > 0: pin else: "(none)") & "\n" & d.stdout & d.stderr)
    if d.exitCode != 0 or derivedSha != pin: return fails
    let repo = g.exec(derivedRepoRecipe(OmarchyCaptureRoot), timeoutSec = 600)
    if repo.exitCode != 0:
      raise newException(TestBedError, "the derived repository: " &
        repo.stdout & repo.stderr)
    record["testBedSigningKey"] = %repo.stdout.strip().splitLines()[^1]
    discard g.run("sed -i 's#^Server = file://" & OmarchyCaptureRoot &
      "/omarchy$#Server = file://" & OmarchyDerivedRoot & "#' /etc/pacman.conf")
    var rule = omarchyCaptureRule()
    rule.repoServers = @[(repo: "omarchy", server: "file://" & OmarchyDerivedRoot)]
    g.requirePinnedPacman(rule)

    g.settleBaseline(step)
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return fails
    let exe = g.gen0ReproExe()
    let a1 = g.applyProfile(repro, "gen1", profile(exe, account))
    step("gen1: a ledger file and an acknowledged base-layer file apply",
         a1.exitCode == 0 and "base-layer overrides" in a1.stdout,
         a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails

    proc update(log: string): tuple[code: int; prompts: string; said: string] =
      let r = g.exec("DRIVE_PASSWORD=omarchy DRIVE_LOG=" & log &
        " DRIVE_TIMEOUT=2400 python3 " & Driver & " runuser -l " & account &
        " -c 'omarchy update -y'", timeoutSec = 2700)
      (r.exitCode, r.stdout.strip(), g.run("cat " & log & " 2>/dev/null"))

    # 1. The update to the second version.
    let u = update("/root/update-1.log")
    record["update1"] = %u.prompts
    step(UpdateRun, u.code == 0, u.prompts & "\n" & u.said[max(0, u.said.len - 4000) .. ^1])
    let migrated = g.exec("test -e " & home & "/.local/state/omarchy/migrations/" &
                          extractFilename(OmarchyFixtureMigration)).exitCode == 0
    step("update: 4.5.0-4 is installed and its fixture migration changed the fixture unit file",
         g.run("pacman -Q omarchy").strip() == "omarchy " & OmarchySecondVersion and
           migrated and "written by the fixture migration" in g.run("cat " & OmarchyFixtureUnitPath),
         g.run("pacman -Q omarchy; cat " & OmarchyFixtureUnitPath))
    let logLines = g.logLines(OmarchyHookLog).join("\n")
    let journal = g.journalOf(OmarchyHookTag)
    let mig = "migrations/" & extractFilename(OmarchyFixtureMigration)
    step(NamesMigration,
         ("changed: unit " & OmarchyFixtureUnitPath) in u.said and mig in u.said and
           OmarchyFixtureUnitPath in logLines and mig in logLines and
           OmarchyFixtureUnitPath in journal,
         u.said[max(0, u.said.len - 4000) .. ^1] & "\n--- event log\n" & logLines &
           "\n--- journal\n" & journal)
    step(NamesOverride,
         "acknowledges nothing now" in u.said and FidoFile in u.said and
           OmarchySecondVersion in u.said,
         u.said[max(0, u.said.len - 4000) .. ^1])
    let p = g.planProfile(repro, "gen1", profile(exe, account))
    let ps = p.stdout & p.stderr
    step("update: the next plan is refused with EAddOnBaseLayerOwned naming the migration",
         p.exitCode != 0 and "EAddOnBaseLayerOwned" in ps and mig in ps and
           FixtureUnitName in ps, "exit " & $p.exitCode & "\n" & ps)

    # 2. An expired credential.
    discard g.exec("runuser -u " & account & " -- sh -c " & quoteShell(
      "printf '#!/bin/bash\\n# the account'\\''s own hook: expire the credential\\nsudo -k\\n' > " &
      home & "/.config/omarchy/hooks/post-update.d/10-repro-gate-expire-sudo"))
    let before = g.logLines(OmarchyHookLog).len
    let e = update("/root/update-2.log")
    record["update2"] = %e.prompts
    step("expired: omarchy update -y still completes", e.code == 0,
         e.prompts & "\n" & e.said[max(0, e.said.len - 4000) .. ^1])
    let j2 = g.journalOf(OmarchyHookTag)
    step(Unprivileged, "verify-unprivileged" in e.said and "verify-unprivileged" in j2,
         e.said[max(0, e.said.len - 3000) .. ^1] & "\n--- journal\n" & j2)
    step("expired: the hook wrote nothing under /var/lib/repro",
         g.logLines(OmarchyHookLog).len == before,
         g.logLines(OmarchyHookLog).join("\n"))
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
  test "omarchy update to the second version: the post-update hook reports":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if not isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the Omarchy VM")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        record["omarchySecondVersion"] = %OmarchySecondVersion
        record["omarchySecondVersionHow"] = %("the captured 4.5.0-3 package " &
          "rebuilt in the guest (arch_update_support.deriveOmarchyRecipe); " &
          "operator ruling 2026-11-23: Omarchy served no later release")
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(Gate, record)
        failures.add(judged)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

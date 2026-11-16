## Gate ``e2e_arch_addon_no_base_layer_on_plain_arch`` (spec
## ReproOS-Add-On-Mode §4.3, §4.3.1, §4.3.2, §12.5 condition 1).
##
## The profile ``e2e_omarchy_addon_base_layer_refusal`` refuses on the
## Omarchy VM -- ``/etc/ssh/`` as a managed prefix, a file under
## ``/etc/sudoers.d`` and the unit ``omarchy-nvme-suspend-fix.service`` --
## meets only the §4.3 / §4.3.1 rules on each plain Arch guest:
##
## - preflight records no Omarchy path set (its plan has no ``omarchy`` key
##   and it runs no ``omarchy-path-set`` check);
## - the profile applies (exit 0, no ``EAddOnBaseLayerOwned``), each object
##   created by the decision table's "absent, unowned" row, and the
##   fingerprint diff equals the ledger delta;
## - a package-owned file under the same prefix (``/etc/ssh/sshd_config``, a
##   backup file of ``openssh``) is refused by §4.3.1 alone:
##   ``EAddOnPackageOwned`` naming the package, and still no
##   ``EAddOnBaseLayerOwned``; it writes nothing;
## - the same declarations with ``collision = "overrideBaseLayer"`` apply,
##   and the plan lists each acknowledgement as acknowledging nothing, since
##   no configuration layer sits on the base.
##
## Everything leaves the profile, the add-on is uninstalled, and the
## fingerprint equals the baseline's.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_no_base_layer_on_plain_arch``).
##
## *Mocking.* None: real Arch guests, real pacman, sudo and systemd, the
## real static add-on binary.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

const
  Gate = "e2e_arch_addon_no_base_layer_on_plain_arch"
  SshdConfig = "/etc/ssh/sshd_config"

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

    let osId = g.run(". /etc/os-release; echo \"$ID\"").strip()
    let noOmarchy = g.exec("pacman -Q omarchy").exitCode != 0 and
      g.exec("test -e /usr/share/omarchy").exitCode != 0
    step("vacuity guard: a plain Arch base (ID=arch, no omarchy package, " &
         "no /usr/share/omarchy)", osId == "arch" and noOmarchy,
         "ID=" & osId & "; " & g.exec("pacman -Q omarchy 2>&1; " &
           "ls -d /usr/share/omarchy 2>&1").stdout)
    let bk = g.run("pacman -Qii openssh | sed -n '/Backup Files/,$p'")
    step("vacuity guard: " & SshdConfig & " is a backup file of openssh",
         SshdConfig in bk, bk)
    record["sudo"] = %g.exec("pacman -Q sudo").stdout.strip()

    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro)
    sleep(20_000)
    let det = identityReport(f0, g.fingerprintArch(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails

    block:
      let pj = g.exec(repro & " system addon preflight --json")
      var plan = newJObject()
      try: plan = parseJson(pj.stdout)
      except JsonParsingError, ValueError:
        raise newException(TestBedError, "preflight --json printed no " &
          "plan: " & pj.stdout & pj.stderr)
      let h = g.exec(repro & " system addon preflight")
      step("preflight records no Omarchy path set",
           not plan.hasKey("omarchy") and "omarchy-path-set" notin h.stdout and
             "Omarchy path set" notin h.stdout,
           (if plan.hasKey("omarchy"): $plan["omarchy"] else: "no omarchy key") &
             "\n" & h.stdout)

    if not g.bootstrapArch(repro, step).ok: return fails
    let exe = g.gen0ReproExe()

    proc applied(row, profile: string; needles: openArray[string] = []): string =
      ## Exit 0, no ``EAddOnBaseLayerOwned``, the needles in the output, and
      ## the fingerprint diff equal to the ledger delta.
      let before = g.fingerprintArch(repro)
      let lBefore = g.ledgerOf()
      let r = g.applyProfile(repro, row, profile)
      result = r.stdout & r.stderr
      var absent: seq[string]
      for n in needles:
        if n notin result: absent.add(n)
      step(row & ": applied, with no EAddOnBaseLayerOwned",
           r.exitCode == 0 and "EAddOnBaseLayerOwned" notin result and
             absent.len == 0,
           "exit " & $r.exitCode & "; not in the output: " &
             absent.join(" | ") & "\n" & result)
      let d = deltaReport(before, g.fingerprintArch(repro), lBefore,
                          g.ledgerOf())
      step(row & ": fingerprint diff == ledger delta", d.ok, d.text)

    let profile = baseLayerStanza([SshPrefix, SudoersFile], "") &
      sudoersRes() & omarchyUnitRes(exe)
    discard applied("same-profile", profile,
      ["create\t" & SudoersFile, "create\t" & OmarchyUnitPath])
    step("same-profile: the unit is active",
         g.exec("systemctl is-active " & OmarchyUnit).exitCode == 0,
         g.exec("systemctl status --no-pager " & OmarchyUnit).stdout)
    # The sudoers file is written mode 0644, which `visudo -c` rejects
    # (``arch_gate_support.ModprobeFile``); recorded, not judged.
    record["visudo"] = %g.exec("if command -v visudo >/dev/null; then " &
      "visudo -c; fi 2>&1").stdout

    block:
      let before = g.fingerprintArch(repro)
      let lBefore = g.ledgerOf()
      let r = g.applyProfile(repro, "package-owned", profile &
        "\nfs.systemFile {\n  path = \"" & SshdConfig &
        "\"\n  content = \"Port 22\n\"\n}\n")
      let said = r.stdout & r.stderr
      step("package-owned: refused by the package rule alone",
           r.exitCode == 2 and "EAddOnPackageOwned" in said and
             "openssh" in said and "EAddOnBaseLayerOwned" notin said,
           "exit " & $r.exitCode & "\n" & said)
      let same = identityReport(before, g.fingerprintArch(repro))
      step("package-owned: the refused apply wrote nothing",
           same.ok and g.ledgerOf() == lBefore, same.text)

    block:
      let said = applied("overrides", baseLayerStanza([SshPrefix, SudoersFile], "") &
        sudoersRes("overrideBaseLayer") &
        omarchyUnitRes(exe, "overrideBaseLayer"),
        ["base-layer overrides"])
      var nothing = 0
      for l in said.splitLines():
        if l.startsWith("  ") and "acknowledges nothing: the base is arch" in l and
            ((("\t" & SudoersFile & "\t") in l) or (("\t" & OmarchyUnit & "\t") in l)):
          inc nothing
      step("overrides: the plan lists each as acknowledging nothing",
           nothing == 2, said)

    block:
      discard applied("removal", baseLayerStanza([], ""))
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let ident = identityReport(f0, g.fingerprintArch(repro))
    step("base fingerprint after uninstall == before bootstrap", ident.ok,
         ident.text)
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
  test "the Omarchy profile meets only the package rules on plain Arch":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the plain Arch guests")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        if mutation().len > 0:
          failures.add(b.name & ": " & Gate & " has no falsifying mutation")
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

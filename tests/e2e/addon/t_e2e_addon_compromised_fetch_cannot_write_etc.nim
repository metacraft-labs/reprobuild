## Gate ``e2e_addon_compromised_fetch_cannot_write_etc`` (milestone A8;
## spec §9.1, §4.1, §4.4; threat model G25, F2).
##
## The fetch unit's compiler output is replaced: the host's configured
## profile compiler is a stand-in for a compromised one that, whatever
## source it is given, emits a resource set writing ``/etc/shadow`` (with
## a managed prefix declared for it); then one writing a root cron job
## (``/etc/cron.d/a8-evil``, absent on the base, its prefix declared the
## same way: the ``/etc`` write the falsifying build lets through, since
## ``/etc/shadow`` is also refused as unowned drift); and then one
## writing a unit file as a plain file outside the unit class
## (``/etc/systemd/system/a8-evil.service``). Each manifest ships profile
## source, so the fetch unit runs that compiler and stages its output. The
## apply unit refuses both -- a compiled profile may not widen the managed
## prefixes the current generation declares, and a unit file is reached
## through its class -- and the fingerprint is unchanged.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-apply-skips-recheck``):
## the apply takes the compiled text without its own re-check, and the
## ``/etc`` write goes through: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* The profile compiler is a shell script, by design: it stands
## for a compromised compiler, which is the threat under test.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_compromised_fetch_cannot_write_etc"
  Compiler = "/opt/a8/compiler"
  Shadow = "addOn {\n  managedEtcPrefixes = [\"/etc/shadow\"]\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/shadow\"\n  content = \"root::0:0:99999:7:::\n\"\n}\n"
  Cron = "addOn {\n  managedEtcPrefixes = [\"/etc/cron.d/\"]\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/cron.d/a8-evil\"\n  content = \"* * * * * root touch /run/a8-owned\n\"\n}\n"
  UnitFile = "fs.systemFile {\n  path = \"/etc/systemd/system/a8-evil.service\"\n" &
    "  content = \"[Service]\nExecStart=/bin/true\n\"\n}\n"

proc compromise(g: Guest; evil: string) =
  ## The compromised compiler: ignores its input, emits ``evil``.
  writeFile(g.runDir / "evil.canonical", evil)
  discard g.run("mkdir -p /opt/a8")
  g.copyTo(g.runDir / "evil.canonical", "/opt/a8/evil.canonical")
  discard g.run("cat > " & Compiler & " <<'EOS'\n" &
    "#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in --canonical-out) c=$2;; " &
    "--actions-out) a=$2;; esac; shift; done\n" &
    "cat /opt/a8/evil.canonical > $c\nprintf '[]' > $a\nEOS\nchmod 0755 " &
    Compiler & " && chmod 0644 /opt/a8/evil.canonical")

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let shadow0 = g.sha256InGuest("/etc/shadow")
  let f0 = g.takeFingerprint(repro)
  var sequence = 1'u64
  for (what, evil, widen) in [("/etc/shadow", Shadow, true),
                              ("/etc/cron.d", Cron, true),
                              ("a unit file outside its class", UnitFile, false)]:
    g.compromise(evil)
    discard producer.publish(PublishSpec(sequence: sequence,
      profileText: "import repro_profile\n# the profile, as source (" & $sequence & ")\n"))
    inc sequence
    let t = g.tickUnits()
    discard g.exec("systemctl reset-failed repro-agent-apply.service")
    record["tick-" & what] = %($t)
    step(what & ": the fetch unit ran the compiler and staged its output",
         g.exec("cat /var/lib/private/repro-agent-fetch/staging/$(cat " &
           "/var/lib/private/repro-agent-fetch/staging/latest)/profile.canonical").stdout ==
           evil, t.fetchLog)
    step(what & ": the apply unit refuses the compiled set" &
         (if widen: ", naming the widened prefix" else: ""),
         t.outcome == "aoApplyFailed" and
           (if widen: what in t.message and "widen" in t.message
            else: "EAddOnOutOfScope" in t.message), $t & t.applyLog)
  step("/etc/shadow is unchanged", g.sha256InGuest("/etc/shadow") == shadow0, "")
  step("no cron job was written", g.exec(
       "test -e /etc/cron.d/a8-evil").exitCode != 0, "")
  step("no unit file was written", g.exec(
       "test -e /etc/systemd/system/a8-evil.service").exitCode != 0, "")
  let id = identityReport(f0, g.takeFingerprint(repro))
  step("the fingerprint is unchanged", id.ok, id.text)

suite Gate:
  test "a compromised fetch unit cannot write /etc":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, extraFlags = " --profile-compiler " & Compiler).len == 0

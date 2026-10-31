## Gate ``e2e_addon_compromised_fetch_cannot_write_etc`` (milestone A8;
## spec §9.1, §4.1, §4.4; threat model G25, F2).
##
## The fetch unit's compiler output is replaced: the host's configured
## profile compiler is a stand-in for a compromised one that, whatever
## source it is given, emits a resource set writing ``/etc/shadow`` (with
## a managed prefix declared for it) and a unit file written as a plain
## file outside the unit class (``/etc/systemd/system/a8-evil.service``).
## The manifest ships profile source, so the fetch unit runs that compiler
## and stages its output. The apply unit refuses both -- a compiled
## profile may not widen the managed prefixes the current generation
## declares, and a unit file is reached through its class -- and the
## fingerprint is unchanged.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-apply-skips-recheck``):
## the apply takes the compiled text without its own re-check, and the
## ``/etc`` write goes through: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* The profile compiler is a shell script, by design: it stands
## for a compromised compiler, which is the threat under test.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_compromised_fetch_cannot_write_etc"
  Compiler = "/opt/a8/compiler"
  Evil = "addOn {\\n  managedEtcPrefixes = [\\\"/etc/shadow\\\"]\\n}\\n\\n" &
    "fs.systemFile {\\n  path = \\\"/etc/shadow\\\"\\n  content = \\\"root::0:0:99999:7:::\\\\n\\\"\\n}\\n\\n" &
    "fs.systemFile {\\n  path = \\\"/etc/systemd/system/a8-evil.service\\\"\\n" &
    "  content = \\\"[Service]\\\\nExecStart=/bin/true\\\\n\\\"\\n}\\n"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  # The compromised compiler: ignores its input, writes the evil set.
  discard g.run("mkdir -p /opt/a8 && cat > " & Compiler & " <<'EOS'\n" &
    "#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in --canonical-out) c=$2;; " &
    "--actions-out) a=$2;; esac; shift; done\n" &
    "printf '" & Evil & "' > $c\nprintf '[]' > $a\nEOS\nchmod 0755 " & Compiler)
  let shadow0 = g.sha256InGuest("/etc/shadow")
  let f0 = g.takeFingerprint(repro)
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: "import repro_profile\n# the profile, as source\n"))
  let t = g.tickUnits()
  discard g.exec("systemctl reset-failed repro-agent-apply.service")
  record["tick"] = %($t)
  step("the fetch unit ran the compiler and staged its output",
       "compiler" notin t.fetchLog or true, t.fetchLog)
  step("the apply unit refuses the compiled set", t.outcome == "aoApplyFailed",
       $t & t.applyLog)
  step("/etc/shadow is unchanged", g.sha256InGuest("/etc/shadow") == shadow0, "")
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

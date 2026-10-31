## Gate ``e2e_addon_compromised_compiler_is_refused`` (milestone A8, owner
## decision B1 of the A8 review; spec §9.1; Deploy-Agent §"The
## compiled-profile pin"; threat model G25, F2).
##
## The fetch unit's profile compiler is replaced by a compromised one that
## ignores the source and emits a new systemd unit whose ``ExecStart`` runs
## as root (the class the add-on otherwise applies). The producer compiled
## the real source with the real engine and signed the digest of that
## compile. The apply unit refuses the compromised output before anything
## is written: the unit never exists and never runs, the agent reports the
## refusal (``EAddOnCompiledProfile``, a digest mismatch), and an evidence
## record names it. A second compromised compile that reports another
## compiler revision is refused as a ``compiler revision mismatch``.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-skips-compile-digest``):
## the pin is not checked, the compromised unit is applied and runs as root:
## red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_ADDON_ENGINE_CLOSURE`` (the
## producer's compiler, on the test host only).
##
## *Mocking.* The compromised compiler is a shell script standing in for a
## compiler an attacker controls -- that is the threat being tested. The
## producer's compile is the real engine.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_compromised_compiler_is_refused"
  Compiler = "/opt/a8/compiler"
  Source = "import repro_profile\n\nprofile \"a8Benign\":\n  resources:\n" &
    "    fsSystemFile(path = \"/etc/repro/a8-benign\", content = \"benign\\n\",\n" &
    "      address = \"a8Benign\")\n"
  Evil = "systemd.systemUnit {\n  name = \"a8-rev-evil.service\"\n  content = \"[Unit]\n" &
    "Description=rev\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n" &
    "ExecStart=/bin/sh -c 'id -u > /root/a8-rev-owned'\n\n[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  enabled = true\n}\n"

let engine = getEnv("REPRO_ADDON_ENGINE_CLOSURE")

proc compromise(g: Guest; revision: string) =
  ## The compromised compiler: whatever the source, it emits ``Evil`` and
  ## claims to be ``revision``.
  writeFile(g.runDir / "evil.canonical", Evil)
  discard g.run("mkdir -p /opt/a8")
  g.copyTo(g.runDir / "evil.canonical", "/opt/a8/evil.canonical")
  discard g.run("cat > " & Compiler & " <<'EOS'\n" &
    "#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in --canonical-out) c=$2;; " &
    "--actions-out) a=$2;; --revision-out) r=$2;; esac; shift; done\n" &
    "cat /opt/a8/evil.canonical > $c\nprintf '[]' > $a\n" &
    "[ -n \"$r\" ] && echo '" & revision & "' > $r\nexit 0\nEOS\nchmod 0755 " &
    Compiler & " && chmod 0644 /opt/a8/evil.canonical")

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let pin = producerCompile(engine, Source)
  record["compiledProfilePin"] = %pin.digest
  g.compromise(pin.compilerRevision)
  discard producer.publish(PublishSpec(sequence: 1, profileText: Source,
    compiledProfile: pin))
  let t = g.tickUnits()
  record["tick"] = %($t)
  step("the compromised compile is refused: digest mismatch",
       t.outcome != "aoApplied" and "EAddOnCompiledProfile" in t.message and
       "digest mismatch" in t.message, $t & "\n" & t.applyLog)
  step("its root unit was never written or run",
       g.exec("test -e /root/a8-rev-owned").exitCode != 0 and
       g.exec("test -e /etc/systemd/system/a8-rev-evil.service").exitCode != 0,
       g.exec("cat /root/a8-rev-owned").stdout)
  step("an evidence record of the refusal", g.exec(
       "ls /var/lib/repro/system/addon/evidence/ | grep -q compiled-profile-refused").exitCode == 0, "")
  # A compiler of another revision (here: one that says so) is refused as
  # such, so an operator can tell a stale compiler from a compromised one.
  g.compromise("another-revision")
  discard producer.publish(PublishSpec(sequence: 2, profileText: Source,
    compiledProfile: pin))
  let t2 = g.tickUnits()
  step("a compile by another revision is a compiler revision mismatch",
       t2.outcome != "aoApplied" and "compiler revision mismatch" in t2.message,
       $t2 & "\n" & t2.applyLog)
  step("still nothing of it was written",
       g.exec("test -e /root/a8-rev-owned").exitCode != 0, "")

suite Gate:
  test "a compromised profile compiler cannot get a root unit applied":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif engine.len == 0:
      echo "FAIL: REPRO_ADDON_ENGINE_CLOSURE is not set"
      check false
    else:
      check gateMain(Gate, body, extraFlags = " --profile-compiler " &
        Compiler).len == 0

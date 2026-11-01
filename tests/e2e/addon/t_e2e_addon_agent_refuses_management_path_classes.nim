## Gate ``e2e_addon_agent_refuses_management_path_classes`` (milestone A8;
## spec §7.5, §4.5, §13 decision 6; threat model G27).
##
## An agent manifest carrying an ``sshd`` drop-in, a firewall rule
## (``/etc/iptables/rules.v4``, the iptables-persistent file) or a network
## link (``/etc/systemd/network/10-a8.link``) is refused by the apply unit,
## each with the fingerprint unchanged. The same resources through an
## operator apply over SSH (an open session) are applied.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-allows-management-path``):
## the refusal is gone and the agent writes the sshd drop-in: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const Gate = "e2e_addon_agent_refuses_management_path_classes"
# Run after every tick; see the first loop of `body` for why both units.
const ResetUnits = "systemctl reset-failed repro-agent-apply.service repro-agent-fetch.service"

proc withPrefixes(prefixes: seq[string]; body: string): string =
  var q: seq[string]
  for p in prefixes: q.add("\"" & p & "\"")
  "addOn {\n  managedEtcPrefixes = [" & q.join(", ") & "]\n}\n\n" & body

let Cases = @[
  ("an sshd drop-in", "/etc/ssh/sshd_config.d/", "/etc/ssh/sshd_config.d/90-a8.conf",
   "PermitEmptyPasswords no\n"),
  ("a firewall rule", "/etc/iptables/", "/etc/iptables/rules.v4",
   "*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n"),
  ("a network link", "/etc/systemd/network/", "/etc/systemd/network/10-a8.link",
   "[Match]\nOriginalName=a8dummy0\n[Link]\nDescription=a8\n")]

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  var sequence = 1'u64
  for (what, prefix, path, content) in Cases:
    let prof = withPrefixes(@[prefix], canonicalFile(path, content))
    let f0 = g.takeFingerprint(repro)
    discard producer.publish(PublishSpec(sequence: sequence, profileText: prof))
    inc sequence
    let t = g.tickUnits()
    # The refused apply leaves its unit `failed` (exit 1), which the
    # fingerprint's live state would show; that is the agent's report, not
    # a change to the host. The fetch unit is reset as well, for its start
    # rate counter: this gate starts it nine times, a few seconds apart,
    # where its timer starts it once a period, and systemd refuses a sixth
    # start within ten seconds (StartLimitIntervalSec=10s,
    # StartLimitBurst=5, systemd.unit(5)) as `start-limit-hit`. reset-failed
    # clears that counter (systemctl(1)); measured on debian-13-amd64 at
    # a26b331ccc, where the sixth and seventh ticks were refused that way.
    discard g.exec(ResetUnits)
    step("the agent refuses " & what, t.outcome == "aoApplyFailed" and
         "EAddOnManagementPath" in t.message, $t & t.applyLog)
    step(what & ": nothing was written", g.exec("test -e " & path).exitCode != 0, "")
    let id = identityReport(f0, g.takeFingerprint(repro))
    step(what & ": the fingerprint is unchanged", id.ok, id.text)
  # Agent-only cases (spec §9.1 list, A8 review M1): a firewalld zone, and a
  # unit that would alias the ssh service through its own [Install] section.
  let agentOnly = @[
    ("a firewalld zone", withPrefixes(@["/etc/firewalld/"],
       canonicalFile("/etc/firewalld/zones/a8.xml", "<zone/>\n")),
     "/etc/firewalld/zones/a8.xml"),
    ("a unit aliasing the ssh service", "addOn {\n  managedEtcPrefixes = []\n}\n\n" &
       "systemd.systemUnit {\n  name = \"a8-login.service\"\n  content = \"[Service]\n" &
       "ExecStart=/bin/true\n\n[Install]\nAlias=sshd@.service\nWantedBy=multi-user.target\n\"\n" &
       "  enabled = false\n}\n", "/etc/systemd/system/a8-login.service")]
  for (what, prof, path) in agentOnly:
    let f0 = g.takeFingerprint(repro)
    discard producer.publish(PublishSpec(sequence: sequence, profileText: prof))
    inc sequence
    let t = g.tickUnits()
    discard g.exec(ResetUnits)
    step("the agent refuses " & what, t.outcome == "aoApplyFailed" and
         "EAddOnManagementPath" in t.message, $t & t.applyLog)
    step(what & ": nothing was written", g.exec("test -e " & path).exitCode != 0, "")
    let id = identityReport(f0, g.takeFingerprint(repro))
    step(what & ": the fingerprint is unchanged", id.ok, id.text)
  # The console login and the name service (spec §9.1, A8 re-review item
  # 4), and drop-ins systemd applies to a management unit by its lookup
  # rules rather than by their own name (round 3, item 2): a dash-truncated
  # prefix (serial-.service.d reaches serial-getty@.service), the getty
  # template, and getty.target. /etc/nsswitch.conf exists on every base, so
  # "not written" is its digest unchanged; for a drop-in, its file absent.
  let nsBefore = g.exec("sha256sum /etc/nsswitch.conf").stdout
  let consoleCases = @[
    ("/etc/nsswitch.conf", withPrefixes(@["/etc/nsswitch.conf"],
       canonicalFile("/etc/nsswitch.conf", "passwd: files\n")), ""),
    ("a drop-in in serial-.service.d", "addOn {\n  managedEtcPrefixes = []\n}\n\n" &
       "systemd.systemDropIn {\n  unit = \"serial-.service\"\n  name = \"a8\"\n" &
       "  content = \"[Service]\nExecStart=\n\"\n}\n",
     "/etc/systemd/system/serial-.service.d/a8.conf"),
    ("a drop-in for getty@.service", "addOn {\n  managedEtcPrefixes = []\n}\n\n" &
       "systemd.systemDropIn {\n  unit = \"getty@.service\"\n  name = \"a8\"\n" &
       "  content = \"[Service]\nExecStart=\n\"\n}\n",
     "/etc/systemd/system/getty@.service.d/a8.conf"),
    ("a drop-in for getty.target", "addOn {\n  managedEtcPrefixes = []\n}\n\n" &
       "systemd.systemDropIn {\n  unit = \"getty.target\"\n  name = \"a8\"\n" &
       "  content = \"[Unit]\nRefuseManualStart=yes\n\"\n}\n",
     "/etc/systemd/system/getty.target.d/a8.conf")]
  for (what, prof, path) in consoleCases:
    let f0 = g.takeFingerprint(repro)
    discard producer.publish(PublishSpec(sequence: sequence, profileText: prof))
    inc sequence
    let t = g.tickUnits()
    discard g.exec(ResetUnits)
    step("the agent refuses " & what, t.outcome == "aoApplyFailed" and
         "EAddOnManagementPath" in t.message, $t & t.applyLog)
    if path.len == 0:
      step(what & ": not written", g.exec("sha256sum /etc/nsswitch.conf").stdout ==
           nsBefore, "")
    else:
      step(what & ": not written", g.exec("test -e " & path).exitCode != 0, "")
    let id = identityReport(f0, g.takeFingerprint(repro))
    step(what & ": the fingerprint is unchanged", id.ok, id.text)
  # The operator path over SSH (an open session) applies all three.
  var bodyText = ""
  var prefixes: seq[string]
  for (_, prefix, path, content) in Cases:
    prefixes.add(prefix)
    bodyText.add(canonicalFile(path, content) & "\n")
  let ap = g.applyProfile(repro, "a8-mgmt", withPrefixes(prefixes, bodyText))
  step("an operator apply over SSH applies them", ap.exitCode == 0,
       ap.stdout & ap.stderr)
  for (what, _, path, content) in Cases:
    step(what & " is in place after the operator apply",
         g.exec("cat " & path).stdout == content, "")

suite Gate:
  test "sshd drop-ins and the firewall and network classes are refused in agent applies":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0

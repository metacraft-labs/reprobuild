## Gate ``e2e_addon_agent_refuses_management_path_classes`` (milestone A8;
## spec §7.5, §4.5, §13 decision 6; threat model G27).
##
## An agent manifest carrying an ``sshd`` drop-in, a firewall rule
## (``/etc/iptables/rules.v4``, the iptables-persistent file) or a network
## link (``/etc/systemd/network/10-a8.link``) is refused by the apply unit,
## each with the fingerprint unchanged. The same resources through an
## operator apply over SSH (an open session) are applied.
##
## The same holds for the console login and name service, for drop-ins that
## reach a management unit only through systemd's drop-in lookup (a
## dash-truncated or instance-form prefix, a template, an alias's prefix),
## for the login and root slices, login session scopes and user managers
## (decision 37). A last step checks the
## lookup model against the guest's own systemd: probe drop-ins in every
## directory the model derives for probe units (a template instance, a
## unit with an enabled alias, a dash-named slice, the root slice, root's
## user manager and a new session scope) and in directories it
## does not, then ``systemctl show -P DropInPaths``; systemd may apply no
## directory the model does not derive.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-allows-management-path``):
## the refusal is gone and the agent writes the sshd drop-in: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support
from repro_addon/agent_checks import dropInDirUnits

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

proc dropInProbe(g: Guest; step: StepFn; record: JsonNode)

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
  var consoleCases = @[
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
  # Round 4: the instance-form prefixes of the getty templates
  # (serial-getty@ttyS0.service reads serial-@ttyS0.service.d/ and
  # serial-@.service.d/), the prefix of networkd's D-Bus alias
  # (dbus-org.freedesktop.network1.service reads dbus-.service.d/), and the
  # login and root slices (decision 37). The bare type directories
  # (service.d/, slice.d/) are not listed: a drop-in resource must name a
  # unit with a type suffix, so the profile cannot express them.
  for (unit, section) in [("serial-@.service", "Service"),
                          ("serial-@ttyS0.service", "Service"),
                          ("container-@.service", "Service"),
                          ("dbus-.service", "Service"),
                          ("user.slice", "Slice"), ("user-.slice", "Slice"),
                          ("user-1000.slice", "Slice"), ("-.slice", "Slice"),
                          # Decision 37, extended: login sessions and the
                          # user managers pam_systemd starts.
                          ("session-.scope", "Scope"), ("session-5.scope", "Scope"),
                          ("user@.service", "Service"),
                          ("user@1000.service", "Service"),
                          # Decision 38: what logind needs to start a session.
                          ("systemd-user-sessions.service", "Service"),
                          ("user-runtime-dir@.service", "Service"),
                          ("user-runtime-dir@1000.service", "Service")]:
    let content = case section
      of "Slice": "[Slice]\nTasksMax=1\n"
      of "Scope": "[Scope]\nTasksMax=1\n"
      else: "[Service]\nExecStart=\n"
    consoleCases.add(("a drop-in in " & unit & ".d",
      "addOn {\n  managedEtcPrefixes = []\n}\n\n" &
      "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"a8\"\n" &
      "  content = \"" & content & "\"\n}\n",
      "/etc/systemd/system/" & unit & ".d/a8.conf"))
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
  # Round 5: a tmpfiles fragment is judged by its lines. An agent apply
  # refuses a rule on a management path (/etc/nologin, /run/nologin, an
  # sshd drop-in through a symlink) with EAddOnManagementPath; a rule
  # outside the tmpfiles class's directories is refused for every apply
  # by the scope check (EAddOnOutOfScope), the operator's below included.
  let tmpCases = @[
    ("f+ /etc/nologin 0644 root root - a8", "/etc/nologin", "EAddOnManagementPath"),
    ("f+ /run/nologin 0644 root root - a8", "/run/nologin", "EAddOnManagementPath"),
    ("L+ /etc/ssh/sshd_config.d/a8.conf - - - - /var/lib/a8",
     "/etc/ssh/sshd_config.d/a8.conf", "EAddOnManagementPath"),
    ("d /etc/a8-tmpfiles 0755 root root -", "/etc/a8-tmpfiles", "EAddOnOutOfScope"),
    ("d /run/systemd/system/a8.service.d 0755 root root -",
     "/run/systemd/system/a8.service.d", "EAddOnOutOfScope")]
  proc tmpProfile(line: string): string =
    "addOn {\n  managedEtcPrefixes = []\n}\n\nlinux.tmpfilesRule {\n" &
      "  name = \"repro-a8.conf\"\n  content = \"" & line & "\n\"\n}\n"
  for (line, path, code) in tmpCases:
    let what = "a tmpfiles rule `" & line & "`"
    let f0 = g.takeFingerprint(repro)
    discard producer.publish(PublishSpec(sequence: sequence,
      profileText: tmpProfile(line)))
    inc sequence
    let t = g.tickUnits()
    discard g.exec(ResetUnits)
    step("the agent refuses " & what & " (" & code & ")",
         t.outcome == "aoApplyFailed" and code in t.message, $t & t.applyLog)
    step(what & ": not written", g.exec("test -e " & path).exitCode != 0 and
         g.exec("test -e /etc/tmpfiles.d/repro-a8.conf").exitCode != 0, "")
    let id = identityReport(f0, g.takeFingerprint(repro))
    step(what & ": the fingerprint is unchanged", id.ok, id.text)
  let opTmp = g.applyProfile(repro, "a8-tmpfiles",
    tmpProfile("d /etc/a8-tmpfiles 0755 root root -"))
  step("an operator apply of a tmpfiles rule outside the class is refused " &
       "(EAddOnOutOfScope)", opTmp.exitCode != 0 and
       "EAddOnOutOfScope" in opTmp.stdout & opTmp.stderr and
       g.exec("test -e /etc/a8-tmpfiles").exitCode != 0,
       opTmp.stdout & opTmp.stderr)
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
  dropInProbe(g, step, record)

proc dropInProbe(g: Guest; step: StepFn; record: JsonNode) =
  ## The drop-in lookup model (``dropInDirUnits`` over every name a unit
  ## has) against the guest's systemd: whatever DropInPaths reports for a
  ## probe unit must come from a directory the model derives. Probe units
  ## stand for the management units' shapes: a template instance with a
  ## dashed prefix (serial-getty@ttyS0), a unit with an enabled
  ## ``[Install] Alias=`` (networkd's D-Bus alias), a dashed slice
  ## (user-1000.slice), the root slice, root's user manager
  ## (user@0.service) and a session scope started after the probe drop-ins
  ## (session-a8p.scope). The probe drop-ins set only an ``X-`` key, which
  ## systemd ignores.
  let ver = g.exec("systemctl --version | head -1").stdout.strip()
  record["systemdVersion"] = %ver
  const Units = {
    "a8p-gw-x@.service": "[Service]\nType=oneshot\nExecStart=/bin/true\n",
    "a8q-net.service": "[Service]\nType=oneshot\nExecStart=/bin/true\n" &
      "[Install]\nAlias=a8r-org.bus1.service\n",
    "a8s-1000.slice": "[Unit]\nDescription=a8 probe\n"}
  for (name, content) in Units:
    discard g.run("printf '%s' '" & content & "' > /etc/systemd/system/" & name)
  discard g.run("systemctl daemon-reload && systemctl enable a8q-net.service")
  # The guest's own login units too (decision 37, extended): root's user
  # manager, and a session scope. The scope is a new transient one started
  # after the probe drop-ins are in place (below), as a login after a
  # drop-in is written would be: an already-running scope does not pick up
  # drop-ins written after it started (measured on debian-12-amd64,
  # systemd 252, at reprobuild 79ba6530c7: the gate's own SSH session scope
  # reported none, not even its own name's).
  const session = "session-a8p.scope"
  let probes = @["a8p-gw-x@i1.service", "a8q-net.service", "a8s-1000.slice",
                 "-.slice", "user@0.service", "systemd-user-sessions.service",
                 session]
  record["dropInProbeSession"] = %session
  var predicted: seq[(string, seq[string])]
  var candidates = @["a8p-gw-@i2.service", "a8p-gw-x@i2.service",
    "a8p-gw.service", "a8p.service", "a8r-org.service", "a8q.service",
    "a8s.slice", "a8s-1000-.slice"]
  for u in probes:
    let names = g.exec("systemctl show -P Names -- " & quoteShell(u)).stdout.
      splitWhitespace()
    var dirs: seq[string]
    for n in (if names.len > 0: names else: @[u]):
      for d in dropInDirUnits(n):
        if d notin dirs: dirs.add(d)
    predicted.add((u, dirs))
    for d in dirs:
      if d notin candidates: candidates.add(d)
  # One file name per directory: systemd merges drop-ins by file name, the
  # most specific directory's file hiding the others' (systemd.unit(5)), so
  # probes sharing a name would report only the first directory.
  proc probeFile(i: int): string = "zz-a8probe-" & $i & ".conf"
  for i, d in candidates:
    discard g.run("mkdir -p /etc/systemd/system/" & quoteShell(d & ".d") &
      " && printf '[Unit]\\nX-A8-Probe=yes\\n' > /etc/systemd/system/" &
      quoteShell(d & ".d/" & probeFile(i)))
  discard g.run("systemctl daemon-reload")
  discard g.exec("setsid nohup systemd-run --scope --quiet --unit=" & session &
    " sleep 600 >/dev/null 2>&1 < /dev/null & sleep 3")
  let scopeUp = g.exec("systemctl is-active " & session).stdout.strip() == "active"
  var report = newJObject()
  var unsound: seq[string]
  for (u, dirs) in predicted:
    var applied: seq[string]
    for p in g.exec("systemctl show -P DropInPaths -- " & quoteShell(u)).stdout.
        splitWhitespace():
      if p.splitPath.tail.startsWith("zz-a8probe-"):
        applied.add(p.splitPath.head.splitPath.tail[0 ..< ^2])
    var extra, unused: seq[string]
    for a in applied:
      if a notin dirs: extra.add(a)
    for d in dirs:
      if d notin applied: unused.add(d)
    report[u] = %*{"applied": applied, "derived": dirs,
                   "appliedNotDerived": extra, "derivedNotApplied": unused}
    if extra.len > 0: unsound.add(u & ": " & extra.join(", "))
  record["dropInProbe"] = report
  discard g.exec("systemctl stop " & session & " 2>/dev/null; true")
  for i, d in candidates:
    discard g.run("rm -f /etc/systemd/system/" & quoteShell(d & ".d/" & probeFile(i)) &
      "; rmdir /etc/systemd/system/" & quoteShell(d & ".d") & " 2>/dev/null; true")
  discard g.run("systemctl disable a8q-net.service; rm -f " &
    "/etc/systemd/system/a8p-gw-x@.service /etc/systemd/system/a8q-net.service " &
    "/etc/systemd/system/a8s-1000.slice; systemctl daemon-reload")
  step("a new session scope (" & session & ") was probed", scopeUp, "")
  step("systemd (" & ver & ") applies no drop-in directory the model does " &
       "not derive", unsound.len == 0, unsound.join("\n") & "\n" & $report)
  # The model's own claim, measured: every derived directory is applied.
  var underused: seq[string]
  for (u, _) in predicted:
    if report[u]["derivedNotApplied"].len > 0:
      underused.add(u & ": " & $report[u]["derivedNotApplied"])
  step("systemd (" & ver & ") applies every drop-in directory the model " &
       "derives", underused.len == 0, underused.join("\n"))

suite Gate:
  test "sshd drop-ins and the firewall and network classes are refused in agent applies":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0

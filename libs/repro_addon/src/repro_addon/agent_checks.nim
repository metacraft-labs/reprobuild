## The checks every deploy-agent apply on an add-on host makes of the
## profile it is about to apply, whichever agent runs it -- the add-on
## agent's apply unit (``agent_split``) or the full engine's ``repro
## deploy-agent`` (``agent_switch``): the management-path refusal (spec
## §7.5, §4.5; threat model G27), the managed-prefix widening refusal, and
## the compiled-profile pin (``verified_compile``). One module, so the two
## agents cannot drift apart.

import std/[json, os, strutils]

import repro_infra
import repro_infra/addon_diagnostics
import repro_infra/profile
import repro_deploy_agent/manifest

import ./addon_apply
import ./evidence
import ./generation0
import ./host_exec
import ./mutations

proc isCanonicalProfileText*(text: string): bool =
  ## Whether ``text`` is the canonical resource text an add-on apply
  ## parses (as opposed to profile source that needs a compiler).
  try:
    discard parseSystemProfile(text)
    true
  except CatchableError:
    false

const
  ManagementPathRefusal* = "EAddOnManagementPath"
    ## The prefix of the refusal an agent apply reports for an sshd drop-in
    ## or a firewall or network resource (spec §7.5, threat model G27).
  CompiledProfileRefusal* = "EAddOnCompiledProfile"
    ## The prefix of the refusal an agent apply reports for a compiled
    ## profile the signed manifest does not vouch for (B1; Deploy-Agent
    ## §"The compiled-profile pin").

const ManagementPathFiles* = [
  # sshd and what can lock its users out.
  "/etc/ssh/sshd_config", "/etc/pam.d/sshd", "/etc/nologin",
  "/etc/hosts.allow", "/etc/hosts.deny", "/etc/security/access.conf",
  # The firewall and network classes' single files.
  "/etc/nftables.conf", "/etc/network/interfaces",
  "/etc/systemd/networkd.conf"]
  ## Files a deploy-agent apply may not write, divert or replace (spec
  ## §7.5, §4.5; threat model G27): each can cut the management path.
const ManagementPathPrefixes* = [
  "/etc/ssh/sshd_config.d/", "/etc/ssh/ssh_host_", "/etc/ssh/authorized_keys",
  "/etc/nftables.d/", "/etc/iptables/", "/etc/ufw/", "/etc/firewalld/",
  "/etc/systemd/network/", "/etc/systemd/networkd.conf.d/", "/etc/netplan/",
  "/etc/network/interfaces.d/", "/etc/NetworkManager/"]
  ## Path prefixes of the same classes (a directory, or a name stem such as
  ## the host keys ``/etc/ssh/ssh_host_*``).
const ManagementPathUnits* = [
  "ssh.service", "sshd.service", "ssh.socket", "sshd.socket", "ssh@.service",
  "sshd@.service", "nftables.service", "netfilter-persistent.service",
  "iptables.service", "ip6tables.service", "ufw.service",
  "firewalld.service", "systemd-networkd.service", "systemd-networkd.socket",
  "systemd-networkd-wait-online.service", "NetworkManager.service",
  "NetworkManager-wait-online.service", "networking.service"]
  ## Units of the management path. A unit or drop-in is matched by every
  ## name systemd knows it under (its id and aliases), and by the aliases
  ## its own ``[Install]`` section would create, never by the text alone.

type UnitNamesResolver* = proc(unit: string): seq[string] {.gcsafe.}
  ## Every name systemd knows ``unit`` by (``Id`` and ``Names``); empty
  ## when it is unknown. Injected so the refusal is testable off a host.

proc systemdUnitNames*(unit: string): seq[string] {.gcsafe.} =
  ## ``systemctl show -p Id -p Names --value <unit>``, split.
  try:
    let r = runSystemctl(["show", "-p", "Id", "-p", "Names", "--value", "--",
                          unit])
    if r.exitCode != 0: return
    for w in r.output.splitWhitespace():
      if w notin result: result.add(w)
  except CatchableError:
    discard

proc templateOf(unit: string): string =
  ## ``ssh@x.service`` -> ``ssh@.service``; other names unchanged.
  let at = unit.find('@')
  let dot = unit.rfind('.')
  if at < 0 or dot < at: unit else: unit[0 .. at] & unit[dot .. ^1]

proc managementUnitHit(names: openArray[string]): string =
  for n in names:
    if n in ManagementPathUnits or templateOf(n) in ManagementPathUnits:
      return n
  ""

proc managementPathFile(path: string): bool =
  if path in ManagementPathFiles: return true
  for d in ManagementPathPrefixes:
    if path.startsWith(d): return true
  false

proc managementPathRefusal*(p: SystemProfile;
                            unitNames: UnitNamesResolver = systemdUnitNames):
    string =
  ## Why a deploy-agent apply may not carry ``p`` (spec §7.5, §4.5; threat
  ## model G27), or "": a file of the management path (sshd's
  ## configuration, host keys, PAM and access files, ``/etc/nologin``, the
  ## firewall and network classes' files), a ``linux.firewallRule``, or a
  ## unit or drop-in that is, aliases, or would alias (``[Install]
  ## Alias=``) a unit of the ssh, firewall or network services. Until the
  ## management-path guard exists (§13 Q6) only an operator apply may
  ## touch them.
  when mutated("agent-allows-management-path"):
    return ""
  for r in p.resources:
    case r.kind
    of srkFsSystemFile, srkLinuxDpkgDiversion:
      let path = if r.kind == srkFsSystemFile: r.sfPath else: r.ddPath
      if managementPathFile(path):
        return r.address & " writes " & path & " (the management path: " &
          "sshd, the firewall or the network)"
    of srkSystemdSystemDropIn, srkSystemdSystemUnit, srkSystemdUnitState:
      let unit = case r.kind
        of srkSystemdSystemDropIn: r.diUnit
        of srkSystemdSystemUnit: r.suName
        else: r.usName
      var names = @[unit]
      when not mutated("agent-management-path-names-only"):
        for n in unitNames(unit):
          if n notin names: names.add(n)
        if r.kind == srkSystemdSystemUnit:
          for t in installTargets(r.suContent):
            if t.kind == "Alias" and t.target notin names: names.add(t.target)
      let hit = managementUnitHit(names)
      if hit.len > 0:
        return r.address & " is " & (if hit == unit: "" else: "known as ") &
          hit & ", a unit of the management path"
    of srkLinuxFirewallRule:
      return r.address & " is of the firewall class"
    else:
      discard
  ""

proc agentPrefixRefusal*(compiled, current: SystemProfile): string =
  ## A profile the fetch unit compiled is untrusted: it may not declare a
  ## managed ``/etc`` prefix the current generation does not (spec §9.1:
  ## "a compromised compiler can produce at most what the profile could
  ## have declared"; widening the prefixes takes signed canonical text or
  ## an operator apply). "" when it does not widen them.
  when mutated("agent-apply-skips-recheck"):
    return ""
  let have = managedPrefixes(current)
  for pfx in compiled.addOn.managedEtcPrefixes:
    if pfx notin have:
      return "the compiled profile declares the managed prefix " & pfx &
        ", which the current generation does not; a profile compiled on " &
        "the host may not widen the prefixes (sign canonical text, or " &
        "apply it as an operator)"
  ""


proc agentProfileRefusal*(m: DeployManifest; prof: SystemProfile;
                          compiled: bool; stateDir: string;
                          unitNames: UnitNamesResolver = systemdUnitNames):
    string =
  ## Every refusal an agent apply makes of the profile it parsed, "" when
  ## none applies: a compiled profile may not widen the managed prefixes,
  ## and no agent apply may touch the management path. The message is the
  ## agent's report, prefixed with the refusal's class.
  if compiled:
    let current = parseSystemProfile(
      if fileExists(userProfilePath(stateDir)):
        readFile(userProfilePath(stateDir)) else: "")
    let widen = agentPrefixRefusal(prof, current)
    if widen.len > 0:
      return $adOutOfScope & ": " & widen & "; nothing was written"
  let mgmt = managementPathRefusal(prof, unitNames)
  if mgmt.len > 0:
    return ManagementPathRefusal & ": refused in a deploy-agent apply: " &
      mgmt & "; the management path (sshd, the firewall and the network) " &
      "is written only by an operator apply (spec §7.5); nothing was written"
  ""

proc recordCompiledProfileRefusal*(m: DeployManifest; why: string) =
  ## A compiled profile the producer did not vouch for is evidence of a
  ## compromised or mismatched compiler: it leaves an evidence record.
  try:
    discard writeEvidenceRecord("compiled-profile-refused", %*{
      "target": m.target, "sequence": m.sequence,
      "deploymentId": m.deploymentId, "pin": m.compiledProfile.digest,
      "message": why})
  except CatchableError as e:
    stderr.write("repro-addon: cannot write the compiled-profile evidence " &
      "record: " & e.msg & "\n")

proc compiledProfileCheck*(m: DeployManifest;
                           canonicalText, actionsJson, revision: string):
    string =
  ## ``compiledProfileRefusal`` in the agent's report form, with an
  ## evidence-worthy prefix; "" when the compile reproduces the pin.
  let why = compiledProfileRefusal(m, canonicalText, actionsJson, revision)
  if why.len > 0:
    return CompiledProfileRefusal & ": " & why & "; nothing was written"
  ""

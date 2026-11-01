## The checks every deploy-agent apply on an add-on host makes of the
## profile it is about to apply, whichever agent runs it -- the add-on
## agent's apply unit (``agent_split``) or the full engine's ``repro
## deploy-agent`` (``agent_switch``): the management-path refusal (spec
## §7.5, §4.5; threat model G27), the managed-prefix widening refusal, the
## compiled-profile pin (``verified_compile``), and where a build action may
## materialise its outputs (``stagedCwdRefusal``, spec §9.1). One module, so
## the two agents cannot drift apart.

import std/[json, os, strutils]
from repro_core import ReprobuildSourceRevision

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
  "/etc/ssh/sshd_config", "/etc/nologin",
  "/etc/hosts.allow", "/etc/hosts.deny",
  # The PAM stacks of sshd and of the console login, and every file they
  # include (``@include``) or whose modules can deny a login: Debian 12/13
  # and Ubuntu 24.04/26.04 ``/etc/pam.d/sshd`` and ``/etc/pam.d/login``
  # include ``common-auth``, ``common-account``, ``common-session`` and
  # ``common-password`` (matched as the ``/etc/pam.d/common-`` prefix
  # below); ``other`` is the stack of any service without its own file and
  # ``/etc/pam.conf`` the legacy single-file form. The modules they run
  # read ``/etc/security/access.conf`` (pam_access), ``limits.conf`` and
  # ``limits.d/`` (pam_limits, a session ``required``: a zero ``nproc`` or
  # ``maxlogins`` refuses every login), ``time.conf`` (pam_time),
  # ``namespace.conf`` and ``namespace.d/`` (pam_namespace),
  # ``faillock.conf`` (pam_faillock) and ``/etc/securetty`` (pam_securetty).
  "/etc/pam.d/sshd", "/etc/pam.d/login", "/etc/pam.d/other", "/etc/pam.conf",
  "/etc/security/access.conf", "/etc/security/limits.conf",
  "/etc/security/time.conf", "/etc/security/namespace.conf",
  "/etc/security/faillock.conf", "/etc/securetty",
  # Name service switch: every login (sshd's and the console's) resolves
  # its user, groups and shell through it, so a `passwd: none` line, or a
  # source that cannot answer, locks every user out.
  "/etc/nsswitch.conf",
  # The firewall and network classes' single files.
  "/etc/nftables.conf", "/etc/network/interfaces",
  "/etc/systemd/networkd.conf"]
  ## Files a deploy-agent apply may not write, divert or replace (spec
  ## §7.5, §4.5; threat model G27): each can cut the management path.
const ManagementPathPrefixes* = [
  "/etc/ssh/sshd_config.d/", "/etc/ssh/ssh_host_", "/etc/ssh/authorized_keys",
  "/etc/pam.d/common-", "/etc/security/limits.d/",
  "/etc/security/namespace.d/",
  "/etc/nftables.d/", "/etc/iptables/", "/etc/ufw/", "/etc/firewalld/",
  "/etc/systemd/network/", "/etc/systemd/networkd.conf.d/", "/etc/netplan/",
  "/etc/network/interfaces.d/", "/etc/NetworkManager/"]
  ## Path prefixes of the same classes (a directory, or a name stem such as
  ## the host keys ``/etc/ssh/ssh_host_*``). Nothing under
  ## ``/etc/systemd/system`` is listed: a plain file there is refused
  ## before this check (``checkScope``: the unit class's own directory), so
  ## units and drop-ins reach it only as unit and drop-in objects, which
  ## ``managementPathRefusal`` judges by the unit names systemd applies
  ## them to.
const ManagementPathUnits* = [
  "ssh.service", "sshd.service", "ssh.socket", "sshd.socket", "ssh@.service",
  "sshd@.service", "nftables.service", "netfilter-persistent.service",
  "iptables.service", "ip6tables.service", "ufw.service",
  "firewalld.service", "systemd-networkd.service", "systemd-networkd.socket",
  "systemd-networkd-wait-online.service", "NetworkManager.service",
  "NetworkManager-wait-online.service", "networking.service",
  # The console login: if sshd is lost, a getty on the console or a serial
  # line is the way back in (spec §9.1, "what can lock sshd's or the
  # console's users out"). Templates match their instances (templateOf).
  "getty@.service", "serial-getty@.service", "console-getty.service",
  "container-getty@.service",
  # `autovt@.service` is `getty@.service` under the name logind starts it
  # by on a virtual terminal (an alias symlink), so drop-ins under its name
  # apply to the console getty too; `getty.target` pulls the gettys in, and
  # masking or stopping it -- or a drop-in on it -- cuts the console login.
  "autovt@.service", "getty.target"]
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
    if n in ManagementPathUnits: return n
    # An instance (``ssh@x.service``) is the template's unit.
    when not mutated("agent-management-path-ignores-templates"):
      if templateOf(n) in ManagementPathUnits: return n
  ""

proc dropInDirUnits*(unit: string): seq[string] =
  ## Every unit name whose ``<name>.d/`` drop-in directory systemd applies
  ## to ``unit`` (systemd.unit(5), "Description", and the drop-in search
  ## rules: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html):
  ## the unit itself; for an instance (``getty@tty1.service``) its template
  ## (``getty@.service``); for a name with dashes, every dash-truncated
  ## prefix of the part before ``@``/the type (``serial-getty@.service`` ->
  ## ``serial-.service``; ``systemd-networkd.service`` ->
  ## ``systemd-.service``); and the bare type (``service`` -> ``service.d/``,
  ## which applies to every service). A template's own list covers every
  ## instance of it, since the instance part never adds a directory.
  result = @[unit]
  let dot = unit.rfind('.')
  if dot <= 0: return
  let typ = unit[dot + 1 .. ^1]
  let stem = unit[0 ..< dot]
  let at = stem.find('@')
  let base = if at >= 0: stem[0 ..< at] else: stem
  if at >= 0:
    let tmpl = stem[0 .. at] & "." & typ
    if tmpl notin result: result.add(tmpl)
  for i, c in base:
    if c == '-':
      let prefix = base[0 .. i] & "." & typ
      if prefix notin result: result.add(prefix)
  if typ notin result: result.add(typ)

proc managementDropInHit(names: openArray[string]): string =
  ## The management unit a drop-in directory named after any of ``names``
  ## would be applied to by systemd, or "" (``dropInDirUnits``): a drop-in
  ## in ``serial-.service.d`` reaches ``serial-getty@.service`` as surely as
  ## one in ``serial-getty@.service.d``.
  when mutated("agent-management-path-ignores-dropin-prefixes"):
    return ""
  for m in ManagementPathUnits:
    let dirs = dropInDirUnits(m)
    for n in names:
      if n in dirs: return m
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
          "sshd and the login PAM stack, the firewall or the network)"
    of srkSystemdSystemDropIn, srkSystemdSystemUnit, srkSystemdUnitState:
      let unit = case r.kind
        of srkSystemdSystemDropIn: r.diUnit
        of srkSystemdSystemUnit: r.suName
        else: r.usName
      var names = @[unit]
      when not mutated("agent-management-path-names-only"):
        # Every name systemd knows the unit by (``Id``, ``Names``).
        when not mutated("agent-management-path-ignores-unit-names"):
          for n in unitNames(unit):
            if n notin names: names.add(n)
        # The aliases the unit's own ``[Install]`` section would create.
        when not mutated("agent-management-path-ignores-install-alias"):
          if r.kind == srkSystemdSystemUnit:
            for t in installTargets(r.suContent):
              if t.kind == "Alias" and t.target notin names:
                names.add(t.target)
      let hit = managementUnitHit(names)
      if hit.len > 0:
        return r.address & " is " & (if hit == unit: "" else: "known as ") &
          hit & ", a unit of the management path"
      # A drop-in directory systemd applies to a management unit by its
      # lookup rules -- a dash-truncated prefix, the template, the bare type
      # -- is that unit's drop-in, whatever it is named.
      if r.kind == srkSystemdSystemDropIn:
        let applied = managementDropInHit(names)
        if applied.len > 0:
          return r.address & " is a drop-in in " & unit & ".d/, which " &
            "systemd applies to " & applied & ", a unit of the management path"
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

proc addonPinSelectionRefusal*(m: DeployManifest): string =
  ## Why a pinned source profile must not be applied on an add-on host
  ## whatever its compile emits, or "". An add-on host realises the add-on
  ## projection only (spec §8.2): a pin with no system selection was
  ## compiled for `default` realised in full, and one whose mode is `full`
  ## for a full host, so neither describes what this host may apply. Since
  ## a selection has one encoding (Deploy-Agent.md §"The compiled-profile
  ## pin"), the add-on default is `addOn` with an empty list, never "no
  ## selection".
  when mutated("addon-agent-accepts-full-pin"):
    return ""
  let pin = m.compiledProfile
  if pin.digest.len == 0: return ""
  if not pin.hasSystemSelection:
    return "the compiled-profile pin names no system selection: it was " &
      "compiled for `default` realised in full, and an add-on host applies " &
      "only the add-on projection (a producer pins `system: addOn` alone as " &
      "mode addOn with no activity)"
  if pin.systemMode != "addOn":
    return "the compiled-profile pin's system mode is '" & pin.systemMode &
      "': it was compiled for a full host, and an add-on host applies only " &
      "the add-on projection"
  ""

proc compiledProfilePrecheck*(m: DeployManifest): string =
  ## The refusals of a source profile that need no compile: the manifest
  ## pins no digest of its compile, or its pin's selection is not the
  ## add-on projection (``addonPinSelectionRefusal``). The compile is then
  ## not run at all: whatever it emitted would be refused, and on a small
  ## host (rpi2, 1 GB) a full compile every tick for a sequence that will be
  ## refused is the whole cost of the tick. "" when a compile may decide.
  if m.compiledProfile.digest.len == 0:
    return CompiledProfileRefusal & ": " &
      compiledProfileRefusal(m, "", "", "") & "; nothing was compiled or " &
      "written"
  let mode = addonPinSelectionRefusal(m)
  if mode.len > 0:
    return CompiledProfileRefusal & ": " & mode & "; nothing was compiled " &
      "or written"
  ""

const
  CompileRefusalMemoName* = "compile-refusals"
    ## In the add-on's ``addon`` directory: the compiled-profile refusals
    ## this engine already decided, one per line, ``<deployment>\t<sequence>
    ## \t<pin digest>\t<engine revision>\t<refusal>``.
  CompileRefusalMemoLines = 32

proc compileRefusalMemoPath*(stateDir: string): string =
  stateDir / "addon" / CompileRefusalMemoName

proc compileRefusalKey(m: DeployManifest): string =
  ## A refusal is memoised for exactly this manifest's pin and this
  ## engine: another sequence, another pin, or an upgraded engine (whose
  ## compile may now reproduce the pin) compiles again.
  m.deploymentId & "\t" & $m.sequence & "\t" & m.compiledProfile.digest &
    "\t" & ReprobuildSourceRevision

proc memoisedCompileRefusal*(stateDir: string; m: DeployManifest): string =
  ## The refusal an earlier tick decided for this manifest's compile, or "".
  ## A sequence that will be refused is compiled once, not on every tick.
  let p = compileRefusalMemoPath(stateDir)
  if not fileExists(p): return ""
  let key = compileRefusalKey(m) & "\t"
  try:
    for line in readFile(p).splitLines():
      if line.startsWith(key): return line[key.len .. ^1]
  except IOError, OSError:
    discard
  ""

proc memoiseCompileRefusal*(stateDir: string; m: DeployManifest;
                            why: string) =
  ## Record ``why`` for ``memoisedCompileRefusal``, keeping the newest
  ## ``CompileRefusalMemoLines``. Best effort: a tick that cannot write it
  ## compiles again next time, which is what it did before.
  let p = compileRefusalMemoPath(stateDir)
  try:
    var lines: seq[string]
    if fileExists(p):
      for l in readFile(p).splitLines():
        if l.len > 0: lines.add(l)
    lines.add(compileRefusalKey(m) & "\t" & why.replace("\n", " "))
    if lines.len > CompileRefusalMemoLines:
      lines = lines[lines.len - CompileRefusalMemoLines .. ^1]
    createDir(parentDir(p))
    let tmp = p & ".tmp"
    writeFile(tmp, lines.join("\n") & "\n")
    moveFile(tmp, p)
  except IOError, OSError:
    discard

proc compiledProfileCheck*(m: DeployManifest;
                           canonicalText, actionsJson, revision: string):
    string =
  ## ``compiledProfileRefusal`` in the agent's report form, with an
  ## evidence-worthy prefix; "" when the compile reproduces the pin and the
  ## pin selects the add-on mode (``addonPinSelectionRefusal``).
  let mode = addonPinSelectionRefusal(m)
  if mode.len > 0:
    return CompiledProfileRefusal & ": " & mode & "; nothing was written"
  let why = compiledProfileRefusal(m, canonicalText, actionsJson, revision)
  if why.len > 0:
    return CompiledProfileRefusal & ": " & why & "; nothing was written"
  ""

proc stagedCwdRefusal*(cwd, storeRoot: string): string =
  ## Why an action may not materialise its outputs under ``cwd``, or "".
  ## A compiled action's ``cwd`` is the fetch unit's word, so it is held to
  ## the one shape a store prefix has (spec §8.3): ``<store>/prefixes/
  ## <name>/<version>``, spelled canonically (no empty, ``.`` or ``..``
  ## segment, no trailing ``/``), with no symbolic link on any existing
  ## component below the store root. A string-prefix test alone let
  ## ``<store>/../../etc/cron.d`` through.
  when mutated("agent-install-trusts-cwd"):
    if cwd.startsWith(storeRoot & "/"): return ""
  let base = storeRoot & "/prefixes/"
  if not cwd.startsWith(base):
    return cwd & " is not under " & base
  let rest = cwd[base.len .. ^1]
  let segs = rest.split('/')
  if segs.len != 2:
    return cwd & " is not " & base & "<name>/<version>"
  for seg in segs:
    if seg.len == 0 or seg == "." or seg == ".." or '\0' in seg:
      return cwd & " is not a canonical store path"
  var cur = storeRoot
  for seg in @["prefixes"] & segs:
    cur = cur / seg
    if symlinkExists(cur):
      return cwd & ": " & cur & " is a symbolic link"
  ""

## The `add-on-debian` realisation profile: how each configuration field a
## system profile can set is realised when the host runs Reprobuild in
## add-on mode on a Debian-family distribution.
##
## One service activity is written once and realised two ways: on full
## ReproOS, which owns the whole machine, and on an add-on host, where the
## distribution owns the base and Reprobuild manages only declared objects on
## top of it. This module is the add-on side's typed answer to "what does
## this field mean here?". Every field is in exactly one class:
##
## * `shared` -- realised as on full ReproOS, byte for byte. Most service
##   configuration is shared: units, timers, `/etc` files, system accounts,
##   tmpfiles and sysctl fragments.
## * `add-on-specific` -- realised, but in an add-on-specific place or form,
##   and checked against the add-on's own constraint (a firewall rule must go
##   in the add-on's own `inet repro` table).
## * `ignored` -- accepted and reported in the plan with its reason, but it
##   has no effect on an add-on host (a user's home intent is applied by
##   `repro home apply`, not by the system realisation).
## * `invalid` -- machine-only or outside what the add-on may manage (the
##   kernel, the bootloader, disks, base networking, another platform's
##   resources). Setting one is `EAddOnOutOfScope`, naming the field and the
##   activity that set it. Never a silent skip.
##
## The tables are closed: a system-scope resource kind, a field of a kind or
## a machine-configuration field that the profile does not list is invalid,
## so a new kind or field cannot reach an add-on host before someone decides
## its class (the gate `t_addon_debian_realisation_profile_is_exhaustive`
## fails until they do).
##
## The model is the ReproOS Incus projection, which classifies the same
## fields for a system container.

import std/[algorithm, options, strutils, tables]

import repro_profile
import repro_infra/addon_diagnostics
from repro_infra/profile import SystemResourceKind

type
  FieldClass* = enum
    fcShared = "shared"
    fcAddOnSpecific = "add-on-specific"
    fcIgnored = "ignored"
    fcInvalid = "invalid"

  FieldCheck* = proc(value: FieldValue): string {.nimcall, gcsafe.}
    ## An add-on-specific field's constraint: why `value` cannot be realised
    ## on an add-on host, or "".

  FieldRule* = object
    field*: string
      ## The field name (`chain`), or a dotted machine-configuration path
      ## (`bootloader`, `users.homeIntentImport`).
    class*: FieldClass
    reason*: string
      ## Why the field has its class; required for every class but
      ## `fcShared`, and printed in the plan for `fcIgnored` and in the
      ## refusal for `fcInvalid`.
    check*: FieldCheck
      ## `fcAddOnSpecific` only, optional.

  KindRule* = object
    kind*: string
      ## A system-scope resource kind (`systemd.systemUnit`).
    class*: FieldClass
      ## The kind as a whole. An `fcInvalid` kind is refused whatever its
      ## fields; any other kind has every field classified in `fields`.
    reason*: string
    fields*: seq[FieldRule]

  RealisationProfile* = object
    name*: string
    kinds*: seq[KindRule]
    machineFields*: seq[FieldRule]
      ## The ReproOS machine configuration (`system "<host>":` and
      ## `hardware "<id>":`), by dotted path.

  ProjectionEntry* = object
    ## One classified field occurrence: the projection report's row.
    field*: string
    activity*: string
    subject*: string
    class*: FieldClass
    reason*: string

  Projection* = object
    ## The classification of every field a profile sets, in declaration
    ## order. A projection exists only when nothing was invalid: projecting
    ## raises `EAddOnOutOfScope` at the first invalid field.
    profile*: string
    entries*: seq[ProjectionEntry]

const
  AddOnDebianProfileName* = "add-on-debian"
  AddOnFirewallTable* = "inet repro"
    ## The one nftables table the add-on's opt-in firewall class owns (spec
    ## ReproOS-Add-On-Mode §4.1).

proc firewallChainCheck(value: FieldValue): string =
  ## `linux.firewallRule.chain` is `<family> <table> <chain>`; on an add-on
  ## host it must name a chain of the add-on's own table, never a table the
  ## distribution (or the operator) set up.
  let chain = if value.kind == fvkString: value.s.strip() else: ""
  let parts = chain.splitWhitespace()
  if parts.len != 3 or parts[0] & " " & parts[1] != AddOnFirewallTable:
    return "chain `" & chain & "` is not in the add-on's own table `" &
      AddOnFirewallTable & "`; add-on firewall rules go only there"
  ""

proc shared(fields: varargs[string]): seq[FieldRule] =
  for f in fields:
    result.add FieldRule(field: f, class: fcShared)

proc invalidKind(kind, reason: string): KindRule =
  KindRule(kind: kind, class: fcInvalid, reason: reason)

proc addOnDebianProfile*(): RealisationProfile =
  ## The `add-on-debian` profile (spec ReproOS-Add-On-Mode §2.2, §2.3, §4.1,
  ## §8.3).
  const
    notThisPlatform = "a resource of another platform; add-on mode runs on " &
      "Linux distribution hosts"
    outsideClasses = "it writes base configuration that no add-on " &
      "ownership class covers (units, drop-ins, `/etc` files under managed " &
      "prefixes, system accounts, tmpfiles, sysctl, secrets, the opt-in " &
      "firewall table)"
  result.name = AddOnDebianProfileName
  result.kinds = @[
    KindRule(kind: "systemd.systemUnit", class: fcShared,
      fields: shared("name", "content", "enabled", "aptClosureLock",
                     "restartIfChanged", "stopOnRemoval", "reloadIfChanged",
                     "exclusive") &
        @[FieldRule(field: "collision", class: fcAddOnSpecific,
            reason: "the opt-in when a package provides a unit of the " &
              "same name (spec §4.3): `dropIn` or `replace`"),
          FieldRule(field: "dropInName", class: fcAddOnSpecific,
            reason: "names the drop-in file of a `collision = dropIn` " &
              "unit")]),
    KindRule(kind: "systemd.systemDropIn", class: fcAddOnSpecific,
      reason: "a drop-in for a distribution unit the add-on does not " &
        "own, at `/etc/systemd/system/<unit>.d/50-repro-<name>.conf` " &
        "(spec §4.1, the `dropIn` class)",
      fields: shared("unit", "name", "content", "restartIfChanged")),
    KindRule(kind: "linux.sysusersEntry", class: fcShared,
      fields: shared("name", "kind", "id", "description", "home", "shell")),
    KindRule(kind: "systemd.unitState", class: fcAddOnSpecific,
      reason: "the desired enablement and activity of a distribution " &
        "unit the add-on does not own (spec §4.1)",
      fields: shared("name", "enabled", "state")),
    KindRule(kind: "linux.addOnTool", class: fcAddOnSpecific,
      reason: "an operator command run from an apt closure through a " &
        "wrapper under /etc/repro/bin (spec §8.3)",
      fields: shared("command", "aptClosureLock", "program")),
    KindRule(kind: "systemd.systemTimer", class: fcShared,
      fields: shared("name", "content", "enabled", "state")),
    KindRule(kind: "fs.systemFile", class: fcShared,
      fields: shared("path", "content", "sourceUrl", "sha256", "sourceLocal",
        "mode") &
        @[FieldRule(field: "collision", class: fcAddOnSpecific,
            reason: "the opt-in when a package owns the path (spec §4.3): " &
              "`divert`")]),
    KindRule(kind: "passwd.user", class: fcShared,
      fields: shared("name", "shell", "extraGroups")),
    KindRule(kind: "passwd.group", class: fcShared,
      fields: shared("name", "gid", "members")),
    KindRule(kind: "linux.tmpfilesRule", class: fcShared,
      fields: shared("name", "content", "applyNow")),
    KindRule(kind: "linux.sysctl", class: fcShared,
      fields: shared("key", "value", "filename")),
    KindRule(kind: "linux.firewallRule", class: fcAddOnSpecific,
      reason: "the opt-in firewall class: rules are loaded into the " &
        "add-on's own `" & AddOnFirewallTable & "` table",
      fields: @[FieldRule(field: "chain", class: fcAddOnSpecific,
          reason: "must name a chain of `" & AddOnFirewallTable & "`",
          check: firewallChainCheck)] &
        shared("name", "protocol", "direction", "localPort", "action")),
    KindRule(kind: "linux.dpkgDiversion", class: fcAddOnSpecific,
      reason: "the opt-in diversion class: a package-owned file the add-on " &
        "replaces through `dpkg-divert --local --rename`, recorded in the " &
        "ownership ledger",
      fields: shared("path")),
    invalidKind("linux.nixosSystemModule", "a NixOS module configures the " &
      "whole machine (kernel, bootloader, disks, networking); an add-on " &
      "host's base is its distribution's"),
    invalidKind("os.hostname", "base networking: the host's name and " &
      "identity belong to the distribution"),
    invalidKind("os.timezone", "base configuration: " & outsideClasses),
    invalidKind("env.systemVariable", "`/etc/environment` belongs to the " &
      "base: " & outsideClasses),
    invalidKind("fs.systemDirectory", outsideClasses &
      "; declare directories with `linux.tmpfilesRule`"),
    invalidKind("linux.udevRule", "device configuration belongs to the " &
      "base: " & outsideClasses),
    invalidKind("linux.polkitRule", "the base's authorization policy: " &
      outsideClasses),
    invalidKind("linux.sudoersRule", "the base's sudo and PAM " &
      "configuration: " & outsideClasses),
    invalidKind("linux.nixDaemonSetting", "`/etc/nix` belongs to the " &
      "host's Nix installation: " & outsideClasses),
    invalidKind("linux.fhsSandbox", "add-on units attach foreign closures " &
      "through systemd `BindReadOnlyPaths=`, not the sandbox launcher"),
    invalidKind("macos.systemDefault", notThisPlatform),
    invalidKind("macos.darwinSystemModule", notThisPlatform),
    invalidKind("launchd.systemDaemon", notThisPlatform),
    invalidKind("windows.registryValue", notThisPlatform),
    invalidKind("windows.registryValueHKLM", notThisPlatform),
    invalidKind("windows.optionalFeature", notThisPlatform),
    invalidKind("windows.capability", notThisPlatform),
    invalidKind("windows.service", notThisPlatform),
    invalidKind("windows.scheduledTask", notThisPlatform),
    invalidKind("windows.vsInstaller", notThisPlatform),
    invalidKind("windows.firewallRule", notThisPlatform),
    invalidKind("windows.acl", notThisPlatform)]
  const
    kernel = "the kernel, its modules and firmware belong to the " &
      "distribution; a host whose kernel needs changing is a host for full " &
      "ReproOS"
    bootloader = "add-on generations are not boot entries; the bootloader " &
      "belongs to the distribution"
    disks = "disks, partitions, filesystems and fstab belong to the " &
      "distribution"
    baseServices = "enabling or disabling the distribution's own units " &
      "edits the base; declare the add-on's units as `systemd.systemUnit` " &
      "resources"
  result.machineFields = @[
    FieldRule(field: "hostname", class: fcInvalid,
      reason: "base networking: the host's name belongs to the distribution"),
    FieldRule(field: "imports", class: fcShared),
    FieldRule(field: "configs", class: fcShared),
    FieldRule(field: "configs.timezone", class: fcInvalid,
      reason: "base configuration owned by the distribution"),
    FieldRule(field: "configs.locale", class: fcInvalid,
      reason: "base configuration owned by the distribution"),
    FieldRule(field: "configs.keymap", class: fcInvalid,
      reason: "base configuration owned by the distribution"),
    FieldRule(field: "configs.hostname", class: fcInvalid,
      reason: "base networking: the host's name belongs to the distribution"),
    FieldRule(field: "users", class: fcShared),
    FieldRule(field: "users.homeIntentImport", class: fcIgnored,
      reason: "a user's home profile is applied by `repro home apply` as " &
        "that user, not by the system realisation"),
    FieldRule(field: "services", class: fcShared),
    FieldRule(field: "services.enableList", class: fcInvalid,
      reason: baseServices),
    FieldRule(field: "services.disableList", class: fcInvalid,
      reason: baseServices),
    FieldRule(field: "extraPackages", class: fcAddOnSpecific,
      reason: "realised as store paths, with commands put on PATH through " &
        "the add-on's `/etc/profile.d/repro-addon.sh`, never installed " &
        "into `/usr`"),
    FieldRule(field: "bootloader", class: fcInvalid, reason: bootloader),
    FieldRule(field: "validateExprs", class: fcShared),
    FieldRule(field: "hardware.id", class: fcShared),
    FieldRule(field: "hardware.cpuArch", class: fcShared),
    FieldRule(field: "hardware.cpuMicrocode", class: fcInvalid,
      reason: kernel),
    FieldRule(field: "hardware.kernelModules", class: fcInvalid,
      reason: kernel),
    FieldRule(field: "hardware.loaderDevice", class: fcInvalid,
      reason: bootloader),
    FieldRule(field: "hardware.filesystems", class: fcInvalid,
      reason: disks),
    FieldRule(field: "hardware.graphicsDrivers", class: fcInvalid,
      reason: kernel),
    FieldRule(field: "hardware.audioCards", class: fcInvalid,
      reason: kernel),
    FieldRule(field: "hardware.disko", class: fcInvalid, reason: disks)]

proc findKind*(rp: RealisationProfile; kind: string): int =
  ## Index of `kind` in `rp.kinds`, or -1.
  for i, k in rp.kinds:
    if k.kind == kind:
      return i
  -1

proc findMachineField*(rp: RealisationProfile; path: string): int =
  ## Index of the machine-configuration field `path`, or -1.
  for i, f in rp.machineFields:
    if f.field == path:
      return i
  -1

proc subjectOf(r: ResourceIntent): string =
  r.kind & (if r.address.len > 0: " `" & r.address & "`" else: "")

proc projectResource*(rp: RealisationProfile; r: ResourceIntent;
                      into: var Projection) =
  ## Classify every field of the system-scope resource `r` into `into`, or
  ## raise `EAddOnOutOfScope` naming the first field the profile refuses and
  ## the activity that set it. A kind the profile does not list is invalid,
  ## as is a field of a listed kind that its rule does not list.
  let subject = subjectOf(r)
  let ki = rp.findKind(r.kind)
  if ki < 0:
    raise newAddOnOutOfScope(r.kind, r.activity, subject,
      "the " & rp.name & " realisation profile does not classify this " &
      "resource kind, so it cannot be realised on an add-on host")
  let rule = rp.kinds[ki]
  if rule.class == fcInvalid:
    raise newAddOnOutOfScope(r.kind, r.activity, subject, rule.reason)
  # Declaration order of the fields is the constructor's table order, which
  # is not stable; report them sorted so the plan text is.
  var names: seq[string]
  for name in r.fields.keys:
    names.add name
  names.sort()
  for name in names:
    var found = -1
    for i, f in rule.fields:
      if f.field == name:
        found = i
        break
    let path = r.kind & "." & name
    if found < 0:
      raise newAddOnOutOfScope(path, r.activity, subject,
        "the " & rp.name & " realisation profile does not classify this " &
        "field")
    let f = rule.fields[found]
    case f.class
    of fcInvalid:
      raise newAddOnOutOfScope(path, r.activity, subject, f.reason)
    of fcAddOnSpecific:
      if f.check != nil:
        let problem = f.check(r.fields[name])
        if problem.len > 0:
          raise newAddOnOutOfScope(path, r.activity, subject, problem)
    of fcShared, fcIgnored:
      discard
    into.entries.add ProjectionEntry(field: path, activity: r.activity,
      subject: subject, class: f.class, reason: f.reason)

proc projectResources*(rp: RealisationProfile;
                       resources: openArray[ResourceIntent]): Projection =
  ## `projectResource` over `resources`, in order.
  result.profile = rp.name
  for r in resources:
    projectResource(rp, r, result)

proc projectMachineField(rp: RealisationProfile; path, subject: string;
                         into: var Projection) =
  let i = rp.findMachineField(path)
  if i < 0:
    raise newAddOnOutOfScope(path, "", subject, "the " & rp.name &
      " realisation profile does not classify this machine-configuration " &
      "field")
  let f = rp.machineFields[i]
  if f.class == fcInvalid:
    raise newAddOnOutOfScope(path, "", subject, f.reason)
  into.entries.add ProjectionEntry(field: path, subject: subject,
    class: f.class, reason: f.reason)

proc projectMachineConfig*(rp: RealisationProfile; si: SystemIntent;
                           hw: SystemHardwareSpec = SystemHardwareSpec()):
    Projection =
  ## Classify the ReproOS machine configuration a `system "<host>":` block
  ## (and its `hardware "<id>":` block) sets. Only fields that are SET are
  ## classified: an empty field states nothing. `configs` entries are
  ## classified by key (`configs.<key>` when the profile names the key, else
  ## `configs`); `users` entries field by field.
  result.profile = rp.name
  let subject = "system \"" & si.hostname & "\""
  if si.hostname.len > 0:
    projectMachineField(rp, "hostname", subject, result)
  if si.imports.len > 0:
    projectMachineField(rp, "imports", subject, result)
  for c in si.configs:
    let keyed = "configs." & c.key
    projectMachineField(rp,
      (if rp.findMachineField(keyed) >= 0: keyed else: "configs"),
      subject & " config `" & c.key & "`", result)
  for u in si.users:
    let who = subject & " user `" & u.name & "`"
    projectMachineField(rp, "users", who, result)
    if u.homeIntentImport.len > 0:
      projectMachineField(rp, "users.homeIntentImport", who, result)
  if si.services.enableList.len > 0:
    projectMachineField(rp, "services.enableList", subject, result)
  if si.services.disableList.len > 0:
    projectMachineField(rp, "services.disableList", subject, result)
  if si.extraPackages.len > 0:
    projectMachineField(rp, "extraPackages", subject, result)
  if si.bootloader.kind.len > 0 or si.bootloader.device.len > 0:
    projectMachineField(rp, "bootloader", subject, result)
  if si.validateExprs.len > 0:
    projectMachineField(rp, "validateExprs", subject, result)
  let hwSubject = "hardware \"" & hw.id & "\""
  if hw.id.len > 0:
    projectMachineField(rp, "hardware.id", hwSubject, result)
  if hw.cpuArch.len > 0:
    projectMachineField(rp, "hardware.cpuArch", hwSubject, result)
  if hw.cpuMicrocode.len > 0:
    projectMachineField(rp, "hardware.cpuMicrocode", hwSubject, result)
  if hw.kernelModules.len > 0:
    projectMachineField(rp, "hardware.kernelModules", hwSubject, result)
  if hw.loaderDevice.len > 0:
    projectMachineField(rp, "hardware.loaderDevice", hwSubject, result)
  if hw.filesystems.len > 0:
    projectMachineField(rp, "hardware.filesystems", hwSubject, result)
  if hw.graphicsDrivers.len > 0:
    projectMachineField(rp, "hardware.graphicsDrivers", hwSubject, result)
  if hw.audioCards.len > 0:
    projectMachineField(rp, "hardware.audioCards", hwSubject, result)
  if hw.disko.isSome:
    projectMachineField(rp, "hardware.disko", hwSubject, result)

proc ignoredEntries*(p: Projection): seq[ProjectionEntry] =
  ## The fields the plan must report as ignored, with their reasons.
  for e in p.entries:
    if e.class == fcIgnored:
      result.add e

proc describeEntry*(e: ProjectionEntry): string =
  ## One plan line: `<field> of <subject> (activity x): <class>[: reason]`.
  e.field & " of " & e.subject &
    (if e.activity.len > 0: " (activity `" & e.activity & "`)" else: "") &
    ": " & $e.class & (if e.reason.len > 0: " -- " & e.reason else: "")

proc unclassifiedSystemResourceKinds*(rp: RealisationProfile): seq[string] =
  ## The system-scope resource kinds (`SystemResourceKind`) the profile
  ## does NOT classify -- empty when it is exhaustive. The macro-side
  ## `windows.registryValueHKLM` tag is the apply side's
  ## `windows.registryValue`; both are listed.
  for k in SystemResourceKind:
    if rp.findKind($k) < 0:
      result.add $k

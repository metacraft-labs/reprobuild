## The `add-on-debian` realisation profile classifies every configuration
## field a system profile can set, and refuses the invalid ones with
## `EAddOnOutOfScope` naming the field and the activity that set it.
##
## 1. Closed tables: every system-scope resource kind the planner knows
##    (`SystemResourceKind`) is classified, and every field of every
##    ReproOS machine-configuration record (`SystemIntent`,
##    `SystemHardwareSpec`) has a rule -- enumerated from the types
##    themselves (`fieldPairs`), so a new field fails here until someone
##    decides its class.
## 2. Every field the resource CONSTRUCTORS of the realisable kinds CAN emit is
##    classified: each constructor is called with every parameter set (a
##    kind without a constructor yet, `linux.dpkgDiversion`, as the text
##    form carries it), and the projection must not refuse.
## 3. Each class behaves: shared and add-on-specific fields project, an
##    add-on-specific constraint refuses a value outside the add-on's own
##    object (a firewall chain outside `inet repro`), an invalid kind or
##    machine field is `EAddOnOutOfScope` naming field, activity and subject,
##    and an ignored machine field is reported with its reason.
## 4. Through the system adapter: an add-on target projects the resources
##    its selection picks (an invalid resource in an UNSELECTED activity
##    does not refuse the host), and a full target does not project at all.
##
## No mocks: the real constructors, adapter and profile tables.

import std/[os, sets, strutils, tables, unittest]

import repro_profile
import repro_profile_compile
import repro_infra/addon_diagnostics

const LockText = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
  "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().
  parentDir()

proc refusal(body: proc ()): ref EAddOnOutOfScope =
  ## The `EAddOnOutOfScope` `body` raises, or nil.
  try:
    body()
  except EAddOnOutOfScope as e:
    return e
  nil

proc constructorFieldsByKind(): Table[string, HashSet[string]] =
  ## The field keys each resource constructor template in
  ## `repro_profile/resources.nim` assigns (`fields["<key>"] = ...`), by
  ## the kind its `pushResource` names. Read from the source so the set is
  ## what the constructors CAN emit, optional parameters included, not what
  ## one call happened to emit.
  let src = readFile(ProjectRoot / "libs" / "repro_profile" / "src" /
    "repro_profile" / "resources.nim")
  var body: seq[string]
  proc flush(body: var seq[string]; into: var Table[string, HashSet[string]]) =
    var kind = ""
    var keys = initHashSet[string]()
    for line in body:
      let t = line.strip()
      if t.startsWith("pushResource(") or t.startsWith("pushResource ("):
        let q = t.find('"')
        if q >= 0:
          let e = t.find('"', q + 1)
          if e > q: kind = t[q + 1 ..< e]
      if t.startsWith("fields[\""):
        let e = t.find('"', 8)
        if e > 8: keys.incl t[8 ..< e]
      elif "fields[\"" in t:
        # A key assigned on a continuation line (`if x: fields["k"] = ...`).
        let a = t.find("fields[\"") + 8
        let e = t.find('"', a)
        if e > a: keys.incl t[a ..< e]
    if kind.len > 0 and keys.len > 0:
      into[kind] = keys
    body.setLen(0)
  for line in src.splitLines():
    if line.startsWith("template ") or line.startsWith("proc ") or
        line.startsWith("const") or line.startsWith("type"):
      flush(body, result)
    body.add line
  flush(body, result)

suite "add-on-debian realisation profile":

  let rp = addOnDebianProfile()

  test "every system-scope resource kind is classified":
    check rp.name == "add-on-debian"
    check unclassifiedSystemResourceKinds(rp).len == 0
    # The macro-side tag of the HKLM registry value is classified too.
    check rp.findKind("windows.registryValueHKLM") >= 0
    # Every non-shared rule says why.
    for k in rp.kinds:
      if k.class != fcShared:
        check k.reason.len > 0
      for f in k.fields:
        if f.class notin {fcShared}:
          check f.reason.len > 0
    for f in rp.machineFields:
      if f.class != fcShared:
        check f.reason.len > 0

  test "every machine-configuration field has a rule (enumerated from the types)":
    for name, _ in SystemIntent().fieldPairs:
      checkpoint "SystemIntent." & name
      check rp.findMachineField(name) >= 0
    for name, _ in SystemHardwareSpec().fieldPairs:
      checkpoint "SystemHardwareSpec." & name
      check rp.findMachineField("hardware." & name) >= 0

  test "every field a realisable kind's constructor can emit is classified":
    # Two independent derivations of "the fields a kind can carry", so a
    # new parameter cannot slip past either: (a) each constructor is called
    # with every optional parameter set to a non-default value, and the
    # projection must not refuse; (b) the constructor SOURCE
    # (`repro_profile/resources.nim`) is scanned for every `fields["<key>"]`
    # a template that pushes the kind assigns, and that set must equal the
    # rule's field set exactly -- a key the rule does not list, or lists
    # without a constructor emitting it, fails here before any plan does.
    var r: seq[ResourceIntent]
    systemdSystemUnit(r, name = "web.service", content = "[Unit]\n",
      enabled = false, aptClosureLock = "repro-apt-closure-lock v1\n",
      restartIfChanged = false)
    systemdSystemTimer(r, name = "web.timer", content = "[Timer]\n",
      enabled = false, state = "stopped")
    systemdUnitState(r, name = "avahi-daemon.service", enabled = false,
      state = "Stopped")
    addOnTool(r, command = "ipmitool", aptClosureLock = "lock\n",
      program = "/usr/bin/ipmitool")
    fsSystemFile(r, path = "/etc/web/a.conf", content = "x", mode = "0640")
    fsSystemFile(r, path = "/etc/web/b.conf",
      sourceUrl = "https://example.org/b.conf", sha256 = repeat('a', 64))
    fsSystemFile(r, path = "/etc/web/c.conf", sourceLocal = "./c.conf")
    passwdUser(r, name = "web", shell = "/usr/sbin/nologin",
      extraGroups = @["adm"])
    passwdGroup(r, name = "web", gid = "990", members = @["web"])
    linuxTmpfilesRule(r, name = "web", content = "d /var/lib/web 0700",
      applyNow = false)
    linuxSysctl(r, key = "net.core.somaxconn", value = "1024",
      filename = "90-repro-web.conf")
    linuxFirewallRule(r, chain = "inet repro input", name = "web",
      protocol = "tcp", action = "accept", direction = "inbound",
      localPort = "443")
    # The collision opt-ins (A3), the unit-state and tool kinds, and the
    # switch's transition fields and classes (A4).
    systemdSystemUnit(r, name = "cron.service", content = "[Service]\n",
      collision = "dropIn", dropInName = "nice", restartIfChanged = false,
      stopOnRemoval = false, reloadIfChanged = true, exclusive = true,
      healthCheck = "http://127.0.0.1:8000/alive")
    systemdSystemDropIn(r, unit = "cron.service", name = "nice",
      content = "[Service]\nNice=5\n", restartIfChanged = false)
    linuxSysusersEntry(r, name = "web", kind = "user", id = "990",
      description = "web service", home = "/var/lib/web",
      shell = "/usr/sbin/nologin")
    fsSystemFile(r, path = "/etc/ssh/sshd_config", content = "x",
      collision = "divert")
    systemdUnitState(r, name = "avahi-daemon.service", enabled = true,
      state = "Running")
    addOnTool(r, command = "wakeonlan", aptClosureLock = LockText)
    # The diversion class has no profile constructor yet (its kind exists
    # on the apply side, A2); the intent is what the text form carries.
    r.add ResourceIntent(kind: "linux.dpkgDiversion",
      address: "dpkgDiversion:/etc/motd",
      fields: {"path": strField("/etc/motd")}.toTable)
    let p = projectResources(rp, r)
    var kinds = initHashSet[string]()
    for res in r:
      kinds.incl res.kind
    for k in rp.kinds:
      if k.class != fcInvalid:
        checkpoint k.kind
        check k.kind in kinds
    var fieldCount = 0
    for res in r:
      fieldCount += res.fields.len
    check p.entries.len == fieldCount
    for e in p.entries:
      check e.class in {fcShared, fcAddOnSpecific}
    # (b) The source scan.
    let emitted = constructorFieldsByKind()
    checkpoint $emitted
    # Vacuity: the scan sees the closure field and the unit-state kind.
    require emitted.hasKey("systemd.systemUnit")
    check "aptClosureLock" in emitted["systemd.systemUnit"]
    check emitted.hasKey("systemd.unitState")
    for k in rp.kinds:
      if k.class == fcInvalid or not emitted.hasKey(k.kind):
        continue
      var ruleFields = initHashSet[string]()
      for f in k.fields:
        ruleFields.incl f.field
      checkpoint k.kind & ": constructor emits " & $emitted[k.kind] &
        ", rule lists " & $ruleFields
      check emitted[k.kind] == ruleFields
    # Every realisable kind with a constructor was scanned (the kinds the
    # macro has no constructor for are listed, so this cannot pass by the
    # scan finding nothing).
    for k in rp.kinds:
      if k.class != fcInvalid and k.kind notin ["linux.dpkgDiversion"]:
        checkpoint k.kind
        check emitted.hasKey(k.kind)

  test "a firewall rule outside the add-on's own table is out of scope":
    var r: seq[ResourceIntent]
    linuxFirewallRule(r, chain = "inet filter input", name = "ssh",
      protocol = "tcp", action = "accept", localPort = "22")
    r[0].activity = "host_baseline"
    let e = refusal(proc () = discard projectResources(rp, r))
    require not e.isNil
    check e.diagnostic == adOutOfScope
    check e.field == "linux.firewallRule.chain"
    check e.activity == "host_baseline"
    check "EAddOnOutOfScope: " in e.msg
    check "activity `host_baseline`" in e.msg
    check "inet repro" in e.msg

  test "machine-only and foreign resource kinds are out of scope, naming field and activity":
    for (build, field) in [
        (proc (r: var seq[ResourceIntent]) =
          linuxNixosSystemModule(r, name = "boot", content = "{ }"),
         "linux.nixosSystemModule"),
        (proc (r: var seq[ResourceIntent]) =
          osHostname(r, hostname = "x"), "os.hostname"),
        (proc (r: var seq[ResourceIntent]) =
          linuxUdevRule(r, name = "u", content = "x"), "linux.udevRule"),
        (proc (r: var seq[ResourceIntent]) =
          windowsCapability(r, name = "OpenSSH", installed = true),
         "windows.capability")]:
      var r: seq[ResourceIntent]
      build(r)
      r[0].activity = "machine"
      let e = refusal(proc () = discard projectResources(rp, r))
      require not e.isNil
      check e.field == field
      check e.activity == "machine"
    # A profile-wide resource names no activity, and says so.
    var r: seq[ResourceIntent]
    osTimezone(r, tz = "UTC")
    let e = refusal(proc () = discard projectResources(rp, r))
    require not e.isNil
    check e.activity == ""
    check "the profile (no activity)" in e.msg

  test "an unclassified field of a classified kind is out of scope":
    var r: seq[ResourceIntent]
    systemdSystemUnit(r, name = "web.service", content = "[Unit]\n")
    r[0].fields["execStartPre"] = strField("/bin/true")
    let e = refusal(proc () = discard projectResources(rp, r))
    require not e.isNil
    check e.field == "systemd.systemUnit.execStartPre"
    check "does not classify this field" in e.msg

  test "machine configuration: invalid fields refuse, ignored fields are reported":
    let ok = projectMachineConfig(rp, SystemIntent(
      configs: @[SystemConfigEntry(key: "preferredDE")],
      users: @[SystemUserEntry(name: "op", groups: @["adm"],
        homeIntentImport: "./home.nim")],
      extraPackages: @["htop"]))
    let ignored = ignoredEntries(ok)
    check ignored.len == 1
    check ignored[0].field == "users.homeIntentImport"
    check "repro home apply" in describeEntry(ignored[0])
    for (si, hw, field) in [
        (SystemIntent(hostname: "h"), SystemHardwareSpec(), "hostname"),
        (SystemIntent(bootloader: SystemBootloaderSpec(kind: "grub")),
         SystemHardwareSpec(), "bootloader"),
        (SystemIntent(configs: @[SystemConfigEntry(key: "timezone")]),
         SystemHardwareSpec(), "configs.timezone"),
        (SystemIntent(services: SystemServiceList(enableList: @["sshd"])),
         SystemHardwareSpec(), "services.enableList"),
        (SystemIntent(), SystemHardwareSpec(kernelModules: @["kvm"]),
         "hardware.kernelModules"),
        (SystemIntent(), SystemHardwareSpec(filesystems: @[SystemHardwareFs(
          mountPoint: "/")]), "hardware.filesystems"),
        (SystemIntent(), SystemHardwareSpec(loaderDevice: "/dev/sda"),
         "hardware.loaderDevice")]:
      let e = refusal(proc () = discard projectMachineConfig(rp, si, hw))
      checkpoint field
      require not e.isNil
      check e.field == field

suite "add-on realisation through the system adapter":

  proc intentWithActivities(): ProfileIntent =
    result.activities.add ActivityIntent(name: "web")
    result.activities.add ActivityIntent(name: "legacy")
    systemdSystemUnit(result.resources, name = "base.service",
      content = "[Unit]\n", address = "base")
    systemdSystemUnit(result.resources, name = "web.service",
      content = "[Unit]\n", address = "web")
    result.resources[^1].activity = "web"
    # A NixOS module in an activity the add-on host does not select.
    linuxNixosSystemModule(result.resources, name = "legacy.nix",
      content = "{ }", address = "legacy")
    result.resources[^1].activity = "legacy"

  test "an add-on target projects only what its selection picks":
    let intent = intentWithActivities()
    let addOn = adaptSystemProfile(intent, systemPlanTarget("rpi",
      toHashSet(["default", "web"]), srAddOnDebian))
    var addrs: seq[string]
    for r in addOn.profile.resources:
      addrs.add r.address
    check addrs == @["base", "web"]
    check addOn.projection.profile == "add-on-debian"
    check addOn.projection.entries.len > 0
    # Selecting the activity that carries the machine-only resource refuses
    # the host, naming the field and that activity.
    let e = refusal(proc () = discard adaptSystemProfile(intent,
      systemPlanTarget("rpi", toHashSet(["default", "legacy"]),
        srAddOnDebian)))
    require not e.isNil
    check e.field == "linux.nixosSystemModule"
    check e.activity == "legacy"
    # A full target applies the same selection without projecting.
    let full = adaptSystemProfile(intent, systemPlanTarget("pc",
      toHashSet(["default", "legacy"])))
    check full.profile.resources.len == 2
    check full.projection.entries.len == 0

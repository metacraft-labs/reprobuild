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
## 2. Every field the resource CONSTRUCTORS of the realisable kinds emit is
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

import std/[sets, strutils, tables, unittest]

import repro_profile
import repro_profile_compile
import repro_infra/addon_diagnostics

proc refusal(body: proc ()): ref EAddOnOutOfScope =
  ## The `EAddOnOutOfScope` `body` raises, or nil.
  try:
    body()
  except EAddOnOutOfScope as e:
    return e
  nil

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

  test "every field the realisable kinds' constructors emit is classified":
    var r: seq[ResourceIntent]
    systemdSystemUnit(r, name = "web.service", content = "[Unit]\n",
      enabled = true)
    systemdSystemTimer(r, name = "web.timer", content = "[Timer]\n",
      enabled = true, state = "started")
    fsSystemFile(r, path = "/etc/web/a.conf", content = "x", mode = "0640")
    fsSystemFile(r, path = "/etc/web/b.conf",
      sourceUrl = "https://example.org/b.conf", sha256 = repeat('a', 64))
    fsSystemFile(r, path = "/etc/web/c.conf", sourceLocal = "./c.conf")
    passwdUser(r, name = "web", shell = "/usr/sbin/nologin",
      extraGroups = @["adm"])
    passwdGroup(r, name = "web", gid = "990", members = @["web"])
    linuxTmpfilesRule(r, name = "web", content = "d /var/lib/web 0700",
      applyNow = true)
    linuxSysctl(r, key = "net.core.somaxconn", value = "1024",
      filename = "90-repro-web.conf")
    linuxFirewallRule(r, chain = "inet repro input", name = "web",
      protocol = "tcp", action = "accept", direction = "inbound",
      localPort = "443")
    # The diversion class has no profile constructor yet (its kind exists
    # on the apply side, A2); the intent is what the text form carries.
    r.add ResourceIntent(kind: "linux.dpkgDiversion",
      address: "dpkgDiversion:/etc/motd",
      fields: {"path": strField("/etc/motd")}.toTable)
    let p = projectResources(rp, r)
    var kinds = initHashSet[string]()
    for res in r:
      kinds.incl res.kind
    # Every realisable kind was exercised, and every emitted field is in the
    # projection report.
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

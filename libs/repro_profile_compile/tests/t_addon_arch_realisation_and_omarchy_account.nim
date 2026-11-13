## The `add-on-arch` realisation profile and the `addOn` stanza's
## `omarchyAccount` (ReproOS Add-On Mode spec §8.1, §8.3 *Services on
## Arch*, §8.5; §13 decisions 92 and 94).
##
## 1. `add-on-arch` is `add-on-debian` with two differences: an
##    `aptClosureLock` (on a unit or an add-on tool) is `EAddOnOutOfScope`
##    naming "`.deb` closures are not supported on Arch", refused when the
##    profile is projected -- before anything is realised -- and the
##    diversion kind is invalid (pacman has no diversions). Every other kind
##    and field has the class it has on Debian, which is what makes the
##    derived profile exhaustive whenever the Debian one is.
## 2. The same unit with a store package (no `aptClosureLock`) projects.
## 3. The registry realises an Arch-family `addOn` host as `add-on-arch`
##    and refuses an Arch host with no `system:` key (`EAddOnModeMismatch`).
## 4. `omarchyAccount` travels the whole compiled-profile path -- intent,
##    JSON, RBPI, adapter, text renderer -- and the text parser reads and
##    refuses it as the DSL's path does.
##
## No mocks: the real constructors, codecs, adapter, registry and parser.

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_infra
import repro_infra/addon_diagnostics
import repro_infra/host_base
import repro_cli_support/infra_host_registry

const LockText = staticRead("../../repro_dsl_stdlib/tests/fixtures/" &
  "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

proc refusal(body: proc ()): ref EAddOnOutOfScope =
  try:
    body()
  except EAddOnOutOfScope as e:
    return e
  nil

proc archTarget(): SystemPlanTarget =
  systemPlanTarget("archbox", toHashSet(["default"]), srAddOnArch)

suite "the add-on-arch realisation profile":
  test "it is add-on-debian with the .deb closure and diversion refused":
    let deb = addOnDebianProfile()
    let arch = addOnArchProfile()
    check arch.name == "add-on-arch"
    check arch.kinds.len == deb.kinds.len
    for i, k in arch.kinds:
      check k.kind == deb.kinds[i].kind
      if k.kind == "linux.dpkgDiversion":
        check k.class == fcInvalid
        continue
      check k.class == deb.kinds[i].class
      check k.fields.len == deb.kinds[i].fields.len
      for j, f in k.fields:
        check f.field == deb.kinds[i].fields[j].field
        if f.field == "aptClosureLock":
          check f.class == fcInvalid
          check DebClosuresNotOnArch in f.reason
        else:
          check f.class == deb.kinds[i].fields[j].class
    check arch.machineFields == deb.machineFields

  test "a unit with an aptClosureLock is refused at projection, naming .deb closures":
    var p = ProfileIntent(name: "archbox")
    systemdSystemUnit(p.resources, name = "node-exporter.service",
      content = "[Service]\nExecStart=/usr/bin/prometheus-node-exporter\n",
      aptClosureLock = LockText, address = "ne")
    let e = refusal(proc () = discard adaptSystemProfile(p, archTarget()))
    require not e.isNil
    check e.field == "systemd.systemUnit.aptClosureLock"
    check "EAddOnOutOfScope" in e.msg
    check ".deb` closures are not supported on Arch" in e.msg
    # The same profile on Debian projects (the closure is Debian's own).
    discard adaptSystemProfile(p, systemPlanTarget("deb",
      toHashSet(["default"]), srAddOnDebian))

  test "the same unit as a store package plans on Arch":
    var p = ProfileIntent(name: "archbox")
    systemdSystemUnit(p.resources, name = "fixture.service",
      content = "[Service]\nExecStart=/repro/store/prefixes/fixture/1-0123456789abcdef/bin/fixture\n",
      address = "fx")
    let adapted = adaptSystemProfile(p, archTarget())
    check adapted.projection.profile == "add-on-arch"
    check adapted.profile.resources.len == 1
    check "aptClosureLock" notin p.resources[0].fields

  test "a diversion is invalid on Arch":
    let rp = addOnArchProfile()
    let r = ResourceIntent(kind: "linux.dpkgDiversion", address: "d",
      fields: {"path": FieldValue(kind: fvkString, s: "/etc/x")}.toTable)
    var into: Projection
    let e = refusal(proc () = projectResource(rp, r, into))
    require not e.isNil
    check e.field == "linux.dpkgDiversion"
    check "pacman has no diversions" in e.msg

suite "the registry on an Arch-family base":
  proc base(id, idLike: string): HostBase =
    var osr = initTable[string, string]()
    osr["ID"] = id
    if idLike.len > 0: osr["ID_LIKE"] = idLike
    classifyHostBase(osr, "/etc/os-release", true)

  test "Arch and Omarchy are Arch-family distributions":
    check base("arch", "").isArchFamily
    check base("omarchy", "arch").isArchFamily
    check not base("omarchy", "").isArchFamily
    check not base("debian", "").isArchFamily
    check not base("arch", "").isDebianFamily

proc verdict(declared, spelled: bool; mode: ManagementMode):
    HostRegistryVerdict =
  ## A registry entry for `archbox` as `readHostRegistry` reports it (the
  ## registry's own compile is covered by `t_addon_mode_mismatch_is_refused`).
  HostRegistryVerdict(registryPath: "home.nim", host: "archbox",
    management: HostSystemManagement(declared: declared, spelled: spelled,
      mode: mode))

suite "the registry selects add-on-arch":
  test "an addOn Arch host is realised add-on-arch, an Omarchy one too":
    let v = verdict(true, true, mmAddOn)
    for osr in [{"ID": "arch"}.toTable,
                {"ID": "omarchy", "ID_LIKE": "arch"}.toTable]:
      let b = classifyHostBase(osr, "/etc/os-release", true)
      checkHostSystemMode(v, b)
      check realisationFor(v, b) == srAddOnArch

  test "an Arch host with no system: key is refused, asking for addOn":
    let v = verdict(true, false, mmFull)
    let b = classifyHostBase({"ID": "arch"}.toTable, "/etc/os-release", true)
    try:
      checkHostSystemMode(v, b)
      check false
    except EAddOnModeMismatch as e:
      check "system: addOn" in e.msg

suite "omarchyAccount through the compiled-profile path":
  proc intent(account: string): ProfileIntent =
    result = ProfileIntent(name: "archbox")
    result.addOn = AddOnIntent(declared: true,
      managedEtcPrefixes: @["/etc/fixture/"], omarchyAccount: account)

  test "intent, JSON, RBPI, adapter and text carry it":
    let p = intent("zahary")
    check parseProfileIntentJson(emitProfileIntentJson(p)).addOn.omarchyAccount ==
      "zahary"
    check decodeRbpi(encodeRbpi(p)).addOn.omarchyAccount == "zahary"
    let sp = adaptSystemProfile(p, archTarget()).profile
    check sp.addOn.omarchyAccount == "zahary"
    let text = renderSystemProfileToText(sp)
    check "  omarchyAccount = \"zahary\"\n" in text
    check parseSystemProfile(text).addOn == sp.addOn
    check renderProfileText(parseSystemProfile(text)) ==
      renderProfileText(sp)
    # Absent, nothing is emitted: a profile without it encodes as before.
    let bare = intent("")
    check "omarchyAccount" notin emitProfileIntentJson(bare)
    check "omarchyAccount" notin renderSystemProfileToText(
      adaptSystemProfile(bare, archTarget()).profile)

  test "a name that cannot be an account is refused on both paths":
    for bad in ["", "-x", ".x", "a/b", "a b", "x".repeat(33)]:
      check omarchyAccountNameError(bad).len > 0
    check omarchyAccountNameError("zahary").len == 0
    expect ValueError:
      discard adaptSystemProfile(intent("a/b"), archTarget())
    expect ESystemProfileInvalid:
      discard parseSystemProfile("addOn {\n  managedEtcPrefixes = []\n" &
        "  omarchyAccount = \"../root\"\n}\n")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("addOn {\n  omarchyAccount = zahary\n}\n")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("addOn {\n  omarchyAccount = \"a\"\n" &
        "  omarchyAccount = \"b\"\n}\n")

suite "omarchyAccount in the Nim DSL":
  test "the addOn: section's omarchyAccount reaches the compiled intent":
    # The real profile compiler: the macro is only exercised by compiling a
    # profile with it.
    let dir = createTempDir("repro-ar1-omarchy-dsl-", "")
    writeFile(dir / "system.nim", "import repro_profile\n\n" &
      "profile \"archbox\":\n  addOn:\n    managedEtcPrefixes:\n" &
      "      \"/etc/fixture/\"\n    omarchyAccount: \"zahary\"\n" &
      "  resources:\n    fsSystemFile(path = \"/etc/fixture/a\", " &
      "content = \"a\\n\", address = \"a\")\n")
    let res = compileProfileBinary(profileRoot = dir / "system.nim",
      nimcacheDir = dir / "nimcache", outBinary = dir / "nimcache" / "profile",
      repoRoot = reprobuildRepoRoot(), verbose = false)
    let intent = decodeRbpi(rbpiBytesFromJson(res.jsonOutput))
    check intent.addOn.declared
    check intent.addOn.omarchyAccount == "zahary"
    check intent.addOn.managedEtcPrefixes == @["/etc/fixture/"]
    removeDir(dir)

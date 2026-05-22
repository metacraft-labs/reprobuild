## Smoke test for the M68 home-scope resource lifecycle.
##
## Pins:
##   - the umbrella import compiles on every platform
##   - the lifecycle algorithm decides create / no-op / update /
##     destroy correctly for the documented (desired, observed,
##     recorded) tuples
##   - drift detection on update raises `EDrift` by default and
##     is collapsed to `rakUpdate` under `rpReconcileDrift`
##   - the registry-typed value encodings round-trip through the
##     payload byte representation

import std/[strutils, tables, unittest]

import repro_home_resources

suite "M68 smoke: home resource lifecycle":

  test "lifecycle: create on first apply":
    var desired = Resource(kind: rkWindowsRegistryValue,
      address: "test:create",
      registryKey: "HKCU\\Software\\Reprobuild-Tests\\Smoke",
      registryName: "Hello")
    desired.registryPayload.kind = rvkString
    desired.registryPayload.bytes = encodeString("world")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = false
    state.hasRecorded = false
    let action = decideAction(state)
    check action.kind == rakCreate
    check action.resourceKind == rkWindowsRegistryValue

  test "lifecycle: no-op when observed matches desired":
    var desired = Resource(kind: rkFsManagedBlock,
      address: "test:noop",
      hostFilePath: "/tmp/host",
      managedBlockId: "block-1",
      managedBlockContent: "PATH=/foo")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    let want = digestOfResource(desired)
    state.observed.digest = want
    state.observed.rawBytes = @[]
    let action = decideAction(state)
    check action.kind == rakNoOp

  test "lifecycle: safe update when recorded matches observed":
    var desired = Resource(kind: rkFsManagedBlock,
      address: "test:update",
      hostFilePath: "/tmp/host",
      managedBlockId: "block-1",
      managedBlockContent: "PATH=/new")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    state.observed.digest = digestOfBytes(@[byte('o'), byte('l'), byte('d')])
    state.hasRecorded = true
    state.recorded.kind = rkFsManagedBlock
    state.recorded.postWriteDigest = state.observed.digest
    state.recorded.hasPreWriteDigest = false
    let action = decideAction(state)
    check action.kind == rakUpdate

  test "lifecycle: drift_blocked when recorded != observed":
    var desired = Resource(kind: rkFsManagedBlock,
      address: "test:drift",
      hostFilePath: "/tmp/host",
      managedBlockId: "block-1",
      managedBlockContent: "PATH=/desired")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    state.observed.digest = digestOfBytes(@[byte('u'), byte('s'), byte('r')])
    state.hasRecorded = true
    state.recorded.kind = rkFsManagedBlock
    state.recorded.postWriteDigest =
      digestOfBytes(@[byte('w'), byte('e'), byte('w')])
    let action = decideAction(state)
    check action.kind == rakDriftBlocked
    check action.driftExpectedHex.len == 64
    check action.driftObservedHex.len == 64

  test "lifecycle: drift collapses to update with reconcile-drift":
    var desired = Resource(kind: rkFsManagedBlock,
      address: "test:reconcile",
      hostFilePath: "/tmp/host",
      managedBlockId: "block-1",
      managedBlockContent: "PATH=/desired")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    state.observed.digest = digestOfBytes(@[byte('a')])
    state.hasRecorded = true
    state.recorded.kind = rkFsManagedBlock
    state.recorded.postWriteDigest = digestOfBytes(@[byte('b')])
    var opts: DecisionOptions
    opts.reconcile = rpReconcileDrift
    let action = decideAction(state, opts)
    check action.kind == rakUpdate

  test "lifecycle: safe destroy when recorded matches observed":
    var state: ResourceState
    state.address = "test:destroy"
    state.hasDesired = false
    state.observed.present = true
    state.observed.digest = digestOfBytes(@[byte('x')])
    state.hasRecorded = true
    state.recorded.kind = rkWindowsRegistryValue
    state.recorded.postWriteDigest = state.observed.digest
    let action = decideAction(state)
    check action.kind == rakDestroy

  test "registry: typed value kinds round-trip":
    let s = encodeString("hello")
    # UTF-16LE encoding: "hello" = 5 chars * 2 + 2 bytes terminator
    check s.len == 12
    let d = encodeDword(0x12345678'u32)
    check d.len == 4
    check d[0] == 0x78'u8
    check d[3] == 0x12'u8
    let q = encodeQword(0x123456789ABCDEF0'u64)
    check q.len == 8
    check q[0] == 0xF0'u8
    check q[7] == 0x12'u8
    let ms = encodeMultiString(@["foo", "bar"])
    let parsed = decodeMultiString(ms)
    check parsed == @["foo", "bar"]

  test "manifest record: round-trip preserves payload":
    var observed: ObservedState
    observed.present = false
    observed.digest = zeroDigest()
    let rb = toResourceBinding("test:address", rkWindowsRegistryValue,
      "HKCU\\Software\\Foo\\Bar", observed,
      @[byte(0x01), byte(0x02), byte(0x03)], "dword", lpDefault)
    check rb.resourceKind == "windows.registryValue"
    check rb.payloadKind == "dword"
    check rb.payloadBytes.len == 3
    check rb.postWriteDigest != zeroDigest()
    check not rb.hasPreWriteDigest

  test "plan: empty desired set produces zero actions":
    let desired = initDesiredSet()
    var recorded = initOrderedTable[string, RecordedBinding]()
    let report = composePlan(desired, recorded)
    check report.actions.len == 0
    check report.driftCount == 0
    check report.changedCount == 0

  test "plan: rendering contains the header line":
    let desired = initDesiredSet()
    var recorded = initOrderedTable[string, RecordedBinding]()
    let report = composePlan(desired, recorded)
    let rendered = renderPlan(report)
    check rendered.startsWith("repro home plan: 0 resource(s) planned")

  # ----------------------------------------------------------------
  # Wrong-platform fail-closed: each Phase B driver must raise
  # ENotImplementedPlatform on a host whose OS does not match the
  # driver's required platform. Strongly-typed expect: the exception
  # type itself, NOT the Exception base.
  # ----------------------------------------------------------------

  test "phase-B: linux.gsettings raises ENotImplementedPlatform off-Linux":
    when not defined(linux):
      expect ENotImplementedPlatform:
        discard applyGsettings("org.gnome.desktop.interface", "",
          "color-scheme", "'prefer-dark'")
      try:
        discard applyGsettings("org.gnome.desktop.interface", "",
          "color-scheme", "'prefer-dark'")
        check false  # unreachable
      except ENotImplementedPlatform as e:
        check e.resourceKind == "linux.gsettings"
        check e.requiredPlatform == "linux"
        check e.currentPlatform != "linux"
    else:
      skip()

  test "phase-B: macos.userDefault raises ENotImplementedPlatform off-macOS":
    when not defined(macosx):
      expect ENotImplementedPlatform:
        discard applyUserDefault("com.example.test", "DummyKey",
          "1", "", false)
      try:
        discard applyUserDefault("com.example.test", "DummyKey",
          "1", "", false)
        check false  # unreachable
      except ENotImplementedPlatform as e:
        check e.resourceKind == "macos.userDefault"
        check e.requiredPlatform == "macosx"
        check e.currentPlatform != "macosx"
    else:
      skip()

  test "phase-B: systemd.userUnit raises ENotImplementedPlatform off-Linux":
    when not defined(linux):
      # Picks a path that MUST NOT be touched on the wrong platform.
      # If the fail-closed gate ever regresses, this path would appear
      # on disk and surface a separate filesystem fingerprint.
      expect ENotImplementedPlatform:
        discard applyUserUnit("/tmp/repro-m68-smoke-systemd",
          "repro-smoke.service", "[Unit]\nDescription=smoke\n", false)
      try:
        discard applyUserUnit("/tmp/repro-m68-smoke-systemd",
          "repro-smoke.service", "[Unit]\nDescription=smoke\n", false)
        check false  # unreachable
      except ENotImplementedPlatform as e:
        check e.resourceKind == "systemd.userUnit"
        check e.requiredPlatform == "linux"
    else:
      skip()

  test "phase-B: launchd.userAgent raises ENotImplementedPlatform off-macOS":
    when not defined(macosx):
      expect ENotImplementedPlatform:
        discard applyLaunchAgent("/tmp/repro-m68-smoke-launchd",
          "com.example.repro.smoke", "<plist/>", false)
      try:
        discard applyLaunchAgent("/tmp/repro-m68-smoke-launchd",
          "com.example.repro.smoke", "<plist/>", false)
        check false  # unreachable
      except ENotImplementedPlatform as e:
        check e.resourceKind == "launchd.userAgent"
        check e.requiredPlatform == "macosx"
    else:
      skip()

  # ----------------------------------------------------------------
  # Phase B pure-function unit tests. The Linux/macOS drivers'
  # shell-out to gsettings / defaults / systemctl / launchctl can
  # only run on the target OS, but the GVariant encode/parse, the
  # macOS structural comparison, and the launchd plist generation
  # are pure — they run on Windows and are pinned here.
  # ----------------------------------------------------------------

  test "gsettings: GVariant encoder covers the common types":
    check encodeGVariant(GVariantValue(kind: gvkString,
      strVal: "prefer-dark")) == "'prefer-dark'"
    check encodeGVariant(GVariantValue(kind: gvkBool,
      boolVal: true)) == "true"
    check encodeGVariant(GVariantValue(kind: gvkBool,
      boolVal: false)) == "false"
    check encodeGVariant(GVariantValue(kind: gvkInt32,
      intVal: 42'i32)) == "42"
    check encodeGVariant(GVariantValue(kind: gvkStringArray,
      arrVal: @["a", "b"])) == "['a', 'b']"
    # Embedded quote / backslash are escaped.
    check encodeGVariant(GVariantValue(kind: gvkString,
      strVal: "it's")) == "'it\\'s'"
    # Double always carries a decimal point.
    let dbl = encodeGVariant(GVariantValue(kind: gvkDouble, dblVal: 1.0))
    check '.' in dbl

  test "gsettings: GVariant parser round-trips the encoder":
    for v in [
        GVariantValue(kind: gvkString, strVal: "prefer-dark"),
        GVariantValue(kind: gvkString, strVal: "has 'quote'"),
        GVariantValue(kind: gvkBool, boolVal: true),
        GVariantValue(kind: gvkBool, boolVal: false),
        GVariantValue(kind: gvkInt32, intVal: -7'i32),
        GVariantValue(kind: gvkStringArray, arrVal: @["x", "y", "z"]),
        GVariantValue(kind: gvkStringArray, arrVal: @[])]:
      let parsed = parseGVariant(encodeGVariant(v))
      check parsed.kind == v.kind
      case v.kind
      of gvkString: check parsed.strVal == v.strVal
      of gvkBool: check parsed.boolVal == v.boolVal
      of gvkInt32: check parsed.intVal == v.intVal
      of gvkDouble: check parsed.dblVal == v.dblVal
      of gvkStringArray: check parsed.arrVal == v.arrVal

  test "gsettings: relocatable schema spec uses the path form":
    check gsettingsSchemaSpec("org.gnome.desktop.interface", "") ==
      "org.gnome.desktop.interface"
    check gsettingsSchemaSpec("org.gnome.x.custom-keybinding",
      "/org/gnome/x/custom-keybindings/custom0/") ==
      "org.gnome.x.custom-keybinding:" &
      "/org/gnome/x/custom-keybindings/custom0/"

  test "defaults: structural comparison ignores dict key order":
    # A dict with reordered keys is structurally equal.
    check defaultsValuesEqual(
      "{ a = 1; b = 2; }", "{ b = 2; a = 1; }")
    # Whitespace variation does not matter.
    check defaultsValuesEqual(
      "{a=1;b=2;}", "{  a = 1 ;\n  b = 2 ;\n}")
    # A genuinely different value is NOT equal.
    check not defaultsValuesEqual(
      "{ a = 1; b = 2; }", "{ a = 1; b = 3; }")
    # Scalars compare by value.
    check defaultsValuesEqual("  true ", "true")

  test "defaults: structural comparison keeps array order significant":
    # Arrays are ordered — reordering elements IS a real change.
    check not defaultsValuesEqual("( 1, 2, 3 )", "( 3, 2, 1 )")
    check defaultsValuesEqual("( 1, 2, 3 )", "(1,2,3)")
    # Nested dict inside an array, key-reordered, still equal.
    check defaultsValuesEqual(
      "( { x = 1; y = 2; } )", "( { y = 2; x = 1; } )")

  test "defaults: container-domain detection":
    check isContainerDomain(
      "/Users/me/Library/Containers/com.app/Data/Library/" &
      "Preferences/com.app.plist")
    check not isContainerDomain("com.apple.dock")

  test "launchd: plist generator emits a valid-shaped plist":
    let plist = buildLaunchAgentPlist("com.example.repro-dev",
      @["/usr/bin/true", "--flag"], runAtLoad = true)
    check plist.contains("<key>Label</key>")
    check plist.contains("<string>com.example.repro-dev</string>")
    check plist.contains("<key>ProgramArguments</key>")
    check plist.contains("<string>/usr/bin/true</string>")
    check plist.contains("<string>--flag</string>")
    check plist.contains("<key>RunAtLoad</key>")
    check plist.contains("<true/>")
    check plist.startsWith("<?xml version=\"1.0\"")
    # XML-significant characters in args are escaped.
    let escaped = buildLaunchAgentPlist("com.x",
      @["a & b <c>"], runAtLoad = false)
    check escaped.contains("a &amp; b &lt;c&gt;")
    check escaped.contains("<false/>")

  test "launchd: agent plist path derivation":
    check agentPlistPath("/home/user", "com.x") ==
      "/home/user/Library/LaunchAgents/com.x.plist"
    # Trailing slash on the home dir is normalized away.
    check agentPlistPath("/home/user/", "com.x") ==
      "/home/user/Library/LaunchAgents/com.x.plist"

  test "systemd: user-unit path derivation":
    check userUnitPath("/home/user", "repro-dev.service") ==
      "/home/user/.config/systemd/user/repro-dev.service"
    check userUnitPath("/home/user/", "repro-dev.service") ==
      "/home/user/.config/systemd/user/repro-dev.service"

  test "lifecycle: preventDestroy refuses the destroy (absolute)":
    # A recorded resource carrying lpPreventDestroy that is no
    # longer desired must raise EPreventDestroy when enforcement is
    # on — even under rpAcceptOverwrite.
    var state: ResourceState
    state.address = "test:prevent-destroy"
    state.hasDesired = false
    state.observed.present = true
    state.observed.digest = digestOfBytes(@[byte('z')])
    state.hasRecorded = true
    state.recorded.kind = rkWindowsRegistryValue
    state.recorded.postWriteDigest = state.observed.digest
    state.recorded.lifecyclePolicy = lpPreventDestroy
    # Enforcement off (Phase A behaviour): produces a plain destroy.
    let actionWhenDisabled = decideAction(state, DecisionOptions(
      reconcile: rpFailClosed, enforcePreventDestroy: false))
    check actionWhenDisabled.kind == rakDestroy
    # Enforcement on: raises regardless of reconcile policy.
    expect EPreventDestroy:
      discard decideAction(state, DecisionOptions(reconcile: rpFailClosed,
        enforcePreventDestroy: true))
    expect EPreventDestroy:
      discard decideAction(state, DecisionOptions(
        reconcile: rpAcceptOverwrite, enforcePreventDestroy: true))

# ---------------------------------------------------------------------------
# Defence-in-depth: pre-dispatch shell-injection validation.
#
# The four POSIX/macOS home drivers (`gsettings`, `defaults`,
# `systemd_user`, `launchd_user`) interpolate operator-controlled
# typed fields into shell command lines. `resourceValidationError`
# (layer 1) must REJECT any value bearing a shell metacharacter or
# falling outside its closed identifier set, before the value can
# reach a driver — the drivers also `quoteShell` the field (layer
# 2). These are cross-platform pure-logic tests.
# ---------------------------------------------------------------------------

suite "M68 security: shell-injection field validation":

  # The shell metacharacters / whitespace a malicious or malformed
  # field value might carry. `/` is NOT here: a `/` is not a shell
  # metacharacter, and a gsettings RELOCATABLE-schema path
  # legitimately contains `/` — it must stay accepted. The
  # single-segment kinds (launchd label, systemd unit name) ALSO
  # reject `/` via `segmentInjectionChars` below.
  const shellMetaChars = [";", " ", "$", "`", "&", "|", "\n",
    "\t", "\r", "\"", "'", "(", ")", "*", "?", ">", "<"]
  # The single-path-segment kinds reject every shell metacharacter
  # AND `/` (a launchd label / systemd unit name must not escape its
  # one path segment).
  const segmentInjectionChars = @shellMetaChars & @["/"]

  test "isSafeLaunchdLabel: accepts a legitimate reverse-DNS label":
    check isSafeLaunchdLabel("com.metacraft.repro.agent")
    check isSafeLaunchdLabel("repro-dev_agent.v2")
    check isSafeLaunchdLabel("A0")

  test "isSafeLaunchdLabel: rejects metacharacters / empty / dot":
    check not isSafeLaunchdLabel("")
    check not isSafeLaunchdLabel("   ")
    check not isSafeLaunchdLabel(".")
    check not isSafeLaunchdLabel("..")
    for c in segmentInjectionChars:
      check not isSafeLaunchdLabel("com.x" & c & "evil")
    # A label that is `quoteShell`-safe but still not a launchd
    # identifier is rejected too (charset is closed, not just
    # metacharacter-blocking).
    check not isSafeLaunchdLabel("com.x:evil")
    check not isSafeLaunchdLabel("com.x=evil")

  test "hasShellMetacharacter: flags every injection character":
    check not hasShellMetacharacter("com.metacraft.repro")
    check not hasShellMetacharacter("repro-dev.service")
    check not hasShellMetacharacter("org.gnome.desktop.interface")
    # `/` is deliberately NOT a shell metacharacter.
    check not hasShellMetacharacter("/org/gnome/desktop/")
    for c in shellMetaChars:
      check hasShellMetacharacter("safe" & c & "tail")

  test "resourceValidationError: clean POSIX/macOS resources pass":
    # A well-formed resource of each shell-out kind validates clean.
    check resourceValidationError(Resource(kind: rkLaunchdUserAgent,
      address: "agent:ok", launchdLabel: "com.metacraft.repro.agent",
      launchdPlistContent: "<plist/>")) == ""
    check resourceValidationError(Resource(kind: rkMacosUserDefault,
      address: "default:ok", defaultsDomain: "com.apple.dock",
      defaultsKey: "autohide", defaultsValueLiteral: "1",
      defaultsRestartTarget: "Dock")) == ""
    check resourceValidationError(Resource(kind: rkLinuxGsettings,
      address: "gset:ok", gsettingsSchema: "org.gnome.desktop.interface",
      gsettingsKey: "clock-format", gsettingsPath: "",
      gsettingsValueLiteral: "'24h'")) == ""
    check resourceValidationError(Resource(kind: rkSystemdUserUnit,
      address: "unit:ok", unitName: "repro-dev.service",
      unitContent: "[Unit]\n", unitEnabled: true)) == ""
    # A `gsettings` value literal LEGITIMATELY carries spaces / quotes
    # / brackets — it must NOT be rejected by validation (layer 2
    # `quoteShell` protects it).
    check resourceValidationError(Resource(kind: rkLinuxGsettings,
      address: "gset:arr", gsettingsSchema: "org.gnome.shell",
      gsettingsKey: "favorite-apps", gsettingsPath: "",
      gsettingsValueLiteral: "['a.desktop', 'b.desktop']")) == ""
    # Windows / pure-IO driver kinds have nothing to shell-validate.
    check resourceValidationError(Resource(kind: rkFsManagedBlock,
      address: "fs:ok", hostFilePath: "/tmp/x; rm -rf /",
      managedBlockId: "blk", managedBlockContent: "")) == ""

  test "resourceValidationError: rejects an injected launchd label":
    for c in segmentInjectionChars:
      let r = Resource(kind: rkLaunchdUserAgent, address: "agent:evil",
        launchdLabel: "com.x" & c & "touch /tmp/pwn",
        launchdPlistContent: "<plist/>")
      check resourceValidationError(r).len > 0
    # Empty label is also refused.
    check resourceValidationError(Resource(kind: rkLaunchdUserAgent,
      address: "agent:empty", launchdLabel: "",
      launchdPlistContent: "<plist/>")).len > 0

  test "resourceValidationError: rejects an injected macos.userDefault":
    for c in shellMetaChars:
      # Injected domain.
      check resourceValidationError(Resource(kind: rkMacosUserDefault,
        address: "d:evil-domain",
        defaultsDomain: "com.apple.dock" & c & "evil",
        defaultsKey: "autohide", defaultsValueLiteral: "1")).len > 0
      # Injected key.
      check resourceValidationError(Resource(kind: rkMacosUserDefault,
        address: "d:evil-key", defaultsDomain: "com.apple.dock",
        defaultsKey: "autohide" & c & "evil",
        defaultsValueLiteral: "1")).len > 0
      # Injected restartTarget (flows into `killall <target>`).
      check resourceValidationError(Resource(kind: rkMacosUserDefault,
        address: "d:evil-target", defaultsDomain: "com.apple.dock",
        defaultsKey: "autohide", defaultsValueLiteral: "1",
        defaultsRestartTarget: "Dock" & c & "evil")).len > 0

  test "resourceValidationError: rejects an injected gsettings field":
    for c in shellMetaChars:
      # Injected schema.
      check resourceValidationError(Resource(kind: rkLinuxGsettings,
        address: "g:evil-schema",
        gsettingsSchema: "org.gnome.x" & c & "evil",
        gsettingsKey: "k", gsettingsPath: "")).len > 0
      # Injected key.
      check resourceValidationError(Resource(kind: rkLinuxGsettings,
        address: "g:evil-key", gsettingsSchema: "org.gnome.x",
        gsettingsKey: "k" & c & "evil", gsettingsPath: "")).len > 0
      # Injected relocatable-schema path.
      check resourceValidationError(Resource(kind: rkLinuxGsettings,
        address: "g:evil-path", gsettingsSchema: "org.gnome.x",
        gsettingsKey: "k",
        gsettingsPath: "/org/x" & c & "evil/")).len > 0

  test "resourceValidationError: rejects an injected systemd unit name":
    for c in segmentInjectionChars:
      check resourceValidationError(Resource(kind: rkSystemdUserUnit,
        address: "u:evil", unitName: "repro" & c & "evil.service",
        unitContent: "[Unit]\n", unitEnabled: false)).len > 0
    # Empty unit name is refused.
    check resourceValidationError(Resource(kind: rkSystemdUserUnit,
      address: "u:empty", unitName: "", unitContent: "",
      unitEnabled: false)).len > 0

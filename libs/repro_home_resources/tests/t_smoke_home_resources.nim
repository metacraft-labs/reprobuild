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

import std/[os, strutils, tables, tempfiles, unittest]

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

# ---------------------------------------------------------------------------
# fs.userFile driver: whole-file ownership at a `~`-relative `$HOME`
# path. These tests are platform-pure — `applyUserFileResource` and
# `observeUserFile` only touch the filesystem.
# ---------------------------------------------------------------------------

suite "M68 fs.userFile driver":

  test "parseModeOctal: accepts well-formed permission strings":
    check parseModeOctal("0600") == 0o600
    check parseModeOctal("0644") == 0o644
    check parseModeOctal("0755") == 0o755
    # Bare 3-digit form is accepted (chmod also accepts `chmod 644`).
    check parseModeOctal("644") == 0o644
    check parseModeOctal("755") == 0o755

  test "parseModeOctal: rejects malformed mode strings":
    # Empty.
    expect ValueError:
      discard parseModeOctal("")
    # Non-octal digit (8/9).
    expect ValueError:
      discard parseModeOctal("0888")
    expect ValueError:
      discard parseModeOctal("0999")
    # Non-digit character.
    expect ValueError:
      discard parseModeOctal("rwx")
    expect ValueError:
      discard parseModeOctal("0o644")
    # Too long.
    expect ValueError:
      discard parseModeOctal("12345")

  test "filePermissionsFromMode: 0644 maps to rw-r--r--":
    let p = filePermissionsFromMode("0644")
    check fpUserRead in p
    check fpUserWrite in p
    check fpUserExec notin p
    check fpGroupRead in p
    check fpGroupWrite notin p
    check fpGroupExec notin p
    check fpOthersRead in p
    check fpOthersWrite notin p
    check fpOthersExec notin p

  test "filePermissionsFromMode: 0755 maps to rwxr-xr-x":
    let p = filePermissionsFromMode("0755")
    check fpUserRead in p
    check fpUserWrite in p
    check fpUserExec in p
    check fpGroupRead in p
    check fpGroupWrite notin p
    check fpGroupExec in p
    check fpOthersRead in p
    check fpOthersWrite notin p
    check fpOthersExec in p

  test "filePermissionsFromMode: 0600 maps to rw-------":
    let p = filePermissionsFromMode("0600")
    check fpUserRead in p
    check fpUserWrite in p
    check fpUserExec notin p
    check fpGroupRead notin p
    check fpOthersRead notin p

  test "applyUserFileResource: fresh write creates the file":
    let dir = createTempDir("repro-userfile-fresh-", "")
    defer: removeDir(dir)
    let target = dir / "config.txt"
    let content = "hello\nfs.userFile\n"
    let bytes = applyUserFileResource(target, content, "0644")
    check fileExists(target)
    check readFile(target) == content
    check bytes.len == content.len

  test "applyUserFileResource: cache-hit pattern via observeUserFile":
    let dir = createTempDir("repro-userfile-noop-", "")
    defer: removeDir(dir)
    let target = dir / "config.txt"
    let content = "stable content"
    discard applyUserFileResource(target, content, "0644")
    # Re-observe: digest must equal the desired-content digest.
    let observed = observeUserFile(target)
    check observed.present
    var buf = newSeq[byte](content.len)
    for i, ch in content:
      buf[i] = byte(ord(ch))
    check observed.digest == digestOfBytes(buf)

  test "applyUserFileResource: drift overwrite":
    let dir = createTempDir("repro-userfile-drift-", "")
    defer: removeDir(dir)
    let target = dir / "config.txt"
    discard applyUserFileResource(target, "old", "0644")
    discard applyUserFileResource(target, "new", "0644")
    check readFile(target) == "new"

  test "applyUserFileResource: creates parent directories as needed":
    let dir = createTempDir("repro-userfile-parent-", "")
    defer: removeDir(dir)
    let target = dir / "nested" / "deeper" / "config.txt"
    let bytes = applyUserFileResource(target, "x", "0644")
    check fileExists(target)
    check readFile(target) == "x"
    check bytes.len == 1

  test "applyUserFileResource: post-apply re-probe fails closed on bad mode":
    # An invalid mode is caught and reported through IOError. The
    # pre-write atomic rename has already happened, so the file is
    # present, but the operator gets a clear failure rather than a
    # silent skipped permission set.
    let dir = createTempDir("repro-userfile-badmode-", "")
    defer: removeDir(dir)
    let target = dir / "x"
    when not defined(windows):
      expect IOError:
        discard applyUserFileResource(target, "x", "rwx")
    else:
      # On Windows the mode field is a no-op, so even an invalid
      # mode string is accepted (and recorded but not applied).
      discard applyUserFileResource(target, "x", "rwx")
      check fileExists(target)

  test "destroyUserFileResource: removes the file":
    let dir = createTempDir("repro-userfile-destroy-", "")
    defer: removeDir(dir)
    let target = dir / "config.txt"
    discard applyUserFileResource(target, "bye", "0644")
    check fileExists(target)
    destroyUserFileResource(target)
    check not fileExists(target)

  test "destroyUserFileResource: cleans orphan .repro.tmp":
    # Simulate a crash mid-write: a `.repro.tmp` sibling exists but
    # no real file. The destroy direction must clean both so the
    # next apply does not see a confusing stale tmp.
    let dir = createTempDir("repro-userfile-orphan-", "")
    defer: removeDir(dir)
    let target = dir / "config.txt"
    writeFile(target & ".repro.tmp", "partial")
    destroyUserFileResource(target)
    check not fileExists(target & ".repro.tmp")

  test "applyUserFileResource: atomic-write recovery after crash":
    # The previous apply was interrupted between writing the tmp and
    # renaming it, so a `.repro.tmp` orphan sits alongside no real
    # file (or alongside an old real file). The next apply opens
    # tmp with fmWrite (truncate) and renames it over the target —
    # the orphan does not confuse the next run.
    let dir = createTempDir("repro-userfile-crash-", "")
    defer: removeDir(dir)
    let target = dir / "config.txt"
    writeFile(target & ".repro.tmp", "old partial junk")
    discard applyUserFileResource(target, "fresh", "0644")
    check fileExists(target)
    check readFile(target) == "fresh"
    # The tmp has been renamed away — it should no longer exist.
    check not fileExists(target & ".repro.tmp")

  test "observeUserFile: absent file yields not-present":
    let dir = createTempDir("repro-userfile-absent-", "")
    defer: removeDir(dir)
    let target = dir / "never-created.txt"
    let observed = observeUserFile(target)
    check not observed.present
    check observed.digest == zeroDigest()

  when not defined(windows):
    test "applyUserFileResource: POSIX mode application":
      let dir = createTempDir("repro-userfile-mode-", "")
      defer: removeDir(dir)
      let target = dir / "exec.sh"
      discard applyUserFileResource(target,
        "#!/bin/sh\necho hi\n", "0755")
      let perms = getFilePermissions(target)
      check fpUserExec in perms
      check fpGroupExec in perms
      check fpOthersExec in perms
      # And the read-write bits.
      check fpUserRead in perms
      check fpUserWrite in perms

    test "applyUserFileResource: POSIX mode 0600 is restrictive":
      let dir = createTempDir("repro-userfile-secret-", "")
      defer: removeDir(dir)
      let target = dir / "secret"
      discard applyUserFileResource(target, "shh", "0600")
      let perms = getFilePermissions(target)
      check fpUserRead in perms
      check fpUserWrite in perms
      check fpUserExec notin perms
      check fpGroupRead notin perms
      check fpOthersRead notin perms

  when defined(windows):
    test "applyUserFileResource: Windows ignores mode field":
      # The mode is RECORDED (the resource carries it through to the
      # manifest) but the driver does not apply it on Windows. A
      # legitimate octal mode is accepted; the file exists after
      # apply regardless.
      let dir = createTempDir("repro-userfile-win-mode-", "")
      defer: removeDir(dir)
      let target = dir / "config.txt"
      discard applyUserFileResource(target, "x", "0600")
      check fileExists(target)
      check readFile(target) == "x"

  test "digestOfResource: fs.userFile digests content bytes verbatim":
    var r = Resource(kind: rkFsUserFile, address: "uf:test",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/dev/null/ignored",
      userFileContent: "abc",
      userFileMode: "0644")
    let expected = digestOfBytes(@[byte('a'), byte('b'), byte('c')])
    check digestOfResource(r) == expected
    # Empty content: digests the empty byte sequence (consistent with
    # the rest of the family).
    r.userFileContent = ""
    var empty: seq[byte] = @[]
    check digestOfResource(r) == digestOfBytes(empty)

  test "realWorldIdentity: fs.userFile is the host path verbatim":
    let r = Resource(kind: rkFsUserFile, address: "uf:id",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/home/u/.config/x",
      userFileContent: "",
      userFileMode: "0644")
    check realWorldIdentity(r) == "/home/u/.config/x"

  test "lifecycle: no-op for unchanged fs.userFile content":
    # The lifecycle algorithm collapses (desired == observed) to
    # rakNoOp; the resource kind tag travels through unchanged.
    var desired = Resource(kind: rkFsUserFile, address: "uf:noop",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/host/x",
      userFileContent: "stable",
      userFileMode: "0644")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    state.observed.digest = digestOfResource(desired)
    let action = decideAction(state)
    check action.kind == rakNoOp
    check action.resourceKind == rkFsUserFile

  test "lifecycle: create for absent fs.userFile":
    var desired = Resource(kind: rkFsUserFile, address: "uf:create",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/host/x",
      userFileContent: "new",
      userFileMode: "0644")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = false
    let action = decideAction(state)
    check action.kind == rakCreate
    check action.resourceKind == rkFsUserFile

# ===========================================================================
# vscode.extension — pure parse + drift logic. The shell-out side runs
# only when `code` is on PATH; what runs everywhere is the closed-set
# validator, the marketplace-ID charset guard, the `code --list-
# extensions --show-versions` parser, and the canonical-state digest.
# ===========================================================================

suite "vscode.extension pure surface":

  test "isSafeExtensionId accepts marketplace IDs and pins":
    check isSafeExtensionId("vscodevim.vim")
    check isSafeExtensionId("ms-python.python")
    check isSafeExtensionId("vscodevim.vim@1.27.0")
    check isSafeExtensionId("ms_publisher.ext-name")
    check not isSafeExtensionId("")
    check not isSafeExtensionId("evil; rm -rf /")
    check not isSafeExtensionId("ext'name")
    check not isSafeExtensionId("a@b@c")            # double @
    check not isSafeExtensionId("$(whoami)")

  test "parseExtensionSpec splits id and version pin":
    let s = parseExtensionSpec("vscodevim.vim@1.27.0")
    check s.id == "vscodevim.vim"
    check s.pinnedVersion == "1.27.0"
    let u = parseExtensionSpec("ms-python.python")
    check u.id == "ms-python.python"
    check u.pinnedVersion == ""

  test "parseCodeListExtensions reads the deterministic line-oriented form":
    let raw = """
ms-python.python@2024.0.1
vscodevim.vim@1.27.0

# a comment line is skipped
"""
    let parsed = parseCodeListExtensions(raw)
    check parsed.len == 2
    # Sorted by ID.
    check parsed[0].id == "ms-python.python"
    check parsed[0].pinnedVersion == "2024.0.1"
    check parsed[1].id == "vscodevim.vim"
    check parsed[1].pinnedVersion == "1.27.0"

  test "parseCodeListExtensions skips unsafe-looking lines":
    let raw = "good.ext\nevil; rm -rf /\nanother.ok\n"
    let parsed = parseCodeListExtensions(raw)
    check parsed.len == 2
    check parsed[0].id == "another.ok"
    check parsed[1].id == "good.ext"

  test "canonicalExtensionSet sorts by ID":
    let specs = @[
      ExtensionSpec(id: "zzz.last", pinnedVersion: ""),
      ExtensionSpec(id: "aaa.first", pinnedVersion: "1.0")]
    let canon = canonicalExtensionSet(specs)
    check canon == "aaa.first@1.0\nzzz.last\n"

  test "observedCanonical subset semantics ignore extras when removeUnknown=false":
    let installed = @[
      ExtensionSpec(id: "vscodevim.vim", pinnedVersion: "1.27.0"),
      ExtensionSpec(id: "ms-python.python", pinnedVersion: "2024.0.1"),
      ExtensionSpec(id: "extra.installed-by-user", pinnedVersion: "0.1")]
    let desired = @[
      ExtensionSpec(id: "vscodevim.vim", pinnedVersion: "")]
    let obs = observedCanonical(installed, desired, removeUnknown = false)
    # Only the desired ID is kept, without its pin (desired is unpinned).
    check obs == "vscodevim.vim\n"

  test "observedCanonical strict semantics surface extras as drift":
    let installed = @[
      ExtensionSpec(id: "vscodevim.vim", pinnedVersion: "1.27.0"),
      ExtensionSpec(id: "extra.installed-by-user", pinnedVersion: "0.1")]
    let desired = @[
      ExtensionSpec(id: "vscodevim.vim", pinnedVersion: "")]
    let obs = observedCanonical(installed, desired, removeUnknown = true)
    # Full installed set rendered; mismatch vs the desired canonical
    # ("vscodevim.vim\n") triggers an update.
    check obs == "extra.installed-by-user@0.1\nvscodevim.vim@1.27.0\n"

  test "observedCanonical pinned desired keeps live version visible":
    let installed = @[
      ExtensionSpec(id: "vscodevim.vim", pinnedVersion: "1.27.0")]
    let desired = @[
      ExtensionSpec(id: "vscodevim.vim", pinnedVersion: "1.27.0")]
    let obs = observedCanonical(installed, desired, removeUnknown = false)
    check obs == "vscodevim.vim@1.27.0\n"
    # When the live version drifts from the pin, the observed canonical
    # still shows the LIVE version — driving an update.
    let installed2 = @[
      ExtensionSpec(id: "vscodevim.vim", pinnedVersion: "1.27.1")]
    let obs2 = observedCanonical(installed2, desired, removeUnknown = false)
    check obs2 == "vscodevim.vim@1.27.1\n"
    check obs2 != canonicalExtensionSet(desired)

  test "lifecycle: cache-hit when desired matches observed":
    let desired = Resource(kind: rkVscodeExtension, address: "ve:hit",
      lifecyclePolicy: lpDefault,
      vscodeExtensions: @["vscodevim.vim"],
      vscodeRemoveUnknown: false)
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    state.observed.digest = digestOfResource(desired)
    let action = decideAction(state)
    check action.kind == rakNoOp
    check action.resourceKind == rkVscodeExtension

  test "lifecycle: create for absent vscode.extension":
    let desired = Resource(kind: rkVscodeExtension, address: "ve:create",
      lifecyclePolicy: lpDefault,
      vscodeExtensions: @["vscodevim.vim", "ms-python.python"],
      vscodeRemoveUnknown: false)
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = false
    let action = decideAction(state)
    check action.kind == rakCreate
    check action.resourceKind == rkVscodeExtension

  test "realWorldIdentity is the singleton vscode:extensions":
    let r = Resource(kind: rkVscodeExtension, address: "ve",
      vscodeExtensions: @["vscodevim.vim"])
    check realWorldIdentity(r) == "vscode:extensions"

  test "resourceKindFromString covers vscode.extension":
    check resourceKindFromString("vscode.extension") == rkVscodeExtension

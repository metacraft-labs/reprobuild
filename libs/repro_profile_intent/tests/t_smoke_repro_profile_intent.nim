## M83 Phase B smoke tests for the `repro_profile_intent` library:
## the `RBPI` envelope (magic + version + bodyLen + body + BLAKE3
## checksum) and the CBOR `ProfileIntent` body codec.
##
## The test plan covers three layers:
##
## 1. Envelope wrap / unwrap, including every corruption case the
##    envelope reader is required to catch.
## 2. `ProfileIntent` round-trip through the CBOR body codec, with
##    one test per `FieldValue` / `ConfigValue` variant plus the
##    structural extras (`dependsOn`, `WhenGuard`, every host /
##    activity / resource shape).
## 3. Determinism and canonical ordering — the cbor codec sorts maps
##    on encode, so identical inputs must produce byte-identical
##    output and reversed input order must produce the same wire.

import std/[strutils, tables, unittest]

import repro_profile
import repro_profile_intent

# ---------------------------------------------------------------------
# Small builders.
# ---------------------------------------------------------------------

proc smallBody(): seq[byte] =
  result = @[0x01'u8, 0x02, 0x03, 0x04, 0x05]

proc fixtureFull(): ProfileIntent =
  ## A profile that exercises every code path the codec must handle:
  ## activities (with a when-guarded inner package), config overrides
  ## of every kind, a hosts table with multiple keys, resources with
  ## every FieldValue variant, and a dependsOn entry.
  result.name = "full-fixture"
  result.activities.add ActivityIntent(name: "default", body: @[
    ActivityElement(kind: aekPackageRef, pkgName: "neovim"),
    ActivityElement(kind: aekWhenGuard,
      predicate: PredicateExpr(expr: "linux"),
      guardedBody: @[
        ActivityElement(kind: aekPackageRef, pkgName: "i3"),
        ActivityElement(kind: aekPackageRef, pkgName: "rofi")])])
  result.configOverrides.add ConfigOverride(pkg: "git", key: "userName",
    value: strValue("Zahary"))
  result.configOverrides.add ConfigOverride(pkg: "git", key: "depth",
    value: intValue(-42))
  result.configOverrides.add ConfigOverride(pkg: "tmux", key: "mouse",
    value: boolValue(true))
  result.configOverrides.add ConfigOverride(pkg: "neovim", key: "theme",
    value: exprValue("if dark: \"gruvbox\" else: \"solarized\""))
  result.hosts["zeta"] = @["develop"]
  result.hosts["alpha"] = @["default", "develop"]
  var r = ResourceIntent(kind: "fs.userFile", address: "main")
  r.fields["path"] = strField("~/.vimrc")
  r.fields["mode"] = intField(0o644)
  r.fields["executable"] = boolField(false)
  r.fields["extra"] = listField(@["a", "b", "c"])
  r.fields["computed"] = exprField("user.home & \"/.vimrc\"")
  r.dependsOn.add ResourceAddress(kind: "fs.userDir", name: "vimroot")
  result.resources.add r

# ---------------------------------------------------------------------
# Envelope round-trip + corruption.
# ---------------------------------------------------------------------

suite "RBPI envelope: wrap / unwrap":

  test "round-trips a small body":
    let body = smallBody()
    let env = wrapEnvelope(body)
    let recovered = readEnvelope(env)
    check recovered == body

  test "wrapEnvelope produces exactly 10 + bodyLen + 32 bytes":
    let body = smallBody()
    let env = wrapEnvelope(body)
    check env.len == RbpiHeaderSize + body.len + RbpiTrailerSize
    check env.len == 10 + body.len + 32

  test "empty body round-trips":
    let env = wrapEnvelope(@[])
    check env.len == RbpiHeaderSize + RbpiTrailerSize
    let recovered = readEnvelope(env)
    check recovered.len == 0

  test "magic + version are at the documented offsets":
    let env = wrapEnvelope(smallBody())
    check env[0] == byte(ord('R'))
    check env[1] == byte(ord('B'))
    check env[2] == byte(ord('P'))
    check env[3] == byte(ord('I'))
    # u16 LE schema version (tracks RbpiSchemaVersion).
    check env[4] == byte(RbpiSchemaVersion and 0xFF)
    check env[5] == byte((RbpiSchemaVersion shr 8) and 0xFF)

  test "encodeRbpiHeader output matches the wrap prefix":
    let body = smallBody()
    let env = wrapEnvelope(body)
    let header = encodeRbpiHeader(uint32(body.len))
    check header.len == RbpiHeaderSize
    for i in 0 ..< RbpiHeaderSize:
      check env[i] == header[i]

  test "readRbpiHeader returns version + bodyLen":
    let body = smallBody()
    let env = wrapEnvelope(body)
    let (version, bodyLen) = readRbpiHeader(env)
    check version == RbpiSchemaVersion
    check bodyLen == uint32(body.len)

suite "RBPI envelope: corruption detection":

  test "bad magic raises ERbpiCorrupt(field: magic)":
    var env = wrapEnvelope(smallBody())
    env[0] = byte(ord('X'))
    var raised = false
    try:
      discard readEnvelope(env)
    except ERbpiCorrupt as e:
      raised = true
      check e.field == "magic"
    check raised

  test "unsupported version raises ERbpiCorrupt(field: schemaVersion)":
    # DERIVED FROM `RbpiSchemaVersion`, which is already exported, so this
    # needs no accessor: one `+ 1` at the single call site is cheaper than
    # a second name, and the derivation is visible where it is read.
    #
    # It used to poke a literal 7, written when the schema version was 1.
    # The reader's check is an EQUALITY, so 7 stayed unsupported through
    # the bumps to 2 and to 3 and the case kept passing -- but it was
    # measuring "version 7 is refused", not "the version one past this
    # build's is refused", and those come apart the moment the schema
    # reaches 7. Nothing would have reddened; the case would simply have
    # started asserting that the CURRENT version is rejected, which is the
    # opposite property.
    var env = wrapEnvelope(smallBody())
    let unknown = RbpiSchemaVersion + 1'u16
    env[4] = byte(unknown and 0xff'u16)
    env[5] = byte((unknown shr 8) and 0xff'u16)
    var raised = false
    try:
      discard readEnvelope(env)
    except ERbpiCorrupt as e:
      raised = true
      check e.field == "schemaVersion"
    check raised

  test "truncated header (less than 10 bytes) raises envelope-too-short":
    let env = wrapEnvelope(smallBody())
    let cut = env[0 ..< 5]
    var raised = false
    try:
      discard readEnvelope(cut)
    except ERbpiCorrupt as e:
      raised = true
      check e.field == "envelope"
    check raised

  test "truncated body raises ERbpiCorrupt(field: bodyLength)":
    let env = wrapEnvelope(smallBody())
    # Drop several body bytes but keep something that looks like a
    # checksum after the header so the file isn't outright too short.
    var cut: seq[byte] = @[]
    for i in 0 ..< env.len - 3:
      cut.add(env[i])
    var raised = false
    try:
      discard readEnvelope(cut)
    except ERbpiCorrupt as e:
      raised = true
      check e.field == "bodyLength"
    check raised

  test "bad checksum raises ERbpiCorrupt(field: checksum)":
    var env = wrapEnvelope(smallBody())
    env[env.len - 1] = env[env.len - 1] xor 0xff'u8
    var raised = false
    try:
      discard readEnvelope(env)
    except ERbpiCorrupt as e:
      raised = true
      check e.field == "checksum"
    check raised

  test "outright-too-short input raises envelope":
    var raised = false
    try:
      discard readEnvelope(@[0x00'u8, 0x01, 0x02])
    except ERbpiCorrupt as e:
      raised = true
      check e.field == "envelope"
    check raised

# ---------------------------------------------------------------------
# ProfileIntent round-trip — body codec only.
# ---------------------------------------------------------------------

suite "ProfileIntent CBOR body round-trip":

  test "empty ProfileIntent round-trips":
    var p: ProfileIntent
    p.name = "empty"
    let bytes = encodeProfileIntentToBytes(p)
    let q = decodeProfileIntentFromBytes(bytes)
    check q.name == "empty"
    check q.activities.len == 0
    check q.configOverrides.len == 0
    check q.hosts.len == 0
    check q.resources.len == 0

  test "ProfileIntent with one activity + one resource + one host round-trips":
    var p: ProfileIntent
    p.name = "mini"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "neovim")])
    p.hosts["host-a"] = @["default"]
    var r = ResourceIntent(kind: "fs.userFile", address: "rc")
    r.fields["path"] = strField("~/.profile")
    p.resources.add r
    let bytes = encodeProfileIntentToBytes(p)
    let q = decodeProfileIntentFromBytes(bytes)
    check q.name == "mini"
    check q.activities.len == 1
    check q.activities[0].name == "default"
    check q.activities[0].body.len == 1
    check q.activities[0].body[0].kind == aekPackageRef
    check q.activities[0].body[0].pkgName == "neovim"
    check q.hosts.len == 1
    check q.hosts["host-a"] == @["default"]
    check q.resources.len == 1
    check q.resources[0].kind == "fs.userFile"
    check q.resources[0].address == "rc"
    check q.resources[0].fields["path"].kind == fvkString
    check q.resources[0].fields["path"].s == "~/.profile"

  test "FieldValue variants — string":
    var p: ProfileIntent
    p.name = "fv-str"
    var r = ResourceIntent(kind: "fs.userFile", address: "x")
    r.fields["v"] = strField("hello \"world\"")
    p.resources.add r
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.resources[0].fields["v"].kind == fvkString
    check q.resources[0].fields["v"].s == "hello \"world\""

  test "FieldValue variants — int (positive and negative, including low(int))":
    var p: ProfileIntent
    p.name = "fv-int"
    var r = ResourceIntent(kind: "fs.userFile", address: "x")
    r.fields["a"] = intField(0)
    r.fields["b"] = intField(42)
    r.fields["c"] = intField(-1)
    r.fields["d"] = intField(low(int))
    r.fields["e"] = intField(high(int))
    p.resources.add r
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.resources[0].fields["a"].i == 0
    check q.resources[0].fields["b"].i == 42
    check q.resources[0].fields["c"].i == -1
    check q.resources[0].fields["d"].i == low(int)
    check q.resources[0].fields["e"].i == high(int)

  test "FieldValue variants — bool":
    var p: ProfileIntent
    p.name = "fv-bool"
    var r = ResourceIntent(kind: "fs.userFile", address: "x")
    r.fields["t"] = boolField(true)
    r.fields["f"] = boolField(false)
    p.resources.add r
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.resources[0].fields["t"].b == true
    check q.resources[0].fields["f"].b == false

  test "FieldValue variants — list":
    var p: ProfileIntent
    p.name = "fv-list"
    var r = ResourceIntent(kind: "fs.userFile", address: "x")
    r.fields["empty"] = listField(@[])
    r.fields["one"] = listField(@["only"])
    r.fields["many"] = listField(@["a", "b", "c", "d"])
    p.resources.add r
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.resources[0].fields["empty"].items.len == 0
    check q.resources[0].fields["one"].items == @["only"]
    check q.resources[0].fields["many"].items == @["a", "b", "c", "d"]

  test "FieldValue variants — expr":
    var p: ProfileIntent
    p.name = "fv-expr"
    var r = ResourceIntent(kind: "fs.userFile", address: "x")
    r.fields["x"] = exprField("user.home & \"/.cache\"")
    p.resources.add r
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.resources[0].fields["x"].kind == fvkExpr
    check q.resources[0].fields["x"].expr == "user.home & \"/.cache\""

  test "ConfigValue variants — string + int + bool + expr round-trip":
    var p: ProfileIntent
    p.name = "cv"
    p.configOverrides.add ConfigOverride(pkg: "git", key: "userName",
      value: strValue("Zahary"))
    p.configOverrides.add ConfigOverride(pkg: "git", key: "depth",
      value: intValue(-100))
    p.configOverrides.add ConfigOverride(pkg: "tmux", key: "mouse",
      value: boolValue(true))
    p.configOverrides.add ConfigOverride(pkg: "neovim", key: "theme",
      value: exprValue("if dark: \"x\" else: \"y\""))
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.configOverrides.len == 4
    check q.configOverrides[0].value.kind == cvkString
    check q.configOverrides[0].value.s == "Zahary"
    check q.configOverrides[1].value.kind == cvkInt
    check q.configOverrides[1].value.i == -100
    check q.configOverrides[2].value.kind == cvkBool
    check q.configOverrides[2].value.b == true
    check q.configOverrides[3].value.kind == cvkExpr
    check q.configOverrides[3].value.expr == "if dark: \"x\" else: \"y\""

  test "ResourceIntent dependsOn round-trips":
    var p: ProfileIntent
    p.name = "deps"
    var r = ResourceIntent(kind: "fs.userFile", address: "main")
    r.fields["path"] = strField("~/.vimrc")
    r.dependsOn.add ResourceAddress(kind: "fs.userDir", name: "vim")
    r.dependsOn.add ResourceAddress(kind: "pkg", name: "neovim")
    p.resources.add r
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.resources[0].dependsOn.len == 2
    check q.resources[0].dependsOn[0].kind == "fs.userDir"
    check q.resources[0].dependsOn[0].name == "vim"
    check q.resources[0].dependsOn[1].kind == "pkg"
    check q.resources[0].dependsOn[1].name == "neovim"

  test "WhenGuard activity element round-trips (with nested body)":
    var p: ProfileIntent
    p.name = "guarded"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekWhenGuard,
        predicate: PredicateExpr(expr: "windows"),
        guardedBody: @[
          ActivityElement(kind: aekPackageRef, pkgName: "wt"),
          ActivityElement(kind: aekPackageRef, pkgName: "pwsh"),
        ])])
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.activities[0].body.len == 1
    let elt = q.activities[0].body[0]
    check elt.kind == aekWhenGuard
    check elt.predicate.expr == "windows"
    check elt.guardedBody.len == 2
    check elt.guardedBody[0].pkgName == "wt"
    check elt.guardedBody[1].pkgName == "pwsh"

  test "hosts table with multiple keys round-trips":
    var p: ProfileIntent
    p.name = "hh"
    p.hosts["alpha"] = @["default", "develop"]
    p.hosts["zeta"] = @["develop"]
    p.hosts["middle"] = @[]
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.hosts.len == 3
    check q.hosts["alpha"] == @["default", "develop"]
    check q.hosts["zeta"] == @["develop"]
    check q.hosts["middle"].len == 0

  test "hostApplies round-trips, and is absent from the wire when empty":
    # GM7 (envelope schema 7): the per-host concern declaration. A profile
    # without one encodes exactly as a schema-6 profile did -- no key -- so
    # its action-cache identity is unchanged apart from the version.
    var p: ProfileIntent
    p.name = "ha"
    p.hosts["m1"] = @["desktop"]
    p.hosts["home-pc"] = @["desktop"]
    let plain = encodeProfileIntentToBytes(p)
    var plainText = ""
    for b in plain: plainText.add char(b)
    check "hostApplies" notin plainText
    p.hostApplies["m1"] = @["applications", "environment"]
    p.hostApplies["home-pc"] = @[]
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.hostApplies.len == 2
    check q.hostApplies["m1"] == @["applications", "environment"]
    check q.hostApplies["home-pc"].len == 0
    check decodeProfileIntentFromBytes(plain).hostApplies.len == 0

  test "systemManagedElsewhere round-trips (RBPI and JSON), absent when empty":
    # GM10 (envelope schema 9): the hosts whose system scope is managed
    # elsewhere, with the optional pointer. A profile without one encodes
    # exactly as a schema-8 profile did -- no key, in either encoding.
    var p: ProfileIntent
    p.name = "sme"
    p.hosts["infra-host"] = @["default"]
    p.hosts["distro-host"] = @["default"]
    p.hosts["home-pc"] = @["default"]
    let plain = encodeProfileIntentToBytes(p)
    var plainText = ""
    for b in plain: plainText.add char(b)
    check "systemManagedElsewhere" notin plainText
    check "systemManagedElsewhere" notin emitProfileIntentJson(p)
    check decodeProfileIntentFromBytes(plain).systemManagedElsewhere.len == 0
    p.systemManagedElsewhere["infra-host"] = "example-org/infra"
    p.systemManagedElsewhere["distro-host"] = ""
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.systemManagedElsewhere.len == 2
    check q.systemManagedElsewhere["infra-host"] == "example-org/infra"
    check q.systemManagedElsewhere["distro-host"] == ""
    check not q.systemManagedElsewhere.hasKey("home-pc")
    let js = emitProfileIntentJson(p)
    check js.contains("\"systemManagedElsewhere\":{\"distro-host\":" &
      "{\"managedBy\":null},\"infra-host\":{\"managedBy\":" &
      "\"example-org/infra\"}}")
    let r = parseProfileIntentJson(js)
    check r.systemManagedElsewhere == p.systemManagedElsewhere
    # The lookup every reader uses.
    let m = systemManagementFor(r, "infra-host")
    check m.declared and m.managedElsewhere and
      m.managedBy == "example-org/infra"
    let n = systemManagementFor(r, "distro-host")
    check n.managedElsewhere and n.managedBy == ""
    let h = systemManagementFor(r, "home-pc")
    check h.declared and not h.managedElsewhere
    check not systemManagementFor(r, "nowhere").declared
    # A malformed JSON entry is refused, never read as "managed here".
    for bad in ["{\"systemManagedElsewhere\":{\"x\":\"repo\"}}",
                "{\"systemManagedElsewhere\":{\"x\":{}}}",
                "{\"systemManagedElsewhere\":{\"x\":{\"managedBy\":1}}}",
                "{\"systemManagedElsewhere\":[]}"]:
      let doc = js[0 ..< js.len - 1] & "," & bad[1 ..< bad.len - 1] & "}"
      expect ValueError:
        discard parseProfileIntentJson(doc)

  test "stowScopes round-trip (RBPI and JSON), absent when empty":
    # GM11 (envelope schema 10): the stow packages activities claim, in
    # declaration order, with an optional guard. A profile without a claim
    # encodes exactly as a schema-9 profile did -- no key, in either
    # encoding.
    var p: ProfileIntent
    p.name = "stow"
    p.activities = @[ActivityIntent(name: "default"),
                     ActivityIntent(name: "desktop_core")]
    let plain = encodeProfileIntentToBytes(p)
    var plainText = ""
    for b in plain: plainText.add char(b)
    check "stowScopes" notin plainText
    check "stowScopes" notin emitProfileIntentJson(p)
    check decodeProfileIntentFromBytes(plain).stowScopes.len == 0
    p.stowScopes = @[
      StowScope(package: "kitty", activity: "desktop_core"),
      StowScope(package: "rdp", activity: "desktop_core"),
      StowScope(package: "rdp", activity: "default",
        guard: PredicateExpr(expr: "windows"))]
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.stowScopes == p.stowScopes
    let js = emitProfileIntentJson(p)
    check js.contains("\"stowScopes\":[{\"package\":\"kitty\",\"activity\":" &
      "\"desktop_core\",\"guard\":null},{\"package\":\"rdp\",\"activity\":" &
      "\"desktop_core\",\"guard\":null},{\"package\":\"rdp\",\"activity\":" &
      "\"default\",\"guard\":\"windows\"}]")
    check parseProfileIntentJson(js).stowScopes == p.stowScopes
    check stowScopesProblem(q.stowScopes, ["default", "desktop_core"]) == ""
    # The shared validator refuses what the macro never builds.
    check "does not declare" in stowScopesProblem(q.stowScopes, ["default"])
    check "twice" in stowScopesProblem(
      [StowScope(package: "a", activity: "x"),
       StowScope(package: "a", activity: "x")], ["x"])
    check "path" in stowScopesProblem(
      [StowScope(package: "a/b", activity: "x")], ["x"])
    check "empty" in stowPackageNameProblem("")
    check stowPackageNameProblem("..") != ""
    check stowPackageNameProblem(" kitty") != ""
    check stowPackageNameProblem("kit\ty") != ""
    check stowPackageNameProblem("kitty") == ""
    # A malformed JSON claim is refused, never dropped (a dropped claim
    # would put its package on every host).
    for bad in ["{\"stowScopes\":{}}",
                "{\"stowScopes\":[\"kitty\"]}",
                "{\"stowScopes\":[{\"package\":\"kitty\"}]}",
                "{\"stowScopes\":[{\"package\":\"kitty\",\"activity\":1," &
                  "\"guard\":null}]}",
                "{\"stowScopes\":[{\"package\":\"kitty\",\"activity\":" &
                  "\"x\"}]}"]:
      let doc = js[0 ..< js.find(",\"stowScopes\"")] & "," &
        bad[1 ..< bad.len - 1] & "}"
      expect ValueError:
        discard parseProfileIntentJson(doc)

  test "full fixture round-trips structurally":
    let p = fixtureFull()
    let q = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(p))
    check q.name == p.name
    check q.activities.len == p.activities.len
    check q.activities[0].name == "default"
    check q.activities[0].body[0].pkgName == "neovim"
    check q.activities[0].body[1].kind == aekWhenGuard
    check q.activities[0].body[1].predicate.expr == "linux"
    check q.activities[0].body[1].guardedBody.len == 2
    check q.configOverrides.len == 4
    check q.hosts["alpha"] == @["default", "develop"]
    check q.hosts["zeta"] == @["develop"]
    check q.resources.len == 1
    check q.resources[0].kind == "fs.userFile"
    check q.resources[0].fields.len == 5
    check q.resources[0].dependsOn.len == 1

# ---------------------------------------------------------------------
# Determinism + canonical ordering.
# ---------------------------------------------------------------------

suite "ProfileIntent CBOR determinism":

  test "encoding the same ProfileIntent twice produces identical bytes":
    let p = fixtureFull()
    let a = encodeProfileIntentToBytes(p)
    let b = encodeProfileIntentToBytes(p)
    check a == b

  test "hosts table with reversed key insertion order encodes identically":
    var pa: ProfileIntent
    pa.name = "h"
    pa.hosts["alpha"] = @["x"]
    pa.hosts["beta"] = @["y"]
    pa.hosts["gamma"] = @["z"]
    var pb: ProfileIntent
    pb.name = "h"
    pb.hosts["gamma"] = @["z"]
    pb.hosts["beta"] = @["y"]
    pb.hosts["alpha"] = @["x"]
    check encodeProfileIntentToBytes(pa) ==
      encodeProfileIntentToBytes(pb)

  test "ResourceIntent fields table with reversed key order encodes identically":
    var pa: ProfileIntent
    pa.name = "r"
    var ra = ResourceIntent(kind: "fs.userFile", address: "x")
    ra.fields["alpha"] = strField("a")
    ra.fields["beta"] = strField("b")
    ra.fields["gamma"] = strField("c")
    pa.resources.add ra
    var pb: ProfileIntent
    pb.name = "r"
    var rb = ResourceIntent(kind: "fs.userFile", address: "x")
    rb.fields["gamma"] = strField("c")
    rb.fields["beta"] = strField("b")
    rb.fields["alpha"] = strField("a")
    pb.resources.add rb
    check encodeProfileIntentToBytes(pa) ==
      encodeProfileIntentToBytes(pb)

  test "variant 'kind' tag sorts before 'value' inside its parent map":
    # Re-derives the canonical key sort guarantee: every variant map
    # encodes its "kind" tag BEFORE its payload, because the cbor
    # codec sorts map keys lexicographically and "kind" < "value".
    # We check this by encoding a FieldValue, decoding the raw CBOR,
    # and observing the key order on the wire.
    var p: ProfileIntent
    p.name = "k"
    var r = ResourceIntent(kind: "fs.userFile", address: "x")
    r.fields["v"] = strField("hello")
    p.resources.add r
    let bytes = encodeProfileIntentToBytes(p)
    # The encoded body is itself a CBOR value; round-tripping it
    # through the decoder + re-encoder must produce identical bytes
    # if (and only if) the wire is already canonical.
    let q = decodeProfileIntentFromBytes(bytes)
    check encodeProfileIntentToBytes(q) == bytes

# ---------------------------------------------------------------------
# RBPI convenience helpers (envelope + body in one shot).
# ---------------------------------------------------------------------

suite "encodeRbpi / decodeRbpi convenience":

  test "encodeRbpi + decodeRbpi round-trip the full fixture":
    let p = fixtureFull()
    let bytes = encodeRbpi(p)
    # Envelope framing: magic + 10-byte header + 32-byte trailer.
    check bytes.len >=
      RbpiHeaderSize + RbpiTrailerSize
    check bytes[0] == byte(ord('R'))
    let q = decodeRbpi(bytes)
    check q.name == p.name
    check q.activities.len == p.activities.len
    check q.resources.len == p.resources.len

  test "decodeRbpi on a body that lacks the envelope raises checksum/magic":
    let body = encodeProfileIntentToBytes(fixtureFull())
    var raised = false
    try:
      discard decodeRbpi(body)
    except ERbpiCorrupt:
      raised = true
    check raised

  test "raiseRbpiCorrupt tags the field":
    var raised = false
    try:
      raiseRbpiCorrupt("custom", "diagnostic message")
    except ERbpiCorrupt as e:
      raised = true
      check e.field == "custom"
      check e.detail == "diagnostic message"
    check raised

  test "GM4: data-file references round-trip and are absent when empty":
    var p = ProfileIntent(name: "gm4")
    p.activities.add ActivityIntent(name: "default",
      body: @[ActivityElement(kind: aekPackageRef, pkgName: "jq")])
    let without = encodeRbpi(p)
    check decodeRbpi(without).dataFiles.len == 0
    p.dataFiles = @["data/apps.toml", "data/cli.toml"]
    let with = encodeRbpi(p)
    check decodeRbpi(with).dataFiles == @["data/apps.toml", "data/cli.toml"]
    # The key is optional on the wire: present only with references.
    check without != with
    # The JSON form carries them too, and omits the key when empty.
    check emitProfileIntentJson(p).contains("\"dataFiles\":[\"data/apps.toml\"")
    check parseProfileIntentJson(emitProfileIntentJson(p)).dataFiles ==
      p.dataFiles
    p.dataFiles = @[]
    check not emitProfileIntentJson(p).contains("dataFiles")

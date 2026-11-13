## A PROVIDER-GRAPH SNAPSHOT IS A DERIVED CACHE, SO AN UNREADABLE ONE IS
## RECOMPUTED RATHER THAN RAISED.
##
## `provider-fragments.rbsz` holds nothing a provider cannot produce
## again: `loadProviderGraphSnapshot` already answers a MISSING file
## with an empty snapshot, which the refresher reads as "recompute".
## This file pins the other half of that rule — a snapshot whose
## ENVELOPE VERSION this build does not support is the same situation
## (this cache cannot be read) and must get the same answer.
##
## WHY THAT IS NOT THE RULE FOR AN ARTIFACT. D-SS11 deliberately
## version-gates and DECODES the dev-env artifact: an artifact is the
## evaluation's own output, addressed by its content id, and a reader
## that silently discarded one would answer a cache hit with a
## recomputation whose result the caller had already been told the id
## of. A snapshot is not addressed by anything a caller holds, so
## discarding it costs one evaluation and nothing else.
##
## WHY THE QUESTION AROSE AT ALL. One `ProviderGraphVersion` governs
## THREE envelope types — request, response and snapshot — so the
## response-layout change that moved it 1 -> 2 (Shared-Development-
## Services F1 appended `DevEnvResult.actions`) made every existing
## snapshot unreadable even though the SNAPSHOT payload layout did not
## move at all. Bumping without the recompute arm below would therefore
## have turned every `provider-fragments.rbsz` on disk into a hard
## error at the next build, which is why the arm lands first and the
## bump second.
##
## AND THE ARM IS NARROW, which is the half that keeps it honest. It
## translates an UNSUPPORTED VERSION and nothing else: a corrupt
## magic, a truncated payload or trailing bytes still raise, because
## those are not "a cache this build cannot read" — they are a file
## that is not the thing it claims to be, and answering them with a
## silent recomputation is how real corruption stays invisible.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Every snapshot is written by the real `saveProviderGraphSnapshot` or
## by the real `encodeProviderSnapshot`, read back by the real
## `loadProviderGraphSnapshot`, and the version word is moved in the
## real bytes on disk.

import std/[os, strutils, tempfiles, unittest]

import repro_core
import repro_provider_runtime

proc fixture(): ProviderGraphSnapshot =
  ## One fragment with a readable, asserted-on field, so "the snapshot
  ## was recomputed" is told apart from "the snapshot loaded and
  ## happened to be empty".
  ProviderGraphSnapshot(
    providerArtifactId: "provider-artifact-under-test",
    fragments: @[StoredGraphFragment(
      invocationKey: "key-under-test",
      providerArtifactId: "provider-artifact-under-test",
      entryPointId: "pkg.dev-env")])

proc savedBytes(root: string): seq[byte] =
  saveProviderGraphSnapshot(root, fixture())
  let text = readFile(providerSnapshotPath(root))
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc writeBytes(root: string; bytes: seq[byte]) =
  var text = newString(bytes.len)
  for i, b in bytes:
    text[i] = char(b)
  writeFile(providerSnapshotPath(root), text)

proc withVersionWord(bytes: seq[byte]; version: uint16): seq[byte] =
  ## The envelope's version is a little-endian u16 directly after the
  ## 4-byte magic. PINNED at that offset rather than searched for, for
  ## `t_dev_env_large_values`' reason: a scan for the current version's
  ## byte pair lands on whichever one occurs first, which is not
  ## necessarily this field.
  result = bytes
  result[4] = byte(version and 0xff'u16)
  result[5] = byte((version shr 8) and 0xff'u16)

suite "a provider-graph snapshot this build cannot read is RECOMPUTED":

  test "THE POSITIVE CONTROL: an unmolested snapshot loads its fragment":
    # Without this, every case below would pass for a loader that
    # returned an empty snapshot unconditionally.
    let root = createTempDir("provider-snapshot-control", "")
    defer: removeDir(root)
    discard savedBytes(root)
    let loaded = loadProviderGraphSnapshot(root)
    check loaded.providerArtifactId == "provider-artifact-under-test"
    check loaded.fragments.len == 1
    check loaded.fragments[0].invocationKey == "key-under-test"

  test "a MISSING snapshot is an empty one -- the rule this extends":
    let root = createTempDir("provider-snapshot-absent", "")
    defer: removeDir(root)
    createDir(root)
    let loaded = loadProviderGraphSnapshot(root)
    check loaded.fragments.len == 0
    check loaded.providerArtifactId.len == 0

  test "a snapshot one version BELOW this build's is recomputed, not raised":
    # THE CASE THIS FILE EXISTS FOR, and the one measured RED before the
    # recompute arm existed: `loadProviderGraphSnapshot` propagated the
    # codec's `eeUnsupportedVersion` and the build died on a cache.
    #
    # Relative to the accessor, not a literal: after the 1 -> 2 bump
    # this is a genuine legacy v1 snapshot, and it must stay "one below
    # current" across every later bump.
    let root = createTempDir("provider-snapshot-superseded", "")
    defer: removeDir(root)
    let bytes = savedBytes(root)
    writeBytes(root, withVersionWord(bytes,
      providerGraphEnvelopeVersion() - 1'u16))
    let loaded = loadProviderGraphSnapshot(root)
    check loaded.fragments.len == 0
    check loaded.providerArtifactId.len == 0

  test "EVERY version below this build's is recomputed, not only the last":
    # Stated as the property rather than as the one case above, for the
    # reason `actionRecordVersionsThisBuildRefuses` records: a
    # hand-listed set stops covering the newest superseded version the
    # moment the epoch moves, and nothing fails.
    #
    # The probe COUNT is asserted so the loop cannot go vacuous: at
    # `ProviderGraphVersion == 1` the range is `{0}` and at 2 it is
    # `{0, 1}`, so this case measures something at every version this
    # constant has ever held.
    let root = createTempDir("provider-snapshot-all-superseded", "")
    defer: removeDir(root)
    let bytes = savedBytes(root)
    var probed = 0
    for superseded in 0'u16 ..< providerGraphEnvelopeVersion():
      writeBytes(root, withVersionWord(bytes, superseded))
      check loadProviderGraphSnapshot(root).fragments.len == 0
      inc probed
    check probed == int(providerGraphEnvelopeVersion())
    check probed > 0

  test "a FUTURE version is recomputed too, and that is deliberate":
    # A snapshot written by a NEWER build sharing one store. It is not
    # this build's to read and it is not this build's to delete either;
    # recomputing is the only answer that neither crashes nor
    # mis-reads. (`saveProviderGraphSnapshot` will then overwrite it,
    # which is a known consequence of two builds sharing one store and
    # is not what this file is about.)
    let root = createTempDir("provider-snapshot-future", "")
    defer: removeDir(root)
    let bytes = savedBytes(root)
    writeBytes(root, withVersionWord(bytes,
      providerGraphEnvelopeVersion() + 1'u16))
    check loadProviderGraphSnapshot(root).fragments.len == 0

suite "the recompute arm is NARROW: only the version is forgiven":

  test "a corrupt MAGIC still raises":
    # The discriminator. Without these three cases the arm above would
    # be indistinguishable from "ignore every snapshot that fails to
    # decode", which would answer real corruption with a silent
    # recomputation and report nothing.
    let root = createTempDir("provider-snapshot-magic", "")
    defer: removeDir(root)
    var bytes = savedBytes(root)
    bytes[0] = byte(ord('X'))
    writeBytes(root, bytes)
    var message = ""
    try:
      discard loadProviderGraphSnapshot(root)
    except EnvelopeError as err:
      message = err.msg
    check message.len > 0
    check "magic" in message

  test "a TRUNCATED snapshot still raises":
    let root = createTempDir("provider-snapshot-truncated", "")
    defer: removeDir(root)
    let bytes = savedBytes(root)
    writeBytes(root, bytes[0 ..< bytes.len - 8])
    var message = ""
    try:
      discard loadProviderGraphSnapshot(root)
    except EnvelopeError as err:
      message = err.msg
    check message.len > 0

  test "a snapshot carrying ANOTHER envelope type still raises":
    # The type word is the u16 after the version word. A request or a
    # response is not a snapshot, and reading one as a snapshot would
    # be the "wrong layout, right magic" failure the type id exists to
    # refuse.
    let root = createTempDir("provider-snapshot-wrong-type", "")
    defer: removeDir(root)
    var bytes = savedBytes(root)
    bytes[6] = byte(1)
    bytes[7] = byte(0)
    writeBytes(root, bytes)
    var message = ""
    try:
      discard loadProviderGraphSnapshot(root)
    except EnvelopeError as err:
      message = err.msg
    check message.len > 0
    check "type" in message

  test "the CODEC itself still refuses a superseded version by name":
    # The arm belongs to the LOADER, not to the codec: a caller that
    # decodes snapshot bytes it got from somewhere else must still be
    # told. So the refusal is asserted to survive, with its kind.
    let root = createTempDir("provider-snapshot-codec", "")
    defer: removeDir(root)
    let bytes = withVersionWord(savedBytes(root),
      providerGraphEnvelopeVersion() - 1'u16)
    var message = ""
    var kind = eeMalformed
    try:
      discard decodeProviderSnapshot(bytes)
    except EnvelopeError as err:
      message = err.msg
      kind = err.kind
    check message.len > 0
    check "unsupported provider graph envelope version" in message
    check kind == eeUnsupportedVersion

suite "the version this build writes, and the v1 snapshot it supersedes":

  test "the declared provider-graph envelope version is pinned":
    # version-literal-ok: THE pin of this file. Shared-Development-
    # Services F1 moved it 1 -> 2 because `DevEnvResult` grew an
    # `actions` list and the provider RESPONSE payload is positional,
    # so a v1 response decoded as v2 would be read past its end rather
    # than refused -- which is what the loud-but-unnamed `trailing
    # provider response payload bytes` was. F1's second half (§4.8 /
    # D-SS15) moved it 2 -> 3 when `DevEnvServiceMetadata` grew
    # `consumedActionIds`, for the same positional-payload reason one
    # record deeper; this pin confirms that move. This line is meant to
    # fail and name itself on the next bump so the move is confirmed on
    # purpose.
    check providerGraphEnvelopeVersion() == 3'u16

  test "a BYTE-EXACT pre-bump v1 snapshot is recomputed":
    # The strongest form of the rule, and the one that is about the
    # file people actually have on disk: these are not this build's
    # bytes with a word moved, they are the envelope a v1 build wrote
    # -- magic `RBPG`, version 1, type 3 (snapshot), and an EMPTY
    # payload whose layout v1 and v2 share (the bump came from the
    # response, not from here).
    let root = createTempDir("provider-snapshot-v1-literal", "")
    defer: removeDir(root)
    createDir(root)
    var v1: seq[byte] = @[]
    for ch in "RBPG":
      v1.add(byte(ord(ch)))
    # version-literal-ok: these ARE the bytes of a v1 envelope header,
    # which is the subject of the case rather than a stand-in for the
    # current version.
    v1.add(@[byte(1), byte(0)])        # version 1, little-endian
    v1.add(@[byte(3), byte(0)])        # ProviderSnapshotType
    # Payload length 20, and every one of those bytes is accounted for
    # below: an empty `providerArtifactId` (a u32 length of 0), an empty
    # `ProviderManifest` (its own empty id, a zero protocol version and
    # a zero entry-point count: three u32s) and a zero fragment count.
    v1.add(@[byte(20), byte(0), byte(0), byte(0)])
    v1.add(@[byte(0), byte(0), byte(0), byte(0)])  # providerArtifactId: ""
    v1.add(@[byte(0), byte(0), byte(0), byte(0)])  # manifest id: ""
    v1.add(@[byte(0), byte(0), byte(0), byte(0)])  # protocolVersion: 0
    v1.add(@[byte(0), byte(0), byte(0), byte(0)])  # entryPoints: 0
    v1.add(@[byte(0), byte(0), byte(0), byte(0)])  # fragments: 0
    writeBytes(root, v1)
    # It LOADS, and it loads as "nothing cached" rather than raising.
    let loaded = loadProviderGraphSnapshot(root)
    check loaded.fragments.len == 0
    # ...and the file was genuinely a v1 envelope, which the codec says
    # by refusing it. Without this the case above would pass for a v1
    # header this build happened to accept.
    var message = ""
    try:
      discard decodeProviderSnapshot(v1)
    except EnvelopeError as err:
      message = err.msg
    check message.len > 0
    check "version 1" in message

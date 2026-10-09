## Shared-Development-Services L4 — the DECLARED identity and scope cross
## the interface boundary with the service, the v22 envelope carries
## them, a v21 artifact still decodes, and the interface fingerprint
## moves for a change to either and NOT for a change to the
## implementation.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The producers are real ``package`` blocks in ``l4_lift_fixtures.nim``
## expanded by the real DSL macro; the fingerprints are the real
## ``interfaceFingerprint`` over the real codec; the v21 envelope is
## written by the real encoder at version 21 rather than hand-typed.
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, PER SUITE.
##
## * The PAYLOAD suites read ``InterfaceService.identityMode`` /
##   ``.identityStableId`` / ``.scope``, fields that do not exist at the
##   base commit, so there the module does not compile and the compiler's
##   ``undeclared field`` IS the measurement. Said plainly rather than
##   implied.
## * The FINGERPRINT suite is the interesting one, and only ONE of its
##   four assertions discriminates at the base. Before this change no
##   part of a service's identity reached ``ProjectInterface``, so all
##   four fixtures lift to the same digest: "an implementation change
##   does not move it" PASSES at the base and says nothing, while "an
##   identity change moves it" and "a scope change moves it" FAIL there.
##   Those two are the gate; the first is the pair's other half and the
##   guard that the new rows did not start carrying the implementation.
##
## Governing text — ``Shared-Development-Services.md``:
##
## * §4.2 "``stable \"<id>\"`` … There is one instance per ``(id,
##   scope)``, and it survives redefinition."
## * §4.3 "The comparison is therefore on the **interface fingerprint**
##   the lift already produces, which is distinct from the
##   implementation."
## * L3 ``:gate:`` — the lift carries "the declared identity and scope",
##   the clause L3 deferred to this milestone.

import std/[strutils, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_core              # EnvelopeError
import repro_hash              # blake3DomainDigest / hdMetadataEnvelope

import ./l4_lift_fixtures

proc addU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc addU32Le(outp: var seq[byte]; value: uint32) =
  outp.add(byte(value and 0xff'u32))
  outp.add(byte((value shr 8) and 0xff'u32))
  outp.add(byte((value shr 16) and 0xff'u32))
  outp.add(byte((value shr 24) and 0xff'u32))

proc encodeV21ProjectInterfaceArtifact(pi: ProjectInterface): seq[byte] =
  ## A v21 envelope: the service rows carry no identity block, so the v22
  ## reader must default all three fields. Written by the CURRENT codec at
  ## version 21, exactly as ``encodeV20ProjectInterfaceArtifact`` is in
  ## the L3 codec test and ``encodeV11…`` in RP4's — a hand-typed byte
  ## string would be a guess about what v21 was.
  var payload = encodeInterfacePayload(pi, 21'u16)
  let fingerprint = blake3DomainDigest(
    encodeInterfacePayload(pi, 21'u16, forFingerprint = true),
    hdMetadataEnvelope)
  payload.add(byte(ord(fingerprint.algorithm)))
  payload.add(byte(ord(fingerprint.domain)))
  payload.add(fingerprint.bytes)
  payload.add(if pi.standardBuildEligible: 1'u8 else: 0'u8)
  result.add([byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))])
  result.addU16Le(21'u16)
  result.addU16Le(101'u16)
  result.addU32Le(uint32(payload.len))
  result.add(payload)

proc packageDefNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError,
    "fixture drift: no package named " & name & " is registered")

proc liftedInterface(name: string): ProjectInterface =
  toProjectInterface(packageDefNamed(name))

proc namesNormalised(name: string): ProjectInterface =
  ## The lifted interface with every PACKAGE-DERIVED name replaced by a
  ## constant — the same normalisation, and the same reason, as L3's
  ## sibling file: the scenario is ONE package edited between two
  ## revisions, four fixture packages cannot share a name inside one
  ## module, and without undoing the artifice every pair would differ and
  ## the comparison would say nothing. Nothing else is normalised, which
  ## is what keeps the negative direction meaningful.
  result = liftedInterface(name)
  result.projectName = "fingerprint-comparison"
  result.packageName = "fingerprint-comparison"
  for act in result.publicActivities.mitems:
    act.handleType = "NormalisedHandle_" & act.name
  for svc in result.publicServices.mitems:
    if svc.handleType.len > 0:
      svc.handleType = "NormalisedHandle_" & svc.activityName

const IdentityMarker = "l4-identity-marker-0a1b2c3d"
  ## A stable id chosen to be findable in the encoded payload. The two
  ## malformed-byte cases below need the OFFSET of a row's identity mode
  ## and scope bytes, and the first draft of them computed it by counting
  ## backwards from the payload's end. That arithmetic was wrong by four
  ## bytes -- the empty ``publicActivities`` count -- and the test said so
  ## by failing its own precondition rather than by passing vacuously,
  ## which is the only reason it was caught. Locating the row by a marker
  ## cannot drift when another trailing block is added.

proc markedServicePayload(): seq[byte] =
  ## A one-service payload whose row carries ``IdentityMarker`` as its
  ## stable id, ``isimStable`` and ``issUser``.
  var pi: ProjectInterface
  pi.projectName = "codec"
  pi.packageName = "codec"
  pi.publicServices = @[InterfaceService(name: "s",
    identityMode: isimStable, identityStableId: IdentityMarker,
    scope: issUser, location: SourceLocation(file: "r.nim", line: 1))]
  encodeInterfacePayload(pi)

proc markerStart(bytes: seq[byte]): int =
  ## Where ``IdentityMarker``'s text begins in ``bytes``.
  let needle = cast[seq[byte]](IdentityMarker)
  for start in 0 .. bytes.len - needle.len:
    var hit = true
    for i in 0 ..< needle.len:
      if bytes[start + i] != needle[i]:
        hit = false
        break
    if hit:
      return start
  raise newException(ValueError,
    "fixture drift: the identity marker is not in the encoded payload")

proc identityModeOffset(bytes: seq[byte]): int =
  ## The row layout is ``<mode byte><u32 id length><id text><scope
  ## byte>``, so the mode byte is five bytes before the id's text.
  markerStart(bytes) - 5

proc scopeOffset(bytes: seq[byte]): int =
  markerStart(bytes) + IdentityMarker.len

proc serviceNamed(iface: ProjectInterface; name: string): InterfaceService =
  for svc in iface.publicServices:
    if svc.name == name:
      return svc
  raise newException(ValueError, "no lifted service named " & name)

suite "L4 — the lift carries each service's declared identity":

  test "a `stable` service lifts its mode AND its id":
    let svc = liftedInterface("l4LiftProducer").serviceNamed("zitadel")
    check svc.identityMode == isimStable
    check svc.identityStableId == "com.metacraft-labs.sso"

  test "a `derived` service lifts the mode and NO id":
    let svc = liftedInterface("l4LiftProducer").serviceNamed("bootstrap")
    check svc.identityMode == isimDerived
    check svc.identityStableId == ""

  test "a service that declared neither lifts §4's two defaults":
    let svc = liftedInterface("l4LiftProducer").serviceNamed("nginx")
    check svc.identityMode == isimDerived
    check svc.identityStableId == ""
    check svc.scope == issProject

  test "the id is carried verbatim, not digested or qualified":
    # §4.2: the id is "a name, not a secret", chosen reverse-DNS-style.
    # The whole value of that is that the string in the recipe is the
    # string everywhere else, so the lift must not hash it or prefix it
    # with the package name.
    let svc = liftedInterface("l4LiftProducer").serviceNamed("hostAgent")
    check svc.identityStableId == "com.metacraft-labs.host-agent"

suite "L4 — the lift carries each service's declared scope":

  test "all four scopes reach the artifact":
    let iface = liftedInterface("l4LiftProducer")
    check iface.serviceNamed("zitadel").scope == issWorkspace
    check iface.serviceNamed("bootstrap").scope == issProject
    check iface.serviceNamed("hostAgent").scope == issSystem
    check iface.serviceNamed("perUser").scope == issUser

  test "and the set covers the enum, derived rather than listed":
    # A fifth scope added to the DSL without a lifted spelling fails
    # here rather than being noticed by a reader.
    let iface = liftedInterface("l4LiftProducer")
    var seen: seq[InterfaceServiceScope] = @[]
    for svc in iface.publicServices:
      if svc.scope notin seen:
        seen.add(svc.scope)
    check seen.len == int(high(InterfaceServiceScope)) + 1

  test "a package-level service carries identity and scope too":
    # It has no activity and no handle type, and that must not be the
    # reason its instance key goes missing.
    let svc = liftedInterface("l4LiftProducer").serviceNamed("hostAgent")
    check svc.activityName == ""
    check svc.handleType == ""
    check svc.identityMode == isimStable
    check svc.scope == issSystem

suite "L4 — identity and scope live on the SERVICE row, by design":
  ## L3's record left a note saying this milestone would add them to
  ## ``InterfaceActivity``. It did not, and the placement is asserted so
  ## the decision is falsifiable rather than a comment: `identity` and
  ## `scope` are setters of a `service`, one activity may declare
  ## several, and §4 keys an INSTANCE -- a service.

  test "an InterfaceService has the three fields":
    # The positive control for the negative assertion below: without it,
    # "an activity has no identityMode" would also pass if the fields
    # had never been added anywhere.
    var svc: InterfaceService
    check compiles(svc.identityMode)
    check compiles(svc.identityStableId)
    check compiles(svc.scope)

  test "an InterfaceActivity has none of them":
    var act: InterfaceActivity
    check not compiles(act.identityMode)
    check not compiles(act.identityStableId)

  test "and it names the service rows that do":
    let iface = liftedInterface("l4LiftProducer")
    for act in iface.publicActivities:
      if act.name != "sso":
        continue
      check act.services == @["zitadel", "bootstrap"]
      for name in act.services:
        # Every named service resolves to a row carrying the key.
        discard iface.serviceNamed(name)
      return
    check false

suite "L4 — the v22 envelope round-trips identity and scope":

  test "every (mode, scope) pairing survives encode + decode":
    var pi: ProjectInterface
    pi.projectName = "codec"
    pi.packageName = "codec"
    var expected: seq[InterfaceService] = @[]
    for mode in InterfaceServiceIdentityMode:
      for scope in InterfaceServiceScope:
        let svc = InterfaceService(
          name: $mode & "-" & $scope,
          activityName: "a",
          handleType: "H",
          identityMode: mode,
          identityStableId:
            (if mode == isimStable: "id." & $scope else: ""),
          scope: scope,
          location: SourceLocation(file: "repro.nim", line: 7))
        pi.publicServices.add(svc)
        expected.add(svc)
    let decoded = decodeInterfacePayload(encodeInterfacePayload(pi))
    check decoded.publicServices.len == expected.len
    for i in 0 ..< expected.len:
      check decoded.publicServices[i].identityMode ==
        expected[i].identityMode
      check decoded.publicServices[i].identityStableId ==
        expected[i].identityStableId
      check decoded.publicServices[i].scope == expected[i].scope

  test "a v21 envelope decodes with §4's defaults, not with a failure":
    var pi: ProjectInterface
    pi.projectName = "infra"
    pi.packageName = "infra"
    # A stable id and a wide scope are SET on the way in, so the test can
    # tell "the v21 reader defaulted them" from "the v21 writer happened
    # to be handed defaults".
    pi.publicServices = @[InterfaceService(
      name: "zitadel", activityName: "sso", handleType: "H",
      identityMode: isimStable, identityStableId: "com.example.sso",
      scope: issWorkspace,
      location: SourceLocation(file: "repro.nim", line: 9))]
    let decoded = decodeProjectInterfaceArtifact(
      encodeV21ProjectInterfaceArtifact(pi))
    check decoded.projectInterface.publicServices.len == 1
    check decoded.projectInterface.publicServices[0].name == "zitadel"
    check decoded.projectInterface.publicServices[0].identityMode ==
      isimDerived
    check decoded.projectInterface.publicServices[0].identityStableId == ""
    check decoded.projectInterface.publicServices[0].scope == issProject

  test "an out-of-range identity mode byte is refused, not cast":
    var bytes = markedServicePayload()
    let at = identityModeOffset(bytes)
    check bytes[at] == byte(ord(isimStable))
    bytes[at] = 9'u8
    expect EnvelopeError:
      discard decodeInterfacePayload(bytes)

  test "an out-of-range scope byte is refused, not cast":
    var bytes = markedServicePayload()
    let at = scopeOffset(bytes)
    check bytes[at] == byte(ord(issUser))
    bytes[at] = 9'u8
    expect EnvelopeError:
      discard decodeInterfacePayload(bytes)

suite "L4 — the interface fingerprint discriminates on identity and scope":

  test "an IMPLEMENTATION change leaves the fingerprint alone":
    # §4.3's middle row — "a differing implementation is immaterial" —
    # only means something if a differing implementation really is
    # immaterial. NOTE ON DIRECTION: this assertion also passes at the
    # base commit, where nothing about a service's identity reaches the
    # interface. It is here as the pair's other half, and as the guard
    # that the v22 rows did not start carrying the implementation.
    check interfaceFingerprint(namesNormalised("l4SigBaseline")) ==
      interfaceFingerprint(namesNormalised("l4SigSameImpl"))

  test "a different stable ID moves the fingerprint":
    # The gate. Fails before this change, because both sides hashed to
    # the same digest.
    check interfaceFingerprint(namesNormalised("l4SigBaseline")) !=
      interfaceFingerprint(namesNormalised("l4SigOtherIdentity"))

  test "a different SCOPE moves the fingerprint":
    # The second half of the key, and the second assertion that fails
    # before this change.
    check interfaceFingerprint(namesNormalised("l4SigBaseline")) !=
      interfaceFingerprint(namesNormalised("l4SigOtherScope"))

  test "the implementation pair really did differ (control)":
    # Without this, "an implementation change does not move the
    # fingerprint" would also pass if the two fixtures had silently
    # become identical — fixture drift that looks exactly like success.
    let baseline = packageDefNamed("l4SigBaseline")
    let same = packageDefNamed("l4SigSameImpl")
    check baseline.devEnvBodyHash.len > 0
    check baseline.devEnvBodyHash != same.devEnvBodyHash

  test "the identity pair differs ONLY in the id (control)":
    # The mirror control: if `l4SigOtherIdentity` had drifted in its argv
    # too, the positive assertion above would pass for the wrong reason.
    let baseline = liftedInterface("l4SigBaseline")
    let other = liftedInterface("l4SigOtherIdentity")
    check baseline.publicServices.len == 1
    check other.publicServices.len == 1
    check baseline.publicServices[0].name == other.publicServices[0].name
    check baseline.publicServices[0].scope == other.publicServices[0].scope
    check baseline.publicServices[0].identityStableId ==
      "com.example.api"
    check other.publicServices[0].identityStableId ==
      "com.example.api.OTHER"

  test "the scope pair differs ONLY in the scope (control)":
    let baseline = liftedInterface("l4SigBaseline")
    let other = liftedInterface("l4SigOtherScope")
    check baseline.publicServices[0].identityStableId ==
      other.publicServices[0].identityStableId
    check baseline.publicServices[0].scope == issWorkspace
    check other.publicServices[0].scope == issUser

  test "moving the declaration down the file does NOT move it":
    # TI3: the fingerprint is a projection over the SEMANTIC contract. The
    # three new values sit AFTER ``location`` in the row, so a
    # ``forFingerprint`` flag that stopped being threaded would show up
    # here rather than in a consumer's spurious rebuild.
    var moved = namesNormalised("l4SigBaseline")
    for svc in moved.publicServices.mitems:
      svc.location.line += 100
      svc.location.file = "somewhere/else.nim"
    for act in moved.publicActivities.mitems:
      act.location.line += 100
    check interfaceFingerprint(namesNormalised("l4SigBaseline")) ==
      interfaceFingerprint(moved)

  test "the location shift was real (control)":
    var moved = namesNormalised("l4SigBaseline")
    let before = moved.publicServices[0].location.line
    for svc in moved.publicServices.mitems:
      svc.location.line += 100
    check moved.publicServices[0].location.line == before + 100

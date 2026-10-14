## Shared-Development-Services L6 — the DECLARED MAJOR COMPATIBILITY
## FIELD crosses the interface boundary with the service, the v25
## envelope carries it, a v24 artifact still decodes to the UNDECLARED
## major, and the interface fingerprint moves for a change to the major
## and NOT for a change to the implementation.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The producers are real ``package`` blocks in ``l6_lift_fixtures.nim``
## expanded by the real DSL macro; the fingerprints are the real
## ``interfaceFingerprint`` over the real codec; the v24 envelope is
## written by the real encoder at version 24 rather than hand-typed.
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, PER SUITE.
##
## * The PAYLOAD suites read ``ServiceInterfaceDef.compatibilityMajor``
##   and ``InterfaceService.compatibilityMajor``, fields that do not
##   exist at the base commit ``dc41f156f``, so there the module does not
##   compile and the compiler's ``undeclared field`` IS the measurement.
##   Said plainly rather than implied.
## * The FINGERPRINT suite is the interesting one, and only TWO of its
##   three assertions discriminate at the base. Before this change no
##   part of a service's major reached ``ProjectInterface``, so all four
##   fixtures lift to the same digest: "an implementation change does not
##   move it" PASSES at the base and says nothing, while "a major change
##   moves it" and "an absent setter moves it" FAIL there. Those two are
##   the gate; the first is the pair's other half and the guard that the
##   new field did not start carrying the implementation.
## * The v24 suite's assertion that a v24 row decodes to major 0 also
##   cannot be written at the base (no field to read), but its *reason*
##   is behavioural and is asserted downstream in
##   ``t_l6_attach_decision_has_three_outcomes.nim``: two undeclared
##   definitions attach SILENTLY, which is what makes 0-and-not-1 the
##   right default.
##
## Governing text — ``Shared-Development-Services.md``:
##
## * §4.3's table: "| major compatibility field differs | **Refuse.** |"
## * §4.3 "The comparison is therefore on the **interface fingerprint**
##   the lift already produces, which is distinct from the
##   implementation."
## * §10: "an incompatible major refuses".

import std/[strutils, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_core              # EnvelopeError
import repro_hash              # blake3DomainDigest / hdMetadataEnvelope

import ./l6_lift_fixtures

proc addU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc addU32Le(outp: var seq[byte]; value: uint32) =
  outp.add(byte(value and 0xff'u32))
  outp.add(byte((value shr 8) and 0xff'u32))
  outp.add(byte((value shr 16) and 0xff'u32))
  outp.add(byte((value shr 24) and 0xff'u32))

proc encodeV24ProjectInterfaceArtifact(pi: ProjectInterface): seq[byte] =
  ## A v24 envelope: the service rows carry no major, so the v25 reader
  ## must default it. Written by the CURRENT codec at version 24, exactly
  ## as ``encodeV23ProjectInterfaceArtifact`` is in L4's sibling file and
  ## ``encodeV20…`` in L3's — a hand-typed byte string would be a guess
  ## about what v24 was.
  ##
  ## v24 and NOT v22: the major moved from v23 to v25 when this branch
  ## merged ``agents``, whose own v22 is the macOS application fields on
  ## the tarball archive detail -- see ``EnvelopeVersion``'s note on the
  ## numbering.
  var payload = encodeInterfacePayload(pi, 24'u16)
  let fingerprint = blake3DomainDigest(
    encodeInterfacePayload(pi, 24'u16, forFingerprint = true),
    hdMetadataEnvelope)
  payload.add(byte(ord(fingerprint.algorithm)))
  payload.add(byte(ord(fingerprint.domain)))
  payload.add(fingerprint.bytes)
  payload.add(if pi.standardBuildEligible: 1'u8 else: 0'u8)
  result.add([byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))])
  result.addU16Le(24'u16)
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

proc serviceNamed(pi: ProjectInterface; name: string): InterfaceService =
  for svc in pi.publicServices:
    if svc.name == name:
      return svc
  raise newException(ValueError,
    "no lifted service named " & name & " in " & pi.packageName)

proc interfaceDefNamed(pkg, name: string): ServiceInterfaceDef =
  for def in registeredServiceInterfaces():
    if def.packageName == pkg and def.name == name:
      return def
  raise newException(ValueError,
    "no ServiceInterfaceDef " & pkg & "." & name)

proc namesNormalised(name: string): ProjectInterface =
  ## The lifted interface with every PACKAGE-DERIVED name replaced by a
  ## constant — the same normalisation, and the same reason, as L3's and
  ## L4's sibling files: the scenario is ONE package edited between two
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

proc fingerprintHex(name: string): string =
  toHex(interfaceFingerprint(namesNormalised(name)).bytes).toLowerAscii()

suite "L6 — the declared major reaches the DSL's interface record":

  test "`compatibility 2` lowers to compatibilityMajor 2":
    check interfaceDefNamed("l6LiftProducer", "zitadel").compatibilityMajor ==
      2'u32

  test "a body with NO `compatibility` setter carries the undeclared 0":
    # §4.3's undeclared major, and the value every pre-v25 artifact
    # decodes to. There is no third "unset" state, deliberately: the DSL
    # refuses `compatibility 0`, so 0 in a record can only mean "the
    # author wrote nothing".
    check interfaceDefNamed("l6LiftProducer", "bootstrap").compatibilityMajor ==
      0'u32

  test "`compatibility 1` is distinguishable from declaring nothing":
    check interfaceDefNamed("l6LiftProducer", "nginx").compatibilityMajor ==
      1'u32

  test "the LARGEST major reaches the record, not just a small one":
    # A literal above `int32` range parses as `nnkInt64Lit`. The first
    # draft of the setter tested `arg.kind != nnkIntLit` and refused this
    # with "needs an INTEGER LITERAL; `4294967295'i64` is not one" -- a
    # message that contradicts itself -- while leaving the
    # does-not-fit refusal unreachable. Found by this milestone's probe
    # sweep over 40 generated spellings; this is the end-to-end guard.
    check interfaceDefNamed("l6LiftProducer", "maxGen").compatibilityMajor ==
      high(uint32)

  test "a PACKAGE-LEVEL service carries it too":
    # The row shape with no declaring activity. It goes through the same
    # emitter (`m5ServiceEmission`) and the same shared reading, which is
    # what this pins.
    let def = interfaceDefNamed("l6LiftProducer", "hostAgent")
    check def.compatibilityMajor == 7'u32
    check def.activityName == ""

suite "L6 — and crosses the lift onto `InterfaceService`":

  test "every declared major reaches `publicServices`":
    let pi = liftedInterface("l6LiftProducer")
    check serviceNamed(pi, "zitadel").compatibilityMajor == 2'u32
    check serviceNamed(pi, "bootstrap").compatibilityMajor == 0'u32
    check serviceNamed(pi, "nginx").compatibilityMajor == 1'u32
    check serviceNamed(pi, "hostAgent").compatibilityMajor == 7'u32
    check serviceNamed(pi, "maxGen").compatibilityMajor == high(uint32)

  test "and survives the v25 envelope round-trip":
    let pi = liftedInterface("l6LiftProducer")
    let decoded = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifactFor(pi))).projectInterface
    check serviceNamed(decoded, "zitadel").compatibilityMajor == 2'u32
    check serviceNamed(decoded, "bootstrap").compatibilityMajor == 0'u32
    check serviceNamed(decoded, "nginx").compatibilityMajor == 1'u32
    check serviceNamed(decoded, "hostAgent").compatibilityMajor == 7'u32
    check serviceNamed(decoded, "maxGen").compatibilityMajor == high(uint32)

  test "a large major round-trips without wrapping":
    # The DSL refuses a value above `high(uint32)`; this is the boundary
    # it allows, and the codec has to carry all 32 bits of it or two
    # different generations would compare equal.
    var pi = liftedInterface("l6LiftProducer")
    for svc in pi.publicServices.mitems:
      if svc.name == "zitadel":
        svc.compatibilityMajor = high(uint32)
    let decoded = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifactFor(pi))).projectInterface
    check serviceNamed(decoded, "zitadel").compatibilityMajor == high(uint32)

suite "L6 — a v24 artifact still decodes, to the undeclared major":

  test "a v24 envelope's service rows decode with major 0":
    let pi = liftedInterface("l6LiftProducer")
    let decoded = decodeProjectInterfaceArtifact(
      encodeV24ProjectInterfaceArtifact(pi)).projectInterface
    # Everything v24 DID carry is still there …
    check serviceNamed(decoded, "zitadel").identityStableId ==
      "com.metacraft-labs.sso"
    check serviceNamed(decoded, "zitadel").scope == issWorkspace
    # … and the major it did not carry is the undeclared value rather
    # than a failure or an invented "unset".
    check serviceNamed(decoded, "zitadel").compatibilityMajor == 0'u32
    check serviceNamed(decoded, "hostAgent").compatibilityMajor == 0'u32

  test "the FIRST UNKNOWN envelope version is refused rather than misread":
    # The property: a version this build does not know is refused rather
    # than read with shifted offsets. So the probe has to be the FIRST
    # UNKNOWN version -- one past the current one.
    #
    # IT IS NO LONGER A LITERAL, AND THAT IS THE POINT OF THIS EDIT.
    # This probe hard-coded a byte and the pin had to be hand-moved on
    # every envelope bump (and the numbers it was moved through are no
    # longer even the right ones: this branch's blocks were renumbered up
    # by two on merging ``agents`` -- see ``EnvelopeVersion``'s note). Each
    # time it was silently wrong first -- pinned AT the current version
    # it measured the opposite property, that the current version
    # decodes correctly (which it does, and must) -- and each time a
    # regression sweep found it rather than a compiler. The cause was
    # that `EnvelopeVersion` is private, so the probe had no constant to
    # be relative to; `firstUnknownInterfaceEnvelopeVersion()` is that
    # name, and the next bump needs no edit here.
    #
    # THE TWO ASSERTIONS BELOW ARE NOT THE SAME ASSERTION. The first is
    # the positive control that makes the second discriminate: without
    # it, a `firstUnknownInterfaceEnvelopeVersion()` that returned some
    # absurd number (or that this file poked into the wrong offset)
    # would still produce a refusal, and the case would pass while
    # measuring nothing about the version gate.
    let probe = firstUnknownInterfaceEnvelopeVersion()
    check probe == interfaceEnvelopeVersion() + 1
    var current = encodeProjectInterfaceArtifact(
      artifactFor(liftedInterface("l6LiftProducer")))
    # The control: the CURRENT version, at the same offsets this case
    # pokes, decodes. If this fails the offsets below are wrong and the
    # refusal they produce would say nothing about the version.
    current[4] = byte(interfaceEnvelopeVersion() and 0xff'u16)
    current[5] = byte((interfaceEnvelopeVersion() shr 8) and 0xff'u16)
    check decodeProjectInterfaceArtifact(current)
      .projectInterface.publicServices.len > 0
    var bytes = encodeProjectInterfaceArtifact(
      artifactFor(liftedInterface("l6LiftProducer")))
    bytes[4] = byte(probe and 0xff'u16)
    bytes[5] = byte((probe shr 8) and 0xff'u16)
    expect EnvelopeError:
      discard decodeProjectInterfaceArtifact(bytes)

suite "L6 — the fingerprint moves for the major and not for the impl":

  test "THE CONTROL: an implementation-only change does NOT move it":
    # §4.3's own words for why this is the clause that keeps the warning
    # meaningful: "a design that warns on every difference fails this
    # gate even though every warning it prints is true."
    #
    # At the base commit this assertion PASSES and says nothing (no part
    # of the major reached the interface), which is stated in the file
    # header. Its value is as the other half of the pair below: it is
    # what catches a v25 field that started carrying argv.
    check fingerprintHex("l6SigBaseline") == fingerprintHex("l6SigSameImpl")

  test "a changed major DOES move it":
    check fingerprintHex("l6SigBaseline") != fingerprintHex("l6SigOtherMajor")

  test "and so does deleting the setter":
    check fingerprintHex("l6SigBaseline") != fingerprintHex("l6SigNoMajor")

  test "the two differing fixtures differ from each other as well":
    # 3 != 0, so these must not collapse either. Without this a
    # fingerprint that merely recorded "a major was declared" would pass
    # both assertions above.
    check fingerprintHex("l6SigOtherMajor") != fingerprintHex("l6SigNoMajor")

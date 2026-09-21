## The endorsement chain behind an Intel TDX quote: the Provisioning
## Certification Key, its authority, and Intel's root — **rooted at
## Intel by construction**.
##
## ## The one thing to read before anything else
##
## `evaluateIntelPckChain` takes no trust anchor.
##
## Not an anchor that defaults to Intel's, not a policy that names one,
## not a flag, not a file, not an environment variable, not a
## compile-time define. The procedure's whole parameter list is three
## certificates, a set of revocation lists and a clock, and the set of
## root keys it will accept is `IntelRootKeys`, a `const`. There is no
## configuration of this function under which a chain rooted anywhere
## else is acceptable, because there is no configuration of this
## function.
##
## That is the difference between "the default root is Intel's" and "the
## root is Intel's". The first is a setting, and a setting is a thing an
## operator, a document, a mistake or an attacker can move.
##
## `IntelPckChainSignature` below records the parameter list as a type,
## and a `static` assertion pins `evaluateIntelPckChain` to it. Adding a
## parameter — an anchor, an "allowed roots", a bool — stops the
## compilation, by name, rather than quietly widening what the verifier
## trusts.
##
## ## Why the root is pinned as a KEY and not as a certificate
##
## An anchor is a public key. A certificate is a document *about* a
## public key, and every field of it except the key is a thing an
## impostor may copy: the subject name, the issuer name, the serial, the
## validity window, the extensions, the very algorithm identifiers.
##
## This is not a hypothetical here, and that is why it is worth saying
## twice. Intel's **own** quote-verification library ships sample data
## whose trust root carries Intel's distinguished name character for
## character, is self-signed, is a certificate authority, and endorses a
## complete chain that genuinely verifies under it — and whose key is a
## different key. A verifier matched on any field but the key accepts
## it. So what is pinned here is the curve point, and the common name is
## checked *against the pinned entry* afterwards.
##
## ## The profile
##
## Intel's certificates are `ecdsa-with-SHA256` over `prime256v1`, which
## is the profile `x509.nim` already reads, so this is a policy over
## that reader rather than a second reader. One thing had to change
## there and it is recorded in `MaxSerialValueOctets`: Intel's serials
## are twenty octets with the top bit set, so DER writes twenty-one
## content octets, and a bound on the encoding refused every genuine
## provisioning certificate there is.
##
## What this module adds is Intel's own extension arc — the platform
## instance identifier, the sixteen component security-version numbers,
## the platform configuration enclave's own version, and the family-
## model-stepping-platform-custom identifier that says which TCB
## information document describes this part.
##
## ## What this build does NOT do, stated rather than implied
##
##   * It does not fetch. Intel's provisioning service is an HTTP
##     service; every byte here arrives from the caller.
##   * It reads Intel's published revocation lists and **requires** a
##     current one, issued by the authority that issued the certificate
##     under test and signed by it.
##   * It implements no `authorityKeyIdentifier` matching. The chain is
##     three certificates in a known order; there is nothing to search.
##
## ## Mocking
##
## None. Real Intel DER, real P-256 through BearSSL.

import std/[strutils]

import ./x509

# ---------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------

type
  IntelChainRejection* = enum
    ## `tcAccepted` is the only value here that is not a refusal.
    ##
    ## **A kind is not always a rule here, and a case must not read it
    ## as one.** Three of these values are produced by more than one
    ## rule: `tcNameMismatch` by two, `tcNotACertificateAuthority` by
    ## two, `tcExpired` by three (one per element), and
    ## `tcNoRevocationData` by five conditions funnelling into a single
    ## refusal site. Asserting the kind alone says only that one of that
    ## value's rules fired.
    ##
    ## What makes a case mean ONE rule is the `detail` sentence, and
    ## every one of those rules carries a different one — including the
    ## five revocation conditions, which name individually why each list
    ## they were handed was set aside. Assert the kind *and* the
    ## sentence; `intelChainMessagesAreDistinguishable` only guarantees
    ## that two different KINDS cannot be confused.
    tcAccepted
    tcMalformed
    tcNameMismatch
    tcNotSelfIssued
    tcNotACertificateAuthority
    tcUnrecognisedCriticalExtension
    tcBadSignature
    tcRootIsNotIntel
    tcRootNameDisagreesWithKey
    tcExpired
    tcNoRevocationData
    tcRevoked
    tcLeafIsNotAProvisioningCertificate
    tcLeafCarriesNoPlatformExtension
    tcLeafCarriesNoPlatformIdentifier
    tcLeafCarriesNoPlatformTcb
    tcAuthorityIsNotOneIntelIssues

const
  IntelChainMessage*: array[IntelChainRejection, string] = [
    tcAccepted:
      "this chain links by name, verifies link by link, ends at a root " &
      "this build holds the key of, and is inside every validity window " &
      "it states",
    tcMalformed:
      "an element of this chain did not read as a certificate of the " &
      "shape the vendor issues",
    tcNameMismatch:
      "an element names an issuer that the element above it is not",
    tcNotSelfIssued:
      "the last element of this chain names an issuer other than " &
      "itself, so it is not the self-issued end a chain terminates in",
    tcNotACertificateAuthority:
      "an element issued the element below it without carrying the " &
      "constraint that authorises it to issue anything",
    tcUnrecognisedCriticalExtension:
      "an element marks an extension critical that this build cannot " &
      "act on, and its issuer said to refuse rather than ignore it",
    tcBadSignature:
      "an element does not verify under the key of the element above it",
    tcRootIsNotIntel:
      "the key this chain ends at is not one of the roots compiled into " &
      "this verifier, so nothing it says is endorsed by anybody this " &
      "build recognises",
    tcRootNameDisagreesWithKey:
      "the root's key is one this build holds and the name beside it " &
      "belongs to a different one",
    tcExpired:
      "an element is being used outside the window it states",
    tcNoRevocationData:
      "no current revocation list issued by the authority under test " &
      "was supplied, so whether it has withdrawn this certificate was " &
      "never asked",
    tcRevoked:
      "the provisioning certificate's serial number appears on the " &
      "current withdrawal list its own authority publishes",
    tcLeafIsNotAProvisioningCertificate:
      "the first element is not named as the provisioning certification " &
      "key a quoting enclave's report is signed with",
    tcLeafCarriesNoPlatformExtension:
      "the first element carries none of the vendor's own platform " &
      "description, so there is nothing saying which part it is for",
    tcLeafCarriesNoPlatformIdentifier:
      "the platform description states no family-model-stepping value, " &
      "so no trusted-computing-base document can be selected for it",
    tcLeafCarriesNoPlatformTcb:
      "the platform description does not state all sixteen component " &
      "versions and the configuration enclave's own, so a version " &
      "comparison would be made against a number that is missing",
    tcAuthorityIsNotOneIntelIssues:
      "the middle element is named as neither of the two provisioning " &
      "authorities the vendor operates"]

proc intelChainMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another.
  for a in IntelChainRejection:
    for b in IntelChainRejection:
      if a == b: continue
      if IntelChainMessage[a] in IntelChainMessage[b]: return false
  true

# ---------------------------------------------------------------------
# Intel's own extension arc
# ---------------------------------------------------------------------

const
  IntelSgxArc* = "1.2.840.113741.1.13.1"
    ## Intel's private enterprise arc, `1.2.840.113741`, sub-arc
    ## `1.13.1`. The whole platform description hangs off it, as a
    ## nested `SEQUENCE OF SEQUENCE { OID, value }` rather than as one
    ## extension per fact.
  OidIntelPpid* = IntelSgxArc & ".1"
  OidIntelTcb* = IntelSgxArc & ".2"
  OidIntelPceId* = IntelSgxArc & ".3"
  OidIntelFmspc* = IntelSgxArc & ".4"
  OidIntelSgxType* = IntelSgxArc & ".5"
  OidIntelPlatformInstanceId* = IntelSgxArc & ".6"
  OidIntelConfiguration* = IntelSgxArc & ".7"
  OidIntelPceSvn* = OidIntelTcb & ".17"
  OidIntelCpuSvn* = OidIntelTcb & ".18"

  IntelTcbComponentCount* = 16
    ## `sgxtcbcomp01svn` … `sgxtcbcomp16svn`, at `…2.1` … `…2.16`.
  MaxTcbComponent* = 255
    ## Each of the sixteen platform components is one byte.
  MaxPceSvn* = 65_535
    ## The configuration enclave's own version is sixteen bits, and the
    ## vendor's own sample data uses the upper half of that range.

  FmspcLen* = 6
  PpidLen* = 16
  CpuSvnLen* = 16

  PckLeafCommonName* = "Intel SGX PCK Certificate"
  PckPlatformCaCommonName* = "Intel SGX PCK Platform CA"
  PckProcessorCaCommonName* = "Intel SGX PCK Processor CA"
  IntelPckAuthorityCommonNames*: array[2, string] =
    [PckPlatformCaCommonName, PckProcessorCaCommonName]
    ## The two names the middle element may carry. A platform authority
    ## issues for a multi-socket platform registered with the vendor; a
    ## processor authority issues per part. Both chains end at the SAME
    ## root and both publish their own withdrawal list, which is why
    ## they are one decision here and not two — and why the list a chain
    ## is judged against has to be the one its OWN authority issued.

  RecognisedIntelCriticalOids*: array[2, string] =
    [OidBasicConstraints, OidKeyUsage]
    ## RFC 5280 §4.2 applied to this profile: the two critical
    ## extensions Intel's certificates carry and this build acts on. It
    ## takes no parameter for the same reason the root set does not.

type
  IntelPlatformTcb* = object
    ## What the provisioning certificate says about the part's
    ## trusted-computing base. Every field is compared against a
    ## vendor-signed document later; none of it is a claim the machine
    ## makes about itself, because the vendor signed this certificate.
    components*: array[IntelTcbComponentCount, int]
    pceSvn*: int
    cpuSvn*: seq[byte]
    hasComponents*, hasPceSvn*: bool

  IntelPlatformDescription* = object
    present*: bool
    ppid*: seq[byte]
    pceId*: seq[byte]
    fmspcHex*: string
    tcb*: IntelPlatformTcb

  IntelChainVerdict* = object
    reason*: IntelChainRejection
    detail*: string
    rootMatched*: bool
    leafCn*, authorityCn*, rootCn*: string
    authorityIsPlatform*: bool
    platform*: IntelPlatformDescription
    leafSerialHex*, authoritySerialHex*: string
    endorsedAt*: int64
      ## The provisioning certificate's `notBefore`. Inside the signed
      ## certificate, so the machine being judged cannot move it.
    revocationConsulted*: bool

  IntelPckChainSignature* = proc (leafDer, authorityDer, rootDer: seq[byte];
                                  crlDer: seq[seq[byte]];
                                  nowSeconds: int64): IntelChainVerdict
                                 {.nimcall.}
    ## The parameter list `evaluateIntelPckChain` has, recorded as a
    ## type so that it cannot change without a compile error. See the
    ## `static` block at the foot of this file.

proc isAccepted*(v: IntelChainVerdict): bool = v.reason == tcAccepted

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc intelUnsignedValue(buf: openArray[byte]; node: DerNode;
                        maxValue: int; what: string): int =
  ## One non-negative `INTEGER` of Intel's platform description,
  ## bounded at `maxValue`.
  ##
  ## The bound is a PARAMETER and not a constant, because the two kinds
  ## of number in this extension have different widths and a reader
  ## that gave them one width would be wrong about one of them. The
  ## sixteen components are bytes; the configuration enclave's own
  ## version is sixteen bits. Intel's own published sample data states
  ## `0x2961` for the second, and a reader that bounded it at 255
  ## refused that document — which is how the difference was found
  ## here, rather than by reading a table.
  ##
  ## DER writes a leading zero octet whenever the octet after it has
  ## its top bit set, so a one-byte value of `0xc1` occupies two
  ## content octets. That is why the octet count below is one wider
  ## than the value's width and not equal to it.
  expectTag(node, TagInteger, what)
  let maxOctets = (if maxValue > 255: 2 else: 1) + 1
  if node.contentLen < 1 or node.contentLen > maxOctets:
    derFail(what & ": " & $node.contentLen & " octets, and a value " &
      "bounded at " & $maxValue & " occupies at most " & $maxOctets)
  var v = 0
  for i in 0 ..< node.contentLen:
    v = (v shl 8) or int(buf[node.contentStart + i])
  if v < 0 or v > maxValue:
    derFail(what & ": the value " & $v & " is above the bound " &
      $maxValue)
  v

proc readIntelPlatform(value: openArray[byte]): IntelPlatformDescription =
  ## The nested `SEQUENCE OF SEQUENCE { OID, ANY }` inside the
  ## extension's OCTET STRING.
  ##
  ## Walked generically rather than by position, because the vendor does
  ## not emit the members in one fixed order and a reader that assumed
  ## one would be reading the wrong field for whichever part it guessed
  ## wrong about.
  var p = 0
  let outer = readTlv(value, p, "platform description", value.len)
  expectTag(outer, TagSequence, "platform description")
  if p != value.len:
    derFail("platform description: bytes follow the outer SEQUENCE")
  result.present = true
  var seenComponent: array[IntelTcbComponentCount, bool]
  var q = outer.contentStart
  while q < outer.fin:
    let member = readTlv(value, q, "platform description member", outer.fin)
    expectTag(member, TagSequence, "platform description member")
    var m = member.contentStart
    let oidNode = readTlv(value, m, "platform description identifier",
      member.fin)
    expectTag(oidNode, TagOid, "platform description identifier")
    let oid = oidToString(value, oidNode, "platform description identifier")
    let valNode = readTlv(value, m, "platform description value", member.fin)
    if m != member.fin:
      derFail("platform description: bytes follow the value of " & oid)
    case oid
    of OidIntelPpid:
      expectTag(valNode, TagOctetString, "platform instance")
      result.ppid = slice(value, valNode.contentStart, valNode.fin)
    of OidIntelPceId:
      expectTag(valNode, TagOctetString, "configuration enclave identifier")
      result.pceId = slice(value, valNode.contentStart, valNode.fin)
    of OidIntelFmspc:
      expectTag(valNode, TagOctetString, "platform identifier")
      if valNode.contentLen != FmspcLen:
        derFail("platform identifier: " & $valNode.contentLen &
          " bytes; a family-model-stepping value is " & $FmspcLen)
      result.fmspcHex =
        hexOf(slice(value, valNode.contentStart, valNode.fin))
    of OidIntelTcb:
      expectTag(valNode, TagSequence, "platform trusted computing base")
      var t = valNode.contentStart
      while t < valNode.fin:
        let comp = readTlv(value, t, "component", valNode.fin)
        expectTag(comp, TagSequence, "component")
        var c = comp.contentStart
        let cOid = readTlv(value, c, "component identifier", comp.fin)
        expectTag(cOid, TagOid, "component identifier")
        let cName = oidToString(value, cOid, "component identifier")
        let cVal = readTlv(value, c, "component value", comp.fin)
        if c != comp.fin:
          derFail("component: bytes follow the value of " & cName)
        if cName == OidIntelPceSvn:
          result.tcb.pceSvn = intelUnsignedValue(value, cVal,
            MaxPceSvn, "configuration enclave version")
          result.tcb.hasPceSvn = true
        elif cName == OidIntelCpuSvn:
          expectTag(cVal, TagOctetString, "processor version")
          if cVal.contentLen != CpuSvnLen:
            derFail("processor version: " & $cVal.contentLen &
              " bytes; a processor security version is " & $CpuSvnLen)
          result.tcb.cpuSvn = slice(value, cVal.contentStart, cVal.fin)
        else:
          for i in 1 .. IntelTcbComponentCount:
            if cName == OidIntelTcb & "." & $i:
              result.tcb.components[i - 1] =
                intelUnsignedValue(value, cVal, MaxTcbComponent,
                  "component " & $i)
              seenComponent[i - 1] = true
    else:
      discard
    q = member.fin
  var all = true
  for s in seenComponent:
    if not s: all = false
  result.tcb.hasComponents = all

proc intelPlatformOf*(cert: X509Cert): IntelPlatformDescription =
  ## The vendor's platform description, if this certificate carries one.
  for ext in cert.extensions:
    if ext.oid == IntelSgxArc:
      return readIntelPlatform(ext.value)

# ---------------------------------------------------------------------
# The root — a const, with no way in
# ---------------------------------------------------------------------

type
  IntelRootKey* = object
    commonName*: string
    pointHex*: string

const
  IntelRootKeys*: array[1, IntelRootKey] = [
    IntelRootKey(
      commonName: "Intel SGX Root CA",
      pointHex:
        "040ba9c4c0c0c86193a3fe23d6b02cda10a8bbd4e88e48b4458561a36e" &
        "705525f567918e2edc88e40d860bd0cc4ee26aacc988e505a953558c45" &
        "3f6b0904ae7394")]
    ## Intel's published SGX root key, as the uncompressed P-256 point
    ## `0x04 ‖ X ‖ Y`.
    ##
    ## Taken from the certificate Intel's own distribution service
    ## serves at
    ## `certificates.trustedservices.intel.com/Intel_SGX_Provisioning_Certification_RootCA.cer`,
    ## and the gate re-derives it from that certificate's bytes rather
    ## than reading it from here — so this entry is checked against the
    ## vendor's DER, not merely transcribed from it once. The same DER
    ## arrives by four further routes and the gate checks all of them.
    ##
    ## There is one entry and no way to add another at run time. That is
    ## the whole mechanism by which a chain rooted somewhere else is
    ## refused: not a comparison that a flag could skip, but an absence
    ## of anywhere to put another key.

proc hexBytes*(h: string): seq[byte] =
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc sameBytes(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

proc intelRootFor*(point: openArray[byte]): int =
  ## The index of the pinned root holding exactly this key, or `-1`.
  for i in 0 ..< IntelRootKeys.len:
    if sameBytes(point, hexBytes(IntelRootKeys[i].pointHex)): return i
  -1

# ---------------------------------------------------------------------
# The decision
# ---------------------------------------------------------------------

proc unrecognisedCriticalOid(cert: X509Cert): string =
  for ext in cert.extensions:
    if ext.critical and ext.oid notin RecognisedIntelCriticalOids:
      return ext.oid
  ""

proc evaluateIntelPckChain*(leafDer, authorityDer, rootDer: seq[byte];
                            crlDer: seq[seq[byte]];
                            nowSeconds: int64): IntelChainVerdict =
  ## Three certificates, leaf first, and the withdrawal lists the caller
  ## holds. No anchor: see this module's header.
  template no(refusal: IntelChainRejection; because: string) =
    # The parameters are NOT called `reason` and `detail`: a template
    # parameter named after a field of `result` is substituted into
    # `result.detail`, which produces a syntax error in the best case
    # and the wrong field in the worst.
    result.reason = refusal
    result.detail = IntelChainMessage[refusal] & ": " & because
    return result

  var leaf, authority, root: X509Cert
  try:
    leaf = parseCertificate(leafDer)
    authority = parseCertificate(authorityDer)
    root = parseCertificate(rootDer)
  except X509Error as err:
    no(tcMalformed, err.msg)

  result.leafCn = leaf.subjectCn
  result.authorityCn = authority.subjectCn
  result.rootCn = root.subjectCn
  result.leafSerialHex = leaf.serialHex
  result.authoritySerialHex = authority.serialHex
  result.endorsedAt = leaf.notBefore

  # RFC 5280 §4.2, on all three.
  for i, c in [leaf, authority, root]:
    let oid = unrecognisedCriticalOid(c)
    if oid.len > 0:
      no(tcUnrecognisedCriticalExtension, "element " & $i & " (" &
        describeName(c.subjectDn, c.subjectCn) & ") marks " & oid &
        " critical")

  # What the leaf and the authority HAVE to be, checked here rather than
  # at the end.
  #
  # These are facts about the documents' shapes, like the name links
  # below, and the position is deliberate: a rule that sits after the
  # signature checks can only ever be reached by a chain the vendor
  # actually signed, which for an offline gate means it cannot be
  # reached at all. Ordering the structural rules before the
  # cryptographic ones costs nothing — a refusal is a refusal — and it
  # is the difference between a rule with a case and a rule with a
  # comment saying it could not be given one.
  if leaf.subjectCn != PckLeafCommonName:
    no(tcLeafIsNotAProvisioningCertificate, "it is " &
      leaf.subjectCn.escape() & " and a quoting enclave's report is " &
      "signed by " & PckLeafCommonName.escape())
  var authorityKnown = false
  for n in IntelPckAuthorityCommonNames:
    if authority.subjectCn == n: authorityKnown = true
  if not authorityKnown:
    no(tcAuthorityIsNotOneIntelIssues, "it is " &
      authority.subjectCn.escape() & " and the vendor operates " &
      IntelPckAuthorityCommonNames.join(" and "))
  result.authorityIsPlatform =
    authority.subjectCn == PckPlatformCaCommonName

  try:
    result.platform = intelPlatformOf(leaf)
  except X509Error as err:
    no(tcMalformed, "the platform description of " &
      describeName(leaf.subjectDn, leaf.subjectCn) & " did not read: " &
      err.msg)
  if not result.platform.present:
    no(tcLeafCarriesNoPlatformExtension, "it carries no " & IntelSgxArc &
      " extension at all")
  if result.platform.fmspcHex.len != 2 * FmspcLen:
    no(tcLeafCarriesNoPlatformIdentifier, "the description holds " &
      $(result.platform.fmspcHex.len div 2) & " bytes where a " &
      "family-model-stepping value is " & $FmspcLen)
  if not result.platform.tcb.hasComponents or
     not result.platform.tcb.hasPceSvn:
    no(tcLeafCarriesNoPlatformTcb, "the description states " &
      (if result.platform.tcb.hasComponents: "all sixteen components"
       else: "fewer than sixteen components") & " and " &
      (if result.platform.tcb.hasPceSvn: "a configuration enclave version"
       else: "no configuration enclave version"))

  # Names link before signatures are looked at, so a chain that is not a
  # chain is refused as that rather than as a bad signature.
  if not sameBytes(leaf.issuerDn, authority.subjectDn):
    no(tcNameMismatch, "the provisioning certificate names " &
      describeName(leaf.issuerDn, leaf.issuerCn) & " and the authority " &
      "is " & describeName(authority.subjectDn, authority.subjectCn))
  if not sameBytes(authority.issuerDn, root.subjectDn):
    no(tcNameMismatch, "the authority names " &
      describeName(authority.issuerDn, authority.issuerCn) &
      " and the root is " & describeName(root.subjectDn, root.subjectCn))
  if not sameBytes(root.issuerDn, root.subjectDn):
    no(tcNotSelfIssued, "it is issued by " &
      describeName(root.issuerDn, root.issuerCn))

  for (name, c) in {"authority": authority, "root": root}:
    if not c.hasBasicConstraints or not c.isCa:
      no(tcNotACertificateAuthority, "the " & name & " (" &
        describeName(c.subjectDn, c.subjectCn) &
        ") does not carry basicConstraints cA TRUE")
    if c.hasKeyUsage and kuKeyCertSign notin c.keyUsage:
      no(tcNotACertificateAuthority, "the " & name & " (" &
        describeName(c.subjectDn, c.subjectCn) &
        ") has a keyUsage that does not include keyCertSign")

  # THE root rule. Before any signature is checked, because a chain that
  # ends nowhere this build knows is not worth the arithmetic.
  let idx = intelRootFor(root.publicKey)
  if idx < 0:
    no(tcRootIsNotIntel, "it ends at " &
      describeName(root.subjectDn, root.subjectCn) &
      " with serial " & root.serialHex & ", carrying a P-256 key that " &
      "is none of the " & $IntelRootKeys.len & " this build was built " &
      "with")
  result.rootMatched = true
  if root.subjectCn != IntelRootKeys[idx].commonName:
    no(tcRootNameDisagreesWithKey, "the key is " &
      IntelRootKeys[idx].commonName & "'s and the certificate calls " &
      "itself " & root.subjectCn.escape())

  # Validity windows, BEFORE the signatures, and for the same reason the
  # other structural rules sit early: a window is a fact about the
  # document's text, and a rule reachable only through a chain the
  # vendor actually signed is a rule an offline gate cannot give an
  # input to. Moving it up costs nothing — a refusal is a refusal — and
  # it is what lets each of these six sites be reached by editing the
  # element whose window it is about.
  for (name, c) in {"provisioning certificate": leaf,
                    "authority": authority, "root": root}:
    if nowSeconds < c.notBefore:
      no(tcExpired, "the " & name & " is not valid until " &
        $c.notBefore & " and this verification is being made at " &
        $nowSeconds)
    if nowSeconds >= c.notAfter:
      no(tcExpired, "the " & name & " stopped being valid at " &
        $c.notAfter & " and this verification is being made at " &
        $nowSeconds)

  if not leaf.signatureVerifiesUnder(authority.publicKey):
    no(tcBadSignature, "the provisioning certificate does not verify " &
      "under " & describeName(authority.subjectDn, authority.subjectCn))
  if not authority.signatureVerifiesUnder(root.publicKey):
    no(tcBadSignature, "the authority does not verify under " &
      describeName(root.subjectDn, root.subjectCn))
  if not root.signatureVerifiesUnder(root.publicKey):
    no(tcBadSignature, "the root does not verify under its own key, so " &
      "it is not the self-signed certificate it is shaped like")

  # Withdrawal, for the provisioning certificate. A list is current,
  # issued by the authority that issued it, and signed by that
  # authority, or it is not a list this verifier will use.
  #
  # Which authority matters: the vendor publishes one list per
  # authority, and a platform chain judged against the processor
  # authority's list would be judged against a document that says
  # nothing about it. That is the first condition below, and it has a
  # real input — the vendor serves both lists.
  var crls: seq[X509Crl] = @[]
  var unreadable: seq[string] = @[]
  for der in crlDer:
    try:
      crls.add parseCrl(der)
    except X509Error as err:
      # Counted and NAMED rather than swallowed. A list this build
      # cannot read is still "no withdrawal data" — the outcome is the
      # same and it is the fail-closed one — but an operator who handed
      # the verifier a list and got told none was supplied deserves to
      # be told which of the two happened.
      unreadable.add err.msg
  # Five separate conditions decide whether a list answers the
  # question, and each one NAMES itself when it sets a list aside.
  #
  # They are not five bare `continue`s ending in one sentence, and that
  # is the direct answer to what this tree keeps being defeated by: one
  # refusal answering five rules means a case asserting the refusal is
  # asserting none of them in particular.
  var covering = -1
  var setAside: seq[string] = @[]
  for j, crl in crls:
    if not sameBytes(crl.issuerDn, authority.subjectDn):
      setAside.add "one is issued by " &
        describeName(crl.issuerDn, crl.issuerCn) &
        " and not by the authority under test"
      continue
    if not crl.hasNextUpdate:
      setAside.add "one states no next update at all, so nothing in it " &
        "says it is still current"
      continue
    if nowSeconds < crl.thisUpdate:
      setAside.add "one is not in force until " & $crl.thisUpdate
      continue
    if nowSeconds >= crl.nextUpdate:
      setAside.add "one stopped being current at " & $crl.nextUpdate
      continue
    if not crl.signatureVerifiesUnder(authority.publicKey):
      setAside.add "one carries a signature this authority did not make"
      continue
    covering = j
    break
  if covering < 0:
    no(tcNoRevocationData, "this verifier was handed " & $crlDer.len &
      " list(s), of which " & $unreadable.len &
      " did not read at all, and none of the rest is a current one " &
      "issued by " &
      describeName(authority.subjectDn, authority.subjectCn) &
      " and signed by it" &
      (if unreadable.len > 0: " (first reading failure: " & unreadable[0] &
        ")" else: "") &
      (if setAside.len > 0: "; of the ones that did read, " &
        setAside.join(", and ") else: ""))
  result.revocationConsulted = true
  for entry in crls[covering].revoked:
    if entry.serialHex == leaf.serialHex:
      no(tcRevoked, "the provisioning certificate's serial is " &
        leaf.serialHex)

  result.reason = tcAccepted
  result.detail = IntelChainMessage[tcAccepted] & ": " & leaf.subjectCn &
    " for platform " & result.platform.fmspcHex & " under " &
    authority.subjectCn & " under " & root.subjectCn &
    ", whose key is this build's vendor root"

proc serialIsWithdrawn*(crl: X509Crl; serialHex: string): bool =
  ## Whether this list names this serial.
  ##
  ## Exported as a rule of its own because the chain evaluator's
  ## withdrawal REFUSAL has no input that can be manufactured offline —
  ## reaching it needs one list that is both signed by a pinned
  ## authority and names the serial of a certificate beside it, and
  ## making that pair means holding the vendor's private key. The rule
  ## itself does have an input: the vendor's platform list names a
  ## serial, so the comparison can be exercised in both directions
  ## against a real document. That is a smaller claim than "the refusal
  ## is reachable", and it is the one this file is entitled to make.
  for entry in crl.revoked:
    if entry.serialHex == serialHex: return true
  false

static:
  # The structural claim, made mechanically rather than in prose.
  #
  # If anyone adds a parameter to `evaluateIntelPckChain` — a trust
  # anchor, a set of allowed roots, a "permissive" bool, an options
  # object — this assertion stops the build and names the procedure.
  # Prose in a header asking a future editor not to widen a verifier is
  # prose; this is the rule with teeth.
  #
  # It is not a `not compiles(...)`, which passes just as happily on a
  # misspelling as on the property it meant to assert. It is an equality
  # between two type expressions, both of which must name real things
  # for the module to compile at all.
  doAssert typeof(evaluateIntelPckChain) is IntelPckChainSignature

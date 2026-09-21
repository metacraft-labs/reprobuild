## Intel's DCAP collateral: the two signed documents that say what a
## platform's trusted-computing base is worth, and the evaluation that
## turns them plus a quote into one status.
##
## ## Two halves, and the order between them is the design
##
## Collateral arrives as JSON with a detached signature over **one
## member** of the document: `tcbInfo` in a trusted-computing-base
## document, `enclaveIdentity` in an enclave-identity document. The
## signature is raw `R ‖ S` over the SHA-256 of that member's bytes
## *exactly as they were served*.
##
## So this module has two halves and they run in a fixed order:
##
##   1. **Locate and verify, over raw bytes.** The signed member is
##      found by brace matching across the octets that arrived, and the
##      signature is found by scanning for its own member the same way.
##      Nothing is decoded, nothing is re-serialised, nothing is
##      normalised. A verifier that re-encodes a document in order to
##      check its signature is checking its encoder — and here that
##      would be fatal rather than merely circular, because JSON has
##      many encodings of one value and the vendor signed exactly one of
##      them.
##   2. **Then interpret.** `parseTdxTcbInfo` and `parseEnclaveIdentity`
##      take a `VerifiedCollateral`, a type whose payload field is not
##      exported, so **no caller outside this module can construct one**
##      — the only way to obtain it is `verifyCollateral`, which returns
##      it only when a signature verified under the key it was handed.
##      The general-purpose decoder therefore never sees a byte the
##      vendor did not sign.
##
## That ordering is not tidiness. A JSON decoder is a large surface, and
## the documents it reads here come to a verifier from the network. This
## build's answer is that the surface is behind a signature check the
## type system enforces, rather than in front of one.
##
## ## The evaluation
##
## `evaluateTdxTcb` is Intel's own algorithm, transcribed from Intel's
## reference implementation rather than from prose, and the distinction
## earned its keep. `google/go-tdx-guest`'s published description — the
## one most readers will meet first — ends with a step saying that the
## component at index 1 of a level's TDX component array must *equal*
## the value at index 1 of the report's, and that a mismatch rejects the
## level. Intel's own library does something different: when that
## report value is non-zero it **skips indices 0 and 1 of the
## comparison entirely** and consults a separate module identity for
## them. The two rules disagree on real evidence — one of the quotes
## this is gated against is `UpToDate` under Intel's rule and rejected
## under the other — so the choice is load-bearing and is recorded here
## rather than left to whoever reads the code next.
##
## The choice is less contested than that reads, and the reason is
## worth having beside it: `go-tdx-guest`'s own CODE implements the
## vendor's rule, not the description in its own repository.
## `isTdxTcbSvnHigherOrEqual` in `verify/verify.go` opens the
## comparison at index 2 when `teeTcbSvn[1] > 0`, exactly as Intel's
## library does. So the disagreement is between a stale prose
## description and every implementation of it, rather than between two
## implementations — which is why following the vendor here is a
## correction rather than a preference.
##
## The sources, at the commits they were read at:
##
##   * `intel/SGX-TDX-DCAP-QuoteVerificationLibrary` `d12717e3`,
##     `Src/AttestationLibrary/src/Verifiers/Checks/EvaluateTcb.cpp`
##     (`tdxEvaluateTCB`, `areSvnsHigherOrEqual`, `convergeTcbStatuses`),
##     `TdxModuleCheck.cpp` (`findTdxModuleIdentity`) and
##     `TDRelaunchCheck.cpp` (`checkForRelaunch`).
##
## ## What this module does NOT do, stated rather than implied
##
##   * It does not fetch. Every byte arrives from the caller.
##   * It does not check the collateral's own freshness against a clock.
##     `issueDate` and `nextUpdate` are read and exposed; deciding
##     whether a document is too old is the caller's, because the
##     caller is the one that knows what it is verifying and when.
##   * It reads the SGX-flavoured evaluation not at all. A quote that is
##     not a trust domain's is refused one layer up, by `tdx_quote`.
##
## ## Mocking
##
## None. Real Intel-signed documents, real P-256 through BearSSL.

import std/[json, strutils]

import repro_attest/cose

import ./tdx_chain
import ./tdx_quote
import ./x509

# ---------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------

type
  TdxCollateralErrorKind* = enum
    ## One kind per rule; no message below is a substring of any other.
    tceEmptyDocument
    tceSignedMemberNotFound
    tceSignedMemberIsNotAnObject
    tceSignedMemberUnterminated
    tceSignatureMemberNotFound
    tceSignatureIsNotHexadecimal
    tceSignatureWrongWidth
    tceDocumentDoesNotDecode
    tceRequiredFieldMissing
    tceFieldHasTheWrongShape
    tceComponentCountDisagrees
    tceUnrecognisedStatus

  TdxCollateralError* = object of CatchableError
    kind*: TdxCollateralErrorKind

const
  TdxCollateralMessage*: array[TdxCollateralErrorKind, string] = [
    tceEmptyDocument:
      "a collateral document with no bytes in it states nothing",
    tceSignedMemberNotFound:
      "the document holds no member of the name whose bytes the " &
      "detached signature covers",
    tceSignedMemberIsNotAnObject:
      "the member the signature covers does not begin where an object " &
      "begins, so there is no span to take",
    tceSignedMemberUnterminated:
      "the member the signature covers is never closed, so the span " &
      "would run to the end of whatever followed it",
    tceSignatureMemberNotFound:
      "the document carries no detached signature at all",
    tceSignatureIsNotHexadecimal:
      "the detached signature holds a character that is not a hexadecimal " &
      "digit",
    tceSignatureWrongWidth:
      "the detached signature is not the width two curve scalars occupy",
    tceDocumentDoesNotDecode:
      "the vendor-signed bytes are not a document this build can read",
    tceRequiredFieldMissing:
      "a field this evaluation reads is absent from the vendor's document",
    tceFieldHasTheWrongShape:
      "a field this evaluation reads is present and is not of the kind " &
      "it has to be",
    tceComponentCountDisagrees:
      "a published component array does not hold the number of entries " &
      "a platform version has",
    tceUnrecognisedStatus:
      "the vendor's document states a verdict this build has no ordering " &
      "for, and guessing where an unknown verdict sits is how a bad one " &
      "gets accepted"]

proc tdxCollateralMessagesAreDistinguishable*(): bool =
  for a in TdxCollateralErrorKind:
    for b in TdxCollateralErrorKind:
      if a == b: continue
      if TdxCollateralMessage[a] in TdxCollateralMessage[b]: return false
  true

proc collateralFail*(kind: TdxCollateralErrorKind;
                     detail: string) {.noreturn.} =
  var e = newException(TdxCollateralError, TdxCollateralMessage[kind])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.kind = kind
  raise e

# ---------------------------------------------------------------------
# Half one: the span, and the signature over it
# ---------------------------------------------------------------------

const
  TcbInfoMemberName* = "tcbInfo"
  EnclaveIdentityMemberName* = "enclaveIdentity"
  SignatureMemberName* = "signature"
  CollateralSignatureLen* = 64
    ## `R ‖ S`, each 32 bytes big-endian, hexadecimal in the document.
  MaxCollateralBytes* = 262_144
  MaxSpanNesting* = 64
    ## How deep the brace matcher will descend. A bound rather than a
    ## recursion: the matcher is a loop, and this is what stops a
    ## document of nothing but opening braces from being walked
    ## indefinitely before the signature is ever consulted.

type
  VerifiedCollateral* = object
    ## A collateral document whose detached signature verified.
    ##
    ## `payload` is deliberately **not** exported. That is the whole
    ## mechanism: a caller in another module can write
    ## `VerifiedCollateral(memberName: "tcbInfo")` and get an object
    ## whose payload is the empty string, which every reader below
    ## refuses — but it cannot put a document into one. The only way to
    ## obtain a `VerifiedCollateral` carrying bytes is `verifyCollateral`
    ## returning it, and that returns only after a signature verified.
    payload: string
    memberName*: string
    signedSpan*: seq[byte]
      ## The exact octets the signature covers, lifted verbatim.
    signature*: seq[byte]

proc documentOf*(v: VerifiedCollateral): string = v.payload
  ## The verified document, for a caller that wants to show it. Reading
  ## is not the thing the field is protecting against; constructing is.

proc findMemberValueStart(body: string; name: string): int =
  ## The index of the first byte of the value of `"name":`, or `-1`.
  ##
  ## Scans for the quoted name followed by a colon, skipping whitespace
  ## between them. It does not tokenise, and it does not have to: the
  ## only thing downstream of it is a signature check, so a match on a
  ## name that happened to appear inside a string value produces a span
  ## whose signature does not verify.
  let needle = "\"" & name & "\""
  var searchAt = 0
  while true:
    let at = body.find(needle, searchAt)
    if at < 0: return -1
    var p = at + needle.len
    while p < body.len and body[p] in {' ', '\t', '\n', '\r'}: inc p
    if p < body.len and body[p] == ':':
      inc p
      while p < body.len and body[p] in {' ', '\t', '\n', '\r'}: inc p
      return p
    searchAt = at + 1

proc objectSpan(body: string; start: int): int =
  ## The index one past the `}` that closes the object at `start`, or
  ## `-1` if it is never closed.
  ##
  ## Brace counting that knows about strings and about escapes, because
  ## a `}` inside a string value is not a close and a `\"` inside one is
  ## not an end of string. Intel's documents contain both.
  var depth = 0
  var inString = false
  var escaped = false
  var p = start
  while p < body.len:
    let c = body[p]
    if escaped:
      escaped = false
    elif inString:
      if c == '\\': escaped = true
      elif c == '"': inString = false
    else:
      if c == '"': inString = true
      elif c == '{':
        inc depth
        if depth > MaxSpanNesting: return -1
      elif c == '}':
        dec depth
        if depth == 0: return p + 1
    inc p
  -1

proc signedSpanOf*(body: string; memberName: string): seq[byte] =
  ## The exact octets of `body`'s `memberName` member, lifted verbatim.
  if body.len == 0:
    collateralFail(tceEmptyDocument, "zero bytes")
  if body.len > MaxCollateralBytes:
    collateralFail(tceDocumentDoesNotDecode, $body.len &
      " bytes; at most " & $MaxCollateralBytes & " are read")
  let at = findMemberValueStart(body, memberName)
  if at < 0:
    collateralFail(tceSignedMemberNotFound, memberName.escape())
  if body[at] != '{':
    collateralFail(tceSignedMemberIsNotAnObject, memberName.escape() &
      " begins with " & $body[at])
  let fin = objectSpan(body, at)
  if fin < 0:
    collateralFail(tceSignedMemberUnterminated, memberName.escape() &
      " opens at byte " & $at & " and is not closed within " &
      $(body.len - at) & " bytes, or nests deeper than " &
      $MaxSpanNesting)
  result = newSeq[byte](fin - at)
  for i in 0 ..< result.len: result[i] = byte(body[at + i])

proc detachedSignatureOf*(body: string): seq[byte] =
  ## The 64 raw bytes of `body`'s `signature` member.
  let at = findMemberValueStart(body, SignatureMemberName)
  if at < 0:
    collateralFail(tceSignatureMemberNotFound, "no " &
      SignatureMemberName.escape() & " member")
  if body[at] != '"':
    collateralFail(tceSignatureIsNotHexadecimal,
      "the value begins with " & $body[at] & " and not with a string")
  var fin = at + 1
  while fin < body.len and body[fin] != '"': inc fin
  if fin >= body.len:
    collateralFail(tceSignatureIsNotHexadecimal, "the string never ends")
  let text = body[at + 1 ..< fin]
  if text.len != 2 * CollateralSignatureLen:
    collateralFail(tceSignatureWrongWidth, $text.len &
      " hexadecimal characters; two P-256 scalars are " &
      $(2 * CollateralSignatureLen))
  result = newSeq[byte](CollateralSignatureLen)
  for i in 0 ..< CollateralSignatureLen:
    let hi = text[2 * i]
    let lo = text[2 * i + 1]
    if hi notin HexDigits or lo notin HexDigits:
      collateralFail(tceSignatureIsNotHexadecimal,
        "character " & $(2 * i) & " of the value is " & $hi)
    result[i] = byte(parseHexInt(hi & $lo))

proc statedCollateralId*(v: VerifiedCollateral): string =
  ## The `id` member of a verified document, read out of the SIGNED
  ## SPAN with the same locator the signature used and without decoding
  ## anything else.
  ##
  ## It is read this way because it is consulted BEFORE the document's
  ## reader runs, and the whole point of the ordering in this module is
  ## that the general-purpose decoder never sees bytes the vendor did
  ## not sign. Returns the empty string for a record that carries no
  ## document, which every caller treats as "not the identity I want".
  if v.payload.len == 0: return ""
  var span = ""
  for b in v.signedSpan: span.add char(b)
  let at = findMemberValueStart(span, "id")
  if at < 0 or at >= span.len or span[at] != '"': return ""
  var fin = at + 1
  while fin < span.len and span[fin] != '"': inc fin
  if fin >= span.len: return ""
  span[at + 1 ..< fin]

proc verifyCollateral*(body: string; memberName: string;
                       signerPoint: openArray[byte]): VerifiedCollateral =
  ## Locate the signed member, locate the detached signature, and verify
  ## the second over the first under `signerPoint` — the uncompressed
  ## P-256 point out of the vendor's signing certificate.
  ##
  ## Raises `TdxCollateralError` when the document is not shaped like
  ## one, and returns a `VerifiedCollateral` whose payload is empty when
  ## the signature simply did not verify. A caller therefore cannot
  ## confuse "malformed" with "not signed by this key", and neither can
  ## reach a reader.
  ##
  ## The signature goes to `repro_attest/cose`'s primitive with `ES256`,
  ## because that is what it is: raw `R ‖ S` over SHA-256 with a P-256
  ## key. Same primitive, same caller-built-key path, as the quote's own
  ## three signatures one module over.
  result.memberName = memberName
  result.signedSpan = signedSpanOf(body, memberName)
  result.signature = detachedSignatureOf(body)
  var key = CoseKey(curve: ccP256, point: @[])
  for b in signerPoint: key.point.add b
  if ecdsaSignatureIsValid(key, caEs256, result.signedSpan,
                           result.signature):
    result.payload = body

proc isVerified*(v: VerifiedCollateral): bool = v.payload.len > 0

# ---------------------------------------------------------------------
# Half two: what the verified documents say
# ---------------------------------------------------------------------

const
  TdxTcbComponentCount* = 16
  TdxTcbInfoIdTdx* = "TDX"
  EnclaveIdentityIdTdQe* = "TD_QE"

  TdxStatusUpToDate* = "UpToDate"
  TdxStatusSwHardeningNeeded* = "SWHardeningNeeded"
  TdxStatusConfigurationNeeded* = "ConfigurationNeeded"
  TdxStatusConfigurationAndSwHardeningNeeded* =
    "ConfigurationAndSWHardeningNeeded"
  TdxStatusOutOfDate* = "OutOfDate"
  TdxStatusOutOfDateConfigurationNeeded* = "OutOfDateConfigurationNeeded"
  TdxStatusRevoked* = "Revoked"
  TdxStatusTdRelaunchAdvised* = "TdRelaunchAdvised"
  TdxStatusTdRelaunchAdvisedConfigurationNeeded* =
    "TdRelaunchAdvisedConfigurationNeeded"

  PlatformLevelStatuses*: array[7, string] = [
    TdxStatusUpToDate, TdxStatusSwHardeningNeeded,
    TdxStatusConfigurationNeeded,
    TdxStatusConfigurationAndSwHardeningNeeded, TdxStatusOutOfDate,
    TdxStatusOutOfDateConfigurationNeeded, TdxStatusRevoked]
    ## `VALID_TCB_INFO_STATUSES` in the reference implementation: what a
    ## level of a platform document may say. A document stating anything
    ## else is refused rather than read, because a verdict with no
    ## ordering cannot be compared against a floor.

  ModuleLevelStatuses*: array[3, string] =
    [TdxStatusUpToDate, TdxStatusOutOfDate, TdxStatusRevoked]
    ## `VALID_TDX_MODULE_STATUSES`: a module identity's levels may say
    ## strictly less than a platform's. The two lists differ in the
    ## reference implementation and they differ here.

  EnclaveLevelStatuses*: array[5, string] = [
    TdxStatusUpToDate, TdxStatusOutOfDate, TdxStatusConfigurationNeeded,
    TdxStatusRevoked, TdxStatusOutOfDateConfigurationNeeded]
    ## `VALID_QE_STATUSES`: and a third list again, for the same reason.

type
  TdxTcbLevel* = object
    sgxComponents*: array[TdxTcbComponentCount, int]
    tdxComponents*: array[TdxTcbComponentCount, int]
    pceSvn*: int
    status*: string
    tcbDate*: string
    advisoryIds*: seq[string]

  TdxModuleLevel* = object
    isvSvn*: int
    status*: string
    tcbDate*: string
    advisoryIds*: seq[string]

  TdxModuleIdentity* = object
    id*: string
    mrSignerHex*: string
    attributesHex*: string
    attributesMaskHex*: string
    levels*: seq[TdxModuleLevel]

  TdxTcbInfo* = object
    id*: string
    version*: int
    fmspcHex*: string
    pceIdHex*: string
    issueDate*, nextUpdate*: string
    evaluationDataNumber*: int
    levels*: seq[TdxTcbLevel]
    moduleIdentities*: seq[TdxModuleIdentity]

  EnclaveIdentity* = object
    id*: string
    version*: int
    isvProdId*: int
    mrSignerHex*: string
    miscSelectHex*, miscSelectMaskHex*: string
    attributesHex*, attributesMaskHex*: string
    issueDate*, nextUpdate*: string
    levels*: seq[TdxModuleLevel]

proc need(node: JsonNode; key: string; where: string): JsonNode =
  if node.kind != JObject or key notin node:
    collateralFail(tceRequiredFieldMissing, where & "." & key)
  node[key]

proc needStr(node: JsonNode; key: string; where: string): string =
  let v = need(node, key, where)
  if v.kind != JString:
    collateralFail(tceFieldHasTheWrongShape, where & "." & key &
      " is not a string")
  v.getStr

proc needInt(node: JsonNode; key: string; where: string): int =
  let v = need(node, key, where)
  if v.kind != JInt:
    collateralFail(tceFieldHasTheWrongShape, where & "." & key &
      " is not an integer")
  int(v.getInt)

proc needArray(node: JsonNode; key: string; where: string): JsonNode =
  let v = need(node, key, where)
  if v.kind != JArray:
    collateralFail(tceFieldHasTheWrongShape, where & "." & key &
      " is not an array")
  v

proc readComponents(node: JsonNode; key: string;
                    where: string): array[TdxTcbComponentCount, int] =
  let arr = needArray(node, key, where)
  if arr.len != TdxTcbComponentCount:
    collateralFail(tceComponentCountDisagrees, where & "." & key &
      " holds " & $arr.len & " entries and a platform version has " &
      $TdxTcbComponentCount)
  for i in 0 ..< arr.len:
    result[i] = needInt(arr[i], "svn", where & "." & key & "[" & $i & "]")

proc checkedStatus(raw: string; allowed: openArray[string];
                   where: string): string =
  for a in allowed:
    if a == raw: return raw
  collateralFail(tceUnrecognisedStatus, where & " states " &
    raw.escape() & "; this build orders " & allowed.join(", "))

proc advisoriesOf(node: JsonNode): seq[string] =
  if node.kind == JObject and "advisoryIDs" in node and
     node["advisoryIDs"].kind == JArray:
    let ids = node["advisoryIDs"]
    for i in 0 ..< ids.len:
      if ids[i].kind == JString: result.add ids[i].getStr

proc decodeVerified(v: VerifiedCollateral; want: string): JsonNode =
  if v.payload.len == 0:
    collateralFail(tceDocumentDoesNotDecode,
      "this reader was handed a collateral record whose signature was " &
      "never established; only `verifyCollateral` produces one that " &
      "carries a document")
  if v.memberName != want:
    collateralFail(tceDocumentDoesNotDecode,
      "the verified member is " & v.memberName.escape() &
      " and this reader reads " & want.escape())
  # The SIGNED SPAN, and not the document it was lifted out of.
  #
  # That distinction is load-bearing rather than tidy. A document may
  # carry the same member name twice; the span is taken from the FIRST
  # occurrence, because that is where the vendor's signature starts,
  # and a general-purpose decoder over the whole document would hand
  # back the LAST — so a reader that re-looked-up the name would read
  # bytes the signature does not cover, in a document whose signature
  # verifies. The gate builds exactly that document.
  var span = ""
  for b in v.signedSpan: span.add char(b)
  try:
    result = parseJson(span)
  except CatchableError as err:
    collateralFail(tceDocumentDoesNotDecode, err.msg)
  if result.kind != JObject:
    collateralFail(tceSignedMemberIsNotAnObject, want.escape())

proc parseTdxTcbInfo*(v: VerifiedCollateral): TdxTcbInfo =
  ## The platform document, read only from a verified record.
  let root = decodeVerified(v, TcbInfoMemberName)
  result.id = needStr(root, "id", "tcbInfo")
  result.version = needInt(root, "version", "tcbInfo")
  result.fmspcHex = needStr(root, "fmspc", "tcbInfo").toLowerAscii
  result.pceIdHex = needStr(root, "pceId", "tcbInfo").toLowerAscii
  result.issueDate = needStr(root, "issueDate", "tcbInfo")
  result.nextUpdate = needStr(root, "nextUpdate", "tcbInfo")
  result.evaluationDataNumber =
    needInt(root, "tcbEvaluationDataNumber", "tcbInfo")
  let platformLevels = needArray(root, "tcbLevels", "tcbInfo")
  for i in 0 ..< platformLevels.len:
    let lv = platformLevels[i]
    let where = "tcbInfo.tcbLevels[" & $i & "]"
    let tcb = need(lv, "tcb", where)
    var level = TdxTcbLevel(
      sgxComponents: readComponents(tcb, "sgxtcbcomponents", where),
      tdxComponents: readComponents(tcb, "tdxtcbcomponents", where),
      pceSvn: needInt(tcb, "pcesvn", where),
      status: checkedStatus(needStr(lv, "tcbStatus", where),
        PlatformLevelStatuses, where & ".tcbStatus"),
      tcbDate: needStr(lv, "tcbDate", where),
      advisoryIds: advisoriesOf(lv))
    result.levels.add level
  if "tdxModuleIdentities" in root and
     root["tdxModuleIdentities"].kind == JArray:
    let identities = root["tdxModuleIdentities"]
    for i in 0 ..< identities.len:
      let m = identities[i]
      let where = "tcbInfo.tdxModuleIdentities[" & $i & "]"
      var ident = TdxModuleIdentity(
        id: needStr(m, "id", where).toUpperAscii,
        mrSignerHex: needStr(m, "mrsigner", where).toLowerAscii,
        attributesHex: needStr(m, "attributes", where).toLowerAscii,
        attributesMaskHex: needStr(m, "attributesMask", where).toLowerAscii)
      let moduleLevels = needArray(m, "tcbLevels", where)
      for j in 0 ..< moduleLevels.len:
        let lv = moduleLevels[j]
        let lw = where & ".tcbLevels[" & $j & "]"
        ident.levels.add TdxModuleLevel(
          isvSvn: needInt(need(lv, "tcb", lw), "isvsvn", lw),
          status: checkedStatus(needStr(lv, "tcbStatus", lw),
            ModuleLevelStatuses, lw & ".tcbStatus"),
          tcbDate: needStr(lv, "tcbDate", lw),
          advisoryIds: advisoriesOf(lv))
      result.moduleIdentities.add ident

proc parseEnclaveIdentity*(v: VerifiedCollateral): EnclaveIdentity =
  ## The quoting-enclave document, read only from a verified record.
  let root = decodeVerified(v, EnclaveIdentityMemberName)
  result.id = needStr(root, "id", "enclaveIdentity")
  result.version = needInt(root, "version", "enclaveIdentity")
  result.isvProdId = needInt(root, "isvprodid", "enclaveIdentity")
  result.mrSignerHex =
    needStr(root, "mrsigner", "enclaveIdentity").toLowerAscii
  result.miscSelectHex =
    needStr(root, "miscselect", "enclaveIdentity").toLowerAscii
  result.miscSelectMaskHex =
    needStr(root, "miscselectMask", "enclaveIdentity").toLowerAscii
  result.attributesHex =
    needStr(root, "attributes", "enclaveIdentity").toLowerAscii
  result.attributesMaskHex =
    needStr(root, "attributesMask", "enclaveIdentity").toLowerAscii
  result.issueDate = needStr(root, "issueDate", "enclaveIdentity")
  result.nextUpdate = needStr(root, "nextUpdate", "enclaveIdentity")
  let enclaveLevels = needArray(root, "tcbLevels", "enclaveIdentity")
  for i in 0 ..< enclaveLevels.len:
    let lv = enclaveLevels[i]
    let where = "enclaveIdentity.tcbLevels[" & $i & "]"
    result.levels.add TdxModuleLevel(
      isvSvn: needInt(need(lv, "tcb", where), "isvsvn", where),
      status: checkedStatus(needStr(lv, "tcbStatus", where),
        EnclaveLevelStatuses, where & ".tcbStatus"),
      tcbDate: needStr(lv, "tcbDate", where),
      advisoryIds: advisoriesOf(lv))

# ---------------------------------------------------------------------
# The evaluation
# ---------------------------------------------------------------------

type
  TdxTcbOutcome* = enum
    ttoDetermined
    ttoNoLevelCoversThisPlatform
    ttoModuleIdentityNotPublished
    ttoNoModuleLevelCoversThisVersion
    ttoNoEnclaveLevelCoversThisVersion

  TdxTcbEvaluation* = object
    outcome*: TdxTcbOutcome
    status*: string
      ## The converged verdict. Empty unless `outcome` is
      ## `ttoDetermined`.
    platformStatus*: string
    moduleStatus*: string
    enclaveStatus*: string
    componentStatuses*: seq[string]
      ## What the module identity and the enclave identity said, in the
      ## order the convergence consumed them. Exposed because the
      ## convergence is a rule over this sequence and a caller that
      ## cannot see it cannot tell an agreement from a downgrade.
    levelIndex*: int
      ## Which published level the platform matched, or `-1`.
    skippedLeadingComponents*: int
      ## `0` or `2`: how many entries of the level's TDX component array
      ## the comparison skipped, which is decided by the module major
      ## version and by nothing else.
    moduleId*: string
    advisoryIds*: seq[string]
    detail*: string

proc isDetermined*(e: TdxTcbEvaluation): bool =
  e.outcome == ttoDetermined

proc svnsAreHigherOrEqual*(svns: openArray[int];
                           level: array[TdxTcbComponentCount, int];
                           startIndex: int): bool =
  ## `areSvnsHigherOrEqual`: every component from `startIndex` on must
  ## be at least the published one. **Every**, not any — a single
  ## component below the level disqualifies it.
  for i in startIndex ..< TdxTcbComponentCount:
    if i >= svns.len: return false
    if svns[i] < level[i]: return false
  true

proc convergeTcbStatuses*(platform: string;
                          components: openArray[string]): string =
  ## `convergeTcbStatuses`: a component's verdict can only make the
  ## platform's worse, never better.
  ##
  ## The two demotions are the reference implementation's, spelled the
  ## same way: an out-of-date component drags `UpToDate` and
  ## `SWHardeningNeeded` down to `OutOfDate`, and drags the two
  ## configuration verdicts down to `OutOfDateConfigurationNeeded`; a
  ## revoked component makes the whole thing `Revoked` whatever the
  ## platform said.
  var anyOutOfDate = false
  var anyRevoked = false
  for c in components:
    if c == TdxStatusOutOfDate: anyOutOfDate = true
    if c == TdxStatusRevoked: anyRevoked = true
  result = platform
  if anyOutOfDate:
    if platform == TdxStatusUpToDate or
       platform == TdxStatusSwHardeningNeeded:
      result = TdxStatusOutOfDate
    if platform == TdxStatusConfigurationNeeded or
       platform == TdxStatusConfigurationAndSwHardeningNeeded:
      result = TdxStatusOutOfDateConfigurationNeeded
  if anyRevoked:
    result = TdxStatusRevoked

proc isConfigurationNeeded*(status: string): bool =
  status == TdxStatusConfigurationNeeded or
    status == TdxStatusOutOfDateConfigurationNeeded or
    status == TdxStatusConfigurationAndSwHardeningNeeded or
    status == TdxStatusTdRelaunchAdvisedConfigurationNeeded

proc checkForRelaunch*(launchStatus, currentStatus: string): string =
  ## `checkForRelaunch`: a trust domain launched under an out-of-date
  ## base, running on a platform that has since been patched, is told to
  ## relaunch rather than refused outright.
  ##
  ## Only reachable for a report that carries a second version array —
  ## which is what the wider report body is for. A report without one
  ## has no "current" to compare its "launch" against and this is never
  ## consulted.
  if launchStatus == TdxStatusOutOfDate or
     launchStatus == TdxStatusOutOfDateConfigurationNeeded:
    if currentStatus == TdxStatusUpToDate or
       currentStatus == TdxStatusSwHardeningNeeded or
       currentStatus == TdxStatusConfigurationNeeded or
       currentStatus == TdxStatusConfigurationAndSwHardeningNeeded:
      if isConfigurationNeeded(launchStatus) or
         isConfigurationNeeded(currentStatus):
        return TdxStatusTdRelaunchAdvisedConfigurationNeeded
      return TdxStatusTdRelaunchAdvised
  launchStatus

proc moduleIdFor*(majorVersion: int): string =
  ## `"TDX_" + bytesToHexString({tdxModuleVersion})`, upper case.
  "TDX_" & toHex(majorVersion, 2).toUpperAscii

proc evaluateTdxTcb*(info: TdxTcbInfo;
                     platformComponents: openArray[int];
                     pceSvn: int;
                     teeTcbSvns: openArray[int];
                     enclaveSvn: int;
                     enclave: EnclaveIdentity;
                     haveEnclave: bool): TdxTcbEvaluation =
  ## `tdxEvaluateTCB`, over one version array.
  ##
  ## `teeTcbSvns` is a version array from the report — the one it was
  ## launched under, or, for a report that carries two, the one the
  ## platform is running now. Which of the two a caller passes is the
  ## caller's decision and `checkForRelaunch` is how the two answers are
  ## combined; doing it inside here would mean this procedure had to
  ## know which array it had been given.
  result.levelIndex = -1
  result.skippedLeadingComponents =
    if teeTcbSvns.len > TdxModuleMajorSvnIndex and
       teeTcbSvns[TdxModuleMajorSvnIndex] > 0: 2 else: 0
  for i, lv in info.levels:
    if not svnsAreHigherOrEqual(platformComponents, lv.sgxComponents, 0):
      continue
    if pceSvn < lv.pceSvn: continue
    if not svnsAreHigherOrEqual(teeTcbSvns, lv.tdxComponents,
                                result.skippedLeadingComponents):
      continue
    result.levelIndex = i
    result.platformStatus = lv.status
    result.advisoryIds = lv.advisoryIds
    break
  if result.levelIndex < 0:
    result.outcome = ttoNoLevelCoversThisPlatform
    result.detail = "none of the " & $info.levels.len &
      " levels the vendor publishes for platform " & info.fmspcHex &
      " is one this part meets"
    return

  let majorVersion =
    if teeTcbSvns.len > TdxModuleMajorSvnIndex:
      teeTcbSvns[TdxModuleMajorSvnIndex]
    else: 0
  if majorVersion > 0:
    result.moduleId = moduleIdFor(majorVersion)
    var identity = -1
    for i, m in info.moduleIdentities:
      if m.id == result.moduleId: identity = i
    if identity < 0:
      result.outcome = ttoModuleIdentityNotPublished
      result.detail = "the evidence names module " & result.moduleId &
        " and the vendor's document publishes " &
        $info.moduleIdentities.len & " identities, none of them that one"
      return
    var found = false
    for lv in info.moduleIdentities[identity].levels:
      if teeTcbSvns[TdxModuleMinorSvnIndex] >= lv.isvSvn:
        result.moduleStatus = lv.status
        for a in lv.advisoryIds: result.advisoryIds.add a
        found = true
        break
    if not found:
      result.outcome = ttoNoModuleLevelCoversThisVersion
      result.detail = "module " & result.moduleId & " is at version " &
        $teeTcbSvns[TdxModuleMinorSvnIndex] & " and the vendor " &
        "publishes no level at or below it"
      return
    result.componentStatuses.add result.moduleStatus

  if haveEnclave:
    var found = false
    for lv in enclave.levels:
      if enclaveSvn >= lv.isvSvn:
        result.enclaveStatus = lv.status
        for a in lv.advisoryIds: result.advisoryIds.add a
        found = true
        break
    if not found:
      result.outcome = ttoNoEnclaveLevelCoversThisVersion
      result.detail = "the quoting enclave is at version " & $enclaveSvn &
        " and the vendor publishes no level at or below it"
      return
    result.componentStatuses.add result.enclaveStatus

  result.outcome = ttoDetermined
  result.status =
    convergeTcbStatuses(result.platformStatus, result.componentStatuses)
  result.detail = "level " & $result.levelIndex & " of " &
    $info.levels.len & " says " & result.platformStatus &
    (if result.componentStatuses.len > 0:
       ", beside " & result.componentStatuses.join(" and ")
     else: ", with nothing beside it") &
    ", which converges to " & result.status &
    (if result.skippedLeadingComponents > 0:
       " (the first " & $result.skippedLeadingComponents &
       " module components were answered by " & result.moduleId &
       " rather than by the level)"
     else: "")

type
  EnclaveMatchOutcome* = enum
    emoMatches
    emoMeasurerDisagrees
    emoProductDisagrees
    emoMiscSelectDisagrees
    emoAttributesDisagrees

  EnclaveMatchVerdict* = object
    outcome*: EnclaveMatchOutcome
    detail*: string

proc maskedHex(valueHex, maskHex: string): string =
  ## `value & mask`, over two equal-length hexadecimal strings.
  var n = valueHex.len
  if maskHex.len < n: n = maskHex.len
  for i in countup(0, n - 2, 2):
    let v = parseHexInt(valueHex[i .. i + 1])
    let m = parseHexInt(maskHex[i .. i + 1])
    result.add toHex(v and m, 2).toLowerAscii

proc quotingEnclaveMatches*(identity: EnclaveIdentity;
                            mrSignerHex: string; isvProdId: int;
                            miscSelectHex, attributesHex: string):
                           EnclaveMatchVerdict =
  ## Whether the enclave that signed this quote is the enclave the
  ## vendor's identity document describes.
  ##
  ## Four comparisons, two of them under the document's own masks, and
  ## each one names itself. This is the check that stops a TCB status
  ## being read out of a document about a different enclave — which is
  ## not hypothetical: the vendor serves an identity for its SGX
  ## quoting enclave at a sibling path, with a different product
  ## number and a different measurer, and it is a perfectly valid
  ## signed document.
  if identity.mrSignerHex != mrSignerHex.toLowerAscii:
    result.outcome = emoMeasurerDisagrees
    result.detail = "the quoting enclave was signed by " &
      mrSignerHex.toLowerAscii & " and the identity document describes " &
      identity.mrSignerHex
    return
  if identity.isvProdId != isvProdId:
    result.outcome = emoProductDisagrees
    result.detail = "the quoting enclave states product " & $isvProdId &
      " and the identity document describes product " &
      $identity.isvProdId
    return
  let misc = maskedHex(miscSelectHex.toLowerAscii,
    identity.miscSelectMaskHex)
  if misc != maskedHex(identity.miscSelectHex, identity.miscSelectMaskHex):
    result.outcome = emoMiscSelectDisagrees
    result.detail = "the quoting enclave's selected features are " &
      misc & " under the document's own mask and the document states " &
      maskedHex(identity.miscSelectHex, identity.miscSelectMaskHex)
    return
  let attrs = maskedHex(attributesHex.toLowerAscii,
    identity.attributesMaskHex)
  if attrs != maskedHex(identity.attributesHex,
                        identity.attributesMaskHex):
    result.outcome = emoAttributesDisagrees
    result.detail = "the quoting enclave's attributes are " & attrs &
      " under the document's own mask and the document states " &
      maskedHex(identity.attributesHex, identity.attributesMaskHex)
    return
  result.outcome = emoMatches
  result.detail = "the quoting enclave is the one " & identity.id &
    " describes: measurer " & identity.mrSignerHex & ", product " &
    $identity.isvProdId

proc matches*(v: EnclaveMatchVerdict): bool = v.outcome == emoMatches

# ---------------------------------------------------------------------
# The bundle: everything a verifier must hold to reach a status
# ---------------------------------------------------------------------

type
  TdxCollateralOutcome* = enum
    tcoEstablished
    tcoSignerChainIsNotIntels
    tcoTcbInfoNotSignedByTheSigner
    tcoEnclaveIdentityNotSignedByTheSigner
    tcoTcbInfoIsNotForThisPlatform
    tcoTcbInfoIsNotForTrustDomains
    tcoEnclaveIdentityIsNotForTrustDomainQuoting
    tcoQuotingEnclaveDisagreesWithItsIdentity
    tcoNoLevelCoversThisPlatform
    tcoCollateralIsNotCurrent

  TdxCollateralVerdict* = object
    outcome*: TdxCollateralOutcome
    detail*: string
    status*: string
      ## The status a policy floor is compared against. Empty unless
      ## `outcome` is `tcoEstablished`.
    launchStatus*, currentStatus*: string
      ## What the two version arrays of a wider report said, before the
      ## relaunch rule combined them. `currentStatus` is empty for a
      ## report that carries only one array, and the gate asserts that
      ## it is — a build that quietly evaluated the same array twice
      ## would otherwise look like one that evaluated two.
    relaunchApplied*: bool
    evaluation*: TdxTcbEvaluation
    advisoryIds*: seq[string]

  TdxCollateralBundle* = object
    ## What a VERIFIER holds, never what the machine under verification
    ## sends. Every field here is fetched from the vendor by whoever
    ## runs the verifier; a bundle taken from the evidence would be a
    ## machine choosing the document it is judged against.
    tcbInfoJson*: string
    enclaveIdentityJson*: string
    signerDer*: seq[byte]
      ## The vendor's collateral signing certificate.
    signerIssuerDer*: seq[byte]
      ## Its issuer, which has to be the pinned root.

proc isEstablished*(v: TdxCollateralVerdict): bool =
  v.outcome == tcoEstablished

proc establishTdxTcbStatus*(bundle: TdxCollateralBundle;
                            quote: TdxQuote;
                            platform: IntelPlatformDescription):
                           TdxCollateralVerdict =
  ## From a quote and the vendor's two signed documents to one status.
  ##
  ## The signing certificate is checked against the SAME pinned root the
  ## endorsement chain ends at, through `tdx_chain`'s `intelRootFor`, so
  ## there is exactly one root in this build and not two — and no
  ## parameter here can name a different one, for the same reason
  ## `evaluateIntelPckChain` takes no anchor.
  template no(refusal: TdxCollateralOutcome; because: string) =
    result.outcome = refusal
    result.detail = because
    return result

  var signer, issuer: X509Cert
  try:
    signer = parseCertificate(bundle.signerDer)
    issuer = parseCertificate(bundle.signerIssuerDer)
  except X509Error as err:
    no(tcoSignerChainIsNotIntels,
      "the collateral signing chain did not read: " & err.msg)
  if intelRootFor(issuer.publicKey) < 0:
    no(tcoSignerChainIsNotIntels, "the collateral signing certificate " &
      "is issued by " & describeName(issuer.subjectDn, issuer.subjectCn) &
      ", whose key is not the one root this build was built with")
  if not signer.signatureVerifiesUnder(issuer.publicKey):
    no(tcoSignerChainIsNotIntels, "the collateral signing certificate " &
      "does not verify under " &
      describeName(issuer.subjectDn, issuer.subjectCn))
  if not issuer.signatureVerifiesUnder(issuer.publicKey):
    no(tcoSignerChainIsNotIntels, "the root of the collateral signing " &
      "chain does not verify under its own key")

  var verifiedTcb, verifiedIdentity: VerifiedCollateral
  var info: TdxTcbInfo
  var identity: EnclaveIdentity
  try:
    verifiedTcb = verifyCollateral(bundle.tcbInfoJson, TcbInfoMemberName,
      signer.publicKey)
    if verifiedTcb.isVerified:
      # WHICH environment the document describes is read before the
      # reader for one environment runs over it, and not after.
      #
      # After was where it used to be, and the mutation table found the
      # rule with no input because of it: the vendor's own SGX platform
      # document publishes no trust-domain component array, so reading
      # it as a trust domain's failed on a missing field and the rule
      # about the environment was never reached. The identity of a
      # document is not a field of it like any other; it decides which
      # reader is the right one.
      let stated = statedCollateralId(verifiedTcb)
      if stated != TdxTcbInfoIdTdx:
        no(tcoTcbInfoIsNotForTrustDomains, "the platform document " &
          "states id " & stated.escape() & " and a trust domain's is " &
          TdxTcbInfoIdTdx.escape())
    if not verifiedTcb.isVerified:
      no(tcoTcbInfoNotSignedByTheSigner, "the platform document's " &
        "detached signature does not verify under " &
        describeName(signer.subjectDn, signer.subjectCn))
    verifiedIdentity = verifyCollateral(bundle.enclaveIdentityJson,
      EnclaveIdentityMemberName, signer.publicKey)
    if not verifiedIdentity.isVerified:
      no(tcoEnclaveIdentityNotSignedByTheSigner, "the enclave identity " &
        "document's detached signature does not verify under " &
        describeName(signer.subjectDn, signer.subjectCn))
    info = parseTdxTcbInfo(verifiedTcb)
    identity = parseEnclaveIdentity(verifiedIdentity)
  except TdxCollateralError as err:
    no(tcoSignerChainIsNotIntels,
      "the vendor's collateral did not read: " & err.msg)
  if info.fmspcHex != platform.fmspcHex:
    no(tcoTcbInfoIsNotForThisPlatform, "the platform document describes " &
      info.fmspcHex & " and this part's provisioning certificate states " &
      platform.fmspcHex)
  if identity.id != EnclaveIdentityIdTdQe:
    no(tcoEnclaveIdentityIsNotForTrustDomainQuoting,
      "the identity document states id " & identity.id.escape() &
      " and a trust domain's quoting enclave is " &
      EnclaveIdentityIdTdQe.escape())

  let match = quotingEnclaveMatches(identity,
    hexOf(quote.qeReport.mrSigner), int(quote.qeReport.isvProdId),
    toHex(int(quote.qeReport.miscSelect), 8).toLowerAscii,
    hexOf(quote.qeReport.attributes))
  if not match.matches:
    no(tcoQuotingEnclaveDisagreesWithItsIdentity, match.detail)

  var svns: seq[int] = @[]
  for b in quote.body.teeTcbSvn: svns.add int(b)
  var components: seq[int] = @[]
  for c in platform.tcb.components: components.add c

  let launch = evaluateTdxTcb(info, components, platform.tcb.pceSvn,
    svns, int(quote.qeReport.isvSvn), identity, true)
  result.evaluation = launch
  if not launch.isDetermined:
    no(tcoNoLevelCoversThisPlatform, launch.detail)
  result.launchStatus = launch.status
  result.advisoryIds = launch.advisoryIds
  result.status = launch.status

  # A wider report carries a second version array: what the platform is
  # running NOW, against what the trust domain was launched under. The
  # relaunch rule is consulted only when there IS a second array, so a
  # build that evaluated the same array twice would report a
  # `currentStatus` where this reports none.
  if quote.body.hasPreservedTcb:
    var svns2: seq[int] = @[]
    for b in quote.body.teeTcbSvn2: svns2.add int(b)
    let current = evaluateTdxTcb(info, components, platform.tcb.pceSvn,
      svns2, int(quote.qeReport.isvSvn), identity, true)
    if not current.isDetermined:
      no(tcoNoLevelCoversThisPlatform, "the version array the platform " &
        "is running now: " & current.detail)
    result.currentStatus = current.status
    result.status = checkForRelaunch(launch.status, current.status)
    result.relaunchApplied = result.status != launch.status

  result.outcome = tcoEstablished
  result.detail = "the vendor's document for platform " & info.fmspcHex &
    " (issued " & info.issueDate & ", " & $info.levels.len &
    " levels) and its identity for " & identity.id & " say " &
    result.status & "; " & launch.detail &
    (if quote.body.hasPreservedTcb:
       "; the array it is running now says " & result.currentStatus &
       (if result.relaunchApplied: ", so a relaunch is advised" else: "")
     else: "")

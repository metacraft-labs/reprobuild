## The ``reproos.attestation-policy.v1`` measurement policy.
##
## ## What the document is for
##
## A report says what a machine is. A policy says which machines this
## verifier is willing to believe: which roots of trust, which backends,
## which measurements, how old a challenge may be, and how far a vendor's
## trusted computing base may have fallen behind. It is the only
## hand-edited document in the attestation chain, so it is the only one
## whose author can make a mistake nothing else would catch.
##
## That is why almost everything here is a refusal.
##
## ## Fail-closed, and what that means beyond unknown fields
##
## Refusing an unknown key is the easy half. A policy can also be *well
## formed and incoherent* — accepting a backend whose tier it rejects,
## bounding the age of a challenge it does not require, pinning the exact
## measurements of a production image while also accepting a backend that
## measures nothing. Each of those reads as strict and is not, so each is
## refused *at parse time*, before a report is ever seen. A policy this
## module returns is one whose every clause can bite.
##
## The refusals, in one place:
##
##   * an unknown top-level table, an unknown key in any table, a
##     duplicate key, a value of the wrong type;
##   * a schema version this build does not implement;
##   * an unknown tier or backend name, or a repeated one;
##   * an empty tier or backend list — a policy that can accept nothing
##     is not a strict policy, it is a mistake;
##   * a backend whose tier is not accepted, or an accepted tier with no
##     backend to serve it, so the two lists cannot drift apart;
##   * ``allow_mock`` and the ``mock`` tier disagreeing in either
##     direction — both say the same thing and the agreement between them
##     is what is checked, rather than either one alone;
##   * ``allow_mock`` together with pinned measurement manifests (below);
##   * a ``[tcb]`` table with no confidential-computing backend to bound,
##     or a confidential-computing backend with no ``[tcb]`` table;
##   * an age bound on a challenge the policy does not require;
##   * a ``[measurements.evidence]`` table, because this build does not
##     implement the evidence-backed posture and a policy clause nothing
##     enforces is weaker than the policy it appears to be.
##
## ## Why ``allow_mock`` and pinned manifests cannot coexist
##
## Pinning manifest digests says "the machine must measure exactly this
## image". ``allow_mock`` admits a backend that takes no launch
## measurement at all, so a report from it can never be compared to a
## pinned manifest — the comparison is skipped, and the pin becomes
## decoration. The two clauses do not conflict loudly; they conflict
## quietly, in a direction that makes the document look stricter than it
## is. So it is a configuration error, refused here rather than a runtime
## outcome discovered per report.
##
## ## Mocking
##
## None. The parser reads real bytes.

import std/[strutils, tables]

import repro_attest

type
  PolicyError* = object of CatchableError
    ## Raised for any policy document this module will not honour. The
    ## message names the line and the key, because whoever reads it is
    ## editing the file.

  SevSnpTcbMinimum* = object
    ## The four component levels of an SEV-SNP TCB version. Each is a
    ## byte on the wire, so each is bounded here.
    bootloader*: int
    tee*: int
    snp*: int
    microcode*: int

  MeasurementPolicy* = object
    manifests*: seq[string]
      ## ``sha256:<hex>`` digests of the measurement manifests this
      ## verifier will compare against. Empty is a legitimate and
      ## explicit choice — the local-reproduction posture, where the
      ## verifier built the manifest itself — and it must be spelled,
      ## because an absent key is a refusal.
    requireCertificates*: bool
      ## Whether a report must bundle a certificate chain to be
      ## considered at all.

  TcbPolicy* = object
    present*: bool
    sevSnpMinTcb*: SevSnpTcbMinimum
    hasSevSnpMinTcb*: bool
    tdxMinTcbStatus*: string
    hasTdxMinTcbStatus*: bool
    allowGraceDays*: int

  FreshnessPolicy* = object
    maxChallengeAgeSeconds*: int
      ## Zero waives the age bound; a negative value is refused. The
      ## waiver has to be written down, so a policy with no age bound is
      ## a policy that says so.
    requireChallenge*: bool

  AttestationPolicy* = object
    tiers*: seq[AttestationTier]
    backends*: seq[AttestationBackend]
    allowMock*: bool
    measurements*: MeasurementPolicy
    tcb*: TcbPolicy
    freshness*: FreshnessPolicy

const
  AttestationPolicySchema* = "reproos.attestation-policy.v1"

  TierMock* = "mock"
    ## The literal spelling of the tier ``allow_mock`` governs. Pinned
    ## here as a string rather than reached for through ``$atMock``, so a
    ## rename of the enum's serialization cannot silently move which tier
    ## this module's refusals are about.

  KnownTdxTcbStatuses*: array[6, string] = [
    "UpToDate", "SWHardeningNeeded", "ConfigurationNeeded",
    "ConfigurationAndSWHardeningNeeded", "OutOfDate",
    "OutOfDateConfigurationNeeded"]
    ## The DCAP statuses a policy may name as its floor. ``Revoked`` is
    ## deliberately absent: a floor of ``Revoked`` is satisfied by every
    ## quote, which is a policy clause that accepts everything while
    ## reading as though it restricts something.

  MaxTcbComponent* = 255
    ## Each SEV-SNP TCB component is one byte.

  MaxGraceDays* = 365
    ## A grace window is the gap between a TCB recovery and the fleet
    ## finishing its rotation. A year is not that gap; it is an
    ## indefinite acceptance of a known-bad TCB with a number beside it.

  MaxPinnedManifests* = 64
  MaxPolicyBytes* = 65_536

# ---------------------------------------------------------------------
# A strict TOML subset
#
# Hand-written, and deliberately not a general TOML reader. Every value
# this document carries is a string, an integer, a boolean, an array of
# strings, or an inline table of those — so that is the whole grammar,
# and everything else is a refusal naming the line. A general parser
# would accept multi-line strings, dates, floats and arrays of tables,
# none of which this schema defines, and would then have to refuse them
# one layer up with a worse message.
# ---------------------------------------------------------------------

type
  TomlKind = enum
    tkString, tkInt, tkBool, tkStringArray

  TomlValue = object
    line: int
    case kind: TomlKind
    of tkString: s: string
    of tkInt: i: int
    of tkBool: b: bool
    of tkStringArray: a: seq[string]

  TomlDoc = object
    ## Every scalar in the document, keyed by its full dotted path. A
    ## nested table and an inline table produce the same paths, so the
    ## schema layer below never has to know which spelling was used.
    values: OrderedTable[string, TomlValue]

proc fail(line: int; msg: string) {.noreturn.} =
  raise newException(PolicyError, "line " & $line & ": " & msg)

proc isBareKey(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'z', 'A' .. 'Z', '_', '-'}:
      return false
  true

proc requireDottedKey(line: int; key: string): string =
  ## A dotted key is a sequence of bare keys. Anything else — a quoted
  ## segment, an empty segment, whitespace inside — is refused, so one
  ## path has one spelling and a duplicate cannot hide behind a second.
  if key.len == 0: fail(line, "an empty key")
  for part in key.split('.'):
    if not isBareKey(part):
      fail(line, "the key " & key.escape() &
        " has a segment that is not a bare key of [0-9A-Za-z_-]")
  key

proc parseTomlString(line: int; text: string; i: var int): string =
  ## Basic strings only: double quotes, with ``\"`` and ``\\`` the only
  ## escapes. A policy value is a name, a digest or a status word; the
  ## escapes a fuller grammar defines would exist here only to be
  ## mis-read.
  if i >= text.len or text[i] != '"':
    fail(line, "expected a double-quoted string")
  inc i
  result = ""
  while true:
    if i >= text.len:
      fail(line, "an unterminated string")
    let c = text[i]
    if c == '"':
      inc i
      return result
    if c == '\\':
      inc i
      if i >= text.len: fail(line, "an unterminated escape")
      case text[i]
      of '"': result.add '"'
      of '\\': result.add '\\'
      else:
        fail(line, "the escape \\" & text[i] &
          " is not one of the two this reader honours (\\\" and \\\\)")
      inc i
    else:
      if c == '\t' or c == '\r':
        fail(line, "a raw control character inside a string")
      result.add c
      inc i

proc skipSpace(text: string; i: var int) =
  while i < text.len and text[i] in {' ', '\t'}: inc i

proc parseScalar(line: int; text: string; i: var int): TomlValue =
  skipSpace(text, i)
  if i >= text.len: fail(line, "a key with no value")
  if text[i] == '"':
    return TomlValue(line: line, kind: tkString,
                     s: parseTomlString(line, text, i))
  let start = i
  while i < text.len and text[i] notin {',', '}', ']', ' ', '\t', '#'}:
    inc i
  let word = text[start ..< i]
  if word.len == 0: fail(line, "a key with no value")
  if word == "true": return TomlValue(line: line, kind: tkBool, b: true)
  if word == "false": return TomlValue(line: line, kind: tkBool, b: false)
  var digits = word
  if digits.len > 0 and digits[0] == '-': digits = digits[1 .. ^1]
  if digits.len == 0 or not digits.allCharsInSet({'0' .. '9'}):
    fail(line, "the value " & word.escape() &
      " is not a quoted string, an integer, or true/false; this reader " &
      "defines no other scalar")
  var n = 0
  try:
    n = parseInt(word)
  except ValueError:
    fail(line, "the integer " & word.escape() & " does not fit")
  TomlValue(line: line, kind: tkInt, i: n)

proc parseStringArray(line: int; text: string; i: var int): TomlValue =
  ## ``[ "a", "b" ]`` on one line. An array of anything but strings is
  ## refused: every list this schema defines is a list of names.
  inc i                                        # past '['
  var items: seq[string] = @[]
  while true:
    skipSpace(text, i)
    if i < text.len and text[i] == ']':
      inc i
      return TomlValue(line: line, kind: tkStringArray, a: items)
    if i >= text.len: fail(line, "an unterminated array")
    if text[i] != '"':
      fail(line, "an array element that is not a quoted string; every " &
        "list this schema defines is a list of names")
    items.add parseTomlString(line, text, i)
    skipSpace(text, i)
    if i < text.len and text[i] == ',':
      inc i
    elif i < text.len and text[i] == ']':
      inc i
      return TomlValue(line: line, kind: tkStringArray, a: items)
    else:
      fail(line, "an array element not followed by ',' or ']'")

proc put(doc: var TomlDoc; line: int; path: string; v: TomlValue) =
  if doc.values.hasKey(path):
    fail(line, "the key " & path.escape() & " is set twice, and there " &
      "is no rule saying which one would win")
  doc.values[path] = v

proc parseInlineTable(doc: var TomlDoc; line: int; prefix, text: string;
                      i: var int) =
  inc i                                        # past '{'
  while true:
    skipSpace(text, i)
    if i < text.len and text[i] == '}':
      inc i
      return
    if i >= text.len: fail(line, "an unterminated inline table")
    let start = i
    while i < text.len and text[i] notin {'=', ' ', '\t', ',', '}'}: inc i
    let key = requireDottedKey(line, text[start ..< i])
    skipSpace(text, i)
    if i >= text.len or text[i] != '=':
      fail(line, "the inline-table key " & key.escape() & " has no '='")
    inc i
    skipSpace(text, i)
    if i < text.len and text[i] == '{':
      fail(line, "a nested inline table; this schema defines none")
    if i < text.len and text[i] == '[':
      put(doc, line, prefix & "." & key, parseStringArray(line, text, i))
    else:
      put(doc, line, prefix & "." & key, parseScalar(line, text, i))
    skipSpace(text, i)
    if i < text.len and text[i] == ',':
      inc i
    elif i < text.len and text[i] == '}':
      inc i
      return
    else:
      fail(line, "an inline-table entry not followed by ',' or '}'")

proc parseTomlSubset(text: string): TomlDoc =
  result.values = initOrderedTable[string, TomlValue]()
  var section = ""
  var lineNo = 0
  for rawLine in text.splitLines:
    inc lineNo
    var line = rawLine
    if line.len > 0 and line[^1] == '\r': line = line[0 ..< ^1]
    var i = 0
    skipSpace(line, i)
    if i >= line.len: continue
    if line[i] == '#': continue
    if line[i] == '[':
      if i + 1 < line.len and line[i + 1] == '[':
        fail(lineNo, "an array of tables; this schema defines none")
      inc i
      let start = i
      while i < line.len and line[i] != ']': inc i
      if i >= line.len: fail(lineNo, "an unterminated table header")
      section = requireDottedKey(lineNo, line[start ..< i].strip())
      inc i
      skipSpace(line, i)
      if i < line.len and line[i] != '#':
        fail(lineNo, "trailing text after a table header")
      continue
    let keyStart = i
    while i < line.len and line[i] notin {'=', ' ', '\t'}: inc i
    let key = requireDottedKey(lineNo, line[keyStart ..< i])
    skipSpace(line, i)
    if i >= line.len or line[i] != '=':
      fail(lineNo, "the key " & key.escape() & " has no '='")
    inc i
    let path = (if section.len == 0: key else: section & "." & key)
    skipSpace(line, i)
    if i >= line.len: fail(lineNo, "the key " & key.escape() & " has no value")
    if line[i] == '{':
      parseInlineTable(result, lineNo, path, line, i)
    elif line[i] == '[':
      put(result, lineNo, path, parseStringArray(lineNo, line, i))
    else:
      put(result, lineNo, path, parseScalar(lineNo, line, i))
    skipSpace(line, i)
    if i < line.len and line[i] != '#':
      fail(lineNo, "trailing text after the value of " & key.escape())

# ---------------------------------------------------------------------
# Reading the schema out of the document
#
# Every getter CONSUMES the key it read. What is left over at the end is
# exactly the set of keys this build does not understand, so the
# unknown-field refusal is a consequence of the reading rather than a
# second list somebody has to keep in step with the first.
# ---------------------------------------------------------------------

type
  Reader = object
    doc: TomlDoc
    source: string

proc missing(r: Reader; path: string) {.noreturn.} =
  raise newException(PolicyError, r.source & ": the required key " &
    path.escape() & " is absent; a policy this build cannot read in full " &
    "is refused rather than read in part")

proc takeString(r: var Reader; path: string): string =
  if not r.doc.values.hasKey(path): missing(r, path)
  let v = r.doc.values[path]
  if v.kind != tkString:
    fail(v.line, path.escape() & " must be a quoted string")
  r.doc.values.del(path)
  v.s

proc takeInt(r: var Reader; path: string): int =
  if not r.doc.values.hasKey(path): missing(r, path)
  let v = r.doc.values[path]
  if v.kind != tkInt:
    fail(v.line, path.escape() & " must be an integer")
  r.doc.values.del(path)
  v.i

proc takeBool(r: var Reader; path: string): bool =
  if not r.doc.values.hasKey(path): missing(r, path)
  let v = r.doc.values[path]
  if v.kind != tkBool:
    fail(v.line, path.escape() & " must be true or false")
  r.doc.values.del(path)
  v.b

proc takeStringArray(r: var Reader; path: string): seq[string] =
  if not r.doc.values.hasKey(path): missing(r, path)
  let v = r.doc.values[path]
  if v.kind != tkStringArray:
    fail(v.line, path.escape() & " must be an array of quoted strings")
  r.doc.values.del(path)
  v.a

proc hasPrefix(r: Reader; prefix: string): bool =
  for key in r.doc.values.keys:
    if key == prefix or key.startsWith(prefix & "."): return true
  false

proc lineOf(r: Reader; path: string): int =
  if r.doc.values.hasKey(path): r.doc.values[path].line else: 0

# ---------------------------------------------------------------------
# The parser proper
# ---------------------------------------------------------------------

proc isSha256Digest(s: string): bool =
  const prefix = "sha256:"
  if not s.startsWith(prefix): return false
  let hex = s[prefix.len .. ^1]
  if hex.len != 64: return false
  for c in hex:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc parseAttestationPolicy*(text, source: string): AttestationPolicy =
  ## Parse and fully validate a policy document. ``source`` names the
  ## file in every message, because the reader of these errors is
  ## editing it.
  if text.len > MaxPolicyBytes:
    raise newException(PolicyError, source & ": is " & $text.len &
      " bytes; a measurement policy is a page of decisions, and at most " &
      $MaxPolicyBytes & " bytes are read")
  var r = Reader(source: source)
  try:
    r.doc = parseTomlSubset(text)
  except PolicyError as err:
    raise newException(PolicyError, source & ": " & err.msg)

  template refuse(msg: string) =
    raise newException(PolicyError, source & ": " & msg)

  try:
    let schema = r.takeString("schema")
    if schema != AttestationPolicySchema:
      refuse("schema is " & schema.escape() & "; this build understands " &
        AttestationPolicySchema.escape() &
        " and refuses a document it cannot fully honour")

    # -- [accept] ----------------------------------------------------
    var tierNames = r.takeStringArray("accept.tiers")
    var backendNames = r.takeStringArray("accept.backends")
    result.allowMock = r.takeBool("accept.allow_mock")

    if tierNames.len == 0:
      refuse("accept.tiers is empty; a policy that can accept no tier " &
        "can accept no report, which is a mistake rather than a strict " &
        "posture")
    if backendNames.len == 0:
      refuse("accept.backends is empty; a policy that can accept no " &
        "backend can accept no report")

    var seenTiers: seq[string] = @[]
    for name in tierNames:
      if name in seenTiers:
        refuse("accept.tiers repeats " & name.escape())
      seenTiers.add name
      result.tiers.add parseTier(source & ": accept.tiers", name)
    var seenBackends: seq[string] = @[]
    for name in backendNames:
      if name in seenBackends:
        refuse("accept.backends repeats " & name.escape())
      seenBackends.add name
      result.backends.add parseBackend(source & ": accept.backends", name)

    let mockNamed = TierMock in seenTiers
    if result.allowMock and not mockNamed:
      refuse("accept.allow_mock is true but accept.tiers does not name " &
        TierMock.escape() & "; the two say the same thing and it is the " &
        "agreement between them that is checked, so a verifier is never " &
        "one edit away from accepting a report with no root of trust")
    if mockNamed and not result.allowMock:
      refuse("accept.tiers names " & TierMock.escape() &
        " but accept.allow_mock is false; accepting a tier with no root " &
        "of trust has to be said twice, and this document says it once")

    for b in result.backends:
      if tierOf(b) notin result.tiers:
        refuse("accept.backends names " & ($b).escape() &
          ", whose tier is " & ($tierOf(b)).escape() &
          ", and accept.tiers does not accept that tier; a policy whose " &
          "two lists disagree is one whose stricter half is decoration")
    for t in result.tiers:
      var served = false
      for b in result.backends:
        if tierOf(b) == t: served = true
      if not served:
        refuse("accept.tiers names " & ($t).escape() &
          " and accept.backends names no backend of that tier; the tier " &
          "could never be reached")

    # -- [measurements] ----------------------------------------------
    if r.hasPrefix("measurements.evidence"):
      refuse("[measurements.evidence] asks this verifier to accept a " &
        "measurement manifest on the strength of build evidence, which " &
        "this build cannot evaluate. It is refused rather than ignored: " &
        "a policy clause nothing enforces makes the document read " &
        "stricter than the verifier behind it. Pin the manifests you " &
        "accept, or reproduce the image and compare.")
    result.measurements.manifests = r.takeStringArray("measurements.manifests")
    result.measurements.requireCertificates =
      r.takeBool("measurements.require_certificates")
    if result.measurements.manifests.len > MaxPinnedManifests:
      refuse("measurements.manifests pins " &
        $result.measurements.manifests.len & " digests; at most " &
        $MaxPinnedManifests & " are read")
    var seenDigests: seq[string] = @[]
    for d in result.measurements.manifests:
      if not isSha256Digest(d):
        refuse("measurements.manifests carries " & d.escape() &
          "; each entry is \"sha256:<64 lower-case hex characters>\", " &
          "the digest of the manifest document itself")
      if d in seenDigests:
        refuse("measurements.manifests repeats " & d.escape())
      seenDigests.add d

    if result.allowMock and result.measurements.manifests.len > 0:
      refuse("accept.allow_mock is true and measurements.manifests pins " &
        $result.measurements.manifests.len &
        " manifest digest(s). A mock report carries no launch " &
        "measurement, so it can never be compared against a pinned " &
        "manifest — the comparison is skipped and the pin decides " &
        "nothing. The two clauses do not conflict loudly; they conflict " &
        "in the direction that makes this document look stricter than " &
        "the verifier it configures, so it is refused here rather than " &
        "discovered one report at a time")

    # -- [freshness] -------------------------------------------------
    result.freshness.maxChallengeAgeSeconds =
      r.takeInt("freshness.max_challenge_age_seconds")
    result.freshness.requireChallenge = r.takeBool("freshness.require_challenge")
    if result.freshness.maxChallengeAgeSeconds < 0:
      refuse("freshness.max_challenge_age_seconds is " &
        $result.freshness.maxChallengeAgeSeconds &
        "; zero waives the age bound and is the way to say so")
    if not result.freshness.requireChallenge and
       result.freshness.maxChallengeAgeSeconds > 0:
      refuse("freshness.max_challenge_age_seconds bounds the age of a " &
        "challenge that freshness.require_challenge does not require; " &
        "there would be nothing to measure the age of")

    # -- [tcb] -------------------------------------------------------
    var wantsCvm = false
    for b in result.backends:
      if tierOf(b) == atCvm: wantsCvm = true
    result.tcb.present = r.hasPrefix("tcb")
    if wantsCvm and not result.tcb.present:
      refuse("accept.backends names a confidential-computing backend and " &
        "the document carries no [tcb] table; a CVM report states the " &
        "vendor's trusted computing base and a policy that does not " &
        "bound it accepts every TCB level ever shipped, including the " &
        "ones a recovery retired")
    if result.tcb.present and not wantsCvm:
      refuse("[tcb] bounds the trusted computing base of a " &
        "confidential-computing backend and accept.backends names none")
    if result.tcb.present:
      result.tcb.allowGraceDays = r.takeInt("tcb.allow_grace_days")
      if result.tcb.allowGraceDays < 0 or
         result.tcb.allowGraceDays > MaxGraceDays:
        refuse("tcb.allow_grace_days is " & $result.tcb.allowGraceDays &
          "; it is the gap between a TCB recovery and a fleet finishing " &
          "its rotation, so it lies between 0 and " & $MaxGraceDays)
      if abSevSnp in result.backends:
        result.tcb.hasSevSnpMinTcb = true
        result.tcb.sevSnpMinTcb = SevSnpTcbMinimum(
          bootloader: r.takeInt("tcb.sev-snp.min_tcb.bootloader"),
          tee: r.takeInt("tcb.sev-snp.min_tcb.tee"),
          snp: r.takeInt("tcb.sev-snp.min_tcb.snp"),
          microcode: r.takeInt("tcb.sev-snp.min_tcb.microcode"))
        for name, value in result.tcb.sevSnpMinTcb.fieldPairs:
          if value < 0 or value > MaxTcbComponent:
            refuse("tcb.sev-snp.min_tcb." & name & " is " & $value &
              "; each component of an SEV-SNP TCB version is one byte")
      elif r.hasPrefix("tcb.sev-snp"):
        refuse("[tcb] bounds sev-snp and accept.backends does not name it")
      if abTdx in result.backends:
        result.tcb.hasTdxMinTcbStatus = true
        result.tcb.tdxMinTcbStatus = r.takeString("tcb.tdx.min_tcb_status")
        if result.tcb.tdxMinTcbStatus notin KnownTdxTcbStatuses:
          refuse("tcb.tdx.min_tcb_status is " &
            result.tcb.tdxMinTcbStatus.escape() &
            "; this build bounds the statuses " &
            KnownTdxTcbStatuses.join(", ") &
            " and refuses one it cannot order")
      elif r.hasPrefix("tcb.tdx"):
        refuse("[tcb] bounds tdx and accept.backends does not name it")

    # -- what is left is what this build does not understand ---------
    if r.doc.values.len > 0:
      var unknown: seq[string] = @[]
      for key in r.doc.values.keys: unknown.add key
      let first = unknown[0]
      refuse("line " & $r.lineOf(first) & ": the key " & first.escape() &
        " is not part of " & AttestationPolicySchema &
        (if unknown.len > 1: " (and " & $(unknown.len - 1) & " more: " &
           unknown[1 .. ^1].join(", ") & ")" else: "") &
        "; a policy carrying a clause this build cannot honour is " &
        "refused rather than partly applied")
  except ReportError as err:
    # `parseTier` / `parseBackend` speak the report schema's error type.
    # A policy's reader should raise a policy's error whatever refused.
    raise newException(PolicyError, err.msg)

proc acceptsTier*(p: AttestationPolicy; tier: AttestationTier): bool =
  ## Whether the policy admits this root-of-trust tier at all.
  ##
  ## The mock tier answers ``true`` only when ``allow_mock`` is set AND
  ## the tier is listed — the same agreement the parser refuses to let
  ## drift. Checked here again rather than assumed, because this is the
  ## predicate a verdict is derived from and it should not depend on a
  ## refusal in another module having run.
  if tier notin p.tiers: return false
  if tier == atMock: return p.allowMock
  true

proc acceptsBackend*(p: AttestationPolicy; backend: AttestationBackend): bool =
  backend in p.backends and p.acceptsTier(tierOf(backend))

proc pinsManifests*(p: AttestationPolicy): bool =
  p.measurements.manifests.len > 0

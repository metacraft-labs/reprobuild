## The tpm2 backend: the evidence a measured-boot machine produces, and
## the driver that assembles it.
##
## ## What a tpm2 quote is not, on its own
##
## A `TPM2_Quote` answer is two structures — a `TPMS_ATTEST` and the
## `TPMT_SIGNATURE` over it — and between them they carry one digest of
## a set of registers. That digest says the registers held certain
## values; it does not say *why*, and a verifier that can only compare a
## digest against a stored copy of itself can tell you that a machine
## booted the same way twice and nothing about what it booted.
##
## The TCG event log is what supplies the why: replaying it recomputes
## the registers, so a verifier can attribute each extend to the thing
## that performed it. The log is unsigned, which is exactly why it has to
## travel with the quote rather than beside it — an unsigned document
## checked against a signed digest is evidence; an unsigned document
## fetched separately is a document.
##
## So the three artifacts are one piece of evidence and this module gives
## them one encoding.
##
## ## Why the format versions itself INSIDE the blob
##
## A report envelope carries `evidence` as one opaque field and has no
## place to say what format it is in beyond the backend name. `tpm2` is
## the name of a root of trust, not of a serialization, and a future
## composite — one carrying a certified key, say, or a second log — would
## be the same backend and a different document. A reader that guessed
## between them by length or by probing would be a reader that believes
## things nobody said.
##
## `Tpm2EvidenceSchema` is therefore the first thing in the bytes, it is
## versioned, and a blob that begins with anything else is refused rather
## than attempted. A new composite is a new schema, never a new reading
## of this one.
##
## ## The encoding
##
## Big-endian throughout, because every structure inside it is::
##
##   be32(len(schema)) ‖ schema                -- "reproos.tpm2-evidence.v1"
##   be32(memberCount)
##   memberCount × [ be32(tag) ‖ be32(len) ‖ len raw bytes ]
##
## Length-prefixed rather than delimited, for the reason the report
## data's preimage is: a delimiter has to be escaped, an escape has to be
## unescaped, and two implementations that disagree about the unescaping
## produce two documents that are equal on every input anybody tried.
##
## The members are the three artifacts, tagged, and the rules on them are
## all refusals:
##
##   * **Tags strictly ascend**, so one evidence set has exactly one
##     encoding and a member cannot appear twice.
##   * **Every member this schema defines is required.** This is the rule
##     that matters most, and it is why the parser has no "no members"
##     success to degrade into: a composite that parsed with nothing in
##     it would validate trivially and say nothing, which is the failure
##     shape every layer of this system is built to refuse.
##   * **A zero-length member is refused.** An empty event log is not a
##     log that explains nothing, it is an absent log wearing a present
##     one's tag.
##   * **An unknown tag is refused**, not skipped. Skipping is how a
##     verifier comes to ignore the half of the evidence it was the point
##     of the exercise to read.
##   * **Nothing trails the last member.** A blob with bytes appended is
##     not the blob that was assembled.
##
## ## The size bound, measured rather than assumed
##
## The envelope carries at most `MaxEvidenceBase64` base64 characters,
## which is `MaxTpm2EvidenceBytes` raw. The event log is the member that
## can grow: firmware measures every UEFI variable it consults, and on a
## machine with Secure Boot keys enrolled the signature databases are the
## bulk of the log. `composeTpm2Evidence` refuses to build a blob over
## the bound, so the refusal names the machine that produced an oversized
## log instead of surfacing later as a complaint about a document.
##
## ## What this module does NOT do
##
##   * **It verifies no signature.** Nothing in this library performs an
##     ECDSA or RSA check, and assembling evidence is not the place to
##     start: the agent runs inside the thing being trusted, and code
##     that decides whether to trust does not belong there.
##   * **It applies no policy.** Whether the measurements are ACCEPTABLE
##     is a verifier's question and is answered against a pinned
##     manifest, not here.
##   * **It issues no TPM command.** `Tpm2Source` is the seam a command
##     transaction plugs into; the implementation shipped here reads
##     artifacts a TPM has already produced, from paths it is configured
##     with.
##
## ## Mocking
##
## None. `CapturedTpm2Source` is not a mock of a TPM: every byte it
## returns was produced by one, and it reads them from the filesystem
## rather than synthesizing them. The checks in `driverQuote` run against
## those real bytes, which is the point — a source that returns a stale
## or foreign quote is refused by the same rule that would refuse a
## misbehaving device.

import std/[options, os, strutils]

import ./binding
import ./driver
import ./event_log
import ./report
import ./tpm2

const
  Tpm2EvidenceSchema* = "reproos.tpm2-evidence.v1"
    ## The first bytes of every composite this module writes, and the
    ## only ones it reads. See the module header.

  Tpm2DriverName* = "tpm2"

  MaxTpm2EvidenceBytes* = (MaxEvidenceBase64 div 4) * 3
    ## The envelope's bound, in raw bytes. Base64 is four characters per
    ## three bytes, so this is the largest composite that fits.

  MaxTpm2EvidenceMembers* = 3
    ## What this schema defines. A count above it is refused before the
    ## member loop runs, so a declared count of four billion costs a
    ## comparison rather than four billion iterations.

type
  Tpm2EvidenceError* = object of CatchableError
    ## The one error this module raises. The codecs underneath it raise
    ## `Tpm2CodecError` and `TcgEventLogError`; both are translated at
    ## the boundary so a caller needs one `try` and cannot accidentally
    ## catch one refusal while letting another escape.

  Tpm2EvidenceMember* = enum
    ## The tag each member carries on the wire. The values are explicit
    ## and ascending because the wire depends on them: renumbering one
    ## is a format change, not a refactor.
    temAttest = 1
      ## `TPMS_ATTEST`, exactly as the TPM produced it. The signature
      ## covers these bytes and never a re-serialisation of them.
    temSignature = 2
      ## The `TPMT_SIGNATURE` over the attest.
    temEventLog = 3
      ## The TCG event log, as firmware wrote it.

  Tpm2Evidence* = object
    ## The three artifacts, decoded from a composite or on their way
    ## into one.
    attestBytes*: string
    signatureBytes*: string
    eventLogBytes*: string

static:
  # The bound and the enum are one fact. A member added to the enum
  # without the bound moving would be written by the composer and
  # refused by the parser, which is a format that disagrees with itself
  # — so it does not compile instead.
  doAssert MaxTpm2EvidenceMembers ==
           ord(high(Tpm2EvidenceMember)) - ord(low(Tpm2EvidenceMember)) + 1
  doAssert ord(low(Tpm2EvidenceMember)) == 1

proc fail(msg: string) {.noreturn.} =
  raise newException(Tpm2EvidenceError, msg)

proc preview(s: string): string =
  ## An offending value, escaped and BOUNDED.
  ##
  ## A refusal quotes what it refused so an operator can see it, but the
  ## schema field's length is declared by the document being refused — so
  ## quoting it whole lets a hostile blob choose the size of the
  ## diagnostic. Sixty-four bytes is enough to recognise a version tag and
  ## not enough to be a payload.
  const Shown = 64
  if s.len <= Shown: s.escape()
  else: s[0 ..< Shown].escape() & " (and " & $(s.len - Shown) & " more bytes)"

proc memberName(tag: Tpm2EvidenceMember): string =
  case tag
  of temAttest: "attest"
  of temSignature: "signature"
  of temEventLog: "eventLog"

# ---------------------------------------------------------------------
# Composing
# ---------------------------------------------------------------------

proc memberBytes*(ev: Tpm2Evidence; tag: Tpm2EvidenceMember): string =
  ## One member's payload. Written so the composer and the checks agree
  ## about which field carries which tag by construction rather than by
  ## two lists kept in step.
  case tag
  of temAttest: ev.attestBytes
  of temSignature: ev.signatureBytes
  of temEventLog: ev.eventLogBytes

proc composeTpm2Evidence*(ev: Tpm2Evidence): string =
  ## The bytes a tpm2 quote's `evidence` field consists of.
  ##
  ## Every member is required and none may be empty, on the way out as
  ## well as on the way in: a composer that emitted a document its own
  ## parser refuses would move the failure to whoever reads it.
  var w = initTpm2Writer(Tpm2EvidenceSchema)
  w.writeU32(uint32(Tpm2EvidenceSchema.len))
  w.writeBytes(Tpm2EvidenceSchema)
  w.writeU32(uint32(MaxTpm2EvidenceMembers))
  for tag in Tpm2EvidenceMember:
    let payload = ev.memberBytes(tag)
    if payload.len == 0:
      fail(Tpm2EvidenceSchema & ": the " & memberName(tag) &
           " member is empty; a composite carries all " &
           $MaxTpm2EvidenceMembers & " of its members and an absent one " &
           "is a refusal rather than a shorter document")
    w.writeU32(uint32(ord(tag)))
    w.writeU32(uint32(payload.len))
    w.writeBytes(payload)
  result = w.bytes
  if result.len > MaxTpm2EvidenceBytes:
    fail(Tpm2EvidenceSchema & ": this composite is " & $result.len &
         " bytes and the report envelope carries at most " &
         $MaxTpm2EvidenceBytes & " (" & $MaxEvidenceBase64 &
         " base64 characters); the event log is " & $ev.eventLogBytes.len &
         " bytes of it")

# ---------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------

proc parseTpm2Evidence*(blob: string): Tpm2Evidence =
  ## Read a composite. Strict on every axis the module header lists.
  var r = initTpm2Reader(blob, Tpm2EvidenceSchema)
  try:
    let schemaLen = int(r.readU32("schema.size"))
    let schema = r.readBytes("schema", schemaLen)
    if schema != Tpm2EvidenceSchema:
      fail("tpm2 evidence begins " & preview(schema) &
           "; this build reads " & Tpm2EvidenceSchema.escape() &
           " and nothing else, because a composite whose shape was " &
           "guessed is a composite nobody described")

    let declared = r.readU32("memberCount")
    if declared > uint32(MaxTpm2EvidenceMembers):
      fail(Tpm2EvidenceSchema & ": declares " & $declared &
           " members at offset " & $(r.offset - 4) & ", and this schema " &
           "defines " & $MaxTpm2EvidenceMembers)

    var present: array[Tpm2EvidenceMember, string]
    var seen: array[Tpm2EvidenceMember, bool]
    var previous = 0'u32
    for i in 0 ..< int(declared):
      let where = "members[" & $i & "]"
      let rawTag = r.readU32(where & ".tag")
      if rawTag < uint32(ord(low(Tpm2EvidenceMember))) or
         rawTag > uint32(ord(high(Tpm2EvidenceMember))):
        fail(Tpm2EvidenceSchema & ": " & where & " carries tag " & $rawTag &
             " at offset " & $(r.offset - 4) &
             ", which this schema does not define. An unknown member is " &
             "refused rather than skipped: a reader that skipped one " &
             "would ignore evidence somebody meant it to read")
      if rawTag <= previous:
        if rawTag == previous:
          fail(Tpm2EvidenceSchema & ": the " &
               memberName(Tpm2EvidenceMember(rawTag)) &
               " member appears twice, at " & where &
               "; one evidence set has one encoding, so a repeated " &
               "member is a refusal rather than a later value winning")
        fail(Tpm2EvidenceSchema & ": " & where & " carries tag " & $rawTag &
             " after tag " & $previous &
             "; members ascend by tag so one evidence set has exactly " &
             "one encoding")
      previous = rawTag

      let tag = Tpm2EvidenceMember(rawTag)
      let size = int(r.readU32(where & ".size"))
      if size == 0:
        fail(Tpm2EvidenceSchema & ": the " & memberName(tag) &
             " member is empty at " & where &
             "; an empty member is an absent one wearing a present " &
             "member's tag")
      present[tag] = r.readBytes(where & "." & memberName(tag), size)
      seen[tag] = true

    r.finish()

    var missing: seq[string] = @[]
    for tag in Tpm2EvidenceMember:
      if not seen[tag]: missing.add memberName(tag)
    if missing.len > 0:
      fail(Tpm2EvidenceSchema & ": no " & missing.join(", ") &
           " member; every member this schema defines is required, " &
           "because a composite that validated with members missing " &
           "would validate while carrying nothing")

    result = Tpm2Evidence(
      attestBytes: present[temAttest],
      signatureBytes: present[temSignature],
      eventLogBytes: present[temEventLog])
  except Tpm2CodecError as e:
    # Translated, not swallowed. The cursor's refusals are the truncation
    # and length-disagreement rules, and they must reach the caller as
    # refusals of this document rather than as a different exception type
    # a caller might not be catching.
    fail(Tpm2EvidenceSchema & ": " & e.msg)

# ---------------------------------------------------------------------
# Reading what is inside
# ---------------------------------------------------------------------

proc tpm2EvidenceQuote*(ev: Tpm2Evidence): Tpm2Quote =
  ## Decode the two signed structures. Framing is not structure: a
  ## composite whose members are the right length and the wrong bytes is
  ## refused here rather than accepted as well-formed.
  try:
    parseQuote(ev.attestBytes, ev.signatureBytes)
  except Tpm2CodecError as e:
    fail(Tpm2EvidenceSchema & ": the quote does not decode: " & e.msg)

proc tpm2EvidenceLog*(ev: Tpm2Evidence): TcgEventLog =
  ## Decode the event log member.
  try:
    parseEventLog(ev.eventLogBytes)
  except TcgEventLogError as e:
    fail(Tpm2EvidenceSchema & ": the event log does not decode: " & e.msg)

proc logExplainsQuote*(ev: Tpm2Evidence): bool =
  ## Whether replaying this composite's own log reproduces the PCR
  ## composite its own quote carries — the join the composite exists to
  ## make possible.
  ##
  ## It is not a verification and says nothing about the signature; see
  ## the module header and `event_log.explainsQuote`.
  let q = tpm2EvidenceQuote(ev)
  let log = tpm2EvidenceLog(ev)
  try:
    explainsQuote(log, q)
  except TcgEventLogError as e:
    fail(Tpm2EvidenceSchema & ": the log cannot answer for this quote: " &
         e.msg)

# ---------------------------------------------------------------------
# The source seam
# ---------------------------------------------------------------------

type
  Tpm2QuoteBytes* = object
    ## What a `TPM2_Quote` transaction hands back.
    attest*: string
    signature*: string

  Tpm2Source* = ref object of RootObj
    ## Where a `Tpm2Driver`'s three artifacts come from.
    ##
    ## Separate from the driver because the driver's job is the
    ## composite and the checks on it, and those are the same whether the
    ## quote arrives from a device transaction, from a resource manager,
    ## or from files a provisioning step wrote. Folding the transaction
    ## into the driver would make every check untestable without one.
    sourceLabel: string

proc initTpm2Source*(s: Tpm2Source; label: string) =
  if label.len == 0:
    raise newException(Tpm2EvidenceError,
      "a tpm2 source must label itself; the label is what an operator " &
      "reads when a machine will not attest")
  s.sourceLabel = label

proc label*(s: Tpm2Source): string = s.sourceLabel

method sourceProbe*(s: Tpm2Source): BackendReadiness {.base.} =
  raise newException(Tpm2EvidenceError,
    "tpm2 source " & s.label & " does not implement sourceProbe")

method sourceQuote*(s: Tpm2Source; reportData: string): Tpm2QuoteBytes
    {.base.} =
  ## The `TPM2_Quote` transaction, or the artifacts of one.
  ##
  ## `reportData` is passed so a live transaction can use it as
  ## `qualifyingData`. A source is not trusted to have done so — the
  ## driver checks the returned attest, which is the only place the
  ## answer can be checked against the question.
  raise newException(Tpm2EvidenceError,
    "tpm2 source " & s.label & " does not implement sourceQuote")

method sourceEventLog*(s: Tpm2Source): string {.base.} =
  raise newException(Tpm2EvidenceError,
    "tpm2 source " & s.label & " does not implement sourceEventLog")

method sourceCertificates*(s: Tpm2Source): seq[string] {.base.} =
  ## The AK certificate chain the instance holds, RAW DER per element,
  ## or an empty sequence when it holds none. The driver maps empty to
  ## the envelope's `none`, so "fetch your own collateral" and "here is a
  ## chain" stay two different answers.
  @[]

# ---------------------------------------------------------------------
# A source backed by artifacts a TPM already produced
# ---------------------------------------------------------------------

type
  CapturedTpm2Source* = ref object of Tpm2Source
    ## Reads the attest, the signature and the event log from three
    ## paths.
    ##
    ## This is the shape a machine is in after a provisioning step has
    ## taken a quote and the kernel has exposed
    ## `binary_bios_measurements`: three files, written by a TPM and by
    ## firmware, that the agent has only to read. It is not a stand-in
    ## for a device — nothing here synthesizes a byte, and a quote it
    ## returns that does not answer the question asked is refused by the
    ## driver exactly as a misbehaving device's would be.
    attestPath: string
    signaturePath: string
    eventLogPath: string
    certificatePaths: seq[string]

proc newCapturedTpm2Source*(attestPath, signaturePath, eventLogPath: string;
                            certificatePaths: seq[string] = @[]):
                           CapturedTpm2Source =
  result = CapturedTpm2Source(
    attestPath: attestPath,
    signaturePath: signaturePath,
    eventLogPath: eventLogPath,
    certificatePaths: certificatePaths)
  initTpm2Source(result, "captured:" & eventLogPath)

proc readArtifact(path, what: string): string =
  if not fileExists(path):
    raise newException(Tpm2EvidenceError,
      "tpm2 " & what & ": " & path & " does not exist")
  result = readFile(path)
  if result.len == 0:
    raise newException(Tpm2EvidenceError,
      "tpm2 " & what & ": " & path & " is empty")

method sourceProbe*(s: CapturedTpm2Source): BackendReadiness =
  ## Names what is missing rather than reporting that something is.
  ##
  ## An operator looking at a machine that will not attest needs the
  ## path, and a probe that answered "not ready" would send them looking
  ## for it. It reads no file's contents and takes no quote, so asking
  ## whether the machine can attest is not a way to consume its ability
  ## to.
  var absent: seq[string] = @[]
  for path in [s.attestPath, s.signaturePath, s.eventLogPath]:
    if not fileExists(path): absent.add path
  if absent.len == 0:
    BackendReadiness(ready: true,
      detail: "tpm2: quote at " & s.attestPath & ", signature at " &
        s.signaturePath & ", event log at " & s.eventLogPath)
  else:
    BackendReadiness(ready: false,
      detail: "tpm2: no " & absent.join(", no ") &
        "; this machine has no measured-boot evidence to offer")

method sourceQuote*(s: CapturedTpm2Source; reportData: string):
                   Tpm2QuoteBytes =
  Tpm2QuoteBytes(
    attest: readArtifact(s.attestPath, "attest"),
    signature: readArtifact(s.signaturePath, "signature"))

method sourceEventLog*(s: CapturedTpm2Source): string =
  readArtifact(s.eventLogPath, "event log")

method sourceCertificates*(s: CapturedTpm2Source): seq[string] =
  result = @[]
  for path in s.certificatePaths:
    result.add readArtifact(path, "certificate")

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

const
  DefaultQuotedPcrBank* = TpmAlgSha256
  DefaultQuotedPcrs* = [0, 1, 2, 3, 4, 5, 6, 7]
    ## The firmware-owned registers: the platform's own code and
    ## configuration, the option ROMs, the boot manager's code and its
    ## configuration, and the handoff to the OS loader. They are the set
    ## a quote taken before anything of this system's runs can speak
    ## for.

proc defaultQuotedSelection*(): TpmlPcrSelection =
  ## The selection a `Tpm2Driver` is configured with when it is not told
  ## otherwise.
  pcrSelection(DefaultQuotedPcrBank, DefaultQuotedPcrs)

type
  Tpm2Driver* = ref object of AttestationDriver
    ## The tpm2 arm of the backend seam.
    source: Tpm2Source
    selection: TpmlPcrSelection

proc newTpm2Driver*(source: Tpm2Source;
                    selection: TpmlPcrSelection = defaultQuotedSelection()):
                   Tpm2Driver =
  ## The selection is configuration and never a request field: a caller
  ## that could choose which registers are quoted could choose the ones
  ## that say nothing.
  if source.isNil:
    raise newException(DriverError,
      "a tpm2 driver needs a source; a driver with none would have " &
      "nothing to report and no way to say so")
  if selectedPcrs(selection).len == 0:
    raise newException(DriverError,
      "a tpm2 driver configured to quote no register would sign the " &
      "digest of the empty string, which is the same on every machine")
  result = Tpm2Driver(source: source, selection: selection)
  initAttestationDriver(result, abTpm2, Tpm2DriverName)

proc quotedSelection*(d: Tpm2Driver): TpmlPcrSelection =
  ## What this driver is configured to quote. Read by diagnostics and by
  ## whatever renders a machine's attestation capability.
  d.selection

method driverProbe*(d: Tpm2Driver): BackendReadiness =
  d.source.sourceProbe()

proc quoteImpl(d: Tpm2Driver; req: QuoteRequest): QuoteResult =
  let quoted = d.source.sourceQuote(req.reportData)
  let ev = Tpm2Evidence(
    attestBytes: quoted.attest,
    signatureBytes: quoted.signature,
    eventLogBytes: d.source.sourceEventLog())

  let q = tpm2EvidenceQuote(ev)

  if q.qualifyingData != req.reportData:
    raise newException(DriverError,
      "driver " & d.driverName & ": the quote binds " &
      bytesToHex(q.qualifyingData) & " and this request binds " &
      bytesToHex(req.reportData) &
      "; evidence that answers a different question is not an answer " &
      "to this one")

  let quotedRegisters = selectedPcrs(q.attest.quote.pcrSelect)
  let configured = selectedPcrs(d.selection)
  if quotedRegisters != configured:
    raise newException(DriverError,
      "driver " & d.driverName & ": the quote covers " &
      $quotedRegisters.len & " register(s) and this driver is " &
      "configured to quote " & $configured.len &
      "; a quote over a set nobody chose can be a quote over the " &
      "registers that say nothing")

  let log = tpm2EvidenceLog(ev)
  var explains = false
  try:
    explains = explainsQuote(log, q)
  except TcgEventLogError as e:
    raise newException(DriverError,
      "driver " & d.driverName & ": this machine's event log cannot " &
      "answer for its own quote: " & e.msg)
  if not explains:
    raise newException(DriverError,
      "driver " & d.driverName & ": replaying this machine's event log " &
      "does not reproduce the register digest its own quote carries, so " &
      "the log does not describe the boot the TPM attested to")

  let chain = d.source.sourceCertificates()
  result = QuoteResult(
    evidence: composeTpm2Evidence(ev),
    certificates: if chain.len == 0: none(seq[string]) else: some(chain))

method driverQuote*(d: Tpm2Driver; req: QuoteRequest): QuoteResult =
  ## Acquire, check, and compose.
  ##
  ## The checks are in `quoteImpl` rather than in the source because they
  ## are what the backend owes and not what any one acquisition path
  ## does: a driver that passed on whatever it was handed would ship
  ## evidence that fails at the verifier, on the verifier's network, with
  ## nothing said on the machine that produced it.
  ##
  ## EVERY refusal leaves here as a `DriverError` naming this driver.
  ## That is the seam's contract rather than a convenience: whoever reads
  ## the message is looking at a machine that would not attest, and an
  ## exception of the evidence codec's own type escaping the seam would
  ## be a refusal a caller catching `DriverError` does not catch — which
  ## is the difference between a machine that refuses and a machine that
  ## crashes.
  try:
    quoteImpl(d, req)
  except Tpm2EvidenceError as e:
    raise newException(DriverError, "driver " & d.driverName & ": " & e.msg)

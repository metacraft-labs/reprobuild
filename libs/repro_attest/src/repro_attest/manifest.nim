## The ``reproos.attested-image.v1`` measurement manifest.
##
## ## What the document is for
##
## An attested image is verified by comparing what a machine reports at
## runtime against what the build says that image must produce. This is
## the build's half of that comparison: for one image, the digests of its
## outputs and the launch measurements each hardware backend will report
## if it is really that image that booted.
##
## It is a GENERATED artifact and is never hand-edited. Everything in it
## is derived from image bytes, so two builds of the same inputs produce
## the same document byte for byte — which is what lets a verifier who
## rebuilds locally compare documents rather than reason about them.
##
## ## Why parsing is strict
##
## A measurement manifest is a security document. Every failure mode of a
## lenient parser is a way to believe something the build did not say:
##
##   * An **unknown top-level or nested field** is a document written by a
##     newer tool that means something this one cannot honour, so it is
##     refused rather than partly understood.
##   * An **unknown launch shape** — a backend key nobody here implements,
##     or a per-backend record carrying a field this schema does not
##     define — is refused for the same reason, and refused *at the
##     build*, so a document that cannot be verified is never published.
##   * A **self-inconsistent** document is refused: a TPM expectation
##     whose event-log template does not replay to its own ``pcr11`` is a
##     manifest disagreeing with itself, and there is no safe way to pick
##     which half to believe.
##
## Absent optional-looking fields are refused too. An attested image has a
## verity-protected root by construction, so a manifest that omits the
## verity outputs is not a weaker manifest, it is a manifest for something
## else.
##
## ## Mocking
##
## None.

import std/[json, strutils]

import ./measurement

type
  ManifestError* = object of CatchableError
    ## Raised for any document this module will not honour. The message
    ## names the offending key and what was expected, because the reader
    ## of this error is whoever has to fix the document.

  SevSnpExpectation* = object
    ## One enumerated SEV-SNP launch configuration and the ``MEASUREMENT``
    ## the AMD Secure Processor will report for it.
    vcpus*: int
    vcpuType*: string
    ovmf*: string
    policy*: string
    measurement*: string

  TdxExpectation* = object
    ## One TDX launch: the initial-memory measurement plus the runtime
    ## measurement registers a measured direct boot extends.
    mrtd*: string
    rtmr0*: string
    rtmr1*: string
    rtmr2*: string

  TpmExpectation* = object
    ## One TPM 2.0 measured-boot expectation.
    pcr11*: string
      ## The value PCR 11 holds once the stub has measured the image.
    eventLogTemplate*: string
      ## The ordered events that produce it, so a verifier can replay the
      ## value instead of trusting it. See
      ## ``measurement.renderEventLogTemplate``.

  ImageOutputs* = object
    ## The build outputs the measurements are taken over.
    uki*: string
      ## ``sha256:<hex>`` of the unified kernel image.
    verityImage*: string
      ## ``sha256:<hex>`` of the integrity-protected root image.
    verityRootHash*: string
      ## The dm-verity root hash, bare hex — the same string the image's
      ## measured command line pins.

  AttestedImageManifest* = object
    configFingerprint*: string
    imageOutputs*: ImageOutputs
    sevSnp*: seq[SevSnpExpectation]
    tdx*: seq[TdxExpectation]
    tpm*: seq[TpmExpectation]

const
  AttestedImageSchema* = "reproos.attested-image.v1"

  AttestedImageManifestFileName* = "reproos.attested-image.json"
    ## What the document is called when it rides an image build. Declared
    ## here, beside the schema, so the build that writes it and the
    ## verifier that looks for it cannot disagree about the name.

  BackendSevSnp* = "sev-snp"
  BackendTdx* = "tdx"
  BackendTpm* = "tpm"

  KnownBackends*: array[3, string] = [BackendSevSnp, BackendTdx, BackendTpm]
    ## The complete set of launch-measurement shapes this schema defines.
    ## A document naming any other backend is refused; a future backend is
    ## a schema version, not a new key in an old one.

  TopLevelKeys*: array[4, string] =
    ["schema", "configFingerprint", "imageOutputs", "expected"]
  ImageOutputKeys*: array[3, string] = ["uki", "verityImage", "verityRootHash"]
  SevSnpKeys*: array[5, string] =
    ["vcpus", "vcpuType", "ovmf", "policy", "measurement"]
  TdxKeys*: array[4, string] = ["mrtd", "rtmr0", "rtmr1", "rtmr2"]
  TpmKeys*: array[2, string] = ["pcr11", "eventLogTemplate"]

  DigestPrefix* = "sha256:"
  FingerprintMaxLen* = 256
  TemplateMaxLen* = 4096
    ## An event-log template carries one digest per measured section, so
    ## it is bounded by the stub's section table rather than by taste.

proc isLowerHex(s: string; want: int): bool =
  if want > 0 and s.len != want: return false
  if s.len == 0: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc isSafeToken(s: string; maxLen: int): bool =
  ## The character set every scalar in this document is confined to. The
  ## renderer writes JSON by hand so its bytes are stable across compiler
  ## versions; confining the values is what makes that safe, and it is
  ## checked on the way IN so no unrepresentable value can be stored.
  if s.len == 0 or s.len > maxLen: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'z', 'A' .. 'Z', '.', '_', '-', ':',
                '+', '/', '=', ';', ',', '@'}:
      return false
  true

proc requireDigest(where, value: string) =
  if not value.startsWith(DigestPrefix) or
     not isLowerHex(value[DigestPrefix.len .. ^1], 64):
    raise newException(ManifestError,
      where & " must be \"" & DigestPrefix &
      "<64 lower-case hex characters>\", got " & value.escapeJson())

proc requireHex(where, value: string; want: int) =
  if not isLowerHex(value, want):
    raise newException(ManifestError,
      where & " must be " & (if want > 0: $want & " " else: "") &
      "lower-case hex characters, got " & value.escapeJson())

proc requireToken(where, value: string; maxLen = FingerprintMaxLen) =
  if not isSafeToken(value, maxLen):
    raise newException(ManifestError,
      where & " must be a non-empty token of at most " & $maxLen &
      " characters from [0-9A-Za-z._:;,+/=@-], got " & value.escapeJson())

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

proc validateAttestedImageManifest*(m: AttestedImageManifest) =
  ## The single validator. The renderer runs it before it writes and the
  ## parser runs it after it reads, so a document cannot become valid by
  ## the route it travelled.
  requireToken("configFingerprint", m.configFingerprint)
  requireDigest("imageOutputs.uki", m.imageOutputs.uki)
  requireDigest("imageOutputs.verityImage", m.imageOutputs.verityImage)
  requireHex("imageOutputs.verityRootHash", m.imageOutputs.verityRootHash, 64)

  for i, e in m.sevSnp:
    let at = "expected." & BackendSevSnp & "[" & $i & "]"
    if e.vcpus <= 0 or e.vcpus > 1024:
      raise newException(ManifestError,
        at & ".vcpus must be between 1 and 1024, got " & $e.vcpus)
    requireToken(at & ".vcpuType", e.vcpuType)
    requireDigest(at & ".ovmf", e.ovmf)
    if not e.policy.startsWith("0x") or not isLowerHex(e.policy[2 .. ^1], 0):
      raise newException(ManifestError,
        at & ".policy must be \"0x<lower-case hex>\", got " &
        e.policy.escapeJson())
    requireHex(at & ".measurement", e.measurement, 96)

  for i, e in m.tdx:
    let at = "expected." & BackendTdx & "[" & $i & "]"
    requireHex(at & ".mrtd", e.mrtd, 96)
    requireHex(at & ".rtmr0", e.rtmr0, 96)
    requireHex(at & ".rtmr1", e.rtmr1, 96)
    requireHex(at & ".rtmr2", e.rtmr2, 96)

  for i, e in m.tpm:
    let at = "expected." & BackendTpm & "[" & $i & "]"
    requireHex(at & ".pcr11", e.pcr11, 64)
    requireToken(at & ".eventLogTemplate", e.eventLogTemplate, TemplateMaxLen)
    # The template is not decoration: it must produce the value beside it.
    var replayed = ""
    try:
      replayed = replayEventLogTemplate(e.eventLogTemplate)
    except MeasurementError as err:
      raise newException(ManifestError,
        at & ".eventLogTemplate is not replayable: " & err.msg)
    if replayed != e.pcr11:
      raise newException(ManifestError,
        at & ".eventLogTemplate replays to " & replayed &
        " but the entry claims pcr11 " & e.pcr11 &
        "; a manifest that disagrees with itself is refused")

# ---------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------

proc renderAttestedImageManifest*(m: AttestedImageManifest): string =
  ## The canonical bytes. Hand-rendered in a fixed key order with a fixed
  ## indent so two builds of the same image produce the same file — a
  ## document whose bytes move on their own cannot be compared, and
  ## comparison is the only thing it is for.
  validateAttestedImageManifest(m)
  proc q(s: string): string = "\"" & s & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(AttestedImageSchema) & ",\n"
  result.add "  \"configFingerprint\": " & q(m.configFingerprint) & ",\n"
  result.add "  \"imageOutputs\": {\n"
  result.add "    \"uki\": " & q(m.imageOutputs.uki) & ",\n"
  result.add "    \"verityImage\": " & q(m.imageOutputs.verityImage) & ",\n"
  result.add "    \"verityRootHash\": " & q(m.imageOutputs.verityRootHash) & "\n"
  result.add "  },\n"
  result.add "  \"expected\": {\n"

  result.add "    " & q(BackendSevSnp) & ": ["
  for i, e in m.sevSnp:
    result.add (if i == 0: "\n" else: ",\n")
    result.add "      {\n"
    result.add "        \"vcpus\": " & $e.vcpus & ",\n"
    result.add "        \"vcpuType\": " & q(e.vcpuType) & ",\n"
    result.add "        \"ovmf\": " & q(e.ovmf) & ",\n"
    result.add "        \"policy\": " & q(e.policy) & ",\n"
    result.add "        \"measurement\": " & q(e.measurement) & "\n"
    result.add "      }"
  result.add (if m.sevSnp.len > 0: "\n    ],\n" else: "],\n")

  result.add "    " & q(BackendTdx) & ": ["
  for i, e in m.tdx:
    result.add (if i == 0: "\n" else: ",\n")
    result.add "      {\n"
    result.add "        \"mrtd\": " & q(e.mrtd) & ",\n"
    result.add "        \"rtmr0\": " & q(e.rtmr0) & ",\n"
    result.add "        \"rtmr1\": " & q(e.rtmr1) & ",\n"
    result.add "        \"rtmr2\": " & q(e.rtmr2) & "\n"
    result.add "      }"
  result.add (if m.tdx.len > 0: "\n    ],\n" else: "],\n")

  result.add "    " & q(BackendTpm) & ": ["
  for i, e in m.tpm:
    result.add (if i == 0: "\n" else: ",\n")
    result.add "      {\n"
    result.add "        \"pcr11\": " & q(e.pcr11) & ",\n"
    result.add "        \"eventLogTemplate\": " & q(e.eventLogTemplate) & "\n"
    result.add "      }"
  result.add (if m.tpm.len > 0: "\n    ]\n" else: "]\n")

  result.add "  }\n"
  result.add "}\n"

# ---------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------

proc requireObject(node: JsonNode; where: string): JsonNode =
  if node.kind != JObject:
    raise newException(ManifestError, where & " must be a JSON object")
  node

proc requireKeys(node: JsonNode; where: string; allowed: openArray[string]) =
  for key in node.keys:
    if key notin allowed:
      raise newException(ManifestError,
        where & " carries the unknown field " & key.escapeJson() &
        "; this build understands " & allowed.join(", ") &
        " and refuses a document it cannot fully honour")
  for key in allowed:
    if not node.hasKey(key):
      raise newException(ManifestError,
        where & " is missing the required field " & key.escapeJson())

proc str(node: JsonNode; where, key: string): string =
  let v = node[key]
  if v.kind != JString:
    raise newException(ManifestError,
      where & "." & key & " must be a string")
  v.getStr

proc parseAttestedImageManifest*(text, source: string): AttestedImageManifest =
  ## Parse and fully validate a manifest. ``source`` names the document in
  ## every error message, because these errors are read by whoever has to
  ## regenerate it.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    raise newException(ManifestError, source & ": not JSON: " & err.msg)
  discard requireObject(doc, source)
  requireKeys(doc, source, TopLevelKeys)

  let schema = str(doc, source, "schema")
  if schema != AttestedImageSchema:
    raise newException(ManifestError,
      source & ": schema is " & schema.escapeJson() & "; this build " &
      "understands " & AttestedImageSchema.escapeJson() & " and refuses " &
      "a document it cannot fully honour")

  result.configFingerprint = str(doc, source, "configFingerprint")

  let outputs = requireObject(doc["imageOutputs"], source & ".imageOutputs")
  requireKeys(outputs, source & ".imageOutputs", ImageOutputKeys)
  result.imageOutputs = ImageOutputs(
    uki: str(outputs, source & ".imageOutputs", "uki"),
    verityImage: str(outputs, source & ".imageOutputs", "verityImage"),
    verityRootHash: str(outputs, source & ".imageOutputs", "verityRootHash"))

  let expected = requireObject(doc["expected"], source & ".expected")
  requireKeys(expected, source & ".expected", KnownBackends)
  for backend in KnownBackends:
    if expected[backend].kind != JArray:
      raise newException(ManifestError,
        source & ".expected." & backend & " must be an array of launch " &
        "shapes, even when it is empty")

  for i, entry in expected[BackendSevSnp].elems:
    let at = source & ".expected." & BackendSevSnp & "[" & $i & "]"
    discard requireObject(entry, at)
    requireKeys(entry, at, SevSnpKeys)
    if entry["vcpus"].kind != JInt:
      raise newException(ManifestError, at & ".vcpus must be an integer")
    result.sevSnp.add SevSnpExpectation(
      vcpus: entry["vcpus"].getInt,
      vcpuType: str(entry, at, "vcpuType"),
      ovmf: str(entry, at, "ovmf"),
      policy: str(entry, at, "policy"),
      measurement: str(entry, at, "measurement"))

  for i, entry in expected[BackendTdx].elems:
    let at = source & ".expected." & BackendTdx & "[" & $i & "]"
    discard requireObject(entry, at)
    requireKeys(entry, at, TdxKeys)
    result.tdx.add TdxExpectation(
      mrtd: str(entry, at, "mrtd"),
      rtmr0: str(entry, at, "rtmr0"),
      rtmr1: str(entry, at, "rtmr1"),
      rtmr2: str(entry, at, "rtmr2"))

  for i, entry in expected[BackendTpm].elems:
    let at = source & ".expected." & BackendTpm & "[" & $i & "]"
    discard requireObject(entry, at)
    requireKeys(entry, at, TpmKeys)
    result.tpm.add TpmExpectation(
      pcr11: str(entry, at, "pcr11"),
      eventLogTemplate: str(entry, at, "eventLogTemplate"))

  try:
    validateAttestedImageManifest(result)
  except ManifestError as err:
    raise newException(ManifestError, source & ": " & err.msg)

# ---------------------------------------------------------------------
# Construction from image bytes
# ---------------------------------------------------------------------

proc tpmExpectationFor*(ukiImage: string): TpmExpectation =
  ## The TPM-tier expectation for one unified kernel image, derived from
  ## the image's own bytes and nothing else.
  let m = measureUkiPcr11(ukiImage)
  TpmExpectation(pcr11: m.pcr11, eventLogTemplate: renderEventLogTemplate(m))

proc attestedImageManifest*(configFingerprint, ukiImage, verityImageDigest,
                            verityRootHash: string;
                            backends: openArray[string] = KnownBackends
                            ): AttestedImageManifest =
  ## Build the manifest for one attested image.
  ##
  ## ``backends`` enumerates the launch shapes to compute. A name outside
  ## ``KnownBackends`` is refused HERE — at the build — so an image is
  ## never published with an expectation nothing can verify. Backends
  ## whose calculators do not exist yet contribute an empty array, which
  ## says "this build computed no expectation for you" rather than
  ## silently omitting the key.
  for b in backends:
    if b notin KnownBackends:
      raise newException(ManifestError,
        "unknown launch measurement backend " & b.escapeJson() &
        "; this build computes " & KnownBackends.join(", ") &
        " and refuses to emit an expectation it cannot name")
  result.configFingerprint = configFingerprint
  result.imageOutputs = ImageOutputs(
    uki: DigestPrefix & sha256Hex(ukiImage),
    verityImage: verityImageDigest,
    verityRootHash: verityRootHash)
  if BackendTpm in backends:
    result.tpm = @[tpmExpectationFor(ukiImage)]
  # sev-snp and tdx launch-digest precomputation is not implemented; the
  # arrays stay empty and say so, rather than carrying a placeholder a
  # verifier could mistake for a computed value.
  validateAttestedImageManifest(result)

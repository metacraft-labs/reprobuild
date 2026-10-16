## The fixture corpus has a lifecycle, and this gate is where it is
## enforced.
##
## ## What this is for
##
## Sixty-seven pinned artifacts underpin every attestation gate in this
## repository. Roughly a third of them are dated documents a vendor
## reissues on its own schedule — revocation lists and
## trusted-computing-base documents — and they go stale whether or not
## anybody is watching. Before this gate the corpus had rich prose about
## where every byte came from and no machine-readable record of anything,
## so the first notice of a stale document was an unrelated gate failing
## on a morning nobody chose, naming a report rather than the collateral.
##
## Five properties, and each has its own suite because each fails for a
## different reason and wants a different response.
##
## 1. **The ledger describes the bytes.** Every recorded length and
##    digest is re-derived from the constant, never read back from the
##    table that records it.
## 2. **Every date is read out of the artifact.** The recorded window is
##    re-derived from the artifact's own DER or JSON through the
##    readers the verifier itself uses. A date in the table is a record,
##    not a source, and the two are compared so they cannot drift.
## 3. **The ledger and the census are complete**, in both directions,
##    against a directory scan and against the constants the corpus
##    modules declare. This is the check that stops a corpus growing a
##    member nothing tracks.
## 4. **Pinned clocks agree with the material they judge.** Five gates
##    state their own `Now`. Each must fall inside the validity window
##    of the collateral it evaluates, or that gate is testing nothing —
##    and this is the concrete failure a refresh causes: a revocation
##    list reissued next month has a `thisUpdate` AFTER those clocks,
##    and the chain evaluators set a list that is not yet in force
##    aside, so three gates would start reporting "no revocation data"
##    with nothing in their own diffs to explain it.
## 5. **Nothing here is a secret.** Every one of these artifacts was
##    either captured from a machine by a script that handles real key
##    material or fetched from a publisher, and this is a public
##    repository: a corpus that picked up a private key would publish
##    it irreversibly. The scan that says so has a POSITIVE control, so
##    it is a scan and not a loop over strings that occur in nothing.
## 6. **The lifecycle decision itself** — `repro_attest_verify/lifecycle`
##    — at its boundaries, both directions, with the refusal it makes
##    when asked to build an instruction with no remedy.
##
## ## The two clocks
##
## Everything here judges the corpus at a PINNED instant. That is not a
## convenience: a case that judged it at the wall clock would change its
## answer daily and would eventually fail for a reason that is not a
## defect, which is how a gate gets turned off. Noticing the calendar is
## the scheduled monitor's job, and the monitor uses the wall clock for
## exactly that reason.
##
## ## Mocking
##
## None. Real pinned bytes, real DER and JSON readers, real dates.

import std/[algorithm, os, sequtils, strutils, tables, times, unittest]

import nimcrypto/[hash, sha2]

import repro_attest_verify/lifecycle
import repro_attest_verify/snp_chain
import repro_attest_verify/x509

include ./attestation_fixture_ledger

const
  ExpectedLedgerRows = 67
  ExpectedPublisherRows = 18
  ExpectedCensusRows = 28

  UnledgeredCorpus = "tcg_event_log_vectors.nim"
    ## A corpus module the LEDGER says nothing about, used as the
    ## discriminator that makes the scan a scan. Named as a constant so
    ## the row that points it at a ledgered module instead is one
    ## visible edit.

  Day = 86_400'i64
    ## Spelled out rather than imported: `lifecycle` keeps its own
    ## seconds-per-day PRIVATE so it does not collide with `snp_tcb`'s
    ## through the umbrella re-export.

type
  PinnedClockGate = object
    ## A gate that states its own `Now`, and the ledger rows that clock
    ## has to sit inside.
    source: string
    now: int64
    mustBeCurrent: seq[string]

const
  PinnedClockGates: array[6, PinnedClockGate] = [
    PinnedClockGate(
      source: "t_snp_fixture_verify.nim", now: 1_788_220_800'i64,
      mustBeCurrent: @["KdsMilanCrlDerHex", "KdsGenoaCrlDerHex",
                       "KdsTurinCrlDerHex", "VirteeMilanVcekDerHex",
                       "GsgMilanVcekDerHex", "VirteeTurinVcekDerHex"]),
    PinnedClockGate(
      source: "t_snp_chain_requires_amd_root.nim", now: 1_788_220_800'i64,
      mustBeCurrent: @["KdsMilanCrlDerHex", "KdsGenoaCrlDerHex",
                       "KdsTurinCrlDerHex", "VirteeMilanVcekDerHex",
                       "GsgMilanVcekDerHex", "VirteeTurinVcekDerHex"]),
    PinnedClockGate(
      source: "t_snp_tcb_policy.nim", now: 1_788_220_800'i64,
      mustBeCurrent: @["KdsMilanCrlDerHex", "VirteeMilanVcekDerHex"]),
    PinnedClockGate(
      source: "t_tdx_chain_requires_intel_root.nim", now: 1_790_294_400'i64,
      mustBeCurrent: @["PcsPckCrlPlatformDerHex", "IntelRootCrlDerHex",
                       "IntelTcbSigningCertDerHex"]),
    PinnedClockGate(
      source: "t_tdx_collateral_and_verifier_arm.nim", now: 1_790_294_400'i64,
      mustBeCurrent: @["PcsTcbInfoSprJson", "PcsTcbInfoEmrJson",
                       "PcsTdxQeIdentityJson", "PcsSgxQeIdentityJson",
                       "PcsSgxTcbInfoJson", "PcsPckCrlPlatformDerHex",
                       "IntelTcbSigningCertDerHex"]),
    PinnedClockGate(
      # FOUND BY REVIEW. This gate states its clock as `const Now = …`
      # on ONE line, and the scan below read only a line that BEGINS
      # `Now = `, so it was invisible to the completeness check and had
      # no row — a sixth pinned clock judging the same revocation list
      # the other three do, and the one refreshing that list will break
      # without the ledger naming it. The scan now reads both spellings.
      source: "t_snp_evidence_reaches_the_verdict.nim",
      now: 1_789_000_000'i64,
      mustBeCurrent: @["KdsMilanCrlDerHex", "VirteeMilanVcekDerHex",
                       "GsgMilanVcekDerHex"])]

proc sha256Hex(s: string): string =
  let d = sha256.digest(s)
  for i in 0 ..< 32: result.add toHex(int(d.data[i]), 2).toLowerAscii

proc iso(t: int64): string = utc(fromUnix(t)).format(IsoInstantFormat)

proc amdCertWindow(der: string): LifecycleWindow =
  var b = newSeq[byte](der.len)
  for i in 0 ..< der.len: b[i] = byte(der[i])
  let c = parseAmdCertificate(b)
  window(c.notBefore, c.notAfter)

proc amdCrlWindow(der: string): LifecycleWindow =
  var b = newSeq[byte](der.len)
  for i in 0 ..< der.len: b[i] = byte(der[i])
  let c = parseAmdCrl(b)
  if c.hasNextUpdate: window(c.thisUpdate, c.nextUpdate)
  else: windowEndingNever(c.thisUpdate)

proc jsonMember(js, key: string): string =
  let k = "\"" & key & "\":\""
  let i = js.find(k)
  doAssert i >= 0, "no " & key & " member"
  let j = js.find('"', i + k.len)
  js[i + k.len ..< j]

proc windowOfRow(row: LedgerRow): LifecycleWindow =
  ## The window an artifact states, read out of the artifact.
  ##
  ## Exhaustive over the `window` column by refusing anything else: a
  ## row whose reader this procedure does not know about fails rather
  ## than returning a window with no dates in it, which would have
  ## classified as `lsNoStatedEnd` and looked like a finding.
  let raw = bytesOf(row.name)
  case row.window
  of "amd-certificate": amdCertWindow(raw)
  of "amd-revocation-list": amdCrlWindow(raw)
  of "x509-certificate": windowOfCertificate(raw)
  of "x509-revocation-list": windowOfRevocationList(raw)
  of "tcb-document":
    windowOfIssueAndNextUpdate(jsonMember(raw, "issueDate"),
                               jsonMember(raw, "nextUpdate"))
  else:
    raise newException(ValueError,
      row.name & " names the reader " & row.window.escape() &
      " and this gate has none")

proc hasWindow(row: LedgerRow): bool =
  row.window notin ["none", "unreadable"]

proc rowNamed(name: string): LedgerRow =
  for r in ledgerRows():
    if r.name == name: return r
  raise newException(ValueError, "no ledger row named " & name)

proc constantsDeclaredBy(module: string): seq[string] =
  ## Every top-level constant a corpus module declares, by a scan of its
  ## own source.
  ##
  ## A scan rather than a list, because a list of the members of a list
  ## is the defeat shape this gate exists to avoid one instance of. The
  ## rule is the house's own layout: two spaces, a capitalised
  ## identifier, an optional export marker, then `=`. Type declarations
  ## match it too and are excluded by what follows the `=`.
  for raw in readFile(integrationDir() / module).splitLines():
    if not raw.startsWith("  ") or raw.startsWith("   "): continue
    let body = raw[2 .. ^1]
    if body.len == 0 or body[0] notin {'A' .. 'Z'}: continue
    let eq = body.find('=')
    if eq < 1 or body[eq - 1] != ' ': continue
    let name = body[0 ..< eq].strip()
    var bare = name
    if bare.endsWith("*"): bare = bare[0 .. ^2]
    if not bare.allCharsInSet({'A' .. 'Z', 'a' .. 'z', '0' .. '9'}): continue
    let rhs = body[eq + 1 .. ^1].strip()
    if rhs.startsWith("object") or rhs.startsWith("enum") or
       rhs.startsWith("ref object"): continue
    result.add bare

proc corpusFilesInThisDirectory(): seq[string] =
  ## Every file in this directory carrying pinned bytes, by the three
  ## rules the census records.
  let dir = integrationDir()
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let base = path.extractFilename
    if not base.endsWith(".nim"): continue
    if base.endsWith("_vectors.nim") or base.endsWith("_corpus.nim"):
      result.add base
      continue
    var run = 0
    var longest = 0
    for raw in readFile(path).splitLines():
      let line = raw.strip()
      var hex = line
      if hex.startsWith("\""): hex = hex[1 .. ^1]
      var digits = 0
      for c in hex:
        if c in HexDigits and c notin {'A' .. 'F'}: inc digits
        else: break
      if digits >= 60:
        inc run
        if run > longest: longest = run
      else:
        run = 0
    if longest >= 12: result.add base
  for sub in ["fixtures", "fixtures/tdx"]:
    let d = dir / sub
    if not dirExists(d): continue
    for kind, path in walkDir(d):
      if kind == pcFile: result.add sub & "/" & path.extractFilename
  result.sort()

# ---------------------------------------------------------------------

suite "the ledger describes the bytes":

  test "every recorded length and digest is what the constant holds":
    var rows = 0
    for row in ledgerRows():
      checkpoint(row.name)
      let raw = bytesOf(row.name)
      check raw.len == row.bytes
      check sha256Hex(raw) == row.sha256
      inc rows
    check rows == ExpectedLedgerRows

  test "the rows are distinct artifacts, not one artifact many times":
    # Without this a table of sixty-seven rows over one constant would
    # satisfy every check above.
    var digests: seq[string] = @[]
    for row in ledgerRows(): digests.add row.sha256
    check digests.deduplicate.len == ExpectedLedgerRows
    var names: seq[string] = @[]
    for row in ledgerRows(): names.add row.name
    check names.deduplicate.len == ExpectedLedgerRows

  test "a digest is the artifact's, not this gate's idea of an empty one":
    # `sha256Hex("")` is a fixed 64-character string, so a `bytesOf`
    # that returned nothing for every row would produce a table of
    # sixty-seven identical digests and the case above would already
    # catch it. This is the same statement made directly, because the
    # indirect version is one refactor away from not holding.
    let ofNothing = sha256Hex("")
    for row in ledgerRows():
      check row.sha256 != ofNothing
      check row.bytes > 0

suite "every date is read out of the artifact, not out of the table":

  test "every recorded window is re-derived from the artifact's own bytes":
    var checked = 0
    for row in ledgerRows():
      if not hasWindow(row): continue
      checkpoint(row.name & " (" & row.window & ")")
      let w = windowOfRow(row)
      check w.hasNotBefore
      check iso(w.notBefore) == row.notBefore
      if w.hasNotAfter:
        check iso(w.notAfter) == row.notAfter
      else:
        check row.notAfter == "-"
      inc checked
    check checked == 35

  test "the windowed rows span all five readers, and each is used":
    var byReader = initCountTable[string]()
    for row in ledgerRows(): byReader.inc row.window
    check byReader["amd-certificate"] == 6
    check byReader["amd-revocation-list"] == 3
    check byReader["x509-certificate"] == 14
    check byReader["x509-revocation-list"] == 4
    check byReader["tcb-document"] == 8
    check byReader["none"] == 31
    check byReader["unreadable"] == 1
    check byReader.len == 7

  test "a row recorded as having no stated end really has none":
    # One pinned revocation list carries no `nextUpdate`, on purpose,
    # and it is the input the evaluators' set-aside rule needs. If the
    # reader started returning an end for it the negative would go
    # quiet, so the absence is asserted rather than assumed.
    let row = rowNamed("PcsPckCrlPlatformWithoutNextUpdateDerHex")
    let w = windowOfRow(row)
    check not w.hasNotAfter
    check classify(w, LedgerReferenceInstant) == lsNoStatedEnd
    check not isUsable(lsNoStatedEnd)
    # And its sibling, which differs only by carrying the field, does.
    let sib = windowOfRow(rowNamed("PcsPckCrlPlatformDerHex"))
    check sib.hasNotAfter
    check sib.notBefore == w.notBefore

  test "the unreadable row is unreadable AT THE RULE it names":
    # A pinned trust root this build's certificate reader refuses,
    # because it is signed with an algorithm the reader deliberately
    # does not implement. Recorded as unreadable rather than given a
    # date nobody derived — and the refusal is checked at its own rule,
    # so "unreadable" cannot come to mean "malformed" without a case
    # noticing.
    let row = rowNamed("NitroRootG1DerHex")
    check row.window == "unreadable"
    check row.notBefore == "-"
    check row.notAfter == "-"
    var refused = ""
    try:
      discard windowOfCertificate(bytesOf(row.name))
    except X509Error as err:
      refused = err.msg
    check "the signature algorithm is 1.2.840.10045.4.3.3" in refused
    check "ecdsa-with-SHA256" in refused
    # The same reader accepts a root it CAN read, so the refusal is
    # about this certificate and not about the reader being broken.
    check windowOfCertificate(bytesOf("IntelSgxRootCaDerHex")).hasNotAfter

suite "the ledger and the census are complete":

  test "every corpus file in this directory has a census row":
    let found = corpusFilesInThisDirectory()
    var recorded: seq[string] = @[]
    for row in censusRows(): recorded.add row.path
    check found.len == 27
    for path in found:
      checkpoint(path)
      check path in recorded
    for row in censusRows():
      checkpoint(row.path)
      check fileExists(integrationDir() / row.path)
    check censusRows().len == ExpectedCensusRows

  test "the census separates stable material from refreshed material":
    var byKind = initCountTable[string]()
    for row in censusRows(): byKind.inc row.kind
    check byKind["stable-protocol"] == 5
    check byKind["mixed"] == 4
    check byKind["local-capture"] == 6
    check byKind["refreshed-collateral"] == 3
    check byKind["genuine-capture"] == 3
    check byKind["no-corpus"] == 4
    check byKind["not-attestation"] == 3
    # Every row states a refresh route, and `never` is stated rather
    # than left blank: "this cannot go stale" is a claim somebody made,
    # not an absence of one.
    for row in censusRows():
      checkpoint(row.path)
      check row.refresh.len > 0
      check row.note.len > 0
      if row.kind == "stable-protocol":
        check row.refresh in ["never", "-"]
    for row in censusRows():
      if row.kind == "mixed": check row.refresh == "see-ledger"

  test "every constant the three corpus modules declare has a ledger row":
    var ledgerNames: seq[string] = @[]
    for row in ledgerRows(): ledgerNames.add row.name
    var declared = 0
    for module in ["snp_vectors.nim", "tdx_vectors.nim", "nitro_vectors.nim"]:
      for name in constantsDeclaredBy(module):
        checkpoint(module & " declares " & name)
        check name in ledgerNames
        inc declared
    check declared == 62
    # And the other direction: no row invents a constant.
    var fromModules = 0
    for row in ledgerRows():
      if row.name.startsWith("fixtures/"): continue
      checkpoint(row.name)
      check row.name in constantsDeclaredBy(row.module)
      inc fromModules
    check fromModules == 62

  test "the source scan really reads the modules, and is not a constant":
    # Three per-module counts are necessary and — MEASURED, not assumed
    # — not sufficient. A procedure that answered out of the LEDGER
    # instead of out of the source returns exactly these three lists,
    # because the ledger is complete over these three modules by
    # construction; that mutation was executed and this case was green
    # under it before the discriminator below was added.
    let snp = constantsDeclaredBy("snp_vectors.nim")
    let tdx = constantsDeclaredBy("tdx_vectors.nim")
    let nitro = constantsDeclaredBy("nitro_vectors.nim")
    check snp.len == 16
    check tdx.len == 31
    check nitro.len == 15
    check "KdsMilanChainPem" in snp
    check "KdsMilanChainPem" notin tdx
    # The `object` exclusion is load-bearing: `tdx_vectors` declares a
    # type in the same shape as a constant, and it is not an artifact.
    check "TdxFixtureDigest" notin tdx
    # THE DISCRIMINATOR: a corpus module the ledger says nothing about.
    # It is in the census — it is a local capture, not vendor material —
    # so nothing in the ledger names any of its constants. A procedure
    # answering out of the ledger returns an empty list for it; a
    # procedure that reads the source returns the twelve it declares.
    let unledgered = constantsDeclaredBy(UnledgeredCorpus)
    check unledgered.len == 12
    check "AgileLogHex" in unledgered
    var ledgerNames: seq[string] = @[]
    for row in ledgerRows(): ledgerNames.add row.name
    for name in unledgered:
      checkpoint(name)
      check name notin ledgerNames

  test "every publisher is used and every publisher states a remedy":
    var used = initCountTable[string]()
    for row in ledgerRows(): used.inc row.publisher
    var ids: seq[string] = @[]
    for p in publisherRows():
      checkpoint(p.id)
      ids.add p.id
      check p.what.len > 0
      # The remedy is the whole deliverable of that table. An empty one
      # is what `refreshInstruction` refuses to build a message from.
      check p.refreshWith.len > 20
      check used[p.id] > 0
    check ids.len == ExpectedPublisherRows
    check ids.deduplicate.len == ExpectedPublisherRows
    for row in ledgerRows():
      checkpoint(row.name)
      check row.publisher in ids

  test "material served live carries an observation date and minted material does not":
    var live = 0
    for row in ledgerRows():
      checkpoint(row.name)
      if row.publisher == "this-repository":
        # It has no upstream, so there is nothing an observation date
        # would be an observation OF.
        check row.observed == "-"
        check row.class in ["minted-negative", "derived-reading"]
      if row.observed != "-":
        check row.observed.len == 10
        check row.observed.startsWith("202")
        inc live
    check live == 22

suite "pinned clocks agree with the material they judge":

  test "every gate that states its own clock has a row here":
    # The defeating mutation this guards against is a sixth gate
    # pinning a clock that nothing relates to the corpus. The scan is
    # over the sources, so adding one without a row is red.
    var found: seq[string] = @[]
    for kind, path in walkDir(integrationDir()):
      if kind != pcFile: continue
      let base = path.extractFilename
      if not base.startsWith("t_") or not base.endsWith(".nim"): continue
      for raw in readFile(path).splitLines():
        var line = raw.strip()
        # BOTH spellings. A one-line `const Now = …` is the same
        # declaration as a `const` block with `Now = …` under it, and
        # reading only the second missed a real gate — see the row
        # added above, and the case that now pins both forms.
        if line.startsWith("const "): line = line[6 .. ^1].strip()
        if line.startsWith("Now = ") or line.startsWith("Now* = "):
          if base notin found: found.add base
    found.sort()
    var recorded: seq[string] = @[]
    for g in PinnedClockGates: recorded.add g.source
    recorded.sort()
    check found == recorded
    check found.len == 6

  test "each pinned clock falls inside the window of what it judges":
    var pairs = 0
    for g in PinnedClockGates:
      check g.mustBeCurrent.len > 0
      for name in g.mustBeCurrent:
        checkpoint(g.source & " at " & iso(g.now) & " judges " & name)
        let row = rowNamed(name)
        check hasWindow(row)
        let w = windowOfRow(row)
        let status = classify(w, g.now)
        check isUsable(status)
        check g.now >= w.notBefore
        check g.now < w.notAfter
        inc pairs
    check pairs == 27

  test "the scan reads BOTH spellings a gate can declare its clock in":
    # The repair above, with its own case. Without this the scan could
    # be narrowed back to the indented form and the case above would
    # still be green, because the table would have been narrowed in the
    # same edit. Here the TREE is the authority: both forms occur in
    # it, so a scan that handles one of them cannot find six gates.
    var oneLine, inBlock = 0
    for g in PinnedClockGates:
      for raw in readFile(integrationDir() / g.source).splitLines():
        let line = raw.strip()
        if line.startsWith("const Now = "): inc oneLine
        elif line.startsWith("Now = "): inc inBlock
    check oneLine == 1
    check inBlock == 5
    check oneLine + inBlock == PinnedClockGates.len

  test "the pinned clocks really are the ones the sources state":
    # Transcribed constants, so the transcription is checked. Otherwise
    # the case above would prove that some number sits inside a window.
    for g in PinnedClockGates:
      checkpoint(g.source)
      let text = readFile(integrationDir() / g.source)
      var spelled = ""
      for c in $g.now:
        spelled.add c
      # The sources write the constant with underscore separators.
      var grouped = ""
      var digits = spelled
      while digits.len > 3:
        grouped = "_" & digits[digits.len - 3 .. ^1] & grouped
        digits = digits[0 ..< digits.len - 3]
      grouped = digits & grouped
      check ("Now = " & grouped & "'i64") in text

  test "a clock outside its material's window is NOT usable":
    # The complement, so "isUsable" is not a function that returns true.
    let row = rowNamed("KdsMilanCrlDerHex")
    let w = windowOfRow(row)
    check classify(w, w.notAfter) == lsExpired
    check not isUsable(classify(w, w.notAfter))
    check classify(w, w.notBefore - 1) == lsNotYetInForce
    check not isUsable(classify(w, w.notBefore - 1))
    # And this is the refresh hazard the runbook names: a reissued list
    # begins later than the clocks that judge it.
    for g in PinnedClockGates:
      if "KdsMilanCrlDerHex" notin g.mustBeCurrent: continue
      check classify(window(w.notBefore + 60 * Day, w.notAfter + 60 * Day),
                     g.now) == lsNotYetInForce

suite "the corpus as it stands, at a pinned instant":

  test "the pinned instant is the one the constant names":
    check iso(LedgerReferenceInstant) == "2026-09-29T00:00:00Z"

  test "the three vendor revocation lists are due for refresh, not expired":
    # The state this whole gate exists to make visible: still usable,
    # and days from not being.
    var due = 0
    for name in ["KdsMilanCrlDerHex", "KdsGenoaCrlDerHex",
                 "KdsTurinCrlDerHex"]:
      checkpoint(name)
      let w = windowOfRow(rowNamed(name))
      check classify(w, LedgerReferenceInstant) == lsDueForRefresh
      check isUsable(classify(w, LedgerReferenceInstant))
      check w.notAfter - LedgerReferenceInstant < 7 * Day
      inc due
    check due == 3

  test "three collateral documents have already expired":
    var expired = 0
    for row in ledgerRows():
      if not hasWindow(row): continue
      if classify(windowOfRow(row), LedgerReferenceInstant) == lsExpired:
        checkpoint(row.name & " expired " & row.notAfter)
        check row.class == "vendor-collateral"
        inc expired
    check expired == 3

  test "the whole corpus partitions across the statuses":
    var byStatus = initCountTable[LifecycleStatus]()
    for row in ledgerRows():
      if not hasWindow(row): continue
      byStatus.inc classify(windowOfRow(row), LedgerReferenceInstant)
    check byStatus[lsExpired] == 3
    check byStatus[lsDueForRefresh] == 10
    check byStatus[lsCurrent] == 21
    check byStatus[lsNoStatedEnd] == 1
    check byStatus[lsNotYetInForce] == 0
    var total = 0
    for _, n in byStatus: total += n
    check total == 35
    # Needing attention is the complement of being current, and the two
    # are asserted as a partition rather than as two counts that happen
    # to add up.
    var attention = 0
    for status, n in byStatus:
      if needsAttention(status): attention += n
      else: check status == lsCurrent
    check attention == 35 - byStatus[lsCurrent]

  test "no stable-protocol or minted artifact is in the expiring set":
    # The separation, asserted rather than described: the material that
    # goes stale is exactly the material a vendor reissues.
    for row in ledgerRows():
      if not hasWindow(row): continue
      let status = classify(windowOfRow(row), LedgerReferenceInstant)
      if status in {lsExpired, lsDueForRefresh}:
        checkpoint(row.name)
        check row.class == "vendor-collateral"
      if row.class in ["protocol-vector", "derived-reading"]:
        check not hasWindow(row)

const
  SecretMarkers = ["PRIVATE KEY", "BEGIN RSA PRIVATE", "BEGIN EC PRIVATE",
                   "BEGIN OPENSSH PRIVATE", "BEGIN PGP PRIVATE",
                   "BEGIN DSA PRIVATE"]
    ## The armouring every common private-key encoding opens with. A
    ## key stored in raw DER carries no such marker and this scan would
    ## not see it — stated here rather than left for a reader to assume
    ## otherwise, and it is not the gap it looks like: every capture
    ## script in this tree writes keys in the armoured form, which is
    ## exactly what a copy-paste accident would carry across.

  PublicMarkerRows = 10
    ## How many artifacts carry the public marker. Measured, not
    ## guessed: four PEM chains and six documents whose certification
    ## data carries a chain of its own. Pinned as a NUMBER so a scan
    ## that found only the obvious four would be red.

  PublicMarker = "BEGIN CERTIFICATE"
    ## The positive control. A certificate is public by definition and
    ## the corpus is full of them, so a scan that reports zero for this
    ## is a scan that is not reading the bytes.

proc rowsContaining(marker: string): seq[string] =
  for row in ledgerRows():
    if marker in bytesOf(row.name): result.add row.name

suite "sanitization: nothing in this corpus is a secret":

  test "the scan reads the artifacts, proved on something that IS there":
    # Without this the case below is a loop over six strings that occur
    # in nothing, which is satisfied by a procedure that never opens a
    # file. The same procedure, the same corpus, a marker whose count
    # is MEASURED rather than hoped.
    let public = rowsContaining(PublicMarker)
    check public.len == PublicMarkerRows
    check "KdsMilanChainPem" in public

  test "no pinned artifact carries private key material":
    for marker in SecretMarkers:
      checkpoint(marker)
      check rowsContaining(marker).len == 0

  test "and neither does any corpus module's own source text":
    # The artifacts above are DECODED bytes. A key pasted into a header
    # comment appears in none of them, and it would still be published.
    var scanned = 0
    for row in censusRows():
      if row.kind == "not-attestation": continue
      let text = readFile(integrationDir() / row.path)
      checkpoint(row.path)
      check text.len > 0
      for marker in SecretMarkers: check marker notin text
      inc scanned
    check scanned == ExpectedCensusRows - 3

suite "the lifecycle decision":

  test "classify is exact at both edges":
    let w = window(1_000, 2_000)
    check classify(w, 999, horizonSeconds = 0) == lsNotYetInForce
    check classify(w, 1_000, horizonSeconds = 0) == lsCurrent
    check classify(w, 1_999, horizonSeconds = 0) == lsCurrent
    check classify(w, 2_000, horizonSeconds = 0) == lsExpired
    check classify(w, 2_001, horizonSeconds = 0) == lsExpired

  test "the horizon announces an expiry without being one":
    let w = window(0, 1_000)
    check classify(w, 899, horizonSeconds = 100) == lsCurrent
    check classify(w, 900, horizonSeconds = 100) == lsDueForRefresh
    check classify(w, 999, horizonSeconds = 100) == lsDueForRefresh
    check classify(w, 1_000, horizonSeconds = 100) == lsExpired
    # Still usable while due: announcing a deadline must not BE the
    # outage it exists to prevent.
    check isUsable(lsDueForRefresh)
    check not isUsable(lsExpired)

  test "the default horizon is thirty days and is read as such":
    check DefaultRefreshHorizonDays == 30
    let w = window(0, 100 * Day)
    check classify(w, 100 * Day - 31 * Day) == lsCurrent
    check classify(w, 100 * Day - 30 * Day) == lsDueForRefresh

  test "a window that has not opened is reported as that, not as expiring":
    let w = window(1_000, 1_001)
    check classify(w, 0) == lsNotYetInForce

  test "on an INVERTED window the ORDER of the tests is the whole answer":
    # The case above does not establish the order, and this was measured
    # rather than assumed: for a WELL-FORMED window the two conditions
    # are mutually exclusive, so swapping them changes nothing any input
    # can see. The claim becomes observable only on an inverted window —
    # which this type does not forbid, because nothing here PARSES a
    # window, it is handed one by a caller who might have built it from
    # two fields it read in the wrong order.
    #
    # There the order is the whole of the answer, and "not yet in force"
    # is the right one: it sends the reader at the clock or at whoever
    # built the window, where the fault is, instead of at an expiry.
    let inverted = LifecycleWindow(hasNotBefore: true, notBefore: 2_000,
                                   hasNotAfter: true, notAfter: 1_000)
    check classify(inverted, 1_500) == lsNotYetInForce
    # And the two instants where both orders agree, so the case above is
    # not passing by naming an instant nothing distinguishes.
    check classify(inverted, 500) == lsNotYetInForce
    check classify(inverted, 2_500) == lsExpired

  test "no stated end is neither current nor usable":
    let w = windowEndingNever(0)
    check classify(w, 10_000_000) == lsNoStatedEnd
    check not isUsable(lsNoStatedEnd)
    check needsAttention(lsNoStatedEnd)

  test "usable and needing attention are not the same partition":
    # `lsDueForRefresh` is in both, which is the whole point of it. A
    # test that only counted them would not see the overlap.
    var usableAndQuiet, usableAndLoud, unusable = 0
    for s in LifecycleStatus:
      if isUsable(s) and needsAttention(s): inc usableAndLoud
      elif isUsable(s): inc usableAndQuiet
      else: inc unusable
    check usableAndQuiet == 1
    check usableAndLoud == 1
    check unusable == 3

  test "an instruction names the artifact, the state, the date, the origin and the remedy":
    let w = window(0, 100 * Day)
    let msg = refreshInstruction(
      "KdsMilanCrlDerHex", lcVendorCollateral, lsExpired, w, 110 * Day,
      "the processor vendor's key distribution service",
      "curl -sS https://example.invalid/crl")
    check "KdsMilanCrlDerHex" in msg
    check "expired" in msg
    check iso(100 * Day) in msg
    check "10 days ago" in msg
    check "vendor-collateral" in msg
    check "the processor vendor's key distribution service" in msg
    check "Refresh it with: curl -sS https://example.invalid/crl" in msg

  test "a due instruction counts forward and an expired one counts back":
    let w = window(0, 100 * Day)
    let due = refreshInstruction("x", lcVendorCollateral, lsDueForRefresh, w,
                                 90 * Day, "somewhere", "do this")
    check "in 10 days" in due
    check "days ago" notin due
    let gone = refreshInstruction("x", lcVendorCollateral, lsExpired, w,
                                  110 * Day, "somewhere", "do this")
    check "10 days ago" in gone
    check "in 10 days" notin gone

  test "an instruction with no remedy is refused rather than printed":
    let w = window(0, 100 * Day)
    expect LifecycleError:
      discard refreshInstruction("x", lcVendorCollateral, lsExpired, w,
                                 110 * Day, "somewhere", "")

  test "every status produces an instruction, and they differ":
    let w = window(0, 100 * Day)
    var seen: seq[string] = @[]
    for s in LifecycleStatus:
      let m = refreshInstruction("x", lcTrustRoot, s, w, 50 * Day, "o", "r")
      check m.startsWith("x: " & $s)
      check "Refresh it with: r" in m
      seen.add m
    check seen.deduplicate.len == 5

  test "drift means different things for different classes":
    check driftOf(lcProtocolVector, "aa", "aa") == doUnchanged
    check driftOf(lcGenuineCapture, "aa", "aa") == doUnchanged
    check driftOf(lcProtocolVector, "aa", "bb") == doDrifted
    check driftOf(lcTrustRoot, "aa", "bb") == doDrifted
    check driftOf(lcVendorCollateral, "aa", "bb") == doDrifted
    check driftOf(lcGenuineCapture, "aa", "bb") == doExpectedToDiffer
    # Every class is reached, every outcome is reachable, and the two
    # classes with no publisher REFUSE rather than answering — asserted
    # as a partition over the enumeration so a class added without a
    # decision cannot slip through as one of these counts.
    var drifted, expected, refused = 0
    for c in LifecycleClass:
      try:
        case driftOf(c, "aa", "bb")
        of doDrifted: inc drifted
        of doExpectedToDiffer: inc expected
        of doUnchanged: check false
      except LifecycleError:
        inc refused
    check drifted == 3
    check expected == 1
    check refused == 2
    check drifted + expected + refused == ord(high(LifecycleClass)) + 1

  test "a class with no publisher is refused, equal digests included":
    # The refusal is about there being no second party, not about the
    # digests differing. Answering "unchanged" for an artifact nobody
    # went and looked at is an absence wearing a verdict's clothes.
    for c in [lcMintedNegative, lcDerivedReading]:
      expect LifecycleError: discard driftOf(c, "aa", "bb")
      expect LifecycleError: discard driftOf(c, "aa", "aa")

  test "an absent observation is not an observation of no change":
    # This rule had NO case. It had one, and the case was deleted while
    # the drift block beside it was being rewritten; the mutation that
    # removes the guard was GREEN until the case came back. An empty
    # digest means nobody looked, and answering either "drifted" or
    # "unchanged" for it reports a comparison that did not happen.
    for pair in [("", "bb"), ("aa", ""), ("", "")]:
      let (pinned, observed) = pair
      checkpoint(pinned.escape() & " against " & observed.escape())
      var refused = ""
      try:
        discard driftOf(lcTrustRoot, pinned, observed)
      except LifecycleError as err:
        refused = err.msg
      check "an absent observation is not an observation of no change" in
        refused
    # The same class with two real digests does not refuse, so the
    # refusal is about the emptiness and not about the class.
    check driftOf(lcTrustRoot, "aa", "bb") == doDrifted

  test "a drift report says which side is which":
    let m = driftInstruction("KdsMilanCrlDerHex", lcVendorCollateral,
                             doDrifted, "aaaa", "bbbb",
                             "the vendor's service", "re-fetch it")
    check "pinned aaaa" in m
    check "the vendor's service now serves bbbb" in m
    check "Refresh it with: re-fetch it" in m
    let q = driftInstruction("quote-operator-a.bin", lcGenuineCapture,
                             doExpectedToDiffer, "aaaa", "bbbb",
                             "operator A", "ask again")
    check "not a refutation of the first" in q
    check "genuine-capture" in q

  test "an unchanged report carries the digest and stops there":
    let m = driftInstruction("x", lcTrustRoot, doUnchanged, "aaaa", "aaaa",
                             "o", "r")
    check m == "x: unchanged at aaaa"

  test "the scheduled monitor's copy of this decision agrees with it":
    # ADDED BY REVIEW. The tables beside this gate exist because "two
    # readers need the same facts and only one of them is Nim" -- and
    # that reasoning was applied to the DATA and not to the DECISION.
    # `tools/attestation_collateral_monitor.py` carries its own
    # `DRIFT_MEANS`, its own five statuses and its own horizon, hand
    # kept, in another language, with nothing comparing them. A second
    # copy nobody checks is the thing the tables were introduced to
    # avoid.
    #
    # This is a source scan and it is narrow on purpose: it pins the
    # SPELLINGS and the horizon, which is where a divergence would
    # actually bite (the monitor prints a status name an operator then
    # looks up in the runbook). It does not establish that the two
    # implementations decide alike on every input, and that is stated
    # rather than implied.
    let monitor = readFile(integrationDir().parentDir.parentDir /
                           "tools" / "attestation_collateral_monitor.py")
    check monitor.len > 0
    # The positive control first: a file that failed to load, or a scan
    # that read nothing, must not satisfy the loop below.
    check "DRIFT_MEANS = {" in monitor
    check "NEEDS_ATTENTION = {" in monitor
    for c in LifecycleClass:
      checkpoint($c)
      check ("\"" & $c & "\":") in monitor
    for s in LifecycleStatus:
      checkpoint($s)
      check ("\"" & $s & "\"") in monitor
    # And no SIXTH class on the monitor's side, which would be a rule
    # this module has no arm for.
    var quoted = 0
    let opens = monitor.find("DRIFT_MEANS = {")
    let table = monitor[opens .. monitor.find("}", opens)]
    for line in table.splitLines():
      if line.strip().startsWith("\""): inc quoted
    check quoted == ord(high(LifecycleClass)) + 1
    check ("DEFAULT_HORIZON_DAYS = " & $DefaultRefreshHorizonDays) in monitor

  test "every ledger class is a class the decision module knows":
    var spelled: seq[string] = @[]
    for c in LifecycleClass: spelled.add $c
    for row in ledgerRows():
      checkpoint(row.name)
      check row.class in spelled
    # And every class the module declares is used by the corpus, so the
    # enumeration is not carrying a member nothing reaches.
    var used = initCountTable[string]()
    for row in ledgerRows(): used.inc row.class
    for c in LifecycleClass:
      checkpoint($c)
      check used[$c] > 0

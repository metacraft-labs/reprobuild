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
## 4. **Pinned clocks agree with the material they judge.** Six gates
##    state their own `Now`, and each one is DERIVED rather than chosen:
##    it is the first UTC midnight at which every artifact that gate
##    judges is in force, recomputed here from the artifacts' own dates
##    and required to be equal. "Inside the window" alone is satisfied
##    by any instant in a fifty-day interval, which is how a clock ends
##    up far ahead of its evidence.
##
##    The failure this catches is not hypothetical and was MEASURED, not
##    argued: the vendor reissued all three of its revocation lists with
##    a `thisUpdate` three weeks after the instant those gates pinned,
##    and the chain evaluators set a list that is not yet in force
##    aside. Refreshing the bytes while leaving the clocks alone makes
##    FOUR gates report "no revocation data" — 12 cases across them —
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
    ## A gate that states its own `Now`, and what that clock judges.
    ##
    ## The two lists together are a PARTITION of the windowed ledger rows
    ## the gate's own source references, and the suite below derives that
    ## set by reading the source rather than trusting either list. Before
    ## that, `mustBeCurrent` was hand-kept with nothing tying it to the
    ## gate at all, and four of the six rows disagreed with their gate:
    ## three names in `t_snp_fixture_verify` and one in
    ## `t_snp_chain_requires_amd_root` that those gates do not reference,
    ## and one in `t_snp_tcb_policy` that it does. None of the four moved
    ## a derived clock on the day they were found, which is why they had
    ## gone unnoticed — a hand-kept list is wrong for a while before it
    ## is wrong expensively.
    source: string
    now: int64

    mustBeCurrent: seq[string]
      ## Artifacts this gate requires to be IN FORCE at `now`. The clock
      ## is the first midnight at which all of them are, so adding a row
      ## with a later start moves the clock and dropping the latest one
      ## moves it back.

    notRequiredCurrent: seq[string]
      ## Artifacts the gate references and deliberately does NOT require
      ## in force: material pinned to be refused, and vintages pinned for
      ## being old. Without this list the partition could only be made to
      ## hold by requiring an impostor certificate to be current, which
      ## would be a false statement about what the gate needs; with it,
      ## the excuse is written down and costs something. Two rules make
      ## it more than a free-form note, and they are cases below: nothing
      ## named here may be named in ANY gate's `mustBeCurrent`, and
      ## nothing named here may carry an OBSERVATION DATE — which every
      ## artifact somebody went to a publisher for does, and no artifact
      ## that came out of a project's committed test data or was minted
      ## here does. So the list cannot be used to silence the next
      ## reissue; that has to be answered with new bytes and a
      ## recomputed clock.

const
  PinnedClockGates: array[6, PinnedClockGate] = [
    PinnedClockGate(
      source: "t_snp_fixture_verify.nim", now: 1_790_121_600'i64,
      mustBeCurrent: @["GsgMilanVcekDerHex", "KdsMilanCrlDerHex",
                       "VirteeMilanVcekDerHex"],
      notRequiredCurrent: @[]),
    PinnedClockGate(
      source: "t_snp_chain_requires_amd_root.nim", now: 1_790_121_600'i64,
      mustBeCurrent: @["KdsGenoaCrlDerHex", "KdsMilanCrlDerHex",
                       "KdsTurinCrlDerHex", "VirteeMilanVcekDerHex",
                       "VirteeTurinVcekDerHex"],
      notRequiredCurrent: @["ImpostorArkHex", "ImpostorAskHex",
                            "ImpostorVcekHex"]),
    PinnedClockGate(
      source: "t_snp_tcb_policy.nim", now: 1_790_121_600'i64,
      mustBeCurrent: @["GsgMilanVcekDerHex", "KdsMilanCrlDerHex",
                       "VirteeMilanVcekDerHex"],
      notRequiredCurrent: @[]),
    PinnedClockGate(
      source: "t_tdx_chain_requires_intel_root.nim", now: 1_790_985_600'i64,
      mustBeCurrent: @["IntelRootCrlDerHex", "IntelSgxRootCaDerHex",
                       "PcsPckCrlPlatformDerHex",
                       "PcsPckCrlProcessorDerHex"],
      notRequiredCurrent: @["ImpostorCaDerHex",
                            "ImpostorCaNotAnAuthorityDerHex",
                            "ImpostorCaWithoutCertSignDerHex",
                            "ImpostorLeafDerHex",
                            "ImpostorLeafWithUnknownCriticalDerHex",
                            "ImpostorLeafWithoutFmspcDerHex",
                            "ImpostorLeafWithoutPlatformDerHex",
                            "ImpostorLeafWithoutTcbDerHex",
                            "ImpostorRootDerHex", "IntelSampleCaDerHex",
                            "IntelSampleLeafDerHex", "IntelSampleRootDerHex",
                            "PcsPckCrlPlatformWithoutNextUpdateDerHex"]),
    PinnedClockGate(
      source: "t_tdx_collateral_and_verifier_arm.nim", now: 1_790_985_600'i64,
      mustBeCurrent: @["IntelSgxRootCaDerHex", "IntelTcbSigningCertDerHex",
                       "PcsPckCrlPlatformDerHex", "PcsSgxQeIdentityJson",
                       "PcsSgxTcbInfoJson", "PcsTcbInfoEmrJson",
                       "PcsTcbInfoSprJson", "PcsTdxQeIdentityJson"],
      notRequiredCurrent: @["GtgQeIdentityJson", "GtgTcbInfoEmrJson",
                            "GtgTcbInfoSprJson", "ImpostorCaDerHex",
                            "ImpostorLeafDerHex", "ImpostorRootDerHex",
                            "IntelSampleCaDerHex", "IntelSampleLeafDerHex",
                            "IntelSampleRootDerHex"]),
    PinnedClockGate(
      # FOUND BY REVIEW. This gate states its clock as `const Now = …`
      # on ONE line, and the scan below read only a line that BEGINS
      # `Now = `, so it was invisible to the completeness check and had
      # no row — a sixth pinned clock judging the same revocation list
      # the other three do, and the one refreshing that list will break
      # without the ledger naming it. The scan now reads both spellings.
      source: "t_snp_evidence_reaches_the_verdict.nim",
      now: 1_790_121_600'i64,
      mustBeCurrent: @["GsgMilanVcekDerHex", "KdsMilanCrlDerHex",
                       "VirteeMilanVcekDerHex"],
      notRequiredCurrent: @[])]

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

proc jsonNumber(js, key: string): int =
  ## An unquoted numeric member, read the same way `jsonMember` reads a
  ## quoted one: by finding the member and taking the digits after it.
  let k = "\"" & key & "\":"
  let i = js.find(k)
  doAssert i >= 0, "no " & key & " member"
  var j = i + k.len
  var digits = ""
  while j < js.len and js[j] in {'0' .. '9'}:
    digits.add js[j]
    inc j
  doAssert digits.len > 0, key & " is not a number"
  parseInt(digits)

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

proc firstMidnightAtOrAfter(t: int64): int64 =
  ## The first UTC midnight at or after `t`. Exact at the boundary: a
  ## `t` that already IS a midnight is its own answer, which matters
  ## because it is the difference between a clock sitting on the
  ## instant its material came into force and a clock a whole day past
  ## it for no stated reason.
  ((t + Day - 1) div Day) * Day

proc openingMidnight(g: PinnedClockGate): int64 =
  ## THE CLOCK RULE, as a computation over the bytes.
  ##
  ## A gate's `Now` is the first UTC midnight at which every artifact
  ## that gate judges is simultaneously in force — the midnight at or
  ## after the latest `notBefore` among them. Everything on the right
  ## of this is read out of an artifact's own DER or JSON by
  ## `windowOfRow`, so the only thing the gate source contributes is
  ## the constant being checked.
  ##
  ## Why an equality and not a bound. "Inside the window" is satisfied
  ## by any instant in a fifty-day interval, and a refresh that has to
  ## move a clock will reach for one that passes — which is how a clock
  ## ends up far past the evidence and the next refresh silently stops
  ## testing anything. The earliest defensible instant is a decision
  ## nobody has to make twice, and it moves if and only if the material
  ## moves.
  result = low(int64)
  for name in g.mustBeCurrent:
    let w = windowOfRow(rowNamed(name))
    doAssert w.hasNotBefore, name & " states no start"
    if w.notBefore > result: result = w.notBefore
  result = firstMidnightAtOrAfter(result)

proc codeOnly(text: string): string =
  ## `text` with every comment and every string literal replaced by a
  ## space, so what is left is the code.
  ##
  ## Both removals are load-bearing and both have cost this repository a
  ## gate that could not fail. A name left in a COMMENT is the
  ## most-repeated way a check in this tree has turned out to check
  ## nothing, and a name in a STRING is a label rather than a use — the sibling gate that
  ## records provenance writes `pin "KdsMilanCrlDerHex", …`, and a scan
  ## that counted that would call every artifact referenced by every gate
  ## that merely names it.
  ##
  ## Nim's character literal IS tracked, and the thing that makes that
  ## delicate is that `'` is also the numeric-suffix sigil — a reader
  ## that treated `1_790_985_600'i64` as an opening quote would swallow
  ## the rest of the line, including any reference on it. The two are
  ## told apart the way the compiler tells them apart: a `'` directly
  ## after an identifier or a number character is a suffix, and anywhere
  ## else it opens a literal. Both halves have input in the sources this
  ## scans — `check line == '"'` is a literal carrying a quote, and
  ## `'i64` appears in every one of the six gates — and both are cases
  ## below.
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if text[i] == '\'' and
       (i == 0 or text[i - 1] notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}):
      var j = i + 1
      while j < text.len and text[j] != '\'' and text[j] != '\n':
        if text[j] == '\\': inc j
        inc j
      i = min(j + 1, text.len)
      result.add ' '
    elif text[i] == '"':
      if i + 2 < text.len and text[i + 1] == '"' and text[i + 2] == '"':
        var j = i + 3
        while j + 2 < text.len and
              not (text[j] == '"' and text[j + 1] == '"' and text[j + 2] == '"'):
          inc j
        i = min(j + 3, text.len)
      else:
        var j = i + 1
        while j < text.len and text[j] != '"' and text[j] != '\n':
          if text[j] == '\\': inc j
          inc j
        i = min(j + 1, text.len)
      result.add ' '
    elif text[i] == '#':
      if i + 1 < text.len and text[i + 1] == '[':
        var j = i + 2
        while j + 1 < text.len and not (text[j] == ']' and text[j + 1] == '#'):
          inc j
        i = min(j + 2, text.len)
        result.add ' '
      else:
        while i < text.len and text[i] != '\n': inc i
        result.add ' '
    else:
      result.add text[i]
      inc i

proc referencedCorpusNames(source: string): seq[string] =
  ## Every WINDOWED ledger row the named gate's source references as an
  ## identifier, in the gate's own code.
  ##
  ## This is the mechanical side of the two lists above: the gate source
  ## is the authority and the table is what is checked against it, so a
  ## gate that starts or stops referencing an artifact cannot stay in
  ## silent disagreement with its row.
  let code = codeOnly(readFile(integrationDir() / source))
  var seen: seq[string] = @[]
  for row in ledgerRows():
    if not hasWindow(row): continue
    if row.name in seen: continue
    # Whole-identifier, so `PcsPckCrlPlatformDerHex` is not found inside
    # `PcsPckCrlPlatformWithoutNextUpdateDerHex`.
    var at = 0
    while true:
      let k = code.find(row.name, at)
      if k < 0: break
      let beforeOk = k == 0 or code[k - 1] notin
        {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}
      let after = k + row.name.len
      let afterOk = after >= code.len or code[after] notin
        {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}
      if beforeOk and afterOk:
        seen.add row.name
        break
      at = k + 1
  seen.sort()
  seen

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
    check pairs == 26

  test "the two lists are exactly what the gate's own source references":
    # THE MECHANICAL TIE, and the residual this closes. `mustBeCurrent`
    # was hand-kept against sources that change, which is the shape this
    # whole file exists to remove one instance of: the only thing that
    # related a row to its gate was somebody remembering, and four of six
    # rows had stopped agreeing.
    #
    # The gate's SOURCE is the authority and the table is the side under
    # test. For every windowed ledger row a gate's code names, the row
    # must appear in exactly one of the two lists; and neither list may
    # name a row the code does not name. So a gate that starts
    # referencing an artifact is red until its row says what the clock
    # must do about it, and a gate that stops referencing one is red
    # until the stale name goes.
    var referenced = 0
    for g in PinnedClockGates:
      checkpoint(g.source)
      var declared = g.mustBeCurrent & g.notRequiredCurrent
      # Neither list may repeat a name and the two may not overlap: a
      # name in both would satisfy the partition while saying the gate
      # does and does not require the artifact in force.
      check declared.deduplicate.len == declared.len
      declared.sort()
      let scanned = referencedCorpusNames(g.source)
      check declared == scanned
      referenced += scanned.len
    # The scan is not vacuous and the two lists are not one list: both
    # have members, and the counts are pinned so a scan that returned
    # nothing — or everything — could not satisfy the loop.
    check referenced == 51
    var mustTotal, excusedTotal = 0
    for g in PinnedClockGates:
      mustTotal += g.mustBeCurrent.len
      excusedTotal += g.notRequiredCurrent.len
    check mustTotal == 26
    check excusedTotal == 25
    check mustTotal + excusedTotal == referenced

  test "the scan reads CODE, not comments and not string literals":
    # Without this the case above is satisfied by a scan over the raw
    # file, and the two shapes that defeats are the two this repository
    # has paid for most often: a name that stayed behind in a comment after
    # the code using it was deleted, and a name that only ever appears as
    # a LABEL in a string.
    #
    # Both halves have real input in the tree rather than constructed
    # ones. `t_snp_evidence_reaches_the_verdict` names each of its
    # artifacts once in its header prose and once in its code, and
    # `t_snp_fixture_verify` names `KdsTurinCrlDerHex` in a comment and
    # NOWHERE in its code — so a `codeOnly` that stopped stripping
    # comments would put that name in that gate's referenced set, and the
    # partition case above would be red. That is the stripping's reachable
    # input, said out loud because without it the only thing exercising it
    # would be this case's own constructed strings.
    let verdictGate = "t_snp_evidence_reaches_the_verdict.nim"
    let raw = readFile(integrationDir() / verdictGate)
    let code = codeOnly(raw)
    proc occurrences(hay, needle: string): int =
      var at = 0
      while true:
        let k = hay.find(needle, at)
        if k < 0: return
        inc result
        at = k + 1
    check occurrences(raw, "KdsMilanCrlDerHex") == 2
    check occurrences(code, "KdsMilanCrlDerHex") == 1
    check occurrences(raw, "GsgMilanVcekDerHex") == 3
    check occurrences(code, "GsgMilanVcekDerHex") == 2
    # So the transform removes mentions, and it does not remove them all:
    # a `codeOnly` that returned the empty string would satisfy the first
    # half of each pair and not the second.
    check code.len > raw.len div 2
    # And each shape directly, because the real input above only exercises
    # the single-hash comment.
    const Name = "KdsTurinCrlDerHex"
    for hidden in ["# " & Name,
                   "## " & Name,
                   "#[ " & Name & " ]#",
                   "\"" & Name & "\"",
                   "\"\"\"" & Name & "\"\"\"",
                   "check f(\"" & Name & "\") # and " & Name]:
      checkpoint(hidden)
      check Name notin codeOnly(hidden)
    # The positive control: the same name in code survives, so the
    # transform is not simply deleting the name.
    check Name in codeOnly("let x = " & Name)
    check Name in codeOnly("let x = " & Name & " # not here though")
    # And on the real file: the name is in the text and not in the code.
    let snpGate = readFile(integrationDir() / "t_snp_fixture_verify.nim")
    check Name in snpGate
    check Name notin codeOnly(snpGate)
    check Name notin referencedCorpusNames("t_snp_fixture_verify.nim")
    # A numeric suffix is not a character literal, and mistaking it for
    # one would swallow the rest of the line — including the next
    # reference on it. A character literal that CARRIES a quote is the
    # other half, and both shapes are in the gates this scans: the
    # trust-domain collateral gate writes `'"'` and every gate writes
    # `'i64`.
    check Name in codeOnly("check now == 1_790_985_600'i64 and " & Name)
    check Name in codeOnly("if c == '\"': discard " & Name)
    check Name in codeOnly("for x in s.split('\\t'): discard " & Name)
    check Name in codeOnly("if c == '#': discard " & Name)
    # And a character literal is still a literal: what is INSIDE one is
    # not code, so a name spelled there does not count as a reference.
    check "Kds" notin codeOnly("let c = 'K'")

  test "nothing a gate excuses is material this corpus requires in force":
    # The first of two costs on `notRequiredCurrent`, and what stops it
    # being a place to put an artifact that is about to expire. An
    # artifact is either material some gate needs in force or material
    # pinned to be refused; it cannot be both, and the partition is
    # asserted across ALL gates rather than within each one.
    var required, excused: seq[string] = @[]
    for g in PinnedClockGates:
      for n in g.mustBeCurrent:
        if n notin required: required.add n
      for n in g.notRequiredCurrent:
        if n notin excused: excused.add n
    check required.len == 16
    check excused.len == 19
    for n in excused:
      checkpoint(n)
      check n notin required
    # Both directions, so the disjointness is not a statement about an
    # empty set on either side.
    for n in required:
      checkpoint(n)
      check n notin excused

  test "nothing a gate excuses is material somebody fetched from a publisher":
    # The second cost, and the one aimed at this file's own recurring
    # failure: the next time a vendor reissues, the answer has to be new
    # bytes and a recomputed clock, and it must not be possible to make
    # the reissue quiet by moving the name from one list to the other.
    #
    # The property that separates the two is the ledger's `observed`
    # column. An artifact somebody went to a publisher for is an artifact
    # this corpus tracks as CURRENT, and a publisher can reissue it. An
    # artifact with no observation date arrived from a project's
    # committed test data at a pinned commit, or from a vendor's sample
    # data, or was minted here — none of which has a current answer to
    # drift to. So an excuse is available for exactly the second kind.
    #
    # This covers more than a fetch-route rule would, which is why it
    # replaced one: all five of the trust-domain documents, both of its
    # withdrawal lists and both of its certificates carry observation
    # dates, and only two of those nine can be re-fetched in one request.
    var excusable, refused = 0
    for g in PinnedClockGates:
      for n in g.notRequiredCurrent:
        checkpoint(g.source & " excuses " & n)
        check rowNamed(n).observed == "-"
        inc excusable
    check excusable == 25
    # The complement, and it is the control: every artifact any gate
    # requires in force that DOES carry an observation date could not be
    # excused by this rule. Without this the rule above could be
    # satisfied by a corpus in which nothing is observed at all.
    var required: seq[string] = @[]
    for g in PinnedClockGates:
      for n in g.mustBeCurrent:
        if n notin required: required.add n
    check required.len == 16
    for n in required:
      if rowNamed(n).observed != "-": inc refused
    check refused == 13
    # And the fetch table, which is the weaker statement of the same
    # thing and is kept because it is the one the scheduled tool acts on:
    # nothing excused has an unattended refresh route, and the table is
    # not empty of things the gates require.
    var routes: seq[string] = @[]
    for f in fetchRows(): routes.add f.name
    for g in PinnedClockGates:
      for n in g.notRequiredCurrent:
        check n notin routes
    var withRoute = 0
    for n in required:
      if n in routes: inc withRoute
    check withRoute == 5

  test "each pinned clock IS the first midnight its material is all in force":
    # The rule, as an equality rather than as a range. The case above
    # establishes that each clock sits somewhere inside the windows; a
    # fifty-day interval has a lot of somewheres, and "inside" is
    # satisfied by a value picked because it passed. This says WHICH
    # instant, computed from the artifacts' own dates, and the gate
    # sources are the other side — so a clock nudged by hand to clear a
    # boundary is red even though it is still inside the window.
    for g in PinnedClockGates:
      checkpoint(g.source & ": states " & iso(g.now) & ", rule gives " &
                 iso(openingMidnight(g)))
      check g.now == openingMidnight(g)
    # And the rule is not a constant function: the two vendors' material
    # came into force on different days, so the six gates carry two
    # distinct clocks and not one. Without this a derivation that
    # returned the same midnight for every input would satisfy the loop.
    var clocks = initCountTable[int64]()
    for g in PinnedClockGates: clocks.inc g.now
    check clocks.len == 2
    check iso(1_790_121_600'i64) == "2026-09-23T00:00:00Z"
    check iso(1_790_985_600'i64) == "2026-10-03T00:00:00Z"

  test "the rule rounds UP to a midnight, and is exact when it lands on one":
    # `firstMidnightAtOrAfter` is the whole of the "pick one instant"
    # half of the rule, and an off-by-one there would move every clock a
    # day — in the direction that matters, since a day early is a clock
    # before its material is in force.
    check firstMidnightAtOrAfter(0) == 0
    check firstMidnightAtOrAfter(1) == Day
    check firstMidnightAtOrAfter(Day - 1) == Day
    check firstMidnightAtOrAfter(Day) == Day
    check firstMidnightAtOrAfter(Day + 1) == 2 * Day
    # On the real material: the latest start among what the two AMD
    # chain gates judge is the Turin list, and it is NOT a midnight.
    let turin = windowOfRow(rowNamed("KdsTurinCrlDerHex"))
    check turin.notBefore mod Day != 0
    check firstMidnightAtOrAfter(turin.notBefore) == 1_790_121_600'i64
    check turin.notBefore < 1_790_121_600'i64

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

  test "the pinned instant is the close of the day the corpus was last looked at":
    # Derived, not chosen. The ledger records an observation date for
    # every artifact somebody went and fetched; the reference instant is
    # the UTC midnight that ENDS the latest of them, so it is "the corpus
    # as of the last time anybody looked" rather than a number that stays
    # where it was put while the corpus moves underneath it.
    var latest = ""
    var observed = 0
    for row in ledgerRows():
      if row.observed == "-": continue
      inc observed
      if row.observed > latest: latest = row.observed
    check observed == 22
    check latest == "2026-10-02"
    check LedgerReferenceInstant ==
      parseIsoInstant(latest & "T00:00:00Z", "the latest observation") + Day
    check iso(LedgerReferenceInstant) == "2026-10-03T00:00:00Z"

  test "the instant the corpus was last looked at is one every observation reaches":
    # WHY THE CLOSING MIDNIGHT AND NOT THE OPENING ONE, as the property
    # the opening one violated rather than as a preference.
    #
    # `observed` is a DATE, so it fixes the instant only to within a day,
    # and the OPENING midnight is the one instant in that day at which a
    # document fetched later the same day is not yet in force. That is
    # measured, not imagined: seven observed artifacts were re-fetched
    # between 17:13 and 17:28 UTC, and at the opening midnight every one
    # of them classifies `lsNotYetInForce` — a corpus freshly taken from
    # its publisher reported as a clock fault. At the closing midnight
    # none does, and that holds for a reason rather than by luck: a
    # publisher that SERVED a document on a given day served one that was
    # in force at some instant in that day, hence at its end.
    var reachedAtClose, notReachedAtOpen = 0
    for row in ledgerRows():
      if row.observed == "-" or not hasWindow(row): continue
      checkpoint(row.name & " observed " & row.observed)
      let w = windowOfRow(row)
      check classify(w, LedgerReferenceInstant) != lsNotYetInForce
      inc reachedAtClose
      if classify(w, LedgerReferenceInstant - Day) == lsNotYetInForce:
        inc notReachedAtOpen
    check reachedAtClose == 13
    # And the opening midnight is NOT equivalent, which is what makes this
    # a repair. A corpus in which no observation started late would leave
    # this at zero and the case would be a tautology.
    check notReachedAtOpen == 7

  test "an observation date overlaps the window the artifact states":
    # What stops the column above being free. You cannot have fetched,
    # on a given day, a document that was not yet in force or had
    # already expired — so each observation is tied to dates read out of
    # the observed artifact's own bytes, and the reference instant
    # derived from the column inherits that.
    var checked = 0
    for row in ledgerRows():
      if row.observed == "-" or not hasWindow(row): continue
      checkpoint(row.name & " observed " & row.observed)
      let w = windowOfRow(row)
      let dayStart = parseIsoInstant(row.observed & "T00:00:00Z", row.name)
      check dayStart + Day - 1 >= w.notBefore
      if w.hasNotAfter: check dayStart < w.notAfter
      inc checked
    check checked == 13

  test "the three vendor revocation lists are current, and say until when":
    # They were two days from unusable and were refreshed; this is the
    # state the refresh produced, asserted rather than assumed.
    var current = 0
    for name in ["KdsMilanCrlDerHex", "KdsGenoaCrlDerHex",
                 "KdsTurinCrlDerHex"]:
      checkpoint(name)
      let w = windowOfRow(rowNamed(name))
      check classify(w, LedgerReferenceInstant) == lsCurrent
      check isUsable(classify(w, LedgerReferenceInstant))
      check iso(w.notAfter) == "2026-11-09T01:00:00Z"
      # And they came into force AFTER the clocks the gates used to
      # pin, which is the whole reason the clocks moved in the same
      # change. 1_788_220_800 is 2026-09-01T00:00:00Z, what the three
      # AMD gates stated before this refresh.
      check w.notBefore > 1_788_220_800'i64
      check classify(w, 1_788_220_800'i64) == lsNotYetInForce
      check not isUsable(classify(w, 1_788_220_800'i64))
      inc current
    check current == 3

  test "the trust-domain vendor's seven documents are current, and say until when":
    # The second refresh, with the same shape as the one above. These
    # seven stated a next update of 2026-10-21, which the capped horizon
    # would have begun announcing on 2026-10-06 — on every landing, for
    # fifteen days. This is the state the refresh produced.
    var current = 0
    for name in ["PcsPckCrlPlatformDerHex", "PcsPckCrlProcessorDerHex",
                 "PcsTcbInfoSprJson", "PcsTcbInfoEmrJson",
                 "PcsTdxQeIdentityJson", "PcsSgxQeIdentityJson",
                 "PcsSgxTcbInfoJson"]:
      checkpoint(name)
      let w = windowOfRow(rowNamed(name))
      check classify(w, LedgerReferenceInstant) == lsCurrent
      check isUsable(classify(w, LedgerReferenceInstant))
      # Thirty days to the second, which is this vendor's invariant and
      # the whole reason the horizon is capped at half a lifetime.
      check w.notAfter - w.notBefore == 30 * Day
      # And they came into force AFTER the clock the two trust-domain
      # gates stated before this refresh, which is why those clocks moved
      # in the same change. 1_790_035_200 is 2026-09-22T00:00:00Z.
      check w.notBefore > 1_790_035_200'i64
      check classify(w, 1_790_035_200'i64) == lsNotYetInForce
      check not isUsable(classify(w, 1_790_035_200'i64))
      inc current
    check current == 7

  test "a later issue carries a HIGHER evaluation-data number, not an older one":
    # The replay invariant for a trusted-computing-base document, and the
    # counterpart to "the revocation number went up and the revocation
    # survived" on the other vendor.
    #
    # A reissued document is not proved genuine by its dates — those are
    # the part an attacker rewrites — and a signature only proves the
    # vendor signed SOMETHING. What distinguishes a later issue from an
    # older one replayed under a new name is the vendor's own collateral
    # version: `tcbEvaluationDataNumber` is monotone in the vendor's
    # publication order, so a document stating a LOWER one than a vintage
    # this corpus already holds for the same platform is a rollback
    # whatever its issue date says.
    #
    # Three pairs, each an older vintage and the document refreshed here,
    # and the pairs come from DIFFERENT publishers — the earlier member of
    # each is committed test data in a third-party project, so the two
    # sides cannot both be whatever the service served today.
    var pairs = 0
    for (older, newer) in [("GtgTcbInfoSprJson", "PcsTcbInfoSprJson"),
                           ("GtgTcbInfoEmrJson", "PcsTcbInfoEmrJson"),
                           ("GtgQeIdentityJson", "PcsTdxQeIdentityJson")]:
      checkpoint(older & " then " & newer)
      let a = jsonNumber(bytesOf(older), "tcbEvaluationDataNumber")
      let b = jsonNumber(bytesOf(newer), "tcbEvaluationDataNumber")
      check b > a
      # And the ORDER of the two is read out of the documents' own dates
      # rather than assumed from the names.
      let wa = windowOfRow(rowNamed(older))
      let wb = windowOfRow(rowNamed(newer))
      check wb.notBefore > wa.notBefore
      inc pairs
    check pairs == 3
    # The numbers themselves, so this is not a comparison of two values a
    # single reader could be returning identically: three distinct older
    # numbers are not one number.
    var older: seq[int] = @[]
    for n in ["GtgTcbInfoSprJson", "GtgTcbInfoEmrJson", "GtgQeIdentityJson"]:
      older.add jsonNumber(bytesOf(n), "tcbEvaluationDataNumber")
    check older == @[15, 18, 15]
    # All five documents refreshed here state the SAME number, which is
    # the finding this refresh carries: the vendor moved the dates and
    # left the trusted-computing-base content alone, so no level, status
    # or advisory changed and no verdict here had cause to move.
    for n in ["PcsTcbInfoSprJson", "PcsTcbInfoEmrJson", "PcsTdxQeIdentityJson",
              "PcsSgxQeIdentityJson", "PcsSgxTcbInfoJson"]:
      checkpoint(n)
      check jsonNumber(bytesOf(n), "tcbEvaluationDataNumber") == 20

  test "the next thing in this corpus to expire is named, with its date":
    # The deliverable of the whole file in one line: a reader who wants
    # to know when this corpus next needs a hand does not have to run
    # anything. It is re-derived here rather than recorded, so it cannot
    # go stale quietly — refresh anything and this case says so.
    var soonest = high(int64)
    var who = ""
    for row in ledgerRows():
      if not hasWindow(row) or row.class == "historical-vintage": continue
      let w = windowOfRow(row)
      if not w.hasNotAfter: continue
      if w.notAfter < soonest:
        soonest = w.notAfter
        who = row.name
    check who == "PcsTcbInfoSprJson"
    check iso(soonest) == "2026-11-01T17:13:18Z"
    check soonest > LedgerReferenceInstant

  test "everything expired here is pinned for being expired":
    # The strong form, and the teeth on `historical-vintage`. The class
    # quietens a row in the scheduled monitor, so it has to cost
    # something: nothing else in the corpus may be expired at the
    # reference instant, and every row carrying the class must actually
    # be in the state it claims.
    var expired = 0
    for row in ledgerRows():
      if not hasWindow(row): continue
      if classify(windowOfRow(row), LedgerReferenceInstant) == lsExpired:
        checkpoint(row.name & " expired " & row.notAfter)
        check row.class == "historical-vintage"
        inc expired
    check expired == 3
    var vintages = 0
    for row in ledgerRows():
      if row.class != "historical-vintage": continue
      checkpoint(row.name)
      check hasWindow(row)
      check classify(windowOfRow(row), LedgerReferenceInstant) == lsExpired
      check not isUsable(classify(windowOfRow(row), LedgerReferenceInstant))
      inc vintages
    check vintages == expired

  test "a vintage pinned for being old has no unattended refresh route":
    # The other half of the cost, and the one that stops the class
    # being a mute button. "This cannot be made current" and "one HTTP
    # GET returns the publisher's current answer" are contradictory
    # claims; a row making both would be using the class to silence an
    # artifact that is simply out of date. The monitor refuses such a
    # row outright; this is the same rule where the suite can see it.
    var routes: seq[string] = @[]
    for f in fetchRows(): routes.add f.name
    check routes.len == 8
    for row in ledgerRows():
      if row.class != "historical-vintage": continue
      checkpoint(row.name)
      check row.name notin routes
    # The positive control: the list is not empty and does name rows of
    # the class next door, so "not in it" is a statement about these
    # three rather than about an empty list.
    check "KdsMilanCrlDerHex" in routes
    check rowNamed("KdsMilanCrlDerHex").class == "vendor-collateral"

  test "the whole corpus partitions across the statuses":
    var byStatus = initCountTable[LifecycleStatus]()
    for row in ledgerRows():
      if not hasWindow(row): continue
      byStatus.inc classify(windowOfRow(row), LedgerReferenceInstant)
    check byStatus[lsExpired] == 3
    check byStatus[lsDueForRefresh] == 0
    check byStatus[lsCurrent] == 31
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
    # A freshly refreshed corpus has nothing due, which is the point of
    # refreshing it — and it means `lsDueForRefresh` has no input HERE.
    # Said out loud rather than left to be inferred from a zero: the
    # status is exercised by the boundary cases below and by the
    # projection in the case that follows, and by nothing in this table.
    check byStatus[lsDueForRefresh] == 0

  test "every artifact here becomes due before it expires":
    # `lsDueForRefresh` reaches no row of this corpus today, so the
    # property that matters — that the warning arrives while there is
    # still time — is asserted as a projection over each artifact's own
    # window instead of being left unmeasured. One instant before the
    # end is due and not yet expired, and the announcement opens
    # strictly after the artifact comes into force, so no artifact is
    # born due.
    var projected = 0
    for row in ledgerRows():
      if not hasWindow(row): continue
      let w = windowOfRow(row)
      if not w.hasNotAfter: continue
      checkpoint(row.name)
      check classify(w, w.notAfter - 1) == lsDueForRefresh
      check isUsable(classify(w, w.notAfter - 1))
      check classify(w, w.notBefore) != lsDueForRefresh
      inc projected
    check projected == 34

  test "no stable-protocol or minted artifact is in the expiring set":
    # The separation, asserted rather than described: the material that
    # goes stale is exactly the material a vendor reissues.
    for row in ledgerRows():
      if not hasWindow(row): continue
      let status = classify(windowOfRow(row), LedgerReferenceInstant)
      if status in {lsExpired, lsDueForRefresh}:
        checkpoint(row.name)
        check row.class in ["vendor-collateral", "historical-vintage"]
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

  test "the horizon is capped at half an artifact's own lifetime":
    # The repair, at its boundary. Thirty days is a CEILING; the
    # horizon an artifact actually gets is the lesser of it and half
    # that artifact's stated life, so there is always a quiet period at
    # least as long as the warning.
    check effectiveHorizon(window(0, 100 * Day), 30 * Day) == 30 * Day
    check effectiveHorizon(window(0, 60 * Day), 30 * Day) == 30 * Day
    check effectiveHorizon(window(0, 59 * Day), 30 * Day) ==
      29 * Day + Day div 2
    check effectiveHorizon(window(0, 30 * Day), 30 * Day) == 15 * Day
    check effectiveHorizon(window(0, 2), 30 * Day) == 1
    # Sixty days is the exact crossover: at and above it the ceiling
    # binds, below it the proportion does.
    check effectiveHorizon(window(0, 60 * Day), 30 * Day) ==
      effectiveHorizon(window(0, 10_000 * Day), 30 * Day)

  test "a short-lived document is NOT born due for refresh":
    # The defect, stated as the property it violated. A thirty-day
    # document under a flat thirty-day horizon is due from the instant
    # it is issued, so the announcement is true for its whole life and
    # says nothing. Under the capped horizon it is current for the
    # first half and due for the second.
    let w = window(0, 30 * Day)
    check classify(w, 0) == lsCurrent
    check classify(w, 14 * Day) == lsCurrent
    check classify(w, 15 * Day) == lsDueForRefresh
    check classify(w, 29 * Day) == lsDueForRefresh
    check classify(w, 30 * Day) == lsExpired
    # Under the UNCAPPED rule the same document is due at every instant
    # of its life, which is the comparison that makes the repair a
    # repair rather than a preference. `horizonSeconds` is still honest
    # about what it is handed: a caller asking for a horizon SHORTER
    # than half the life gets exactly that.
    check classify(w, 0, horizonSeconds = 1) == lsCurrent
    check classify(w, 30 * Day - 1, horizonSeconds = 1) == lsDueForRefresh
    check classify(w, 30 * Day - 2, horizonSeconds = 1) == lsCurrent
    # And the cap never makes something usable that was not: the expiry
    # instant is untouched by any horizon.
    for h in [0'i64, 1'i64, 15 * Day, 30 * Day, 10_000 * Day]:
      check classify(w, 30 * Day, horizonSeconds = h) == lsExpired
      check classify(w, 30 * Day - 1, horizonSeconds = h) != lsExpired

  test "the quiet period is at least as long as the warning, always":
    # What "half" buys, over every lifetime rather than at the three
    # points above. For any window, the instant the announcement opens
    # is at or after the window's own midpoint.
    for days in [2, 3, 7, 29, 30, 31, 59, 60, 61, 365, 4_000]:
      let w = window(0, days.int64 * Day)
      let opens = w.notAfter - effectiveHorizon(w, 30 * Day)
      checkpoint($days & " days: opens at " & $(opens div Day))
      check opens >= (w.notAfter - w.notBefore) div 2
      check opens > w.notBefore
      check opens < w.notAfter

  test "a historical vintage is quiet when expired and loud otherwise":
    # `expiryNeedsAttention` is where the class is spent, and it is the
    # only place in this module where a class changes what a status
    # means. Both directions, because the quietening is the part that
    # could hide something.
    check not expiryNeedsAttention(lcHistoricalVintage, lsExpired)
    for s in LifecycleStatus:
      if s == lsExpired: continue
      checkpoint($s)
      check expiryNeedsAttention(lcHistoricalVintage, s)
    # Every other class is unchanged: the status alone decides, and
    # `lsExpired` is loud for all of them.
    for c in LifecycleClass:
      if c == lcHistoricalVintage: continue
      for s in LifecycleStatus:
        checkpoint($c & " / " & $s)
        check expiryNeedsAttention(c, s) == needsAttention(s)
      check expiryNeedsAttention(c, lsExpired)
    # And it is not a procedure that answers the same way whatever it
    # is handed: every class has at least one quiet status and at least
    # one loud one, and for the vintage class the quiet one is
    # `lsExpired` while for every other class it is `lsCurrent`. That
    # inversion is the whole content of the procedure, stated as what
    # distinguishes the arms rather than as the arms themselves.
    for c in LifecycleClass:
      var quiet, loud = 0
      for s in LifecycleStatus:
        if expiryNeedsAttention(c, s): inc loud else: inc quiet
      checkpoint($c & ": " & $quiet & " quiet, " & $loud & " loud")
      check quiet == 1
      check loud == ord(high(LifecycleStatus))
      if c == lcHistoricalVintage:
        check not expiryNeedsAttention(c, lsExpired)
        check expiryNeedsAttention(c, lsCurrent)
      else:
        check expiryNeedsAttention(c, lsExpired)
        check not expiryNeedsAttention(c, lsCurrent)

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
    check driftOf(lcHistoricalVintage, "aa", "bb") == doDrifted
    var drifted, expected, refused = 0
    for c in LifecycleClass:
      try:
        case driftOf(c, "aa", "bb")
        of doDrifted: inc drifted
        of doExpectedToDiffer: inc expected
        of doUnchanged: check false
      except LifecycleError:
        inc refused
    check drifted == 4
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
    # The two decisions this module added after that review, each of
    # which the monitor has to carry its own copy of for the same
    # reason: it cannot link this library. Pinned by the SHAPE of the
    # rule and not only by the name, because a procedure that exists
    # and returns its argument is worse than one that is absent.
    check "def effective_horizon(" in monitor
    check "return min(horizon, lifetime // 2)" in monitor
    check "def expiry_needs_attention(" in monitor
    check "if cls == \"historical-vintage\":" in monitor
    check "return status != \"expired\"" in monitor
    # And it is CALLED, not merely defined. A definition left in place
    # beside a second answer is the most-repeated way a check in this
    # tree has turned out to check nothing.
    check "effective_horizon(not_before, not_after, horizon)" in monitor
    check "expiry_needs_attention(row[\"class\"], status)" in monitor

  test "the scheduled run has a trigger it can actually reach":
    # The other half of "a check that cannot catch what it is for", and
    # the one no amount of care inside the tool could have fixed.
    #
    # A GitHub Actions `schedule:` trigger fires ONLY from the
    # repository's default branch. A workflow that lives on a
    # development branch therefore has no periodic run at all — not
    # late, absent — and nothing anywhere says so: the API reports the
    # workflow as active either way. Measured on this one: between it
    # being added and the first expiry it was written to announce, it
    # had run exactly once, from the `push` that introduced it.
    #
    # So an alarm whose whole subject is the calendar must also carry a
    # trigger that fires from the branch it is sitting on. This reads
    # the `on:` BLOCK rather than the file, and strips comments first,
    # because the reasoning above is prose in that same file and a
    # whole-file grep for "push" would be satisfied by it.
    let wf = readFile(integrationDir().parentDir.parentDir / ".github" /
                      "workflows" / "attestation-collateral.yml")
    check wf.len > 0
    var inOn = false
    var triggers: seq[string] = @[]
    var body: seq[string] = @[]
    for raw in wf.splitLines():
      if raw.len == 0: continue
      let bare = raw.strip()
      if bare.startsWith("#"): continue
      let topLevel = raw[0] notin {' ', '\t'}
      if topLevel:
        inOn = bare.startsWith("on:")
        continue
      if inOn:
        # One indent level under `on:` is an event name.
        if raw.startsWith("  ") and not raw.startsWith("   "):
          triggers.add bare.split(':')[0]
      else:
        body.add bare
    triggers.sort()
    # The schedule stays — it is correct and it starts working the day
    # this file reaches the default branch. What it may not be is the
    # ONLY periodic trigger.
    check "schedule" in triggers
    check "push" in triggers
    check triggers.len == 3
    # And the per-landing arm must be the OFFLINE one. Asking a
    # vendor's service once a week is courteous; asking it on every
    # landing is not, and a per-push run that reached the network would
    # be removed within the month — which would take the expiry half
    # with it.
    var offlineRuns, onlineRuns = 0
    for line in body:
      if not line.startsWith("run: python3 tools/attestation_collateral_monitor.py"):
        continue
      if "--offline" in line: inc offlineRuns else: inc onlineRuns
    check offlineRuns == 1
    check onlineRuns == 1
    check ("if: github.event_name == 'push'") in body
    check ("if: github.event_name != 'push'") in body

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

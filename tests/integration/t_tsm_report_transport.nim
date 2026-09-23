## The kernel's attestation-report surface: the counter discipline, the
## two sources, and every rule either of them can refuse on.
##
## ## What this gate can establish without a root of trust
##
## On a processor that supports neither confidential-computing
## technology `/sys/kernel/config/tsm/report` does not exist, and no
## document is ever obtained from a root of trust. That is not hedged
## anywhere below: one case asserts the absence directly, against the
## real path, so the limit is a measured fact in the gate's own output
## rather than a sentence in a comment.
##
## **Known limit, recorded here because it must be read before this
## suite is run anywhere else.** That case and the two census pins below
## state the absence as an INVARIANT, so this suite is RED on a host that
## does expose the surface — which is the hardware it describes. It needs
## a two-armed form: absent, assert the absence; present, assert the live
## pass. The second arm is deliberately not written here, because a
## branch nothing can execute is the defect this gate exists to avoid; it
## belongs in the change that first has such a host to falsify it on.
##
## What that leaves is everything except the one pass a kernel performs,
## and it is most of the module:
##
##   * the **counter discipline** is a pure function of three readings
##     and a count. The race it defends against needs two processes and
##     a kernel to OCCUR and needs neither to be DESCRIBED, which is why
##     it was written as a pure function in the first place — a rule
##     reachable only on hardware this gate cannot reach is a constant.
##   * the **three filesystem operations** the live pass is made of —
##     read an attribute to end of file, read the counter, offer bytes
##     to an attribute — run here against real files, real permissions
##     and real absences. They are reached AT THE OPERATION rather than
##     through a live pass, and that distinction is stated rather than
##     glossed.
##   * the **captured source** is exercised end to end, because a
##     captured source is a real source: it reads real files a machine
##     with the hardware produced.
##
## Exactly one rule has no input here and it is named in the census
## itself rather than left to be noticed: `tseShortWrite`. The reason is
## NOT that no device short-writes — `/dev/full` accepts nothing and is
## on every Linux — it is that `writeAttribute` cannot observe one.
## `open` is stdio-buffered and `File.close` discards `fclose`'s result,
## so offering 64 bytes to a device that accepts none still returns 64
## and the error is dropped at close; above the buffer size Nim raises
## `IOError` from `writeBuffer` instead of returning a short count. Both
## directions measured. So this rule is unreachable by CONSTRUCTION, and
## the repair is to make the write observable — not to hand the census a
## case that passes for the wrong reason.
##
## ## Why the census is over SITES
##
## A census over refusal KINDS and a census over refusal SITES differ
## precisely when one kind is raised from two places, and then a site
## reached never is paid for by a site reached twice. The two are made
## to coincide here by scanning the module's own source and requiring
## every condition to appear exactly once, so the coincidence is proved
## rather than assumed.
##
## ## Mocking
##
## None. `UnimplementedSource` is not a mock of a source — it is a
## subclass that overrides nothing, which is the only way the base
## seam's own refusals have an input at all. Everything else reads and
## writes real files.

import std/[options, os, strutils, unittest]

import repro_attest

# ---------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------

var reached: set[TsmErrorKind] = {}

proc refuses(body: proc (): void): ref TsmError =
  ## Run something that must refuse, record WHICH rule refused, and hand
  ## the error back so the case can pin the sentence too.
  try:
    body()
  except TsmError as err:
    reached.incl err.kind
    return err
  raise newException(ValueError, "nothing was refused")

proc cardOf(s: set[TsmErrorKind]): int =
  for k in TsmErrorKind:
    if k in s: inc result

const
  TsmSource = staticRead(
    "../../libs/repro_attest/src/repro_attest/tsm_report.nim")

  LiveOnly: array[1, TsmErrorKind] = [tseShortWrite]
    ## The rules this machine cannot reach, enumerated rather than
    ## subtracted. The census below asserts that the reached set and
    ## this one PARTITION the enumeration: a rule that is in neither is
    ## a rule nobody gave an input, and a rule in both is a rule this
    ## list is lying about.

proc raisedKindsIn(source: string): seq[string] =
  ## Every ``tsmFail(tse…`` in a source, in order. The declaration of
  ## `tsmFail` itself is not a call site and does not match, because it
  ## reads ``tsmFail*(kind:``.
  result = @[]
  var i = 0
  const Needle = "tsmFail(tse"
  while i < source.len:
    let at = source.find(Needle, i)
    if at < 0: break
    var j = at + len("tsmFail(")
    var name = ""
    while j < source.len and (source[j].isAlphaAscii or source[j].isDigit):
      name.add source[j]
      inc j
    result.add name
    i = j

# ---------------------------------------------------------------------
# A bench of real files
# ---------------------------------------------------------------------

type Bench = object
  dir: string
  outblobPath, providerPath, auxblobPath: string

var benchSequence = 0

proc newBench(provider = SevSnpProviderName; outblob = "a document";
              auxblob = ""): Bench =
  inc benchSequence
  result.dir = getTempDir() / ("repro-tsm-" & $getCurrentProcessId() & "-" &
                               $benchSequence)
  createDir(result.dir)
  result.outblobPath = result.dir / TsmOutblobAttr
  result.providerPath = result.dir / TsmProviderAttr
  result.auxblobPath = result.dir / TsmAuxblobAttr
  writeFile(result.outblobPath, outblob)
  # The kernel writes the provider's name with a trailing newline, and
  # a capture that preserved the bytes preserves that too.
  writeFile(result.providerPath, provider & "\n")
  if auxblob.len > 0: writeFile(result.auxblobPath, auxblob)

proc source(b: Bench; generation = consistentGeneration()): CapturedTsmSource =
  newCapturedTsmSource(b.outblobPath, b.providerPath, b.auxblobPath,
                       generation)

let boundBytes = repeat('\x5A', ReportDataSize)

type
  UnimplementedSource = ref object of TsmSource
    ## Overrides nothing, so the base seam's refusals have an input.
    ## Without one they are sentences nothing can reach, which is a
    ## constant rather than a rule.

  OversizeSource = ref object of TsmSource
    ## Returns more bytes than any envelope will carry, WITHOUT going
    ## through the file reader.
    ##
    ## That is the point: the file reader has a bound of its own, so the
    ## seam's bound would be unreachable through it — and the seam's
    ## bound is not about files, it is about what any source at all is
    ## allowed to hand back. A source that computed its document would
    ## bypass the reader entirely.

proc newUnimplementedSource(): UnimplementedSource =
  result = UnimplementedSource()
  initTsmSource(result, "overrides-nothing")

method sourceProbe(s: OversizeSource): BackendReadiness =
  BackendReadiness(ready: true, detail: "returns more than fits")

method sourceReport(s: OversizeSource; reportData: string): TsmReportBytes =
  TsmReportBytes(outblob: repeat('X', MaxTsmOutblobBytes + 1),
                 auxblob: none(string), provider: tsmSevSnp,
                 generation: consistentGeneration())

proc newOversizeSource(): OversizeSource =
  result = OversizeSource()
  initTsmSource(result, "oversize")

# ---------------------------------------------------------------------

suite "the refusal vocabulary is one rule per site":

  test "no message is a substring of any other":
    # The property that makes an `in e.msg` assertion mean ONE rule.
    # Checked rather than asserted, because it is a property of
    # eighteen sentences that a reader cannot hold in their head.
    check tsmMessagesAreDistinguishable()

  test "every rule has a site, and every site has exactly one rule":
    let found = raisedKindsIn(TsmSource)
    check found.len == 18
    check ord(high(TsmErrorKind)) + 1 == 18
    for k in TsmErrorKind:
      var seen = 0
      for n in found:
        if n == $k: inc seen
      check seen == 1
    # And nothing is raised that the enumeration does not carry. A name
    # the enum lacks would not compile, so what this catches is a
    # misspelling that happens to compile.
    for n in found:
      var known = false
      for k in TsmErrorKind:
        if n == $k: known = true
      check known

suite "the counter discipline":

  test "a session nobody raced is accepted":
    # The acceptance is spelled as a VALUE rather than left implicit in
    # "nothing raised". A case whose only assertion is the absence of an
    # exception is invisible to a source scanner, and a case a scanner
    # cannot see is a case that can rot into one that asserts nothing.
    var refused = false
    try:
      checkTsmGeneration(consistentGeneration(1), "<gate>")
      checkTsmGeneration(consistentGeneration(2), "<gate>")
    except TsmError:
      refused = true
    check not refused

  test "an entry that already carried writes is refused":
    let e = refuses(proc () =
      checkTsmGeneration(TsmGenerationReading(atOpen: 1, afterWrites: 2,
        afterRead: 2, writesPerformed: 1), "<gate>"))
    check e.kind == tseEntryNotFresh
    check TsmMessage[tseEntryNotFresh] in e.msg

  test "a writer that landed between this process's writes is refused":
    let e = refuses(proc () =
      checkTsmGeneration(TsmGenerationReading(atOpen: 0, afterWrites: 3,
        afterRead: 3, writesPerformed: 2), "<gate>"))
    check e.kind == tseConcurrentWriter
    check "performed 2 write(s)" in e.msg
    check "counter stands at 3" in e.msg

  test "an entry rewritten between the write and the read is refused":
    # The one that matters most: everything else about the document is
    # genuine, and it answers somebody else's question.
    let e = refuses(proc () =
      checkTsmGeneration(TsmGenerationReading(atOpen: 0, afterWrites: 1,
        afterRead: 2, writesPerformed: 1), "<gate>"))
    check e.kind == tseRegeneratedBetweenWriteAndRead
    check "1 when the bound bytes had been written" in e.msg
    check "2 when the document had been read" in e.msg

  test "the three rules are ordered by when the event happened":
    # A collided entry explains the other two, so an entry that was
    # never fresh AND was raced must report the collision: naming the
    # symptom and hiding the cause sends an operator after the wrong
    # thing. This is the ordering defect in its own right — a rule
    # sitting after something that consumed its input.
    let e = refuses(proc () =
      checkTsmGeneration(TsmGenerationReading(atOpen: 7, afterWrites: 99,
        afterRead: 123, writesPerformed: 1), "<gate>"))
    check e.kind == tseEntryNotFresh

  test "a counter that moved by exactly the writes performed passes":
    # The boundary from the other side, so the rule is not satisfied by
    # every input. Two writes, counter at two.
    checkTsmGeneration(TsmGenerationReading(atOpen: 0, afterWrites: 2,
      afterRead: 2, writesPerformed: 2), "<gate>")
    # And one fewer write than the counter saw is a refusal, so the
    # comparison is an equality rather than a floor.
    let e = refuses(proc () =
      checkTsmGeneration(TsmGenerationReading(atOpen: 0, afterWrites: 2,
        afterRead: 2, writesPerformed: 1), "<gate>"))
    check e.kind == tseConcurrentWriter

suite "the provider is matched exactly":

  test "both providers this build reads are recognised":
    check parseTsmProvider(SevSnpProviderName, "<gate>") == tsmSevSnp
    check parseTsmProvider(TdxProviderName, "<gate>") == tsmTdx

  test "the trailing newline the kernel writes is stripped":
    check parseTsmProvider(SevSnpProviderName & "\n", "<gate>") == tsmSevSnp
    check parseTsmProvider("  " & TdxProviderName & "  \n", "<gate>") ==
      tsmTdx

  test "a provider whose name merely starts the same is refused":
    # A prefix match would read `sev_guest_v2` as `sev_guest` and then
    # lift this build's offsets out of a document nobody described.
    let e = refuses(proc () =
      discard parseTsmProvider(SevSnpProviderName & "_v2", "<gate>"))
    check e.kind == tseUnknownProvider
    check SevSnpProviderName in e.msg
    check TdxProviderName in e.msg

  test "an empty provider is refused":
    let e = refuses(proc () = discard parseTsmProvider("", "<gate>"))
    check e.kind == tseUnknownProvider

suite "the base seam refuses on its own behalf":

  test "a source built without a label is refused":
    let e = refuses(proc () =
      var s = UnimplementedSource()
      initTsmSource(s, ""))
    check e.kind == tseSourceUnlabelled

  test "a source that cannot say whether it is ready is refused":
    let e = refuses(proc () = discard newUnimplementedSource().sourceProbe())
    check e.kind == tseSourceProbeUnimplemented
    check "overrides-nothing" in e.msg

  test "a source that implements no transport is refused":
    let e = refuses(proc () =
      discard readTsmReport(newUnimplementedSource(), boundBytes))
    check e.kind == tseSourceReportUnimplemented

suite "the checked entry point":

  test "bytes of the wrong width never reach a source":
    for width in [0, 1, ReportDataSize - 1, ReportDataSize + 1]:
      let e = refuses(proc () =
        discard readTsmReport(newBench().source(), repeat('\x00', width)))
      check e.kind == tseWrongReportDataWidth
      check $width & " bytes" in e.msg
      check $ReportDataSize in e.msg

  test "the width that IS bound is accepted":
    # The bound from the other side: a rule satisfied by every input is
    # not a rule.
    let b = newBench()
    check readTsmReport(b.source(), boundBytes).outblob == "a document"

  test "an empty document is refused":
    let b = newBench(outblob = "")
    let e = refuses(proc () = discard readTsmReport(b.source(), boundBytes))
    check e.kind == tseEmptyOutblob

  test "a document larger than any envelope will carry is refused":
    let e = refuses(proc () =
      discard readTsmReport(newOversizeSource(), boundBytes))
    check e.kind == tseOutblobTooLarge
    check $(MaxTsmOutblobBytes + 1) in e.msg

  test "the counter is checked on EVERY source, not only the live one":
    # The rule lives in the checked entry point rather than in the live
    # source, so a source that never touches a kernel still has to
    # account for the counter it reports. A rule that ran only where it
    # cannot be tested is a rule nothing holds.
    let b = newBench()
    let e = refuses(proc () =
      discard readTsmReport(b.source(TsmGenerationReading(atOpen: 0,
        afterWrites: 1, afterRead: 4, writesPerformed: 1)), boundBytes))
    check e.kind == tseRegeneratedBetweenWriteAndRead

suite "the captured source":

  test "the document comes back exactly as it was captured":
    let doc = "\x00\x01\xFE\xFF binary, with a NUL and high bytes \x7F"
    let b = newBench(outblob = doc)
    let got = readTsmReport(b.source(), boundBytes)
    check got.outblob == doc
    check got.provider == tsmSevSnp
    check got.auxblob.isNone

  test "an auxiliary blob that is present comes back present":
    let b = newBench(auxblob = "certificate table bytes")
    let got = readTsmReport(b.source(), boundBytes)
    check got.auxblob.isSome
    check got.auxblob.get == "certificate table bytes"

  test "an auxiliary blob that is EMPTY is absent, not present-and-empty":
    # The envelope refuses a present-but-empty chain, so the two answers
    # must stay different all the way down.
    let b = newBench()
    writeFile(b.auxblobPath, "")
    check readTsmReport(b.source(), boundBytes).auxblob.isNone

  test "a capture with no document on disk is refused":
    let b = newBench()
    removeFile(b.outblobPath)
    let e = refuses(proc () = discard readTsmReport(b.source(), boundBytes))
    check e.kind == tseCapturedAttributeAbsent
    check b.outblobPath in e.msg

  test "the probe names what is missing, and takes no document":
    let b = newBench()
    check b.source().sourceProbe().ready
    removeFile(b.providerPath)
    let p = b.source().sourceProbe()
    check not p.ready
    check b.providerPath in p.detail

suite "the three filesystem operations":

  test "an attribute is read to end of file, not to its declared size":
    # `readFile` sizes its buffer from `stat`, and a configfs binary
    # attribute reports its declared MAXIMUM there. What is asserted
    # here is the loop: a payload several chunks long comes back whole
    # and in order.
    let b = newBench()
    var payload = ""
    for i in 0 ..< 40_000: payload.add char(i mod 251)
    writeFile(b.outblobPath, payload)
    check readWholeAttribute(b.outblobPath, "outblob", "<gate>") == payload

  test "an attribute that cannot be opened is refused":
    let e = refuses(proc () =
      discard readWholeAttribute(getTempDir() / "no-such-attribute-here",
                                 "outblob", "<gate>"))
    check e.kind == tseAttributeUnopenable

  test "an attribute that keeps producing bytes is cut off":
    # Not the envelope's bound: this one stops a machine choosing how
    # much memory this process takes, and it fires while reading rather
    # than after.
    let b = newBench()
    writeFile(b.outblobPath, repeat('Z', MaxTsmOutblobBytes + 1))
    let e = refuses(proc () =
      discard readWholeAttribute(b.outblobPath, "outblob", "<gate>"))
    check e.kind == tseAttributeOverran
    check $MaxTsmOutblobBytes in e.msg

  test "a counter that is not a number is refused":
    let b = newBench()
    let path = b.dir / TsmGenerationAttr
    writeFile(path, "not-a-number\n")
    let e = refuses(proc () = discard readGeneration(path, "<gate>"))
    check e.kind == tseGenerationNotANumber
    check "not-a-number" in e.msg
    # And a counter that IS a number reads, including with the newline
    # the kernel writes.
    writeFile(path, "17\n")
    check readGeneration(path, "<gate>") == 17'u64

  test "an attribute that cannot be written is refused":
    let b = newBench()
    let readOnly = b.dir / "read-only"
    createDir(readOnly)
    setFilePermissions(readOnly, {fpUserRead, fpUserExec})
    let e = refuses(proc () =
      writeAttribute(readOnly / TsmInblobAttr, boundBytes, "inblob",
                     "<gate>"))
    check e.kind == tseAttributeUnwritable
    setFilePermissions(readOnly, {fpUserRead, fpUserWrite, fpUserExec})

  test "the bytes offered to an attribute reach it whole":
    let b = newBench()
    writeAttribute(b.dir / TsmInblobAttr, boundBytes, "inblob", "<gate>")
    check readFile(b.dir / TsmInblobAttr) == boundBytes

suite "the live surface, on a machine that has none":

  test "THIS MACHINE EXPOSES NO SUCH SURFACE, and the gate says so":
    # The honest statement, asserted rather than written in a comment.
    # If this ever fails, this host has grown a confidential-computing
    # root of trust and everything this gate says about what it could
    # not exercise needs re-reading.
    check not dirExists(TsmReportRoot)

  test "the probe names the directory an operator should look for":
    let p = newConfigfsTsmSource().sourceProbe()
    check not p.ready
    check TsmReportRoot in p.detail
    # And it is the PATH that is named, not merely the fact of absence.
    check "no " & TsmReportRoot in p.detail

  test "asking for a document on such a machine refuses by naming it":
    let e = refuses(proc () =
      discard readTsmReport(newConfigfsTsmSource(), boundBytes))
    check e.kind == tseSurfaceAbsent
    check TsmReportRoot in e.msg

  test "an entry that cannot be made is refused, and the root is named":
    # The surface EXISTS and is not writable — the shape a machine is in
    # when the guest lacks permission on the entry directory.
    let b = newBench()
    let root = b.dir / "surface"
    createDir(root)
    setFilePermissions(root, {fpUserRead, fpUserExec})
    let e = refuses(proc () =
      discard readTsmReport(newConfigfsTsmSource(root = root), boundBytes))
    check e.kind == tseEntryNotCreated
    check root in e.msg
    setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})

  test "a probe on a surface that DOES exist reports ready":
    # The other side of the probe, so it is not a procedure that always
    # says no.
    let b = newBench()
    let root = b.dir / "present-surface"
    createDir(root)
    let p = newConfigfsTsmSource(root = root).sourceProbe()
    check p.ready
    check root in p.detail

suite "the census":

  test "every rule is either reached here or named as needing hardware":
    # A partition, not a subtraction. A rule in neither set is a rule
    # nobody gave an input; a rule in both is a rule the live-only list
    # is lying about. Either is red.
    var live: set[TsmErrorKind] = {}
    for k in LiveOnly: live.incl k
    var missing: seq[string] = @[]
    for k in TsmErrorKind:
      if k notin reached and k notin live: missing.add $k
    check missing == newSeq[string]()
    var both: seq[string] = @[]
    for k in TsmErrorKind:
      if k in reached and k in live: both.add $k
    check both == newSeq[string]()
    check cardOf(reached) + LiveOnly.len == ord(high(TsmErrorKind)) + 1
    check cardOf(reached) == 17
    check LiveOnly.len == 1

  test "the one rule with no input here, and why no device supplies one":
    # Named in a case rather than left to a census line, because
    # "cannot be tested" is a claim and a claim needs a sentence. The
    # claim is narrower than it looks: a short write is not beyond a
    # device's power — `/dev/full` accepts nothing — it is beyond
    # `writeAttribute`'s power to SEE, because the write is
    # stdio-buffered and `File.close` discards `fclose`. See this gate's
    # header; the repair belongs in the writer, not in this case.
    check LiveOnly == [tseShortWrite]
    check tseShortWrite notin reached

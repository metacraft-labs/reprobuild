## The kernel's unified attestation-report surface, and the discipline
## that makes a report read off it an answer to the question this
## process asked.
##
## ## What the surface is
##
## A confidential guest on Linux does not talk to its security processor
## through a device ioctl any more. The kernel exposes one filesystem
## interface for every such root of trust: a caller makes a directory
## under ``/sys/kernel/config/tsm/report``, writes the bytes it wants
## bound into ``inblob``, and reads the signed document back out of
## ``outblob``. The directory's ``provider`` attribute says which root
## answered; ``auxblob`` carries whatever endorsement material the host
## loaded beside it.
##
## Two roots answer on it and this module carries both, because the
## transport is genuinely one transport: the difference between them is
## the shape of the bytes that come back, and that belongs to whichever
## backend reads them rather than to the file that fetched them.
##
## ## The one rule that is not obvious, and is the whole reason this
## module exists
##
## **The directory is shared state, and a report read from it is not
## necessarily a report about the bytes you wrote.**
##
## Nothing in the interface ties a write to the read that follows it.
## Two processes — or one process and a careless retry — writing the
## same entry interleave, and the second write wins: the reader then
## gets a correctly signed, entirely genuine report that binds somebody
## else's 64 bytes. It verifies. It is worthless, and worse than
## worthless, because it verifies.
##
## The kernel's answer is a counter. Every write to any attribute of an
## entry increments its ``generation``, and the documented protocol is
## to read that counter and compare it against the number of writes you
## performed yourself. `checkTsmGeneration` is that comparison, and it
## is a pure function of three readings and a count precisely so that it
## can be exercised without a kernel that has the counter. Three
## distinct things can have gone wrong and each has its own refusal:
##
##   * the entry was **not fresh** — it already carried writes when this
##     process created it, so the name collided with somebody else's
##     entry and everything below is about their session;
##   * a **concurrent writer** landed between this process's own writes,
##     so what ``inblob`` finally held is not what this process put
##     there;
##   * the entry was **rewritten between the write and the read**, so
##     the report in ``outblob`` was regenerated for a different
##     question.
##
## They are three rules and not one because the remedies differ: the
## first is a naming collision, the second and third are races against a
## different process, and an operator reading the refusal needs to know
## which.
##
## ## What this module does NOT do
##
##   * **It parses nothing.** ``outblob`` is bytes here. What is in them
##     is the business of `snp_backend` and `tdx_backend`, which know
##     which document their provider produces.
##   * **It verifies no signature**, for the reason the driver seam
##     gives: the agent runs inside the thing being trusted.
##   * **It fetches no collateral.** ``auxblob`` is what the host
##     already loaded. Reaching a vendor's distribution point is the
##     verifier's business, on the verifier's network.
##
## ## What can and cannot be exercised without the hardware
##
## `ConfigfsTsmSource` is the live path: it makes the directory, writes,
## reads and removes it. It cannot run on a machine whose kernel has no
## such provider, and on such a machine it refuses by naming the path
## that is absent. Its `sourceProbe` is written so that the refusal is
## the useful one — an operator gets the directory to look for rather
## than the word "unavailable".
##
## `CapturedTsmSource` is the offline path, and it is the same shape
## `CapturedTpm2Source` is: it reads ``outblob``, ``auxblob`` and
## ``provider`` from files that a machine with the hardware already
## produced. It synthesizes no document. What it does supply directly is
## the three generation readings, because there is no kernel here to
## produce them — that is stated on the type rather than hidden, and it
## is what gives the rule above an input on a machine that cannot race.
##
## ## Mocking
##
## None. A captured source reads real files; the checks run against
## whatever is in them, and a source that returns a stale or foreign
## report is refused by the same rule that would refuse a misbehaving
## device.

import std/[options, os, strutils]

import ./binding
import ./driver

const
  TsmReportRoot* = "/sys/kernel/config/tsm/report"
    ## Where the kernel mounts the surface. A path and not a device
    ## node: the entry is a directory, and the operations on it are
    ## `mkdir`, `write`, `read` and `rmdir`.

  TsmInblobAttr* = "inblob"
  TsmOutblobAttr* = "outblob"
  TsmAuxblobAttr* = "auxblob"
  TsmProviderAttr* = "provider"
  TsmGenerationAttr* = "generation"
  TsmPrivlevelAttr* = "privlevel"

  SevSnpProviderName* = "sev_guest"
    ## What the security-processor provider calls itself.
  TdxProviderName* = "tdx_guest"
    ## What the trust-domain provider calls itself.

  MaxTsmEvidenceBase64* = 1_048_576
    ## The envelope's evidence bound, restated here as a number rather
    ## than reached for through `report`'s constant.
    ##
    ## This is deliberate and it is the one place in this module where a
    ## duplicate is the right answer. A bound checked against the
    ## constant that produced it passes however that constant is
    ## changed, and widening the envelope's bound must NOT silently
    ## widen what a root of trust is allowed to hand this process. The
    ## driver seam checks the envelope's own bound separately; if the
    ## two ever disagree the smaller one wins, and both are stated.

  MaxTsmOutblobBytes* = (MaxTsmEvidenceBase64 div 4) * 3
    ## The bound in raw bytes: base64 is four characters per three.

type
  TsmErrorKind* = enum
    ## One kind per rule. The messages satisfy the property
    ## `tsmMessagesAreDistinguishable` states and checks — **no message
    ## is a substring of any other** — so a test matching on a fragment
    ## of one refusal cannot be satisfied by a different refusal.
    ##
    ## There is exactly ONE kind per raise site and exactly one raise
    ## site per kind. That is not tidiness: a census over kinds and a
    ## census over sites differ precisely when a kind is raised twice,
    ## and then a site reached never is paid for by a site reached
    ## twice. The gate proves the correspondence by scanning this
    ## module rather than assuming it.
    tseSourceUnlabelled
    tseSourceProbeUnimplemented
    tseSourceReportUnimplemented
    tseSurfaceAbsent
    tseEntryNotCreated
    tseEntryNotFresh
    tseConcurrentWriter
    tseRegeneratedBetweenWriteAndRead
    tseUnknownProvider
    tseWrongReportDataWidth
    tseEmptyOutblob
    tseOutblobTooLarge
    tseAttributeUnopenable
    tseAttributeOverran
    tseGenerationNotANumber
    tseAttributeUnwritable
    tseShortWrite
    tseCapturedAttributeAbsent

  TsmError* = object of CatchableError
    kind*: TsmErrorKind

const
  TsmMessage*: array[TsmErrorKind, string] = [
    tseSourceUnlabelled:
      "a source of hardware evidence was built without a label, and the " &
      "label is what an operator reads when a machine will not attest",
    tseSourceProbeUnimplemented:
      "this source cannot say whether the machine is able to attest, " &
      "because it does not implement the readiness question",
    tseSourceReportUnimplemented:
      "this source cannot obtain a document, because it does not " &
      "implement the one operation the transport consists of",
    tseSurfaceAbsent:
      "this kernel exposes no unified attestation-report directory, so " &
      "there is no root of trust here to ask",
    tseEntryNotCreated:
      "the report entry could not be made, so nothing was asked of the " &
      "root of trust",
    tseEntryNotFresh:
      "the report entry already carried writes when this process made " &
      "it, so the name collided with a session somebody else owns",
    tseConcurrentWriter:
      "another writer changed the report entry while this process was " &
      "still writing it, so what the root of trust finally read is not " &
      "what this process put there",
    tseRegeneratedBetweenWriteAndRead:
      "the report entry was rewritten between this process writing the " &
      "bound bytes and reading the document, so the document that came " &
      "back answers a question somebody else asked",
    tseUnknownProvider:
      "the entry names a provider this build has no reader for, and " &
      "guessing which document came back is how a reader comes to " &
      "parse one structure as another",
    tseWrongReportDataWidth:
      "the bytes offered for binding are not the width the discipline " &
      "binds",
    tseEmptyOutblob:
      "the root of trust produced an empty document, and an empty " &
      "document is an absent one wearing a present one's name",
    tseOutblobTooLarge:
      "the root of trust produced more bytes than a report envelope " &
      "will carry",
    tseAttributeUnopenable:
      "an attribute of a report entry could not be opened, so the " &
      "document this process would return is one it never saw whole",
    tseAttributeOverran:
      "an attribute of a report entry kept producing bytes past the " &
      "largest document that can be carried, so reading it to the end " &
      "would be letting the machine choose how much memory to take",
    tseGenerationNotANumber:
      "the entry's write counter does not read as a number, so there " &
      "is no way to tell whether anything raced this process",
    tseAttributeUnwritable:
      "an attribute of a report entry could not be opened for writing, " &
      "so the bytes to be bound were never offered to the hardware",
    tseShortWrite:
      "fewer bytes reached an attribute than were offered to it, so " &
      "what the hardware was asked to bind is a truncation of what " &
      "this process meant to bind",
    tseCapturedAttributeAbsent:
      "a captured attribute is not on disk, so this source has no " &
      "recorded evidence to offer"]

proc tsmMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another. Checked rather than asserted:
  ## this is the property that makes an ``in e.msg`` assertion mean one
  ## rule, and it is the shape that has defeated gates in this tree
  ## repeatedly.
  for a in TsmErrorKind:
    for b in TsmErrorKind:
      if a == b: continue
      if TsmMessage[a] in TsmMessage[b]: return false
  true

proc tsmFail*(kind: TsmErrorKind; detail: string) {.noreturn.} =
  var e = newException(TsmError, TsmMessage[kind])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.kind = kind
  raise e

type
  TsmProvider* = enum
    ## The two roots of trust this build reads documents from. The
    ## strings are what the kernel writes into ``provider`` and are
    ## matched exactly: a provider named by prefix would let
    ## ``sev_guest_v2`` be read as ``sev_guest``.
    tsmSevSnp = SevSnpProviderName
    tsmTdx = TdxProviderName

  TsmGenerationReading* = object
    ## The three values of the entry's counter this process observed,
    ## and how many writes it performed itself.
    ##
    ## A record rather than three arguments because the rule reads all
    ## of them and a caller that passed two of three would be asking a
    ## different question without saying so.
    atOpen*: uint64
      ## Read immediately after the entry was created. A fresh entry's
      ## counter is zero.
    afterWrites*: uint64
      ## Read after this process finished writing.
    afterRead*: uint64
      ## Read after ``outblob`` was read.
    writesPerformed*: int
      ## How many attribute writes this process made. The counter moves
      ## once per write, so this is the value ``afterWrites`` must hold.

  TsmReportBytes* = object
    ## What one pass over the surface returned.
    outblob*: string
      ## The signed document, RAW bytes, exactly as the root of trust
      ## produced it. Never re-serialised.
    auxblob*: Option[string]
      ## The endorsement material the host loaded beside it, when the
      ## entry has any. ``none`` and an empty string are different
      ## answers and this module keeps them different: a provider that
      ## offers no auxiliary blob is not a provider that offered an
      ## empty one.
    provider*: TsmProvider
    generation*: TsmGenerationReading

  TsmSource* = ref object of RootObj
    ## Where a confidential-computing driver's bytes come from.
    ##
    ## Separate from the drivers because the drivers' job is the checks
    ## on the document, and those are the same whether the bytes arrive
    ## from a live entry or from files a capture wrote. Folding the
    ## filesystem dance into the driver would make every check
    ## untestable without the hardware.
    sourceLabel: string

proc initTsmSource*(s: TsmSource; label: string) =
  if label.len == 0:
    tsmFail(tseSourceUnlabelled, "a source was built with an empty label")
  s.sourceLabel = label

proc label*(s: TsmSource): string = s.sourceLabel

# ---------------------------------------------------------------------
# The rule
# ---------------------------------------------------------------------

proc checkTsmGeneration*(g: TsmGenerationReading; label: string) =
  ## Whether the document this process read answers the question this
  ## process asked. Raises if it does not.
  ##
  ## Pure, and deliberately so: the race it defends against needs two
  ## processes and a kernel counter to *occur*, and needs neither to be
  ## *described*. A rule reachable only on hardware nobody has is a
  ## constant.
  ##
  ## The order of the three tests is the order the events happen in, and
  ## that matters: a collided entry explains the other two, so reporting
  ## a concurrent writer on an entry that was never fresh would name the
  ## symptom and hide the cause.
  if g.atOpen != 0'u64:
    tsmFail(tseEntryNotFresh,
      label & ": the entry's counter was " & $g.atOpen &
      " when this process created it and a new entry's counter is 0")
  if g.afterWrites != uint64(g.writesPerformed):
    tsmFail(tseConcurrentWriter,
      label & ": this process performed " & $g.writesPerformed &
      " write(s) and the entry's counter stands at " & $g.afterWrites)
  if g.afterRead != g.afterWrites:
    tsmFail(tseRegeneratedBetweenWriteAndRead,
      label & ": the counter was " & $g.afterWrites &
      " when the bound bytes had been written and " & $g.afterRead &
      " when the document had been read")

proc parseTsmProvider*(name: string; label: string): TsmProvider =
  ## The provider's own name, matched exactly.
  ##
  ## The kernel writes it with a trailing newline, which is stripped
  ## here and nowhere else, so every caller compares the same string.
  let trimmed = name.strip()
  for p in TsmProvider:
    if $p == trimmed: return p
  var known: seq[string] = @[]
  for p in TsmProvider: known.add $p
  tsmFail(tseUnknownProvider,
    label & ": the entry names " & trimmed.escape() &
    " and this build reads " & known.join(", "))

# ---------------------------------------------------------------------
# The source seam
# ---------------------------------------------------------------------

method sourceProbe*(s: TsmSource): BackendReadiness {.base.} =
  tsmFail(tseSourceProbeUnimplemented, s.label)

method sourceReport*(s: TsmSource; reportData: string): TsmReportBytes
    {.base.} =
  ## One pass over the surface: write the bytes, read the document.
  ##
  ## Call it through `readTsmReport`, never directly. The generation
  ## rule and the bounds are the seam's contract and not any one
  ## source's, and a source invoked around them is a source whose output
  ## nothing checked.
  tsmFail(tseSourceReportUnimplemented, s.label)

proc readTsmReport*(s: TsmSource; reportData: string): TsmReportBytes =
  ## The only way a driver obtains bytes from this surface.
  ##
  ## The checks are here rather than in each source for the reason
  ## `acquireQuote`'s are in the seam: a source handed the wrong number
  ## of bytes has been mis-called and a source returning something no
  ## envelope can carry has misbehaved, and catching either here means
  ## the failure names the source at the moment it happened.
  if reportData.len != ReportDataSize:
    tsmFail(tseWrongReportDataWidth,
      s.label & ": offered " & $reportData.len & " bytes and the " &
      "discipline binds exactly " & $ReportDataSize)

  result = s.sourceReport(reportData)

  checkTsmGeneration(result.generation, s.label)

  if result.outblob.len == 0:
    tsmFail(tseEmptyOutblob, s.label & ": " & TsmOutblobAttr & " is empty")
  if result.outblob.len > MaxTsmOutblobBytes:
    tsmFail(tseOutblobTooLarge,
      s.label & ": " & $result.outblob.len & " bytes, against a bound of " &
      $MaxTsmOutblobBytes)

# ---------------------------------------------------------------------
# Reading a configfs attribute
# ---------------------------------------------------------------------

proc readWholeAttribute*(path, what, label: string): string =
  ## Read one attribute to end of file.
  ##
  ## Explicitly, rather than through `readFile`, and the reason is a
  ## correctness argument rather than a difference anybody can observe
  ## on an ordinary file.
  ##
  ## A configfs binary attribute carries no inode size, so a read sized
  ## from `stat` asks for zero bytes and gets them. The only length that
  ## is right is the one the reads themselves report. Nim's `readFile`
  ## happens to fall back to a loop in exactly that case, so on this
  ## interface it would in fact work — but it would work by a branch the
  ## filesystem chose for it, and the bound below has to be enforced
  ## DURING the read and not after it. A single sized read cannot
  ## enforce a bound at all: by the time it returns, the allocation the
  ## bound exists to prevent has already happened.
  ##
  ## Stated plainly because the gate cannot separate the two on a
  ## regular file, where they agree: what the gate CAN separate is the
  ## loop from a read that stops after one chunk, and the bound from no
  ## bound.
  var f: File
  if not f.open(path, fmRead):
    tsmFail(tseAttributeUnopenable, label & ": " & what & " at " & path)
  defer: f.close()
  var chunk = newString(4096)
  while true:
    let got = f.readBuffer(addr chunk[0], chunk.len)
    if got <= 0: break
    result.add chunk[0 ..< got]
    if result.len > MaxTsmOutblobBytes:
      tsmFail(tseAttributeOverran,
        label & ": " & what & " at " & path & " has produced " &
        $result.len & " bytes, past the bound of " & $MaxTsmOutblobBytes)

# ---------------------------------------------------------------------
# The live path
# ---------------------------------------------------------------------

type
  ConfigfsTsmSource* = ref object of TsmSource
    ## One pass over a real entry: make it, write it, read it, remove it.
    ##
    ## The entry is created per call and removed on every exit path,
    ## including the failing ones. A process that left entries behind
    ## would be a process whose next call collides with its own previous
    ## one, which is exactly the `tseEntryNotFresh` condition — so the
    ## teardown is not tidiness, it is the other half of the rule.
    root: string
    namePrefix: string
    privilegeLevel: Option[int]
      ## Written to ``privlevel`` when set. It is a property of the
      ## machine's configuration and never of a request: a caller who
      ## could choose the privilege level could choose the one whose
      ## report says the least.

var tsmEntrySequence: int
  ## Distinguishes two entries this process makes in the same second.
  ## The process identifier distinguishes them across processes; this
  ## distinguishes them within one, and a name that repeated would be a
  ## process colliding with its own previous session — which the
  ## freshness rule would then report as somebody else's.

proc newConfigfsTsmSource*(root = TsmReportRoot;
                           namePrefix = "reproos-attest";
                           privilegeLevel = none(int)): ConfigfsTsmSource =
  result = ConfigfsTsmSource(root: root, namePrefix: namePrefix,
                             privilegeLevel: privilegeLevel)
  initTsmSource(result, "configfs:" & root)

proc entryRoot*(s: ConfigfsTsmSource): string = s.root

method sourceProbe*(s: ConfigfsTsmSource): BackendReadiness =
  ## Names the directory that is missing rather than reporting that
  ## something is.
  ##
  ## It makes no entry, writes nothing and reads no document, so asking
  ## whether the machine can attest is not a way to consume its ability
  ## to. An operator looking at a machine that will not attest needs the
  ## path; a probe that answered "not ready" would send them looking for
  ## it.
  if dirExists(s.root):
    BackendReadiness(ready: true,
      detail: "confidential-computing report entries at " & s.root)
  else:
    BackendReadiness(ready: false,
      detail: "no " & s.root &
        "; this kernel exposes no confidential-computing root of trust, " &
        "so this machine has no hardware evidence to offer")

proc readGeneration*(path, label: string): uint64 =
  ## The entry's write counter.
  ##
  ## Exported because it is one of the three operations the live pass is
  ## made of, and on a machine with no such provider it is the only way
  ## its refusal has an input at all. See this module's gate: those
  ## rules are reached AT THE OPERATION rather than through a live pass,
  ## and the difference is stated rather than glossed.
  let raw = readWholeAttribute(path, TsmGenerationAttr, label).strip()
  try:
    result = uint64(parseBiggestUInt(raw))
  except ValueError:
    tsmFail(tseGenerationNotANumber,
      label & ": " & TsmGenerationAttr & " reads " & raw.escape())

proc writeAttribute*(path, value, what, label: string) =
  ## Offer bytes to one attribute. Exported for the reason above.
  var f: File
  if not f.open(path, fmWrite):
    tsmFail(tseAttributeUnwritable,
      label & ": " & what & " at " & path)
  defer: f.close()
  if value.len > 0:
    let put = f.writeBuffer(unsafeAddr value[0], value.len)
    if put != value.len:
      tsmFail(tseShortWrite,
        label & ": " & $put & " of " & $value.len & " bytes reached " &
        what & " at " & path)

method sourceReport*(s: ConfigfsTsmSource; reportData: string):
                    TsmReportBytes =
  if not dirExists(s.root):
    tsmFail(tseSurfaceAbsent, s.label & ": no " & s.root)

  inc tsmEntrySequence
  let entry = s.root / (s.namePrefix & "-" & $getCurrentProcessId() & "-" &
                        $tsmEntrySequence)
  try:
    createDir(entry)
  except OSError as e:
    tsmFail(tseEntryNotCreated, s.label & ": " & entry & ": " & e.msg)
  defer:
    try: removeDir(entry)
    except OSError: discard

  var g = TsmGenerationReading()
  g.atOpen = readGeneration(entry / TsmGenerationAttr, s.label)

  if s.privilegeLevel.isSome:
    writeAttribute(entry / TsmPrivlevelAttr, $s.privilegeLevel.get,
                   TsmPrivlevelAttr, s.label)
    inc g.writesPerformed
  writeAttribute(entry / TsmInblobAttr, reportData, TsmInblobAttr, s.label)
  inc g.writesPerformed

  g.afterWrites = readGeneration(entry / TsmGenerationAttr, s.label)

  result.provider = parseTsmProvider(
    readWholeAttribute(entry / TsmProviderAttr, TsmProviderAttr, s.label),
    s.label)
  result.outblob = readWholeAttribute(entry / TsmOutblobAttr,
                                      TsmOutblobAttr, s.label)
  let auxPath = entry / TsmAuxblobAttr
  if fileExists(auxPath):
    let aux = readWholeAttribute(auxPath, TsmAuxblobAttr, s.label)
    # An attribute the provider exposes but leaves empty is NOT an
    # offered-and-empty blob; it is the provider declining to offer one,
    # and the envelope distinguishes the two.
    if aux.len > 0: result.auxblob = some(aux)

  g.afterRead = readGeneration(entry / TsmGenerationAttr, s.label)
  result.generation = g

# ---------------------------------------------------------------------
# The offline path
# ---------------------------------------------------------------------

type
  CapturedTsmSource* = ref object of TsmSource
    ## Reads a document, its auxiliary blob and its provider name from
    ## files that a machine WITH the hardware already produced.
    ##
    ## This is the shape a capture leaves behind: the same three
    ## attributes, copied out of an entry, exactly as
    ## `CapturedTpm2Source` reads a quote, a signature and an event log
    ## that a TPM and firmware already wrote. Nothing here synthesizes a
    ## byte of the document.
    ##
    ## The generation readings are the one thing it cannot read off a
    ## capture, because the counter belongs to a kernel object that no
    ## longer exists by the time the files do. They are supplied at
    ## construction and default to the consistent triple, which is what
    ## gives `checkTsmGeneration` an input on a machine that has no
    ## entry to race over. That is stated here rather than implied: on
    ## this path the counters are configuration, and only on the live
    ## path are they observations.
    outblobPath: string
    auxblobPath: string
    providerPath: string
    generation: TsmGenerationReading

proc consistentGeneration*(writes = 1): TsmGenerationReading =
  ## The readings a session nobody raced produces: a fresh entry, a
  ## counter that moved once per write, and nothing after that.
  TsmGenerationReading(atOpen: 0'u64, afterWrites: uint64(writes),
                       afterRead: uint64(writes), writesPerformed: writes)

proc newCapturedTsmSource*(outblobPath, providerPath: string;
                           auxblobPath = "";
                           generation = consistentGeneration()):
                          CapturedTsmSource =
  result = CapturedTsmSource(outblobPath: outblobPath,
                             auxblobPath: auxblobPath,
                             providerPath: providerPath,
                             generation: generation)
  initTsmSource(result, "captured:" & outblobPath)

method sourceProbe*(s: CapturedTsmSource): BackendReadiness =
  var absent: seq[string] = @[]
  for path in [s.outblobPath, s.providerPath]:
    if not fileExists(path): absent.add path
  if absent.len == 0:
    BackendReadiness(ready: true,
      detail: "a captured report at " & s.outblobPath & ", provider named " &
        "at " & s.providerPath)
  else:
    BackendReadiness(ready: false,
      detail: "no " & absent.join(", no ") &
        "; this machine has no captured hardware evidence to offer")

proc readCaptured(path, what, label: string): string =
  if not fileExists(path):
    tsmFail(tseCapturedAttributeAbsent, label & ": " & what & ": " & path)
  readWholeAttribute(path, what, label)

method sourceReport*(s: CapturedTsmSource; reportData: string):
                    TsmReportBytes =
  result.provider = parseTsmProvider(
    readCaptured(s.providerPath, TsmProviderAttr, s.label), s.label)
  result.outblob = readCaptured(s.outblobPath, TsmOutblobAttr, s.label)
  if s.auxblobPath.len > 0 and fileExists(s.auxblobPath):
    let aux = readWholeAttribute(s.auxblobPath, TsmAuxblobAttr, s.label)
    if aux.len > 0: result.auxblob = some(aux)
  result.generation = s.generation

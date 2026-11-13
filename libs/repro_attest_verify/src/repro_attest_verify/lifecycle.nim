## What a verifier's own inputs are worth on the day it runs.
##
## Every other module in this library asks whether a *machine* should be
## believed. This one asks the question that sits underneath all of
## them: the certificates, revocation lists and trusted-computing-base
## documents a verifier judges with are themselves dated artifacts, and
## a verifier holding an expired one is not a strict verifier — it is a
## verifier that has stopped being able to ask its question. The chain
## evaluators already refuse on that (`crNoRevocationData` and its two
## siblings), which is right and which is also the whole problem: the
## refusal arrives one report at a time, on a morning nobody chose, and
## it names the report rather than the operator's stale collateral.
##
## ## Where the dates come from, and why that is the whole design
##
## Every window here is **read out of the artifact's own bytes**. Not
## transcribed into a table beside it, not configured, not passed in.
## A transcribed date is a second description of the same fact and the
## two drift — and they drift silently, because the transcription is the
## thing a reader checks against. So the readers below take the DER or
## the JSON and return the window it states; a caller that wants to
## record a window in a table records what these returned, and a gate
## that wants to check the table re-derives it.
##
## The one thing that is NOT read out of the bytes is *now*. It is a
## parameter, as it is everywhere else in this library, because a module
## that reads the clock cannot be tested against a date other than
## today's and a verifier that reads the clock cannot be made to
## reproduce a verdict.
##
## ## Five statuses, and why "unbounded" is not "current"
##
## `lsNoStatedEnd` exists so that an artifact with no end date is
## reported as what it is rather than folded into `lsCurrent`. The two
## are very different facts about a revocation list: a certificate must
## carry `notAfter` (DER makes the field mandatory), but a CRL's
## `nextUpdate` is OPTIONAL, and a list with no `nextUpdate` is a list
## that never goes stale *and never becomes current either* — which is
## exactly why `trust.nim` and `snp_chain.nim` both skip such a list
## rather than honour it. Folding the two together here would have this
## module report "current" for the one document those evaluators refuse
## to use.
##
## ## The refresh horizon
##
## `lsDueForRefresh` is the status this module exists for. An artifact
## that expires tomorrow and an artifact that expired yesterday produce
## the same build failure and the same surprise; the difference is that
## one of them could have been refreshed in working hours. So a window
## whose end falls inside the horizon is reported as due, with the
## instruction to refresh it, while it is still valid — `isUsable`
## stays true and no verdict changes.
##
## The horizon is *proportional*, and that is a repair rather than a
## refinement: a flat thirty days is longer than the entire stated
## lifetime of some of the documents in this corpus, and for those the
## announcement was true from the hour they were issued. See
## `effectiveHorizon`.
##
## ## Drift
##
## `driftOf` is the other half of the same job and deliberately has
## nothing to do with time. A pinned vendor artifact can stop being the
## one the vendor serves without any date moving: a revocation list
## gains an entry, a firmware package is rebuilt, a mirror is withdrawn.
## The decision is a digest comparison; what this module adds is that
## the *classification* decides what a difference MEANS. A stable
## protocol vector that no longer matches its publisher is a defect in
## the pin. A live endpoint's response that no longer matches is
## expected — a re-fetch of a live endpoint returns different bytes and
## reading that as a refutation is the mistake this enumeration exists
## to stop somebody making.
##
## ## Mocking
##
## None. Real DER, real dates, a pure decision over values read out of
## real bytes.

import std/[strutils, times]

import ./x509

type
  LifecycleClass* = enum
    ## What KIND of pinned artifact a row describes, which is what
    ## decides whether a difference from the publisher is a defect.
    lcProtocolVector = "protocol-vector"
      ## Bytes a standards body published and will never change. A
      ## difference is a defect in the pin, always.
    lcTrustRoot = "trust-root"
      ## A root of trust: a vendor's self-signed certificate or a
      ## distribution service's chain. Long-lived, rotated rarely, and
      ## rotated in public. A difference is a rotation to investigate,
      ## never something to accept silently.
    lcVendorCollateral = "vendor-collateral"
      ## Revocation lists and trusted-computing-base documents. These
      ## are REISSUED on a schedule; a difference is expected and the
      ## pin is what needs refreshing.
    lcHistoricalVintage = "historical-vintage"
      ## Vendor collateral pinned BECAUSE it is old. A corpus that holds
      ## one vintage of a document proves that this build reads the
      ## vintage it happens to hold; two vintages, issued years apart,
      ## prove that the reader is reading the FORMAT. So some of these
      ## documents are kept at an issue date long past, and their expiry
      ## is the property they are there for rather than a state to get
      ## out of — refreshing one would delete the second vintage and
      ## leave the corpus unable to make the claim.
      ##
      ## It is a separate class and not a note on a `lcVendorCollateral`
      ## row because `needsAttention` is the whole output of the
      ## scheduled monitor: a document that is expired on purpose,
      ## reported as needing attention every week forever, is the
      ## crying-wolf failure the classification exists to prevent, and
      ## the complement — reporting nothing — is worse. The class says
      ## which, and `expiryNeedsAttention` below is where it is spent.
      ##
      ## The claim has teeth in the other direction too. A row in this
      ## class that is NOT expired is a row misclassified to quieten it,
      ## and both this build's gate and the scheduled monitor refuse it.
    lcGenuineCapture = "genuine-capture"
      ## A report, quote or log a real machine produced once. It cannot
      ## be re-fetched and a live endpoint asked again answers with a
      ## DIFFERENT document, which is not a refutation of this one.
    lcMintedNegative = "minted-negative"
      ## Bytes this repository produced in order to be refused. It has
      ## no publisher and no upstream, so there is nothing to compare it
      ## against and `driftOf` refuses rather than answering.
    lcDerivedReading = "derived-reading"
      ## A value computed here from another pinned artifact by an
      ## independent tool — the point on a curve an enclave document's
      ## leaf carries, read out with somebody else's implementation.
      ## Its input cannot move without a row of its own moving, so it
      ## has no publisher either, and `driftOf` refuses it for the same
      ## reason.

  LifecycleWindow* = object
    ## When an artifact states it is usable between. Both ends are
    ## optional because the two documents this library reads differ: a
    ## certificate's `notAfter` is mandatory in DER, a revocation
    ## list's `nextUpdate` is not.
    hasNotBefore*: bool
    notBefore*: int64
    hasNotAfter*: bool
    notAfter*: int64

  LifecycleStatus* = enum
    lsNotYetInForce = "not-yet-in-force"
    lsCurrent = "current"
    lsDueForRefresh = "due-for-refresh"
    lsExpired = "expired"
    lsNoStatedEnd = "no-stated-end"

  DriftOutcome* = enum
    doUnchanged = "unchanged"
    doDrifted = "drifted"
    doExpectedToDiffer = "expected-to-differ"

  LifecycleError* = object of CatchableError
    ## Raised for an artifact whose dates this build will not read. The
    ## reader is whoever pinned it.

const
  SecondsPerDay = 86_400
    ## NOT exported, and that is a deliberate one-line decision rather
    ## than an oversight. `snp_tcb` already exports a constant of this
    ## name, `repro_attest_verify` re-exports both modules, and two
    ## exported constants with one name make every consumer of the
    ## umbrella that says `SecondsPerDay` ambiguous — which is exactly
    ## what happened to a neighbouring gate the first time this module
    ## exported it. A day is 86,400 seconds in both places; the name is
    ## the scarce thing, not the number.

  DefaultRefreshHorizonDays* = 30
    ## How far ahead an expiry is announced, at most. Thirty days is a
    ## month of working days, which is the unit a collateral refresh is
    ## actually scheduled in; a shorter horizon announces a deadline
    ## that has already passed for anyone on holiday.
    ##
    ## It is a CEILING and not the horizon itself — see
    ## `effectiveHorizon`, which is the repair for a defect this
    ## constant had on its own.

  IsoInstantFormat* = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    ## The one spelling of an instant this module reads out of a
    ## vendor's JSON. Strict on purpose: a reader that accepted several
    ## spellings would accept a document whose date it read wrong.

proc window*(notBefore, notAfter: int64): LifecycleWindow =
  ## A window with both ends stated.
  LifecycleWindow(hasNotBefore: true, notBefore: notBefore,
                  hasNotAfter: true, notAfter: notAfter)

proc windowEndingNever*(notBefore: int64): LifecycleWindow =
  ## A window whose end the artifact did not state. See `lsNoStatedEnd`.
  LifecycleWindow(hasNotBefore: true, notBefore: notBefore,
                  hasNotAfter: false, notAfter: 0)

proc parseIsoInstant*(s, what: string): int64 =
  ## An RFC 3339 instant in the one spelling above, as seconds.
  try:
    result = parse(s, IsoInstantFormat, utc()).toTime().toUnix()
  except CatchableError:
    raise newException(LifecycleError,
      what & " is " & s.escape() & "; this build reads an instant " &
      "written as " & IsoInstantFormat & " and nothing else, because a " &
      "reader that accepted several spellings would accept a document " &
      "whose date it read wrong")

proc windowOfCertificate*(der: string): LifecycleWindow =
  ## The validity window a certificate states, read out of the
  ## certificate. Both ends are always present: `parseCertificate`
  ## refuses a certificate whose validity sequence is incomplete, and
  ## refuses one whose `notAfter` does not follow its `notBefore`.
  let cert = parseCertificateBytes(der)
  window(cert.notBefore, cert.notAfter)

proc windowOfRevocationList*(der: string): LifecycleWindow =
  ## The currency window a revocation list states. `nextUpdate` is
  ## OPTIONAL in the format, so a list without one produces a window
  ## with no end — which `classify` reports as `lsNoStatedEnd`, the
  ## status the chain evaluators act on by setting that list aside.
  let crl = parseCrlBytes(der)
  if crl.hasNextUpdate: window(crl.thisUpdate, crl.nextUpdate)
  else: windowEndingNever(crl.thisUpdate)

proc windowOfIssueAndNextUpdate*(issueDate, nextUpdate: string):
    LifecycleWindow =
  ## The window a vendor's trusted-computing-base document states, from
  ## the two members it states it in. Taken as STRINGS because that is
  ## how `tdx_collateral` exposes them — it reads them out of the
  ## signed payload and deliberately judges neither, leaving the
  ## decision here.
  window(parseIsoInstant(issueDate, "the document's issue date"),
         parseIsoInstant(nextUpdate, "the document's next-update date"))

proc effectiveHorizon*(w: LifecycleWindow; horizonSeconds: int64): int64 =
  ## How far ahead THIS artifact's expiry is announced: the lesser of
  ## the caller's horizon and half the artifact's own stated lifetime.
  ##
  ## ## Why a horizon cannot be a flat number
  ##
  ## An announcement that is true for an artifact's whole life is not an
  ## announcement. It was measured rather than reasoned about: every
  ## trusted-computing-base document and platform revocation list one of
  ## these vendors serves states a next-update EXACTLY thirty days after
  ## its issue date, so under a flat thirty-day horizon not one of them
  ## is ever `lsCurrent` — it is born due for refresh and stays due until
  ## it expires. A scheduled run over such a corpus reports the same
  ## rows every week from the day it is switched on, and a report that
  ## has never once been empty cannot say that something changed. That
  ## is the defect this procedure repairs, and it is the same shape as
  ## `driftOf`'s: the value of a signal is in what it does NOT say.
  ##
  ## Half, specifically, because half is the largest fraction that
  ## guarantees the quiet period is at least as long as the warning
  ## period. A larger one leaves a window too short to be news; a
  ## smaller one throws away lead time this corpus has no spare of.
  ##
  ## This NARROWS the warning and never the validity: `lsExpired`,
  ## `isUsable` and every evaluator's refusal are untouched, and an
  ## artifact's expiry date is still read out of its own bytes. The only
  ## thing that moves is the day the announcement starts.
  if not (w.hasNotBefore and w.hasNotAfter): return horizonSeconds
  let lifetime = w.notAfter - w.notBefore
  if lifetime <= 0: return horizonSeconds
  min(horizonSeconds, lifetime div 2)

proc classify*(w: LifecycleWindow; nowSeconds: int64;
               horizonSeconds = int64(DefaultRefreshHorizonDays) *
                                int64(SecondsPerDay)): LifecycleStatus =
  ## Where `nowSeconds` falls in `w`.
  ##
  ## The order of the tests is the order the facts matter in. A window
  ## that has not opened is reported as that whatever its end says,
  ## because an artifact from the future is a clock problem and naming
  ## its expiry would send the reader after the wrong thing.
  if w.hasNotBefore and nowSeconds < w.notBefore:
    return lsNotYetInForce
  if not w.hasNotAfter:
    return lsNoStatedEnd
  if nowSeconds >= w.notAfter:
    return lsExpired
  if nowSeconds + effectiveHorizon(w, horizonSeconds) >= w.notAfter:
    return lsDueForRefresh
  lsCurrent

proc isUsable*(s: LifecycleStatus): bool =
  ## Whether an artifact in this state still judges anything.
  ##
  ## `lsDueForRefresh` is usable and that is the point of it: announcing
  ## an expiry must not BE the expiry, or the announcement is the
  ## outage it was supposed to prevent. `lsNoStatedEnd` is NOT usable,
  ## because the evaluators that meet such a document set it aside.
  s in {lsCurrent, lsDueForRefresh}

proc needsAttention*(s: LifecycleStatus): bool =
  ## Whether a scheduled monitor should report this row. The complement
  ## of `lsCurrent`, written out rather than negated, so a status added
  ## to the enumeration has to be placed in one of the two by hand.
  s in {lsNotYetInForce, lsDueForRefresh, lsExpired, lsNoStatedEnd}

proc expiryNeedsAttention*(class: LifecycleClass; status: LifecycleStatus):
    bool =
  ## Whether a scheduled run should report this (class, status) pair
  ## LOUDLY, as opposed to printing it and moving on.
  ##
  ## `needsAttention` answers the question for a status alone and is
  ## still the right answer for every class but one. A
  ## `lcHistoricalVintage` row is pinned BECAUSE it has expired, so
  ## `lsExpired` is the state it is supposed to be in and reporting it
  ## is noise — while any OTHER status for it contradicts the class,
  ## which is a louder finding than the one it displaces rather than a
  ## quieter one.
  if class == lcHistoricalVintage:
    return status != lsExpired
  needsAttention(status)

proc daysBetween(a, b: int64): int64 =
  ## Whole days from `a` to `b`, rounded toward zero.
  (b - a) div int64(SecondsPerDay)

proc refreshInstruction*(name: string; class: LifecycleClass;
                         status: LifecycleStatus; w: LifecycleWindow;
                         nowSeconds: int64; origin, refreshWith: string):
    string =
  ## What a reader of a failing scheduled run has to do, in one
  ## sentence: which artifact, what state it is in, when it entered or
  ## enters it, where it came from, and the command that replaces it.
  ##
  ## Every one of those five is here because a message missing it sends
  ## the reader somewhere else first. `origin` and `refreshWith` are
  ## the caller's, because this module knows about dates and not about
  ## where anybody's bytes live.
  if refreshWith.len == 0:
    raise newException(LifecycleError,
      "refresh instruction for " & name & " carries no remedy; a report " &
      "that names a stale artifact without saying how to replace it is " &
      "a notification, not an instruction")
  result = name & ": " & $status
  case status
  of lsExpired:
    result.add " since " & $utc(fromUnix(w.notAfter)).format(IsoInstantFormat) &
      " (" & $daysBetween(w.notAfter, nowSeconds) & " days ago)"
  of lsDueForRefresh:
    result.add ", expires " &
      $utc(fromUnix(w.notAfter)).format(IsoInstantFormat) & " (in " &
      $daysBetween(nowSeconds, w.notAfter) & " days)"
  of lsNotYetInForce:
    result.add " until " &
      $utc(fromUnix(w.notBefore)).format(IsoInstantFormat) &
      "; check this machine's clock before refreshing anything"
  of lsNoStatedEnd:
    result.add "; every evaluator in this build sets such a document " &
      "aside rather than honouring it"
  of lsCurrent:
    result.add ", expires " &
      $utc(fromUnix(w.notAfter)).format(IsoInstantFormat)
  result.add ". It is " & $class & " from " & origin &
    ". Refresh it with: " & refreshWith

proc driftOf*(class: LifecycleClass; pinnedSha256, observedSha256: string):
    DriftOutcome =
  ## What a difference between the pinned bytes and the publisher's
  ## current bytes MEANS.
  ##
  ## The classification carries the whole decision, which is the point.
  ## A monitor that reported every difference identically would cry
  ## wolf on `lcGenuineCapture` — where a difference is the expected
  ## result of asking a live endpoint a second time — until nobody read
  ## it, and the one class where a difference is a real defect
  ## (`lcProtocolVector`) would be lost in the noise.
  ##
  ## Two classes have no publisher at all, and this procedure REFUSES
  ## them rather than returning `doUnchanged` for whatever digest it is
  ## handed. A comparison against nothing is not a comparison, and an
  ## answer of "unchanged" for an artifact nobody went and looked at is
  ## the honest-absence shape wearing a verdict's clothes.
  if pinnedSha256.len == 0 or observedSha256.len == 0:
    raise newException(LifecycleError,
      "a drift comparison needs two digests; one of them is empty, and " &
      "an absent observation is not an observation of no change")
  case class
  of lcMintedNegative, lcDerivedReading:
    raise newException(LifecycleError,
      $class & " has no publisher to compare against: it is produced " &
      "here, from inputs this repository already pins, so there is no " &
      "second party whose answer a difference could be a difference FROM")
  of lcProtocolVector, lcTrustRoot, lcVendorCollateral, lcHistoricalVintage:
    # A historical vintage sits here rather than beside `lcGenuineCapture`
    # for a reason worth stating: its publisher is a project's committed
    # test data at a named commit, which cannot answer differently. So a
    # difference IS a defect in the pin, exactly as for the two above —
    # the class quietens its EXPIRY and nothing else.
    if pinnedSha256 == observedSha256: doUnchanged else: doDrifted
  of lcGenuineCapture:
    if pinnedSha256 == observedSha256: doUnchanged else: doExpectedToDiffer

proc driftInstruction*(name: string; class: LifecycleClass;
                       outcome: DriftOutcome;
                       pinnedSha256, observedSha256, origin,
                       refreshWith: string): string =
  ## The same shape as `refreshInstruction`, for the other half.
  result = name & ": " & $outcome
  case outcome
  of doUnchanged:
    result.add " at " & pinnedSha256
    return
  of doDrifted:
    result.add " — pinned " & pinnedSha256 & ", " & origin & " now serves " &
      observedSha256
  of doExpectedToDiffer:
    result.add " — pinned " & pinnedSha256 & ", " & origin & " answered " &
      observedSha256 & ", which for " & $class &
      " is a second answer and not a refutation of the first"
  result.add ". Refresh it with: " & refreshWith

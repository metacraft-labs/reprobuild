## Two decisions that sit between a verified report and a verdict: does
## the report belong to the certificate that endorsed it, and is the
## platform version it states one this verifier still accepts.
##
## ## Binding, before anything about versions
##
## A verified signature says "the holder of this key signed these bytes".
## It does not say the key is the one the chain endorsed, and it does not
## say the report and the certificate describe the same part. Two fields
## say that, and both are inside signed documents:
##
##   * the report's chip identity against the endorsement certificate's,
##     which ties the document to the physical part; and
##   * the report's stated platform version against the version the
##     certificate was *issued for*, which is what stops an endorsement
##     minted for one version being presented beside a report claiming
##     another.
##
## The second is the one worth spelling out. AMD will issue an
## endorsement key for any version a caller asks for, so a fleet can hold
## certificates for several. Without this check a machine could present
## last week's report beside a certificate for a newer version and read
## as patched.
##
## ## The floor, and the window
##
## A floor is four byte-wide component levels; a report is below it if
## any component is. That much is a comparison.
##
## The window is the part that needs care, and it needs it in one
## specific place: **what dates it**. A grace window exists because
## raising a floor does not patch a fleet — there is a gap between the
## two, and a verifier that refuses the whole fleet on the day the floor
## moves is a verifier an operator turns off. So a report below the floor
## is accepted for a bounded time *after the floor took effect*.
##
## "After the floor took effect" is a date the **verifier** holds. It is
## emphatically not one taken from the evidence, and the tempting
## candidate is worth naming so that nobody reaches for it later: the
## endorsement certificate's `notBefore` looks like the instant the
## vendor endorsed this part at this version, and it is not — the vendor
## issues an endorsement on demand for whatever version is asked for, so
## a machine that wanted a fresh window could simply request a fresh
## certificate for its old version and get one. Anchoring a grace window
## on that field would hand the machine being judged control of how long
## it is excused.
##
## So `floorEffectiveAt` is a parameter, supplied by the caller from its
## own configuration, and a non-positive value grants **no grace at all**
## whatever the day count says. A window with no start is not a window.
##
## ## What is NOT wired yet, stated plainly
##
## `AttestationPolicy` carries `allowGraceDays` and this module is its
## first consumer — before this it was parsed, bounded, and read by
## nothing. It does **not** carry a floor-effective date, so the caller
## supplies that separately. Giving the policy document a key for it is
## a change to a fail-closed reader that four existing documents would
## have to grow, and it is not done here.
##
## ## Mocking
##
## None. Pure decision over values another module read out of real bytes.

import std/[strutils]

import ./policy
import ./snp_chain
import ./snp_report

type
  SnpBindingOutcome* = enum
    sboBound
    sboChipIdentityDisagrees
    sboPlatformVersionDisagrees

  SnpBindingVerdict* = object
    outcome*: SnpBindingOutcome
    detail*: string

  SnpTcbOutcome* = enum
    stoAtOrAboveFloor
    stoBelowFloorWithinGrace
    stoBelowFloorOutsideGrace
    stoBelowFloorWithNoWindow

  SnpTcbVerdict* = object
    outcome*: SnpTcbOutcome
    detail*: string
    below*: seq[string]
      ## Which components are below, named with both numbers. Empty
      ## exactly when the outcome is `stoAtOrAboveFloor`.
    graceDays*: int
    graceEndsAt*: int64
      ## The last instant a below-floor report is accepted at, inclusive.
      ## Zero when no window was in force.
    flagged*: bool
      ## True whenever the floor was not met, whatever the window said.
      ## An acceptance inside a window is an acceptance that has to stay
      ## visible: it is the one place this verifier says yes to a
      ## platform its own policy calls too old.

const
  SecondsPerDay* = 86_400

proc isAcceptance*(v: SnpTcbVerdict): bool =
  v.outcome in {stoAtOrAboveFloor, stoBelowFloorWithinGrace}

proc isBound*(v: SnpBindingVerdict): bool = v.outcome == sboBound

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc bindReportToEndorsement*(report: SnpReport;
                              chain: AmdChainVerdict): SnpBindingVerdict =
  ## Whether an accepted chain endorses THIS report.
  ##
  ## Takes the chain's verdict rather than its leaf certificate, so it
  ## cannot be called on a chain that was never evaluated: the fields it
  ## reads are populated only on the path that reaches an acceptance.
  if report.chipId.len != chain.hwId.len or
     hexOf(report.chipId) != hexOf(chain.hwId):
    result.outcome = sboChipIdentityDisagrees
    result.detail = "the report names part " & hexOf(report.chipId) &
      " and the endorsement certificate was issued for " &
      hexOf(chain.hwId) & "; these are two different parts"
    return
  let r = report.reportedTcb
  let e = chain.endorsedTcb
  if r.bootloader != e.bootloader or r.tee != e.tee or
     r.snp != e.snp or r.microcode != e.microcode:
    result.outcome = sboPlatformVersionDisagrees
    result.detail = "the report states " & $r &
      " and the endorsement certificate was issued for bootloader " &
      $e.bootloader & ", tee " & $e.tee & ", snp " & $e.snp &
      ", microcode " & $e.microcode &
      "; an endorsement issued for one platform version is not evidence " &
      "about another"
    return
  result.outcome = sboBound
  result.detail = "the report and the endorsement certificate name part " &
    hexOf(report.chipId) & " at " & $r

proc evaluateSnpTcb*(reported: SnpTcbVersion;
                     floor: SevSnpTcbMinimum;
                     allowGraceDays: int;
                     floorEffectiveAt, nowSeconds: int64): SnpTcbVerdict =
  ## The floor, and the window if the floor is not met.
  ##
  ## `floorEffectiveAt` is the caller's instant, not the evidence's; see
  ## this module's header for why that distinction is the whole design.
  result.graceDays = allowGraceDays
  if reported.bootloader < floor.bootloader:
    result.below.add "bootloader " & $reported.bootloader & " < " &
      $floor.bootloader
  if reported.tee < floor.tee:
    result.below.add "tee " & $reported.tee & " < " & $floor.tee
  if reported.snp < floor.snp:
    result.below.add "snp " & $reported.snp & " < " & $floor.snp
  if reported.microcode < floor.microcode:
    result.below.add "microcode " & $reported.microcode & " < " &
      $floor.microcode

  if result.below.len == 0:
    result.outcome = stoAtOrAboveFloor
    result.detail = "the reported platform version (" & $reported &
      ") is at or above every component of this verifier's floor"
    return

  result.flagged = true
  if allowGraceDays <= 0 or floorEffectiveAt <= 0:
    result.outcome = stoBelowFloorWithNoWindow
    result.detail = "the reported platform version is below the floor (" &
      result.below.join(", ") & ") and no grace window is in force" &
      (if allowGraceDays <= 0: ", because the policy allows none"
       else: ", because no instant was given for the floor taking effect") &
      "; a window with no start is not a window"
    return

  result.graceEndsAt =
    floorEffectiveAt + int64(allowGraceDays) * int64(SecondsPerDay)
  if nowSeconds <= result.graceEndsAt:
    result.outcome = stoBelowFloorWithinGrace
    result.detail = "the reported platform version is below the floor (" &
      result.below.join(", ") & ") and this verification is being made " &
      "at " & $nowSeconds & ", inside the " & $allowGraceDays &
      "-day window that ends at " & $result.graceEndsAt &
      "; this is an acceptance of a platform the policy calls too old"
  else:
    result.outcome = stoBelowFloorOutsideGrace
    result.detail = "the reported platform version is below the floor (" &
      result.below.join(", ") & ") and the " & $allowGraceDays &
      "-day window ended at " & $result.graceEndsAt &
      ", which is before " & $nowSeconds

## Usage events, interest and popularity (`Remix-Registry.md` §"Events,
## interest and popularity (M5)").
##
## Events are unlinkable: each carries a nullifier derived from a secret
## that never leaves the installation, scoped to one release, kind and
## day. The aggregator counts distinct nullifiers among events whose
## eligibility verifies, drops events about non-public releases, applies
## retractions, caps bursts against a trailing median and records every
## cap as a correction. Score formulas are provisional (Trust And
## Reputation M0 owns score semantics); the inputs, intervals and
## corrections are published alongside every score.

import std/[algorithm, math, sets, tables]

import ./types
import ./identity

const
  NullifierContext* = "reproos.remix.event-nullifier.v1"
  DefaultBurstFactor* = 5.0
    ## A day above `factor * trailing median + floor` is capped there.
  DefaultBurstFloor* = 20
  DefaultWindowDays* = 28
  ViewWeight* = 0.1
    ## Views count toward interest at a tenth of an explicit interest.

type
  EventKind* = enum
    ekView = 1
    ekInterest = 2
    ekFollow = 3
    ekInstall = 4
    ekActive = 5
    ekHealthy = 6
    ekRollback = 7
    ekUninstall = 8
    ekReport = 9
    ekReview = 10
    ekCompositionReuse = 11
    ekRetract = 12

  UsageEvent* = object
    kind*: EventKind
    release*: Digest32
    epoch*: uint32
      ## UTC day number.
    nullifier*: Digest32
    eligibility*: seq[byte]
      ## Opaque proof checked by the configured verifier (spec OD-11).
    retracts*: EventKind
      ## For `ekRetract`: the kind of the event withdrawn (same nullifier
      ## derivation, so only its sender can name it).

  Correction* = object
    release*: Digest32
    kind*: EventKind
    epoch*: uint32
    observed*, capped*: int
    reason*: string

  ReleaseScores* = object
    release*: Digest32
    counts*: array[EventKind, int]
      ## Distinct, eligible, non-retracted, burst-capped counts over the
      ## window.
    popularity*: float
      ## Wilson lower bound of the healthy share, times distinct active days.
    popularityInterval*: (float, float)
    interest*: float
    reviewed*: bool

  AggregateConfig* = object
    windowEnd*: uint32
      ## Last epoch included.
    windowDays*: int
    burstFactor*: float
    burstFloor*: int
    publicReleases*: HashSet[Digest32]
    reviewed*: HashSet[Digest32]
      ## Releases with a credible review: interest is not reported.
    verifyEligibility*: proc (e: UsageEvent): bool

  AggregateReport* = object
    scores*: seq[ReleaseScores]
    corrections*: seq[Correction]
    dropped*: array[EventKind, int]
      ## Events not counted, by kind, for any reason (published total only).

proc putU32(d: var seq[byte]; v: uint32) =
  for i in 0 ..< 4: d.add byte((v shr (8 * i)) and 0xff)

proc eventNullifier*(installationSecret: openArray[byte]; release: Digest32;
                     kind: EventKind; epoch: uint32): Digest32 =
  ## Client side. The secret stays on the installation.
  var tail: seq[byte]
  tail.add release
  tail.add byte(ord(kind))
  tail.putU32(epoch)
  domainDigest(NullifierContext, @installationSecret, tail)

proc wilson(successes, trials: int; z = 1.96): (float, float) =
  ## Wilson score interval for a binomial proportion.
  ## https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval#Wilson_score_interval
  if trials == 0: return (0.0, 1.0)
  let n = float(trials)
  let p = float(successes) / n
  let denom = 1 + z * z / n
  let centre = (p + z * z / (2 * n)) / denom
  let half = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
  (max(0.0, centre - half), min(1.0, centre + half))

proc median(xs: seq[int]): float =
  if xs.len == 0: return 0
  var s = xs
  s.sort()
  if s.len mod 2 == 1: float(s[s.len div 2])
  else: (float(s[s.len div 2 - 1]) + float(s[s.len div 2])) / 2

proc aggregate*(events: seq[UsageEvent]; cfg: AggregateConfig): AggregateReport =
  let windowDays = (if cfg.windowDays > 0: cfg.windowDays else: DefaultWindowDays)
  let factor = (if cfg.burstFactor > 0: cfg.burstFactor else: DefaultBurstFactor)
  let floor = (if cfg.burstFloor > 0: cfg.burstFloor else: DefaultBurstFloor)
  let windowStart = (if cfg.windowEnd + 1 >= uint32(windowDays):
                       cfg.windowEnd + 1 - uint32(windowDays) else: 0'u32)
  # 1. Eligibility, publicity, window; retractions collected separately.
  var retracted = initHashSet[(Digest32, EventKind)]()
  var accepted: seq[UsageEvent]
  for e in events:
    if e.kind == ekRetract:
      if cfg.verifyEligibility(e):
        retracted.incl (e.nullifier, e.retracts)
      continue
    if not cfg.verifyEligibility(e) or e.release notin cfg.publicReleases or
       e.epoch > cfg.windowEnd:
      inc result.dropped[e.kind]
      continue
    accepted.add e
  # 2. Distinct nullifiers per (release, kind, epoch), minus retractions.
  #    The nullifier already binds release, kind and epoch, so a replay or
  #    a second event from one installation the same day is one entry.
  var daily = initTable[(Digest32, EventKind, uint32), HashSet[Digest32]]()
  for e in accepted:
    if (e.nullifier, e.kind) in retracted:
      inc result.dropped[e.kind]
      continue
    daily.mgetOrPut((e.release, e.kind, e.epoch), initHashSet[Digest32]()).incl e.nullifier
  # 3. Burst caps against the trailing median of the preceding days.
  var perRelease = initTable[Digest32, array[EventKind, int]]()
  var keys: seq[(Digest32, EventKind, uint32)]
  for k in daily.keys: keys.add k
  keys.sort(proc (a, b: (Digest32, EventKind, uint32)): int =
    result = cmp(ord(a[1]), ord(b[1]))
    if result == 0: result = cmp(a[2], b[2]))
  for (release, kind, epoch) in keys:
    if epoch < windowStart: continue
    var history: seq[int]
    var d = epoch
    for back in 1 .. windowDays:
      if d == 0: break
      dec d
      history.add daily.getOrDefault((release, kind, d)).len
    let observed = daily[(release, kind, epoch)].len
    let bound = int(factor * median(history)) + floor
    var counted = observed
    if observed > bound:
      counted = bound
      result.corrections.add Correction(release: release, kind: kind, epoch: epoch,
        observed: observed, capped: bound,
        reason: "burst above " & $factor & "x trailing median + " & $floor)
    var row = perRelease.getOrDefault(release)
    row[kind] += counted
    perRelease[release] = row
  # 4. Scores.
  var releases: seq[Digest32]
  for r in perRelease.keys: releases.add r
  releases.sort(proc (a, b: Digest32): int =
    for i in 0 ..< 32:
      if a[i] != b[i]: return cmp(a[i], b[i])
    0)
  for r in releases:
    let c = perRelease[r]
    var s = ReleaseScores(release: r, counts: c, reviewed: r in cfg.reviewed)
    let trials = c[ekHealthy] + c[ekRollback] + c[ekUninstall]
    s.popularityInterval = wilson(c[ekHealthy], trials)
    s.popularity = s.popularityInterval[0] * float(c[ekActive])
    if not s.reviewed:
      s.interest = float(c[ekInterest] + c[ekFollow]) + ViewWeight * float(c[ekView])
    result.scores.add s

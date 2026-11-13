## ReproOS-Remix-Protocol-And-Registry M5 verification
## ``test_remix_interest_and_popularity_event_integrity``.
##
## "Legitimate events update the correct aggregates while replay,
## self-traffic, bot bursts, and deleted or private data do not inflate
## ranking."
##
## Eligibility is a set of issued tokens checked by membership. That is a
## stand-in, justified: the eligibility mechanism is open decision OD-11
## (anonymous tokens versus an account-backed issuer), and the aggregator's
## contract is only "count nothing whose eligibility does not verify",
## which a membership check exercises exactly. Nullifiers are the real
## derivation clients use.

import std/[sets, unittest]

import repro_remix

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

let releaseA = d32(1)        # installed and used
let releaseB = d32(2)        # unreviewed, people want it reviewed
let reviewed = d32(3)        # has a credible review
let privateR = d32(4)        # not in the public index

var issued = initHashSet[seq[byte]]()

proc installation(n: int): seq[byte] =
  result = @[byte(n), byte(n shr 8), 0x5a, 0xa5]
  issued.incl result         # eligible: a token was issued for it

proc ev(secret: seq[byte]; kind: EventKind; release: Digest32; day: uint32;
        token: seq[byte] = @[]): UsageEvent =
  UsageEvent(kind: kind, release: release, epoch: day,
    nullifier: eventNullifier(secret, release, kind, day),
    eligibility: (if token.len > 0: token else: secret))

proc config(): AggregateConfig =
  AggregateConfig(windowEnd: 30, windowDays: 28,
    publicReleases: toHashSet([releaseA, releaseB, reviewed]),
    reviewed: toHashSet([reviewed]),
    verifyEligibility: proc (e: UsageEvent): bool = e.eligibility in issued)

proc scoreOf(r: AggregateReport; id: Digest32): ReleaseScores =
  for s in r.scores:
    if s.release == id: return s

# A steady baseline: 10 installations use A every day; 6 ask for B's review.
var baseline: seq[UsageEvent]
for i in 0 ..< 10:
  let s = installation(i)
  baseline.add ev(s, ekInstall, releaseA, 10)
  for day in 10'u32 .. 30:
    baseline.add ev(s, ekActive, releaseA, day)
  baseline.add ev(s, ekHealthy, releaseA, 30)
for i in 10 ..< 16:
  baseline.add ev(installation(i), ekInterest, releaseB, 20)
  baseline.add ev(installation(i), ekInterest, reviewed, 20)

suite "Remix M5 — interest and popularity event integrity":

  test "legitimate events update the right aggregates":
    let r = aggregate(baseline, config())
    let a = r.scoreOf(releaseA)
    check a.counts[ekInstall] == 10
    check a.counts[ekActive] == 10 * 21
    check a.counts[ekHealthy] == 10
    check a.popularity > 0
    check r.scoreOf(releaseB).interest == 6.0
    # Interest is for unreviewed work only; popularity and interest differ.
    check r.scoreOf(reviewed).interest == 0.0
    check r.scoreOf(releaseB).popularity == 0.0
    check r.corrections.len == 0

  test "replays count once":
    var replayed = baseline
    for i in 0 ..< 20: replayed.add baseline
    let r = aggregate(replayed, config())
    check r.scoreOf(releaseA).counts[ekActive] == 10 * 21
    check r.scoreOf(releaseB).interest == 6.0

  test "self-traffic is bounded to one count per installation per day":
    var events = baseline
    let author = installation(999)
    for i in 0 ..< 500:
      events.add ev(author, ekInterest, releaseB, 20)
    check aggregate(events, config()).scoreOf(releaseB).interest == 7.0

  test "ineligible bots count nothing; an eligible burst is capped and recorded":
    var events = baseline
    for i in 0 ..< 5000:
      events.add ev(@[byte(i), byte(i shr 8), 0x01], ekInterest, releaseB, 20)  # no token
    let bots = aggregate(events, config())
    check bots.scoreOf(releaseB).interest == 6.0
    check bots.dropped[ekInterest] >= 5000
    # A campaign of 400 freshly eligible accounts in one day.
    var campaign = baseline
    for day in 10'u32 .. 29:
      campaign.add ev(installation(2000 + int(day)), ekInterest, releaseB, day)
    for i in 0 ..< 400:
      campaign.add ev(installation(3000 + i), ekInterest, releaseB, 30)
    let r = aggregate(campaign, config())
    check r.corrections.len == 1
    check r.corrections[0].release == releaseB
    check r.corrections[0].observed == 400
    check r.corrections[0].capped < 400
    check r.scoreOf(releaseB).interest < 6.0 + 20 + 400

  test "private releases and retracted events do not count":
    var events = baseline
    for i in 0 ..< 50:
      events.add ev(installation(500 + i), ekInterest, privateR, 20)
    let withPrivate = aggregate(events, config())
    check withPrivate.scoreOf(privateR).release != privateR   # absent
    check withPrivate.dropped[ekInterest] == 50
    # Three of the six who asked for B's review withdraw it.
    var retracting = baseline
    for i in 10 ..< 13:
      let s = installation(i)
      retracting.add UsageEvent(kind: ekRetract, release: releaseB, epoch: 20,
        nullifier: eventNullifier(s, releaseB, ekInterest, 20), eligibility: s,
        retracts: ekInterest)
    check aggregate(retracting, config()).scoreOf(releaseB).interest == 3.0

  test "rollbacks and uninstalls lower popularity through the healthy share":
    var unhealthy = baseline
    for i in 0 ..< 10:
      unhealthy.add ev(installation(i), ekRollback, releaseA, 29)
    check aggregate(unhealthy, config()).scoreOf(releaseA).popularity <
          aggregate(baseline, config()).scoreOf(releaseA).popularity

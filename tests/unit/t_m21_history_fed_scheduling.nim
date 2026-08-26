## M21: the ARITHMETIC of the point-in-time queries and of the two
## history-fed schedulers, over rows constructed by hand.
##
## Gate (``reprobuild-specs/RunQuota-Observation-Store.milestones.org``
## §M21): "``stats last-pass`` reports the last passing execution with
## timestamp, revision, and host. ``stats new-failures`` partitions
## current failures into new versus long-standing, reported PER HOST as
## well as pooled ... Adaptive timeouts (§17.4) and duration-based
## sharding (§17.5) read from the shared store, with the documented
## fallback when a test has no history."
##
## **WHAT THIS FILE IS FOR, AND WHAT IT DELIBERATELY IS NOT.** Its
## companion ``tests/integration/t_m21_point_in_time_queries.nim`` proves
## the queries and the schedulers read the REAL shared store, written by
## the REAL runner across TWO REAL host identities. That is the part that
## cannot be faked and it is where the gate's per-host fixture lives.
##
## It is also the part that cannot assert arithmetic to the millisecond:
## a real test's duration is measured, and a bound compared against a
## measured-then-percentiled quantity is the "threshold against a sampled
## quantity" construction §"WHERE THE VACUOUS CHECKS COME FROM" lists
## fourth — it fails on correct code when the sample is unlucky and
## passes on broken code for the same reason.
##
## So the split is deliberate: THE NUMBERS ARE PINNED HERE, where every
## duration is a literal and no clock is involved, and the INTEGRATION is
## proven there. Neither file's assertions can be satisfied by the
## other's implementation.
##
## NO MOCKS. ``GenericTestRow`` is the query interface's own decoded row
## type, the same value ``readGenericTestRows`` produces from the wire;
## constructing one is not substituting a component, it is naming the
## input. Every proc under test below is the one the runner and the
## ``stats`` subcommands call — there is no test-only variant.

import std/[algorithm, sequtils, tables, unittest]

import repro_test_stats

proc row(testId, status, host: string; startedAt: int64;
         durationMs = -1; commit = ""; execution = ""): GenericTestRow =
  ## One execution, spelled out. ``durationMs < 0`` means the runner
  ## reported none — SQL NULL, not zero — which is the distinction the
  ## duration statistics and therefore the adaptive timeouts rest on.
  result = GenericTestRow(
    executionId: (if execution.len > 0: execution
                  else: testId & "@" & host & "@" & $startedAt),
    hostId: host,
    profileId: "profile-" & host,
    testId: testId,
    suite: "m21",
    status: status,
    attempt: 1,
    startedAtUnixMillis: startedAt,
    startedAtKnown: true)
  if durationMs >= 0:
    result.durationMs = durationMs
    result.durationKnown = true
  if commit.len > 0:
    result.gitCommit = commit
    result.gitBranch = "main"
    result.revisionKnown = true

const
  HostA = "host-aaaa"
  HostB = "host-bbbb"

suite "M21 last-pass over constructed rows":

  test "reports the timestamp, revision and host of the last PASS":
    let rows = @[
      row("t::one", "pass", HostA, 1_000, commit = "rev-old"),
      row("t::one", "fail", HostA, 2_000, commit = "rev-mid"),
      # The most recent pass is NOT the most recent execution, which is
      # the whole reason the query exists: a reader who could take the
      # last row would not need it.
      row("t::one", "pass", HostB, 3_000, commit = "rev-newpass"),
      row("t::one", "fail", HostB, 4_000, commit = "rev-newest")]
    let answer = lastPass(rows, "t::one")
    check answer.found
    check answer.everSeen
    check answer.startedAtUnixMillis == 3_000
    check answer.hostId == HostB
    check answer.revision == "rev-newpass"
    check answer.revisionKnown
    check answer.branch == "main"
    check answer.executions == 4

  test "a test that ran and never passed is NOT the same answer as one that never ran":
    ## The two states §17.3's "did this ever work here" turns on. An
    ## implementation that returned "not found" for both would answer a
    ## mistyped test name and a permanently red test identically.
    let rows = @[
      row("t::red", "fail", HostA, 1_000, commit = "rev-1"),
      row("t::red", "timeout", HostA, 2_000, commit = "rev-2")]
    let red = lastPass(rows, "t::red")
    check red.everSeen
    check not red.found
    check red.executions == 2
    let absent = lastPass(rows, "t::nosuchtest")
    check not absent.everSeen
    check not absent.found
    check absent.executions == 0

  test "a pass with no recorded revision reports UNKNOWN, never an empty revision":
    ## §17.3: "A key with no history returns *unknown* rather than zero."
    ## The same rule one field down: a runner that did not know its
    ## revision must not be reported as having run at revision "".
    let rows = @[row("t::norev", "pass", HostA, 1_000)]
    let answer = lastPass(rows, "t::norev")
    check answer.found
    check not answer.revisionKnown
    check answer.revision == RevisionUnknown
    check answer.revision.len > 0

  test "xfail is not a pass and skip is not a verdict":
    ## ``xpass`` IS a pass (the code worked); ``xfail`` is a recorded
    ## expectation of failure and ``skip`` produced no verdict at all.
    ## Admitting either into ``last-pass`` would answer "yes it worked"
    ## about a run in which it did not.
    let rows = @[
      row("t::x", "xfail", HostA, 1_000, commit = "rev-1"),
      row("t::x", "skip", HostA, 2_000, commit = "rev-2")]
    check not lastPass(rows, "t::x").found
    let withXpass = rows & @[row("t::x", "xpass", HostA, 3_000,
      commit = "rev-3")]
    let answer = lastPass(withXpass, "t::x")
    check answer.found
    check answer.revision == "rev-3"

suite "M21 new-failures: pooled and per host":

  ## THE FIXTURE IS THE GATE'S OWN, IN MINIATURE. ``t::split`` passes on
  ## one host and fails on another; every other test here exists to stop
  ## the disagreement it produces from being something this
  ## implementation reports about everything.
  setup:
    let rows = @[
      # Passes on A, fails on B. The B failure is the most recent
      # execution overall, so the POOLED view sees a current failure.
      row("t::split", "pass", HostA, 1_000, commit = "rev-1"),
      row("t::split", "pass", HostA, 2_000, commit = "rev-2"),
      row("t::split", "fail", HostB, 3_000, commit = "rev-2"),
      # A genuine regression, on ONE host: passed, then failed.
      row("t::regression", "pass", HostA, 1_000, commit = "rev-1"),
      row("t::regression", "fail", HostA, 2_500, commit = "rev-2"),
      # A SECOND DISAGREEING TEST, AND OF A DIFFERENT SHAPE. It fails on
      # BOTH hosts, so ``not-failing-everywhere`` cannot arise; the
      # pooled view still calls it NEW because host A passed it inside
      # the window, while host B has never passed it and calls it
      # LONG-STANDING. That is ``age-differs`` ON ITS OWN, which
      # ``t::split`` never produces in isolation.
      #
      # ITS REAL JOB IS TO MAKE THE ENUMERATION BELOW A COUNT RATHER
      # THAN AN EXISTENCE CHECK. Measured 2026-08-26: with ``t::split``
      # as the only disagreeing test, an implementation that reports
      # disagreements for AT MOST ONE test passes this entire file.
      # Two of them is the smallest fixture that fails it.
      row("t::two", "pass", HostA, 1_000, commit = "rev-1"),
      row("t::two", "fail", HostA, 4_000, commit = "rev-2"),
      row("t::two", "fail", HostB, 3_000, commit = "rev-2"),
      # Red everywhere, always.
      row("t::red", "fail", HostA, 1_000, commit = "rev-1"),
      row("t::red", "fail", HostB, 3_000, commit = "rev-2"),
      # Green everywhere, always.
      row("t::green", "pass", HostA, 1_000, commit = "rev-1"),
      row("t::green", "pass", HostB, 3_000, commit = "rev-2")]

  test "the pooled answer alone would have been wrong about t::split":
    let report = newFailureReport(rows)
    check report.hostIds == @[HostA, HostB]

    var pooledAges = initTable[string, string]()
    for entry in report.pooled:
      pooledAges[entry.testId] = $entry.age
    # POOLED SAYS: a new failure. A reader with only this column starts
    # bisecting rev-1..rev-2.
    check pooledAges.getOrDefault("t::split") == "new"

    var hostAges = initTable[string, string]()
    for entry in report.perHost:
      hostAges[entry.testId & "@" & entry.hostId] = $entry.age
    # PER HOST SAYS: on the only host that fails it, it has NEVER passed.
    # That is not a regression; it is a machine that cannot run this
    # test, and no revision in the window is implicated.
    check hostAges.getOrDefault("t::split@" & HostB) == "long-standing"
    # AND ON THE OTHER HOST IT IS NOT FAILING AT ALL — so the pooled
    # sentence "this test is failing" is not true of host A in any sense.
    check not hostAges.hasKey("t::split@" & HostA)
    # The two verdicts are DIFFERENT WORDS, asserted directly rather than
    # through the disagreement list below: if this line and the report's
    # own bookkeeping ever agreed by construction, the check would be
    # measuring the bookkeeping.
    check pooledAges.getOrDefault("t::split") !=
      hostAges.getOrDefault("t::split@" & HostB)

  test "the disagreement is NAMED, with both of its kinds":
    let report = newFailureReport(rows)
    let split = report.disagreements.filterIt(it.testId == "t::split")
    check split.len == 2
    let kinds = split.mapIt($it.kind).sorted()
    check kinds == @["age-differs", "not-failing-everywhere"]
    for item in split:
      check item.detail.len > 0
      check item.hostId.len > 0
    check split.filterIt(it.kind == dkAgeDiffers)[0].hostId == HostB
    check split.filterIt(it.kind == dkNotFailingEverywhere)[0].hostId == HostA

    # AND THE SECOND DISAGREEING TEST, WHOSE SHAPE IS THE OTHER ONE.
    # ``t::two`` is a current failure on BOTH hosts, so the only thing
    # that can differ is the AGE — and it does. A report that only ever
    # named the "it is fine on that machine" case would miss the reading
    # that matters more here: the pooled column says "you broke it",
    # host B says "it has never worked".
    let two = report.disagreements.filterIt(it.testId == "t::two")
    check two.len == 1
    check two[0].kind == dkAgeDiffers
    check two[0].hostId == HostB
    check two[0].pooledAge == faNew
    check two[0].hostAge == faLongStanding
    check two[0].hostFailing
    check two[0].detail.len > 0

  test "a real regression and a permanently red test produce NO disagreement":
    ## WITHOUT THIS THE PREVIOUS TWO ARMS ARE SATISFIED BY AN
    ## IMPLEMENTATION THAT CALLS EVERYTHING A DISAGREEMENT. Both of these
    ## tests are current failures and both are reported; neither has a
    ## pooled verdict that differs from any host's.
    let report = newFailureReport(rows)
    check report.disagreements.filterIt(it.testId == "t::regression").len == 0
    check report.disagreements.filterIt(it.testId == "t::red").len == 0
    check report.pooled.filterIt(it.testId == "t::regression").len == 1
    check report.pooled.filterIt(it.testId == "t::red").len == 1
    check report.pooled.filterIt(it.testId == "t::regression")[0].age == faNew
    check report.pooled.filterIt(it.testId == "t::red")[0].age == faLongStanding
    # And the per-host partition can say NEW, which is what stops "per
    # host" from being a synonym for "long-standing".
    check report.perHost.filterIt(
      it.testId == "t::regression")[0].age == faNew
    # AND THE SET IS EXACTLY THE TWO DISAGREEING TESTS — no more, and no
    # fewer. Naming the two controls individually is not enough in
    # either direction:
    #
    # * OVER-REPORTING. A comparison made for every (test, host) pair
    #   regardless of whether POOLED reports the test as failing lists a
    #   green test as "not failing everywhere" — true of every test that
    #   is fine, and therefore worthless as a signal. Measured
    #   2026-08-26: dropping the ``pooledFailing`` guard leaves the two
    #   ``filterIt`` checks above GREEN and only this line red.
    #
    # * UNDER-REPORTING, WHICH A ONE-ELEMENT EXPECTATION CANNOT SEE.
    #   Measured the same day: while ``t::split`` was the only
    #   disagreeing test in this fixture, an implementation that stopped
    #   after the FIRST test it found a disagreement for passed every
    #   assertion in this file. A list is only asserted to be a list by
    #   an expectation with two things in it.
    check report.disagreements.mapIt(it.testId).deduplicate() ==
      @["t::split", "t::two"]

  test "a test that is green everywhere appears in neither partition":
    let report = newFailureReport(rows)
    check report.pooled.filterIt(it.testId == "t::green").len == 0
    check report.perHost.filterIt(it.testId == "t::green").len == 0
    # NOR IS IT LISTED AS A DISAGREEMENT. A green test is not evidence
    # that the pooled column misled about anything.
    check report.disagreements.filterIt(it.testId == "t::green").len == 0

  test "the entry carries the revision the test last passed at":
    let report = newFailureReport(rows)
    let regression = report.pooled.filterIt(it.testId == "t::regression")[0]
    check regression.lastPassKnown
    check regression.lastPassRevision == "rev-1"
    let red = report.pooled.filterIt(it.testId == "t::red")[0]
    check not red.lastPassKnown
    check red.lastPassRevision == RevisionUnknown

  test "'current failure' is the LATEST verdict, not 'failed at least once'":
    ## A test that failed and then passed is not a current failure. An
    ## implementation using "has a failure in the window" would list
    ## every flaky test as broken, and the partition would be answering a
    ## question nobody asked.
    let recovered = @[
      row("t::flaky", "fail", HostA, 1_000),
      row("t::flaky", "pass", HostA, 2_000)]
    let report = newFailureReport(recovered)
    check report.pooled.len == 0
    check report.perHost.len == 0

  test "a trailing skip does not read as a pass":
    ## ``skip`` produced no verdict, so the most recent VERDICT is the
    ## failure underneath it.
    let skipped = @[
      row("t::skipped", "fail", HostA, 1_000),
      row("t::skipped", "skip", HostA, 2_000)]
    let report = newFailureReport(skipped)
    check report.pooled.len == 1
    check report.pooled[0].testId == "t::skipped"

suite "M21 adaptive timeouts read history and fall back without it":

  setup:
    var config = defaultAdaptiveTimeoutConfig()
    config.enabled = true
    config.metric = tmP99
    config.multiplier = 3.0
    config.minimumMs = 5_000
    config.fallbackMs = 60_000
    config.globalTimeoutMs = 60_000
    config.runs = 20

  test "§17.4's own worked example, to the millisecond":
    ## The table in §17.4: p99 50ms → 5s (minimum); 4.2s → 12.6s; 15.0s →
    ## 45.0s; 30.0s → 90s capped to 60s. Every input is a literal here,
    ## so every output is arithmetic and none of it is a sample.
    let cases = @[
      (name: "math::simple_add", p99: 50, want: 5_000, source: tsMinimum),
      (name: "parser::large_file", p99: 4_200, want: 12_600, source: tsHistory),
      (name: "database::migration", p99: 15_000, want: 45_000,
       source: tsHistory),
      (name: "network::timeout_test", p99: 30_000, want: 60_000,
       source: tsCapped)]
    for entry in cases:
      # One sample IS the p99 of a one-element set, so the entry below
      # describes exactly the history the table's row assumes.
      let answer = adaptiveTimeoutFor(
        DurationEntry(testId: entry.name, samples: 1, meanMs: float(entry.p99),
          medianMs: entry.p99, p90Ms: entry.p99, p99Ms: entry.p99), config)
      checkpoint(entry.name)
      check answer.timeoutMs == entry.want
      check answer.source == entry.source

  test "no history is the FALLBACK, and a measured zero is not":
    ## THE DISCRIMINATION THIS WHOLE FEATURE RESTS ON. A test with no
    ## history and a test that has always run in under a millisecond both
    ## have a metric of zero; only the first may take the fallback. An
    ## implementation keying on the metric instead of on ``samples``
    ## gives the second one a 60-second timeout and reports it as coming
    ## from history.
    let none = adaptiveTimeoutFor(
      DurationEntry(testId: "t::new", samples: 0), config)
    check none.source == tsFallback
    check none.timeoutMs == 60_000
    let instant = adaptiveTimeoutFor(
      DurationEntry(testId: "t::instant", samples: 12), config)
    check instant.source == tsMinimum
    check instant.timeoutMs == 5_000
    check instant.timeoutMs != none.timeoutMs

  test "the metric selector actually selects":
    let entry = DurationEntry(testId: "t::spread", samples: 10,
      meanMs: 1_000.0, medianMs: 900, p90Ms: 4_000, p99Ms: 9_000)
    var c = config
    c.minimumMs = 0
    c.multiplier = 1.0
    c.globalTimeoutMs = 0
    var seen: seq[int] = @[]
    for metric in [tmMean, tmMedian, tmP90, tmP99]:
      c.metric = metric
      seen.add(adaptiveTimeoutFor(entry, c).timeoutMs)
    check seen == @[1_000, 900, 4_000, 9_000]

  test "every test the caller names gets an answer, including unseen ones":
    ## A proc that returned only the tests it had history for would leave
    ## its caller to invent the rest, and the invention is the risk.
    let rows = @[
      row("t::known", "pass", HostA, 1_000, durationMs = 100),
      row("t::known", "pass", HostA, 2_000, durationMs = 100)]
    let answers = adaptiveTimeouts(rows, ["t::known", "t::unseen"], config)
    check answers.len == 2
    check answers[0].testId == "t::known"
    check answers[0].samples == 2
    check answers[0].source == tsMinimum
    check answers[1].testId == "t::unseen"
    check answers[1].samples == 0
    check answers[1].source == tsFallback

  test "a runner that reported NO duration is not a sample of zero":
    ## The generic layer stores an unreported duration as SQL NULL. Rows
    ## like that must not enter the sample: three NULLs averaged as zero
    ## would look exactly like a test that takes no time, and the
    ## timeout derived from it would be the minimum rather than the
    ## fallback.
    let rows = @[
      row("t::untimed", "pass", HostA, 1_000),
      row("t::untimed", "pass", HostA, 2_000)]
    let answers = adaptiveTimeouts(rows, ["t::untimed"], config)
    check answers[0].samples == 0
    check answers[0].source == tsFallback

  test "the per-test window keeps the RECENT executions":
    ## §17.4 reads "the last N runs". A window that kept the OLDEST N
    ## would derive today's timeout from last month's machine.
    let rows = @[
      row("t::drift", "pass", HostA, 1_000, durationMs = 10_000),
      row("t::drift", "pass", HostA, 2_000, durationMs = 10_000),
      row("t::drift", "pass", HostA, 3_000, durationMs = 40),
      row("t::drift", "pass", HostA, 4_000, durationMs = 40)]
    let recent = recentRowsPerTest(rows, 2)
    check recent.len == 2
    check recent.allIt(it.durationMs == 40)
    check recentRowsPerTest(rows, 0).len == 4

suite "M21 duration-based sharding and its documented fallback":

  test "duration bin-packs by TIME where count would split by COUNT":
    ## The discriminator. One slow test and three fast ones: a count
    ## split puts two in each shard; a duration split puts the slow one
    ## alone. An implementation that ignored the estimates would produce
    ## the count answer while claiming to be a duration plan.
    let tests = @["slow", "f1", "f2", "f3"]
    var estimates = initTable[string, int]()
    estimates["slow"] = 1_000
    estimates["f1"] = 10
    estimates["f2"] = 10
    estimates["f3"] = 10
    let duration = planShards(tests, estimates, 2, ssDuration)
    check duration.applied == ssDuration
    check not duration.fellBack
    check duration.assignment[0] == 0
    check duration.assignment[1] == 1
    check duration.assignment[2] == 1
    check duration.assignment[3] == 1
    check duration.shardEstimateMs == @[1_000, 30]

    let count = planShards(tests, estimates, 2, ssCount)
    check count.applied == ssCount
    check count.assignment == @[0, 1, 0, 1]
    # The two plans DIFFER, which is what makes the first one evidence
    # that the estimates were read.
    check duration.assignment != count.assignment

  test "no history falls back to count, and SAYS it fell back":
    ## §17.5: "When no history is available, ``duration`` falls back to
    ## ``count``." A plan that reported the REQUESTED strategy would make
    ## the fallback invisible, and a CI reader comparing two runs could
    ## not tell a real bin-pack from a count split wearing its name.
    let tests = @["a", "b", "c", "d"]
    let plan = planShards(tests, initTable[string, int](), 2, ssDuration)
    check plan.requested == ssDuration
    check plan.applied == ssCount
    check plan.fellBack
    check plan.reason.len > 0
    check plan.assignment == @[0, 1, 0, 1]
    check plan.withHistory == 0
    check plan.withoutHistory == 4

  test "a partial history does NOT fall back, and the unknowns are counted":
    ## The fallback is for "nothing is known", not for "something is
    ## missing". Falling back on the first unknown test would discard
    ## every estimate the store does have the moment a new test appears.
    let tests = @["known", "unknown"]
    var estimates = initTable[string, int]()
    estimates["known"] = 500
    let plan = planShards(tests, estimates, 2, ssDuration)
    check plan.applied == ssDuration
    check not plan.fellBack
    check plan.withHistory == 1
    check plan.withoutHistory == 1
    # The unknown contributes NO estimated time — it is placed, not
    # guessed at.
    check plan.shardEstimateMs == @[500, 0]

  test "every test lands in exactly one shard, whichever strategy ran":
    let tests = @["a", "b", "c", "d", "e", "f", "g"]
    var estimates = initTable[string, int]()
    estimates["a"] = 90
    estimates["d"] = 5
    for strategy in [ssCount, ssDuration]:
      let plan = planShards(tests, estimates, 3, strategy)
      check plan.assignment.len == tests.len
      var perShard = @[0, 0, 0]
      for shard in plan.assignment:
        check shard >= 0
        check shard < 3
        inc perShard[shard]
      check perShard[0] + perShard[1] + perShard[2] == tests.len

  test "durationEstimates omits a test with no measured duration":
    ## A test absent from the table has no estimate, which is different
    ## from an estimate of zero — and is why the bin-packer can count its
    ## unknowns.
    let rows = @[
      row("t::timed", "pass", HostA, 1_000, durationMs = 40),
      row("t::timed", "pass", HostA, 2_000, durationMs = 60),
      row("t::untimed", "pass", HostA, 1_000)]
    let estimates = durationEstimates(rows)
    check estimates.hasKey("t::timed")
    check not estimates.hasKey("t::untimed")
    # Nearest-rank median of {40, 60} is 40.
    check estimates["t::timed"] == 40

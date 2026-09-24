## A scheduler stuck behind somebody else's RunQuota leases says so, says who,
## and -- where the caller bounds it -- gives up with the same facts.
##
## ## The defect this pins
##
## 2026-09-24: `repro exec -- echo hi` in one workspace hung, silently and with
## no end, for as long as another workspace's `repro build` held the host's
## RunQuota budget. `repro exec` compiles the recipe's provider as an engine
## action, the engine offered it to RunQuota, the daemon QUEUED it ("waiting
## for resource budget"), and the engine's inline-RunQuota wait loop then polled
## for a grant forever: the daemon's queue reason was dropped when the offer
## came back, nothing was printed while waiting, and nothing bounded the wait.
## Every `just` recipe of the Agent Harbor repository runs through `repro exec`,
## so every recipe hung.
##
## The fix makes the wait LOUD (announce once blocked, heartbeat after) and,
## where the caller asks, BOUNDED. This file pins the pure half of that: the
## policy clock, and the rendering of "who holds the budget" from the daemon's
## `leases` inspection document. The e2e half, against a real `runquotad`, is
## `tests/e2e/dev-env/t_e2e_dev_env_runquota_queue_is_loud_and_bounded.nim`.

import std/[os, strutils, unittest]

import repro_runquota

const
  announceAfter = 1_000
  heartbeat = 5_000

suite "the RunQuota queue-wait clock":

  test "not being blocked never says anything, however long it lasts":
    var wait = initRunQuotaQueueWait()
    for now in countup(0, 600_000, 250):
      check stepRunQuotaQueueWait(wait, false, now, announceAfter, heartbeat,
        10_000) == rqwKeepWaiting

  test "a momentary queue stays quiet; a real one is announced exactly once":
    var wait = initRunQuotaQueueWait()
    check stepRunQuotaQueueWait(wait, true, 0, announceAfter, heartbeat,
      0) == rqwKeepWaiting
    check stepRunQuotaQueueWait(wait, true, 999, announceAfter, heartbeat,
      0) == rqwKeepWaiting
    check stepRunQuotaQueueWait(wait, true, 1_000, announceAfter, heartbeat,
      0) == rqwAnnounce
    # Announced once: the ticks right after it are quiet again.
    check stepRunQuotaQueueWait(wait, true, 1_025, announceAfter, heartbeat,
      0) == rqwKeepWaiting

  test "while still blocked it repeats itself every heartbeat, and only then":
    var wait = initRunQuotaQueueWait()
    var announces, heartbeats = 0
    for now in countup(0, 21_000, 25):
      case stepRunQuotaQueueWait(wait, true, now, announceAfter, heartbeat, 0)
      of rqwAnnounce: inc announces
      of rqwHeartbeat: inc heartbeats
      of rqwTimedOut: fail()
      of rqwKeepWaiting: discard
    check announces == 1
    # Announced at 1s, then 6s, 11s, 16s, 21s.
    check heartbeats == 4

  test "an unbounded wait never times out -- but it is never silent either":
    var wait = initRunQuotaQueueWait()
    var spoke = false
    for now in countup(0, 3_600_000, 1_000):
      let verdict = stepRunQuotaQueueWait(wait, true, now, announceAfter,
        heartbeat, 0)
      check verdict != rqwTimedOut
      if verdict in {rqwAnnounce, rqwHeartbeat}:
        spoke = true
    check spoke

  test "a bounded wait times out at the bound, measured from the block":
    var wait = initRunQuotaQueueWait()
    # Some unblocked time first: the clock must start at the BLOCK.
    for now in countup(0, 50_000, 1_000):
      discard stepRunQuotaQueueWait(wait, false, now, announceAfter,
        heartbeat, 12_000)
    var timedOutAt = -1
    for now in countup(60_000, 90_000, 25):
      if stepRunQuotaQueueWait(wait, true, now, announceAfter, heartbeat,
          12_000) == rqwTimedOut:
        timedOutAt = now
        break
    check timedOutAt == 72_000

  test "becoming unblocked resets the clock, so progress is never punished":
    var wait = initRunQuotaQueueWait()
    for now in countup(0, 11_000, 25):
      check stepRunQuotaQueueWait(wait, true, now, announceAfter, heartbeat,
        12_000) != rqwTimedOut
    discard stepRunQuotaQueueWait(wait, false, 11_025, announceAfter,
      heartbeat, 12_000)
    # A fresh block: 11s more of it is still inside the bound.
    for now in countup(11_050, 22_000, 25):
      check stepRunQuotaQueueWait(wait, true, now, announceAfter, heartbeat,
        12_000) != rqwTimedOut

suite "who holds the RunQuota budget":

  # The document `runquota leases --json` returned on the affected host on
  # 2026-09-24, while `repro exec` was failing: two leases whose supervisors
  # had died, pinning 8.7 GiB of a 16 GiB budget, plus a queued candidate.
  const measured = """{"leases":[
    {"id":14,"session_id":8,"candidate_id":2,"label":"npm-vendor-geminiCliSource",
     "command_stats_id":"npm-vendor.registry","state":"supervisor_lost","purpose":"work",
     "resources":{"machine_id":"local","cpu_milli":1000,"memory_bytes":1627105280,
       "hard_memory_limit_bytes":0,"io_class":"ioNormal","process_count":1,
       "named_pools":[{"name":"fetch","units":1}]},
     "peak_memory_bytes":0,"process_count":0,
     "diagnostic":{"code":"diagOk","message":"ok","detail":""}},
    {"id":156,"session_id":150,"candidate_id":1,
     "label":"__repro_interface_extract-e18c686e88a36d03",
     "command_stats_id":"repro interface extract edge","state":"supervisor_lost",
     "purpose":"work","resources":{"machine_id":"local","cpu_milli":1000,
       "memory_bytes":7130977280,"hard_memory_limit_bytes":0,"io_class":"ioNormal",
       "process_count":1,"named_pools":[]},
     "peak_memory_bytes":0,"process_count":0,
     "diagnostic":{"code":"diagOk","message":"ok","detail":""}},
    {"id":201,"session_id":170,"candidate_id":1,"label":"__repro_provider_compile",
     "command_stats_id":"repro provider compile edge","state":"queued","purpose":"work",
     "resources":{"machine_id":"local","cpu_milli":1000,"memory_bytes":134217728,
       "hard_memory_limit_bytes":0,"io_class":"ioNormal","process_count":1,
       "named_pools":[]},
     "peak_memory_bytes":0,"process_count":0,
     "diagnostic":{"code":"diagDenied","message":"waiting for resource budget","detail":""}}
  ]}"""

  test "every lease that holds capacity is named, with its state and size":
    let holders = summarizeRunQuotaLeaseHolders(measured)
    check holders.len == 2
    check holders[0].contains("lease 14")
    check holders[0].contains("\"npm-vendor-geminiCliSource\"")
    check holders[0].contains("session 8")
    check holders[0].contains("state=supervisor_lost")
    check holders[0].contains("cpu=1000m")
    check holders[0].contains("mem=1.5 GiB")
    check holders[0].contains("pool:fetch=1")
    check holders[1].contains("__repro_interface_extract-e18c686e88a36d03")
    check holders[1].contains("mem=6.6 GiB")

  test "a queued candidate is a waiter, not a holder":
    for line in summarizeRunQuotaLeaseHolders(measured):
      check not line.contains("__repro_provider_compile")
      check not line.contains("state=queued")

  test "a diagnostic never fails on a document it cannot read":
    check summarizeRunQuotaLeaseHolders("").len == 0
    check summarizeRunQuotaLeaseHolders("not json").len == 0
    check summarizeRunQuotaLeaseHolders("""{"error":"unknown"}""").len == 0
    check summarizeRunQuotaLeaseHolders("""{"leases":[1,"x",null]}""").len == 0

suite "what the wait and the give-up say":

  let holders = summarizeRunQuotaLeaseHolders("""{"leases":[
    {"id":8,"session_id":8,"label":"another workspace's build","state":"running",
     "resources":{"cpu_milli":2000,"memory_bytes":3221225472,"named_pools":[]}}]}""")

  test "the wait names the action, the reason, the endpoint and the holder":
    let text = runQuotaQueueWaitMessage(@["__repro_provider_compile"],
      "waiting for resource budget", r"\\.\pipe\runquota-test", holders, 6_000)
    check text.startsWith("runquota.waiting __repro_provider_compile")
    check "for 6s" in text
    check "waiting for resource budget" in text
    check r"\\.\pipe\runquota-test" in text
    check "another workspace's build" in text

  test "the give-up names the same facts and every remedy":
    let text = runQuotaQueueTimeoutMessage(@["__repro_provider_compile"],
      "waiting for resource budget", r"\\.\pipe\runquota-test", holders,
      120_000)
    check "gave up after 120s" in text
    check "__repro_provider_compile" in text
    check "another workspace's build" in text
    check "supervisor_lost" in text
    check runQuotaQueueTimeoutEnv in text
    check "REPROBUILD_NO_RUNQUOTA=1" in text

  test "an empty holder list is said, not left blank":
    let text = runQuotaQueueWaitMessage(@["a"], "", "pipe", @[], 1_000)
    check "did not report any lease" in text

suite "the queue bound's knob":

  setup:
    let prior = getEnv(runQuotaQueueTimeoutEnv)
    let priorSet = existsEnv(runQuotaQueueTimeoutEnv)
  teardown:
    if priorSet: putEnv(runQuotaQueueTimeoutEnv, prior)
    else: delEnv(runQuotaQueueTimeoutEnv)

  test "unset keeps the caller's default, including no bound at all":
    delEnv(runQuotaQueueTimeoutEnv)
    check runQuotaQueueTimeoutMs(0) == 0
    check runQuotaQueueTimeoutMs(devEnvRunQuotaQueueTimeoutMsDefault) ==
      devEnvRunQuotaQueueTimeoutMsDefault

  test "a positive value overrides it in either direction":
    putEnv(runQuotaQueueTimeoutEnv, "5000")
    check runQuotaQueueTimeoutMs(0) == 5_000
    check runQuotaQueueTimeoutMs(120_000) == 5_000

  test "a malformed or non-positive value cannot disable the default bound":
    for raw in ["", "abc", "0", "-5"]:
      putEnv(runQuotaQueueTimeoutEnv, raw)
      check runQuotaQueueTimeoutMs(120_000) == 120_000

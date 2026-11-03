## The positive controls of ``e2e_addon_validator_never_double_signs``'s two
## checkers (``validator_safety``), on records whose answer is known: each
## slashing condition is found, a clean history is clean, two databases
## that are each clean but disagree are a conflict, a malformed or foreign
## file is an error rather than "clean", and the lifetime check finds an
## overlap, an instance started inside the polling window and one still
## alive at the end, and passes a clean hand-over. The cgroup order pairs
## an incarnation in which no validator was seen, and the monitor's
## coverage (overflow, `end`, incarnations without a validator) is counted. The VM gate's own
## positive control (a second instance with a fresh database double-signs
## for real and the check finds it) is in the gate.
##
## *Mocking.* None: pure functions over literal records.

import std/[json, strutils, tables, unittest]

import ./validator_safety

const Gvr = "0x270d43e74ce340de4bca2b1936beca0f4f5408d9e78aec4850920baf659d5b69"

proc ic(blocks: seq[(int, string)]; atts: seq[(int, int, string)];
        pk = "0xaa"; gvr = Gvr): JsonNode =
  var bs = newJArray()
  for (s, r) in blocks:
    bs.add(%*{"slot": $s, "signing_root": r})
  var as0 = newJArray()
  for (s, t, r) in atts:
    as0.add(%*{"source_epoch": $s, "target_epoch": $t, "signing_root": r})
  %*{"metadata": {"interchange_format_version": "5",
                  "genesis_validators_root": gvr},
     "data": [{"pubkey": pk, "signed_blocks": bs, "signed_attestations": as0}]}

suite "validator_safety":
  test "a clean history has no conflict":
    check conflicts([ic(@[(8, "0x1"), (16, "0x2")],
                        @[(0, 1, "0xa"), (1, 2, "0xb"), (2, 3, "0xc")])]).len == 0

  test "each slashing condition is found":
    let dp = conflicts([ic(@[(8, "0x1"), (8, "0x2")], @[])])
    check dp.len == 1 and dp[0].kind == "double-proposal"
    let dv = conflicts([ic(@[], @[(1, 2, "0xa"), (1, 2, "0xb")])])
    check dv.len == 1 and dv[0].kind == "double-vote"
    let sv = conflicts([ic(@[], @[(1, 5, "0xa"), (2, 4, "0xb")])])
    check sv.len == 1 and sv[0].kind == "surround-vote"
    # The same message twice is not a conflict; a missing root is.
    check conflicts([ic(@[(8, "0x1"), (8, "0x1")], @[])]).len == 0
    check conflicts([ic(@[(8, ""), (8, "")], @[])]).len == 1

  test "two databases each clean but disagreeing are a conflict":
    let a = ic(@[(8, "0x1")], @[(0, 1, "0xa")])
    let b = ic(@[(8, "0x9")], @[(0, 1, "0xa")])
    check conflicts([a]).len == 0 and conflicts([b]).len == 0
    check conflicts([a, b]).len == 1
    check earliestTarget([a, b])["0xaa"] == 1

  test "a malformed or foreign interchange is an error, not clean":
    expect ValueError: discard conflicts([%*{"data": []}])
    var v4 = ic(@[], @[])
    v4["metadata"]["interchange_format_version"] = %"4"
    expect ValueError: discard conflicts([v4])
    expect ValueError:
      discard conflicts([ic(@[], @[]), ic(@[], @[], gvr = "0xother")])

  test "lifetimes: a clean hand-over passes":
    let ls = parseLifetimes("seen 10 1.000\ngone 10 5.000 5.005\n" &
                            "seen 11 5.100\n")
    check overlaps(ls).len == 0

  test "lifetimes: an overlap, a start inside the window, one never gone":
    check overlaps(parseLifetimes("seen 10 1.0\nseen 11 4.0\n" &
                                  "gone 10 5.0 5.005\n")).len == 1
    check overlaps(parseLifetimes("seen 10 1.0\ngone 10 5.000 5.005\n" &
                                  "seen 11 5.002\n")).len == 1
    check overlaps(parseLifetimes("seen 10 1.0\nseen 11 9.0\n")).len == 1
    expect ValueError: discard parseLifetimes("seen 10\n")

  test "cgroups: a restart's successor a few ms later is not an overlap":
    # The A12 review's false positive (finding 3): the successor's /proc
    # start (10 ms ticks) falls before the predecessor's polled exit, but
    # the kernel removed the old incarnation before it created the new one.
    let log = "cg eth-validator.service create 100\n" &
      "seen 10 1.000 eth-validator.service 100\n" &
      "cg eth-validator.service delete\n" &
      "cg eth-validator.service create 101\n" &
      "seen 11 5.000 eth-validator.service 101\n" &
      "gone 10 5.000 5.008\n"
    check overlaps(parseLifetimes(log)).len == 1   # the clock check's verdict
    check cgroupOverlaps(log).len == 0             # the kernel order's

  test "cgroups: a rename handed over in order passes, started early is caught":
    let clean = "cg eth-validator.service create 100\n" &
      "seen 10 1.0 eth-validator.service 100\n" &
      "cg eth-validator.service delete\n" &
      "cg eth-validator-b.service create 200\n" &
      "seen 11 2.0 eth-validator-b.service 200\n"
    check cgroupOverlaps(clean).len == 0
    # The successor's unit created (and running) before the old one's
    # cgroup was removed: the exclusive-as-plain-restart shape.
    let early = "cg eth-validator.service create 100\n" &
      "seen 10 1.0 eth-validator.service 100\n" &
      "cg eth-validator-b.service create 200\n" &
      "seen 11 2.0 eth-validator-b.service 200\n" &
      "cg eth-validator.service delete\n"
    check cgroupOverlaps(early).len == 1
    # Never removed while the other ran: open spans intersect.
    let open = "cg eth-validator.service create 100\n" &
      "seen 10 1.0 eth-validator.service 100\n" &
      "cg eth-validator-b.service create 200\n" &
      "seen 11 2.0 eth-validator-b.service 200\n"
    check cgroupOverlaps(open).len == 1
    # An incarnation in which no validator was seen is paired too: its span
    # contains whatever ran in it, seen or not (validator_safety, *What the
    # order cannot see*).
    let empty = "cg eth-validator-b.service create 200\n" &
      "cg eth-validator.service create 100\n" &
      "seen 10 1.0 eth-validator.service 100\n" &
      "cg eth-validator-b.service delete\n"
    let e = cgroupOverlaps(empty)
    check e.len == 1
    check "no validator seen" in e[0]
    # A creation drained after its directory was removed again (`-`, a
    # monitor that drained late) is a span like any other: early, it is an
    # overlap; it holds no attributable process, so coverage counts it.
    let late = "cg eth-validator.service create 100\n" &
      "seen 10 1.0 eth-validator.service 100\n" &
      "cg eth-validator-b.service create -\n" &
      "cg eth-validator.service delete\n" &
      "cg eth-validator-b.service delete\n"
    check cgroupOverlaps(late).len == 1
    check monitorStats(late).withoutValidator == 1
    # Handed over in order, it is no overlap.
    let emptyInOrder = "cg eth-validator-b.service create 200\n" &
      "cg eth-validator-b.service delete\n" &
      "cg eth-validator.service create 100\n" &
      "seen 10 1.0 eth-validator.service 100\n"
    check cgroupOverlaps(emptyInOrder).len == 0

  test "cgroups: two instances in one incarnation, an unseen incarnation, a stray":
    check cgroupOverlaps("cg u.service create 1\nseen 10 1.0 u.service 1\n" &
                         "seen 11 2.0 u.service 1\n").len == 1
    check cgroupOverlaps("seen 10 1.0 u.service 9\n").len == 1
    # A process outside the units is held to the clock check: overlapping a
    # unit's instance in time, it is reported.
    let stray = "cg u.service create 1\nseen 10 1.0 u.service 1\n" &
      "seen 11 2.0 - -\n"
    check cgroupOverlaps(stray).len == 1
    expect ValueError: discard cgroupOverlaps("cg u.service frozen\n")

  test "monitor coverage: an overflow fails closed; scan gaps, empty incarnations and the end are counted":
    let clean = "cg u.service create 1\nscan 0.006\nseen 10 1.0 u.service 1\n" &
      "scan 0.012\ncg u.service delete\ncg u.service create 2\n" &
      "cg u.service delete\n"
    check cgroupOverlaps(clean).len == 0
    let st = monitorStats(clean)
    check st.overflows == 0
    check st.longestScanGapSec == 0.012
    check st.incarnations == 2
    check st.withoutValidator == 1
    check not st.ended                      # killed, not stopped: no `end`
    # A monitor stopped with SIGTERM drains its queue and writes `end`;
    # the lifetimes and the cgroup order read past it.
    let ended = clean & "end\n"
    check monitorStats(ended).ended
    check parseLifetimes(ended).len == 1
    check cgroupOverlaps(ended).len == 0
    # Nothing may follow `end`: a second writer, or a log appended to.
    expect ValueError: discard monitorStats(ended & "cg u.service create 3\n")
    # A long gap between two scans decides nothing by itself: the run that
    # turned round 2's bound red (0.549 s at 877b33a825), every incarnation
    # seen, is clean.
    let slow = "cg u.service create 1\nscan 0.548571\nseen 10 1.0 u.service 1\n" &
      "cg u.service delete\nend\n"
    let ss = monitorStats(slow)
    check ss.ended and ss.withoutValidator == 0 and ss.overflows == 0
    check cgroupOverlaps(slow).len == 0
    # Events were dropped between two incarnations that look handed over in
    # order: the order no longer shows it, so it is reported.
    let lost = "cg u.service create 1\nseen 10 1.0 u.service 1\n" &
      "cg overflow\ncg u.service delete\ncg v.service create 2\n" &
      "seen 11 2.0 v.service 2\n"
    let ov = cgroupOverlaps(lost)
    check ov.len == 1
    check "IN_Q_OVERFLOW" in ov[0]
    check monitorStats(lost).overflows == 1
    check parseLifetimes(lost).len == 2
    expect ValueError: discard monitorStats("scan\n")

  test "databasesHeld: distinct databases, and db lines do not disturb lifetimes":
    let log = "seen 10 1.0\ndb 10 2049:77 /var/lib/x/validator.db\n" &
      "gone 10 5.0 5.005\nseen 11 6.0\ndb 11 2049:77 /var/lib/x/validator.db\n" &
      "seen 12 9.0\n"
    check databasesHeld(log) == @["2049:77 /var/lib/x/validator.db"]
    check parseLifetimes(log).len == 3
    check databasesHeld(log & "db 12 2049:91 /var/lib/y/validator.db\n").len == 2

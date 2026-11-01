## The positive controls of ``e2e_addon_validator_never_double_signs``'s two
## checkers (``validator_safety``), on records whose answer is known: each
## slashing condition is found, a clean history is clean, two databases
## that are each clean but disagree are a conflict, a malformed or foreign
## file is an error rather than "clean", and the lifetime check finds an
## overlap, an instance started inside the polling window and one still
## alive at the end, and passes a clean hand-over. The VM gate's own
## positive control (a second instance with a fresh database double-signs
## for real and the check finds it) is in the gate.
##
## *Mocking.* None: pure functions over literal records.

import std/[json, tables, unittest]

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

  test "databasesHeld: distinct databases, and db lines do not disturb lifetimes":
    let log = "seen 10 1.0\ndb 10 2049:77 /var/lib/x/validator.db\n" &
      "gone 10 5.0 5.005\nseen 11 6.0\ndb 11 2049:77 /var/lib/x/validator.db\n" &
      "seen 12 9.0\n"
    check databasesHeld(log) == @["2049:77 /var/lib/x/validator.db"]
    check parseLifetimes(log).len == 3
    check databasesHeld(log & "db 12 2049:91 /var/lib/y/validator.db\n").len == 2

## The pure parts of negotiated widths on Reprobuild's side: how a granted
## width is written into a command line, how a range becomes the request
## RunQuota receives, how it crosses the helper's argv, and how the advertised
## frontier follows grants and queue waits.
##
## WHAT IS GUARDED, with the mutation that breaks each:
##
## * The width flag carries the grant: appended, or placed before a `--`,
##   or replacing a value larger than the grant, while a smaller one is kept.
##   Mutation: always append (no capping) and the "asked for more" cases keep
##   64.
## * A range reaches RunQuota as a range. Mutation: drop `withWidthRange` in
##   `toRunQuotaRequest` and the width is absent.
## * The frontier halves once a queued candidate waits past the threshold,
##   at most once per threshold, never below its floor, and grows back as
##   grants arrive at once. Mutation: a constant frontier (`noteOldestWait`
##   doing nothing) and the halving cases fail.
##
## NO MOCKS: values in, values out.

import std/unittest

import runquota_client
import runquota_core
import runquota_protocol
import repro_runquota

suite "the granted width on the command line":
  test "appended when the command has no such flag":
    check withWidthFlag(["bin", "--nocapture"], "--test-threads", 3) ==
      @["bin", "--nocapture", "--test-threads", "3"]

  test "placed before a `--`, never after it":
    check withWidthFlag(["bin", "--", "filter"], "--test-threads", 3) ==
      @["bin", "--test-threads", "3", "--", "filter"]
    check withWidthFlag(["bin", "--", "--test-threads", "9"],
      "--test-threads", 3) == @["bin", "--test-threads", "3", "--",
        "--test-threads", "9"]

  test "a value above the grant, or not a number, becomes the grant":
    check withWidthFlag(["bin", "--test-threads", "64"], "--test-threads",
      3) == @["bin", "--test-threads", "3"]
    check withWidthFlag(["bin", "--test-threads=0"], "--test-threads", 3) ==
      @["bin", "--test-threads=3"]
    check withWidthFlag(["bin", "-j8"], "-j", 3) == @["bin", "-j3"]
    check withWidthFlag(["bin", "--test-threads", "auto"], "--test-threads",
      3) == @["bin", "--test-threads", "3"]
    # A flag with no value at all gets one.
    check withWidthFlag(["bin", "-j", "--keep-going"], "-j", 3) ==
      @["bin", "-j", "3", "--keep-going"]

  test "a value within the grant is kept as written":
    check withWidthFlag(["bin", "--test-threads", "2"], "--test-threads",
      3) == @["bin", "--test-threads", "2"]
    check withWidthFlag(["bin", "--workers=1"], "--workers", 3) ==
      @["bin", "--workers=1"]

  test "a joined flag takes the width attached":
    check withWidthFlag(["nim", "c", "x.nim"], "--parallelBuild:", 4) ==
      @["nim", "c", "x.nim", "--parallelBuild:4"]
    check withWidthFlag(["nim", "--parallelBuild:0", "c"],
      "--parallelBuild:", 4) == @["nim", "--parallelBuild:4", "c"]

  test "argv[0] is never touched, and no flag means no change":
    check withWidthFlag(["--test-threads"], "--test-threads", 3) ==
      @["--test-threads", "--test-threads", "3"]
    check withWidthFlag(["bin"], "", 3) == @["bin"]

  test "the grant in slots rounds a fraction up, and is exported":
    check grantedSlots(3000) == 3
    check grantedSlots(2500) == 3
    check grantedSlots(0) == 1
    let command = ReproCommandSpec(
      argv: widthPlaceholderArgv(["bin"], "-j"), widthFlag: "-j")
    let launched = command.applyGrantedWidth(3000)
    check launched.argv == @["bin", "-j", "3"]
    check "RUNQUOTA_RUN_WIDTH=3" in launched.env
    # No flag declared: launched exactly as declared.
    let plain = ReproCommandSpec(argv: @["bin"])
    check plain.applyGrantedWidth(3000).argv == @["bin"]
    check plain.applyGrantedWidth(3000).env.len == 0

suite "the width is placed before wrapping, filled at launch":
  test "a placeholder survives the wrappers and is filled where they put it":
    let placed = widthPlaceholderArgv(["bin", "--test-threads", "2"],
      "--test-threads")
    check placed[0] == "bin"
    check placed[2] != "2"
    # The umask wrapper quotes the argv into one shell string; the monitor
    # wrapper prefixes it. The placeholder is filled in both.
    let quoted = "umask 022 && exec 'bin' '--test-threads' '" & placed[2] & "'"
    check fillWidthPlaceholders(quoted, 3) ==
      "umask 022 && exec 'bin' '--test-threads' '2'"
    check fillWidthPlaceholders(quoted, 1) ==
      "umask 022 && exec 'bin' '--test-threads' '1'"
    let command = ReproCommandSpec(argv: @["monitor", "--", "bin",
      widthPlaceholderArgv(["bin"], "-j")[1],
      widthPlaceholderArgv(["bin"], "-j")[2]], widthFlag: "-j")
    check command.applyGrantedWidth(4000).argv ==
      @["monitor", "--", "bin", "-j", "4"]
    check fillWidthPlaceholders("no placeholder", 3) == "no placeholder"

suite "a range in the request":
  test "a range reaches RunQuota as a range; none, as one value":
    let ranged = ReproResourceRequest(label: "t", cpuMinMilli: 1000,
      cpuPreferredMilli: 16000).toRunQuotaRequest()
    check ranged.width.present
    check ranged.width.minMilli == 1000'u32
    check ranged.width.preferredMilli == 16000'u32
    check not ranged.width.resizable
    let fixed = ReproResourceRequest(label: "t",
      cpuMilli: 2000).toRunQuotaRequest()
    check not fixed.width.present
    check fixed.resources.cpu.value == 2000'u32
    # A preferred width alone means a minimum of one slot.
    let fromOne = ReproResourceRequest(label: "t",
      cpuPreferredMilli: 4000).toRunQuotaRequest()
    check fromOne.width.minMilli == 1000'u32

  test "the range and the flag cross the helper's argv":
    let request = ReproResourceRequest(label: "t", cpuMinMilli: 1000,
      cpuPreferredMilli: 8000)
    let command = ReproCommandSpec(argv: @["bin"], widthFlag: "--workers")
    let argv = helperCliArgs(request, command, "/r.json")
    var seen: seq[string] = @[]
    for i in 0 ..< argv.len - 1:
      if argv[i] in ["--cpu-min", "--cpu-pref", "--width-flag"]:
        seen.add argv[i] & "=" & argv[i + 1]
    check seen == @["--cpu-min=1000", "--cpu-pref=8000",
      "--width-flag=--workers"]

suite "the advertised frontier":
  test "starts at the configured parallelism, with a floor of two":
    let sizer = initFrontierSizer(8, 1000)
    check sizer.width == 8
    check sizer.floor == 2
    check initFrontierSizer(1, 1000).floor == 1

  test "halves once a queued candidate waits past the threshold":
    var sizer = initFrontierSizer(8, 1000)
    sizer.noteOldestWait(999, 10_000)
    check sizer.width == 8
    sizer.noteOldestWait(1000, 10_000)
    check sizer.width == 4
    # Not again within the same threshold: one long wait counts once.
    sizer.noteOldestWait(1500, 10_500)
    check sizer.width == 4
    sizer.noteOldestWait(2000, 11_000)
    check sizer.width == 2
    sizer.noteOldestWait(3000, 12_000)
    check sizer.width == 2

  test "grows back as grants arrive at once or after a short wait":
    var sizer = initFrontierSizer(8, 1000)
    sizer.noteOldestWait(5000, 10_000)
    sizer.noteOldestWait(5000, 11_000)
    check sizer.width == 2
    sizer.noteQueuedGrant(5000)
    check sizer.width == 2
    sizer.noteQueuedGrant(10)
    check sizer.width == 3
    sizer.noteGrantedAtOnce(4)
    check sizer.width == 7
    sizer.noteGrantedAtOnce(4)
    check sizer.width == 8

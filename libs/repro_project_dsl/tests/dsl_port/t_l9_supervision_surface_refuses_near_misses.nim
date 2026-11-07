## Shared-Development-Services L9 — THE SUPERVISION SETTERS: every
## spelling they accept is honoured, and every plausible misspelling,
## near-miss and wrong-shape spelling is REFUSED BY NAME.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real `nim` this
## repo is built with and asserts on its real diagnostic, through the
## same `checkRecipeSource` helper L1's setter-surface test and L8's
## `contribute:` probe set use. See `service_block_compile_probe.nim`
## for why the in-process `compiles` spelling cannot be used here:
## measured, it answers *false* for every `package` block -- well-formed
## or not -- so both a refusal and its control would be vacuous.
##
## § THE STANDING HUNT THIS FILE IS
##
## The campaign's dominant finding is "constructs that are declared,
## look wired, and are silently dropped", and the `service` body's
## setter walk is the ideal habitat: it ends in `else: discard`, and
## three separate `continue` filters sit in front of that -- a
## statement-kind filter, an arity filter and a head-kind filter -- each
## of which drops its input with no diagnostic.
##
## For these four setters the consequence is worse than a missing value.
## A service that reaches the supervisor with NO readiness probe is
## reported ready as soon as it is spawned, so a consumer that
## `dependsOn` it starts against an instance that is listening and not
## yet seeded: a race rather than an error. An `instance:` block that is
## dropped leaves the service SESSION-OWNED while its author believed it
## was shared, which is the same failure
## `parseSharedServiceInstance` already refuses for the JSON spelling.
##
## THE SIZE OF THE PROBE SET IS A CONSTANT, NOT A SENTENCE: `AllProbes`
## below is the set, every loop iterates it, and a case of its own
## asserts its length and its refusal/honoured split. Three prose
## numbers for one set is how a probe set silently shrinks -- L7's
## review found exactly that in L7's own file.
##
## Each probe is a ONE-LINE-REGION EDIT to the well-formed recipe whose
## own compile is the first case here, and each asserts the edit
## actually changed the source: a `replace` whose needle has drifted
## silently returns the input, which would turn a refusal test into a
## second run of the control.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl

package l9ProbeOwner:
  executable l9ProbeBin:
    build:
      output("bin/l9-probe")

  devEnv:
    activity svc():
      service probe:
        executable l9ProbeBin
        identity stable "com.metacraft-labs.l9-probe"
        scope workspace
        workingDirectory "."
        stateDirectory ".repro/l9-probe"
        readiness fileExists(".repro/l9-probe/ready", timeoutMs = 600000)
        instance:
          lease keep

    enable svc
"""

const Needle = """        workingDirectory "."
        stateDirectory ".repro/l9-probe"
        readiness fileExists(".repro/l9-probe/ready", timeoutMs = 600000)
        instance:
          lease keep
"""

type
  Probe = object
    tag: string
    replacement: string
    mentions: seq[string]
      ## Every fragment the diagnostic MUST carry. Asserting on the
      ## message rather than only on the exit code is earned: L1's first
      ## draft passed a refusal because the fixture it generated had an
      ## unterminated string literal, so "it failed to compile" was true
      ## and said nothing about the construct under test.
    honoured: bool
      ## True for a near-miss that is CORRECT and must compile. A probe
      ## set made only of refusals cannot tell "refuses everything" from
      ## "refuses the wrong things".

const AllProbes* = [
  # ---- the three filters that drop in silence -----------------------
  Probe(tag: "bare-readiness", honoured: false,
    replacement: """        readiness
""",
    mentions: @["bare identifier", "`readiness`", "skip it entirely"]),

  Probe(tag: "bare-instance", honoured: false,
    replacement: """        instance
""",
    mentions: @["bare identifier", "`instance`"]),

  Probe(tag: "bare-working-directory", honoured: false,
    replacement: """        workingDirectory
""",
    mentions: @["bare identifier", "`workingdirectory`"]),

  # The ARITY filter -- the third `continue` in the setter walk, and the
  # one that was still dropping in silence when the other two were
  # closed. `readiness()` is an `nnkCall` of length ONE, so it survives
  # the statement-kind filter and dies at `if stmt.len < 2`. Found by
  # review, not by the original hunt: the hunt probed the bare IDENT of
  # each setter and never its empty-call spelling. `instance()` is the
  # sharpest of the four -- it leaves the service SESSION-OWNED while
  # its author believes they declared a shared instance.
  Probe(tag: "empty-call-readiness", honoured: false,
    replacement: """        readiness()
""",
    mentions: @["NO ARGUMENTS", "`readiness`", "skipped entirely"]),

  Probe(tag: "empty-call-instance", honoured: false,
    replacement: """        instance()
""",
    mentions: @["NO ARGUMENTS", "`instance`", "`discard` body"]),

  Probe(tag: "empty-call-working-directory", honoured: false,
    replacement: """        workingDirectory()
""",
    mentions: @["NO ARGUMENTS", "`workingdirectory`"]),

  Probe(tag: "empty-call-state-directory", honoured: false,
    replacement: """        stateDirectory()
""",
    mentions: @["NO ARGUMENTS", "`statedirectory`"]),

  # THE POSITIVE CONTROL FOR THE FOUR ABOVE, and the reason the refusal
  # keys on the NAME rather than on the shape. An argument-less call is
  # a LEGAL spelling in this DSL -- `m5ServiceShortFormEmission`'s own
  # comment records that `restartOnCrash()` parses as a one-child Call
  # and the arity guard handles it -- so a refusal that fired on the
  # shape would reject working recipes. Without this probe, "refuses
  # `readiness()`" could not be told from "refuses every empty call".
  Probe(tag: "honoured-empty-call-non-supervision-setter", honoured: true,
    replacement: """        restartOnCrash()
""",
    mentions: @[]),

  Probe(tag: "dotted-readiness-head", honoured: false,
    replacement: """        probe.readiness fileExists(".repro/l9-probe/ready")
""",
    mentions: @["dotted head", "skipped entirely"]),

  Probe(tag: "dotted-state-directory-head", honoured: false,
    replacement: """        probe.stateDirectory ".repro/l9-probe"
""",
    mentions: @["dotted head", "statedirectory"]),

  # ---- readiness: the kind ------------------------------------------
  Probe(tag: "unknown-readiness-kind", honoured: false,
    replacement: """        readiness processAlive()
""",
    mentions: @["processAlive", "never ready", "`httpGet`"]),

  Probe(tag: "readiness-kind-without-parens", honoured: false,
    replacement: """        readiness fileExists
""",
    mentions: @["names a probe KIND and gives it nothing"]),

  Probe(tag: "readiness-none-with-args", honoured: false,
    replacement: """        readiness none(".repro/l9-probe/ready")
""",
    mentions: @["takes no arguments", "readiness none"]),

  Probe(tag: "readiness-twice", honoured: false,
    replacement: """        readiness fileExists(".repro/l9-probe/ready")
        readiness httpGet(port = 8080)
""",
    mentions: @["declared twice", "statement order"]),

  Probe(tag: "readiness-string-probe", honoured: false,
    replacement: """        readiness "fileExists"
""",
    mentions: @["written as `none` or as a call"]),

  # ---- readiness: the arguments -------------------------------------
  Probe(tag: "file-exists-without-path", honoured: false,
    replacement: """        readiness fileExists()
""",
    mentions: @["declares no path", "never go ready"]),

  Probe(tag: "file-exists-positional-timeout", honoured: false,
    replacement: """        readiness fileExists(".repro/l9-probe/ready", 600000)
""",
    mentions: @["timeout is a NAMED argument", "read by nothing"]),

  Probe(tag: "misspelled-timeout", honoured: false,
    replacement: """        readiness fileExists(".repro/l9-probe/ready", timeout = 600000)
""",
    mentions: @["`timeout` is not an argument",
                "indistinguishable from support for it"]),

  Probe(tag: "port-on-a-file-probe", honoured: false,
    replacement: """        readiness fileExists(".repro/l9-probe/ready", port = 8080)
""",
    mentions: @["`port` belongs to", "httpGet"]),

  Probe(tag: "http-get-with-nothing", honoured: false,
    replacement: """        readiness httpGet()
""",
    mentions: @["names nothing to probe"]),

  Probe(tag: "http-get-port-and-url", honoured: false,
    replacement: """        readiness httpGet(port = 8080, url = "http://127.0.0.1:8080")
""",
    mentions: @["two answers to the same question"]),

  Probe(tag: "http-get-positional-path", honoured: false,
    replacement: """        readiness httpGet("/debug/ready", port = 8080)
""",
    mentions: @["NAMED arguments only", "reads as the request path"]),

  Probe(tag: "http-get-named-path", honoured: false,
    replacement: """        readiness httpGet(path = "/debug/ready", port = 8080)
""",
    mentions: @["`path` is NOT accepted", "always `/`",
                "read by nothing"]),

  # ---- the `instance:` block ---------------------------------------
  Probe(tag: "instance-as-a-value", honoured: false,
    replacement: """        instance "shared"
""",
    mentions: @["is a BLOCK, not a value", "SESSION-OWNED"]),

  Probe(tag: "instance-twice", honoured: false,
    replacement: """        instance:
          lease keep
        instance:
          lease immediate
""",
    mentions: @["declared twice", "reaped"]),

  Probe(tag: "instance-environment", honoured: false,
    replacement: """        instance:
          environment "development"
""",
    mentions: @["does not take an `environment`", "REPRO_ENVIRONMENT",
                "second answer"]),

  Probe(tag: "instance-identity", honoured: false,
    replacement: """        instance:
          identity stable "com.metacraft-labs.l9-probe"
""",
    mentions: @["does not take an `identity`", "one level out"]),

  Probe(tag: "instance-scope", honoured: false,
    replacement: """        instance:
          scope workspace
""",
    mentions: @["does not take a `scope`", "one level out"]),

  Probe(tag: "instance-bare-ttl", honoured: false,
    replacement: """        instance:
          ttlSeconds 3600
""",
    mentions: @["bare `ttlSeconds`", "lease delayed"]),

  Probe(tag: "instance-unknown-setting", honoured: false,
    replacement: """        instance:
          replicas 2
""",
    mentions: @["does not recognise the setting", "`replicas`"]),

  Probe(tag: "lease-unknown-word", honoured: false,
    replacement: """        instance:
          lease forever
""",
    mentions: @["`lease forever` is not a lease"]),

  Probe(tag: "lease-delayed-without-ttl", honoured: false,
    replacement: """        instance:
          lease delayed
""",
    mentions: @["needs its ttl", "wearing the wrong name"]),

  Probe(tag: "lease-delayed-zero", honoured: false,
    replacement: """        instance:
          lease delayed(0)
""",
    mentions: @["is not a delay", "lease immediate"]),

  Probe(tag: "lease-delayed-negative", honoured: false,
    replacement: """        instance:
          lease delayed(-1)
""",
    mentions: @["is not a delay", "lease keep"]),

  Probe(tag: "lease-as-assignment", honoured: false,
    replacement: """        instance:
          lease = keep
""",
    mentions: @["written as a command, not an assignment"]),

  Probe(tag: "lease-twice", honoured: false,
    replacement: """        instance:
          lease keep
          lease immediate
""",
    mentions: @["declares `lease` twice"]),

  # ---- workingDirectory / stateDirectory ---------------------------
  Probe(tag: "working-directory-twice", honoured: false,
    replacement: """        workingDirectory "."
        workingDirectory "sub"
""",
    mentions: @["declared twice", "dead text"]),

  Probe(tag: "working-directory-two-args", honoured: false,
    replacement: """        workingDirectory ".", "sub"
""",
    mentions: @["takes exactly one directory"]),

  # ---- the honoured near-misses ------------------------------------
  #
  # Without these the file could not tell "refuses everything" from
  # "refuses the wrong things", and three of them are shapes a cautious
  # implementation would plausibly have rejected.
  Probe(tag: "honoured-readiness-none", honoured: true,
    replacement: """        readiness none
        instance:
          lease keep
""",
    mentions: @[]),

  Probe(tag: "honoured-http-get-port", honoured: true,
    replacement: """        readiness httpGet(port = 8080, timeoutMs = 90000)
        instance:
          lease keep
""",
    mentions: @[]),

  Probe(tag: "honoured-http-get-url", honoured: true,
    replacement: """        readiness httpGet(url = "http://127.0.0.1:8080")
        instance:
          lease immediate
""",
    mentions: @[]),

  # A setter that is REAL one level out. The generic unknown-setting arm has
  # to fire for these too, and they are the likeliest misplacement: an author
  # who has just written `instance:` is one indent away from putting the rest
  # of the service's setters inside it.
  Probe(tag: "instance-holds-readiness", honoured: false,
    replacement: """        instance:
          readiness fileExists(".repro/l9-probe/ready")
""",
    mentions: @["does not recognise the setting", "`readiness`"]),

  Probe(tag: "instance-holds-state-directory", honoured: false,
    replacement: """        readiness fileExists(".repro/l9-probe/ready")
        instance:
          stateDirectory ".repro/l9-probe"
""",
    mentions: @["does not recognise the setting", "`stateDirectory`"]),

  Probe(tag: "instance-discard-with-a-value", honoured: false,
    replacement: """        instance:
          discard "shared"
""",
    mentions: @["does not recognise", "bare `discard` is accepted"]),

  Probe(tag: "honoured-empty-instance-block", honoured: true,
    replacement: """        readiness fileExists(".repro/l9-probe/ready")
        instance:
          discard
""",
    mentions: @[]),

  Probe(tag: "honoured-lease-delayed", honoured: true,
    replacement: """        readiness fileExists(".repro/l9-probe/ready")
        instance:
          lease delayed(3600)
""",
    mentions: @[]),

  Probe(tag: "honoured-repeated-state-directory", honoured: true,
    replacement: """        stateDirectory ".repro/l9-probe"
        stateDirectory ".repro/l9-probe-journal"
        readiness fileExists(".repro/l9-probe/ready")
        instance:
          lease keep
""",
    mentions: @[]),

  Probe(tag: "honoured-state-directory-list", honoured: true,
    replacement: """        stateDirectory ".repro/l9-probe", ".repro/l9-probe-journal"
        readiness fileExists(".repro/l9-probe/ready")
        instance:
          lease keep
""",
    mentions: @[]),

  Probe(tag: "honoured-case-insensitive-setters", honoured: true,
    replacement: """        WorkingDirectory "."
        StateDirectory ".repro/l9-probe"
        Readiness fileExists(".repro/l9-probe/ready")
        Instance:
          Lease keep
""",
    mentions: @[]),

  Probe(tag: "honoured-no-supervision-at-all", honoured: true,
    replacement: """""",
    mentions: @[])
]

suite "L9 supervision surface — the controls":

  test "the well-formed recipe compiles":
    # Without this, every refusal below could be passing for a reason
    # that has nothing to do with the construct under test.
    let probe = checkRecipeSource(WellFormed, "l9-supervision-control")
    checkpoint(probe.output)
    check probe.ok

  test "the probe set's size is read from the set, not from prose":
    # 45 -> 50 at review: four refusals for the ARITY filter's
    # empty-call spellings, plus the positive control that keeps the new
    # refusal keyed on the four setter NAMES instead of on the shape.
    check AllProbes.len == 50
    var refusals = 0
    var honoured = 0
    for p in AllProbes:
      if p.honoured: inc honoured else: inc refusals
    check refusals == 40
    check honoured == 10

suite "L9 supervision surface — every near-miss is honoured or named":

  test "each probe is either honoured or refused BY NAME":
    for p in AllProbes:
      let source = WellFormed.replace(Needle, p.replacement)
      # The edit must have landed: a drifted needle would silently make
      # this a second run of the control.
      check source != WellFormed
      let probe = checkRecipeSource(source, "l9-supervision-" & p.tag)
      if p.honoured:
        checkpoint("honoured probe failed to compile: " & p.tag &
          "\n" & probe.output)
        check probe.ok
      else:
        checkpoint("refusal probe compiled clean: " & p.tag)
        check not probe.ok
        for fragment in p.mentions:
          checkpoint("probe " & p.tag & " diagnostic is missing `" &
            fragment & "`:\n" & probe.output)
          check probe.mentions(fragment)

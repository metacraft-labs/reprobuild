## Shared-Development-Services **D-SS10** (§7.1) — THE EXPANSION-TIME
## REFUSAL: a `service` body that `converge`s a contribution point while
## declaring no evaluable readiness probe.
##
## The clause, quoted from §7.1:
##
##   > **A service with `readiness none` cannot order a registration.**
##   > That is the one shape this decision makes illegal rather than
##   > merely discouraged: with no probe there is nothing for completion
##   > to mean, so `dependsOn` would degrade to "materialised" [...] A
##   > registration resource ordered on such a service is **refused at
##   > expansion**, naming the service and that it declares no readiness.
##
## `converge <point>` IS the declaration of that registration resource —
## `macros_b.nim`'s own `converge` arm says so ("a registration is a
## RESOURCE the resource lane reconciles after the instance answers"). So
## the illegal shape is a body carrying both `converge` and no evaluable
## probe, and that is what the cases below compile.
##
## § WHY THE CONTROLS MATTER MORE THAN THE REFUSALS HERE
##
## The refusal is cheap to get right and easy to get TOO BROAD. Three
## controls pin the narrowing:
##
##   * `readiness none` WITHOUT `converge` still compiles. A service that
##     registers nothing has no registration to order, and §7.1 makes no
##     claim about it — a refusal there would be inventing a rule.
##   * each of the two evaluable probe kinds, WITH `converge`, compiles.
##     Without these a refusal keyed on the wrong thing (on `converge`
##     alone, say) would pass every negative case.
##   * the well-formed recipe compiles at all, so a refusal below cannot
##     be passing for an unrelated reason.
##
## § WHY THE TWO PROBELESS SHAPES ARE BOTH REFUSED
##
## `readiness none` and no `readiness` setter at all are the same fact
## about completion. Refusing only the spelling an author WROTE DOWN would
## leave the silent one legal, which is this campaign's dominant defect
## class placed inside the fix for it. The two refusals differ in one
## sentence, because the remedies differ: one author deletes a word, the
## other adds a setter.
##
## § MOCK POLICY — NO MOCKS, DOUBLES OR FAKES, AND NONE MAY BE ADDED.
## The compiler is the real `nim` this repo is built with, invoked on a
## real file by `checkRecipeSource`, and the text asserted on is its real
## output. See `service_block_compile_probe.nim` for why an out-of-process
## `nim check` is used rather than `compiles`.

import std/[strutils, unittest]

import ./service_block_compile_probe

const
  ## The needle every probe replaces: the two supervision lines of the
  ## shared service. Kept as a single literal so a drifted needle makes
  ## the `source != WellFormed` assertion below fail loudly rather than
  ## turning a probe into a second run of the control.
  Needle = """        readiness fileExists("state/idp.ready")
        converge relyingParties
"""

  ActivityNeedle = "      service idp:\n"
    ## Where `extraBody` is spliced: immediately before the typed
    ## `service` block, inside the activity body.

  WellFormed = """import repro_project_dsl

package dss10Pkg:
  devEnv:
    activity sso():
      config:
        relyingParties: seq[string] = @["owner"]

      service idp:
        executable executableAtPath("/bin/sh")
        args "-c", "sleep 1"
        identity stable "com.example.dss10.idp"
        scope workspace
        workingDirectory "."
        readiness fileExists("state/idp.ready")
        converge relyingParties

    enable sso
"""

type
  Probe = object
    tag: string
    honoured: bool
    replacement: string
    extraBody: string
      ## Extra statements spliced into the ACTIVITY body, before the
      ## `service` block. Used by the one probe that needs a sibling
      ## `servicePlaceholder` beside the typed service.
    mentions: seq[string]

const
  ## A sibling `servicePlaceholder` whose opaque JSON carries the probe.
  ## Built from NORMAL string literals rather than a triple-quoted one:
  ## Nim does not process `\"` inside `"""..."""`, so the nested JSON
  ## cannot be written that way.
  PlaceholderBody =
    "      servicePlaceholder(\"other\", \"\"\"{\n" &
    "        \"schemaId\": \"reprobuild.dev-session.service.v1\",\n" &
    "        \"command\": [\"/bin/sh\", \"-c\", \"sleep 1\"],\n" &
    "        \"cwd\": \".\",\n" &
    "        \"readiness\": {\"kind\": \"fileExists\", " &
    "\"path\": \"state/other.ready\"}\n" &
    "      }\"\"\", @[\"sso\"])\n"

const
  AllProbes = @[
    # ---- the two illegal shapes ----
    Probe(tag: "refuse-readiness-none-with-converge", honoured: false,
      replacement: """        readiness none
        converge relyingParties
""",
      mentions: @[
        "service `idp`",
        "declares `readiness none`",
        "NOTHING CAN ORDER A REGISTRATION ON IT",
        "`relyingParties`",
        "REGISTRATION RESOURCE ordered on this service",
        # The remedy must NOT offer the spelling it just refused.
        "readiness fileExists"]),

    Probe(tag: "refuse-no-readiness-at-all-with-converge", honoured: false,
      replacement: """        converge relyingParties
""",
      mentions: @[
        "service `idp`",
        "declares NO `readiness` setter at all",
        "NOTHING CAN ORDER A REGISTRATION ON IT",
        # The refusal must name the OTHER lane, because an author whose
        # probe is in a `servicePlaceholder`'s JSON otherwise reads
        # "declares NO readiness setter at all" as a contradiction of
        # what they wrote. See the next probe.
        "servicePlaceholder"]),

    Probe(tag: "refuse-placeholder-probe-with-typed-converge",
      honoured: false,
      replacement: """        converge relyingParties
""",
      extraBody: PlaceholderBody,
      mentions: @[
        # A DELIBERATE OVER-APPROXIMATION, MEASURED RATHER THAN ASSUMED.
        # A probe in a `servicePlaceholder`'s opaque JSON IS honoured at
        # runtime -- `serviceSpecFromSummary` reads that lane -- so this
        # recipe would have worked, and expansion refuses it anyway
        # because the macro sees the typed body only. The refusal is
        # therefore required to NAME the lane and the remedy; without
        # that, this is a refusal an author cannot act on. Recorded here
        # as the shape it is, not hidden.
        "NOTHING CAN ORDER A REGISTRATION ON IT",
        "servicePlaceholder",
        "move the probe to the typed `readiness` setter"]),

    Probe(tag: "refuse-readiness-none-with-two-points", honoured: false,
      replacement: """        readiness none
        converge relyingParties, relyingParties
""",
      mentions: @[
        "NOTHING CAN ORDER A REGISTRATION ON IT",
        # The POINT COUNT is reported, and a repeated name counts once --
        # `addActiveServiceConvergePoint` is idempotent on a repeated
        # name, so a refusal that counted occurrences would disagree with
        # what is actually registered.
        "1 contribution point"]),

    Probe(tag: "refuse-readiness-none-declared-before-converge",
      honoured: false,
      replacement: """        readiness none
        stateDirectory "state"
        converge relyingParties
""",
      mentions: @["NOTHING CAN ORDER A REGISTRATION ON IT"]),

    Probe(tag: "refuse-readiness-none-declared-after-converge",
      honoured: false,
      replacement: """        converge relyingParties
        readiness none
""",
      mentions: @["NOTHING CAN ORDER A REGISTRATION ON IT"]),

    # ---- the narrowing: the controls ----
    Probe(tag: "honoured-readiness-none-without-converge", honoured: true,
      replacement: """        readiness none
""",
      mentions: @[]),

    Probe(tag: "honoured-no-supervision-and-no-converge", honoured: true,
      replacement: """""",
      mentions: @[]),

    Probe(tag: "honoured-fileExists-with-converge", honoured: true,
      replacement: """        readiness fileExists("state/idp.ready", timeoutMs = 60000)
        converge relyingParties
""",
      mentions: @[]),

    Probe(tag: "honoured-httpGet-port-with-converge", honoured: true,
      replacement: """        readiness httpGet(port = 19443)
        converge relyingParties
""",
      mentions: @[]),

    Probe(tag: "honoured-httpGet-url-with-converge", honoured: true,
      replacement: """        readiness httpGet(url = "https://login.example.test:19443")
        converge relyingParties
""",
      mentions: @[]),

    Probe(tag: "honoured-case-insensitive-readiness-with-converge",
      honoured: true,
      replacement: """        Readiness fileExists("state/idp.ready")
        converge relyingParties
""",
      mentions: @[])
  ]

suite "D-SS10 expansion refusal — the controls":

  test "the well-formed recipe compiles":
    # Without this, every refusal below could be passing for a reason that
    # has nothing to do with the construct under test.
    let probe = checkRecipeSource(WellFormed, "dss10-control")
    checkpoint(probe.output)
    check probe.ok

  test "the probe set's size is read from the set, not from prose":
    check AllProbes.len == 12
    var refusals = 0
    var honoured = 0
    for p in AllProbes:
      if p.honoured: inc honoured else: inc refusals
    check refusals == 6
    check honoured == 6

suite "D-SS10 expansion refusal — every shape is honoured or named":

  test "each probe is either honoured or refused BY NAME":
    for p in AllProbes:
      var source = WellFormed.replace(Needle, p.replacement)
      if p.extraBody.len > 0:
        source = source.replace(ActivityNeedle, p.extraBody & ActivityNeedle)
        check source.contains("servicePlaceholder")
      # The edit must have landed: a drifted needle would silently make
      # this a second run of the control.
      check source != WellFormed
      let probe = checkRecipeSource(source, "dss10-" & p.tag)
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

suite "D-SS10 expansion refusal — it is distinguishable from the resolution one":

  test "the two refusals do not share their distinctive sentence":
    # L5's discipline, quoted from its own test: the expansion-time and
    # resolution-time refusals for one fact must be tellable apart, or a
    # reader cannot know which gate spoke. Expansion owns "NOTHING CAN
    # ORDER A REGISTRATION ON IT"; resolution (`readiness_edge.nim`'s
    # `refuseRegistrationOnProbelessService`) owns "DECLARES NO
    # READINESS".
    let source = WellFormed.replace(Needle, """        readiness none
        converge relyingParties
""")
    check source != WellFormed
    let probe = checkRecipeSource(source, "dss10-distinct")
    check not probe.ok
    checkpoint(probe.output)
    check probe.mentions("NOTHING CAN ORDER A REGISTRATION ON IT")
    check not probe.mentions("DECLARES NO READINESS")

  test "the refusal is anchored at the `converge` line, not the service head":
    # Where the author declared the registration. The refusal's subject is
    # the EDGE, and the line that declares the edge is the one to put a
    # caret under.
    let source = WellFormed.replace(Needle, """        readiness none
        converge relyingParties
""")
    let probe = checkRecipeSource(source, "dss10-anchor")
    check not probe.ok
    checkpoint(probe.output)
    # `converge relyingParties` is line 15 of the probe source: the
    # WellFormed body with `readiness fileExists(...)` swapped for
    # `readiness none` keeps every line number. Asserted as the text the
    # compiler prints rather than as a bare number so a drifted fixture
    # fails visibly.
    var anchoredLine = -1
    for line in probe.output.splitLines():
      if line.contains("NOTHING CAN ORDER A REGISTRATION ON IT"):
        let open = line.find('(')
        let comma = line.find(',', open)
        if open >= 0 and comma > open:
          anchoredLine = parseInt(line[open + 1 ..< comma])
        break
    checkpoint("anchored at line " & $anchoredLine)
    var convergeLine = -1
    var n = 0
    for line in source.splitLines():
      inc n
      if line.strip().startsWith("converge "):
        convergeLine = n
        break
    checkpoint("`converge` is on line " & $convergeLine)
    check convergeLine > 0
    check anchoredLine == convergeLine

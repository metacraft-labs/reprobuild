## Shared-Development-Services D-SS11 (§4.6) — the RESOLVER's surface,
## probed for the one failure mode this campaign keeps finding: a
## construct that is declared, looks wired, and is silently dropped.
##
## §4.6 decides three things together, and two of them have to land
## together or "the lane is worse than absent":
##
##   * "The owner's lifted interface must **carry its contribution
##     points**, so a consumer's contribution is type-checked against a
##     declared point and a misspelled one is refused **by name at the
##     consumer's compile time**";
##   * "a contribution to a point the running instance **does not
##     declare** must be refused, never dropped".
##
## The FIRST of those is what this file measures. The second is a
## runtime property of a live instance and is measured by
## `tests/integration/
## t_dss11_cross_process_contribution_reaches_the_instance.nim`.
##
## WHY A CONSTANT PROBE SET. L9's review found four argument-less call
## forms (`readiness()`, `instance()`, `workingDirectory()`,
## `stateDirectory()`) that compiled clean and were dropped, and the
## refusal had to key on the four NAMES rather than on the shape,
## because `restartOnCrash()` is legal argument-less. The lesson is that
## the near-miss set has to be enumerated and counted rather than
## sampled, so `ResolverProbes` below is a constant and the suite asserts
## its arithmetic: every entry whose `refused` is true must FAIL to
## compile with its phrase present, and every entry whose `refused` is
## false must compile CLEAN. A probe set with no honoured entries would
## pass for an implementation that refused everything.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Two real recipes are written to the real filesystem as workspace
## siblings and compiled by the real `nim` this repo is built with, and
## the text asserted on is the compiler's real output.
## `service_block_compile_probe.nim`'s own header records why an
## out-of-process compile rather than `compiles()`: a `package` block
## inside a `block:` expression makes `compiles` return false for a
## WELL-FORMED recipe too, so `not compiles` is vacuous there and its
## positive control cannot be written at all.
##
## THE POSITIVE CONTROL IS THE FIRST ENTRY, and it is not decoration:
## without a probe that compiles, every refusal assertion below would
## pass for a producer whose lift emitted nothing at all.

import std/[strutils, unittest]

import repro_project_dsl

import ./service_block_compile_probe

const
  OwnerSelector = "dss11owner"
    ## Also the producer's PACKAGE NAME, which
    ## `checkConsumerWithProducer` requires: the consumer reaches the
    ## lifted symbols through the producer's `const <packageValue>*` and
    ## `uses:` names the directory.

  OwnerRecipe = """
import repro_project_dsl

package dss11owner:
  devEnv:
    activity sso():
      config:
        relyingParties: seq[string]
        fixtureUsers: seq[string]

      service idp:
        executable executableAtPath("/bin/sh")
        args "-c", "sleep 1"
        args "--relying-parties"
        args relyingParties
        identity stable "com.example.dss11.idp"
        scope workspace
        workingDirectory "."
        readiness none
        instance:
          lease keep
        converge relyingParties, fixtureUsers

      service plain:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dss11.plain"
        scope project

    enable sso
"""
    ## One SHARED service (`idp`, with an `instance:` block and two
    ## `converge` points) and one session-owned one (`plain`, with
    ## neither). `plain` is the control for "a resolver on a service
    ## that is not shared": without it, the refusal could be firing for
    ## any absent name rather than for a service that exists and is not
    ## resolvable.

  ConsumerPreamble = """
import repro_project_dsl

package dss11consumer:
  uses:
    "dss11owner"

  devEnv:
    activity stack(sso: SharedServiceHandle[LiftedServiceHandle]):
      service app:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dss11.app"
        scope project

"""

type
  ResolverProbe = object
    tag: string
    enableLine: string
    refused: bool
    phrase: string
      ## A fragment the diagnostic must contain. Empty for an honoured
      ## probe.

const
  ResolverProbes: seq[ResolverProbe] = @[
    # ---- HONOURED ----------------------------------------------------
    ResolverProbe(tag: "resolver-with-one-contribution",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = append(\"consumer-rp\")))",
      refused: false, phrase: ""),
    ResolverProbe(tag: "resolver-with-two-points",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = append(\"a\", \"b\"), " &
        "fixtureUsers = append(@[\"dev@example.test\"])))",
      refused: false, phrase: ""),
    ResolverProbe(tag: "resolver-with-no-contribution",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared())",
      refused: false, phrase: ""),
    ResolverProbe(tag: "resolver-without-parentheses",
      # §9.4's consumer "contributes little", and a consumer may
      # contribute nothing and only attach. Nim's dot-call sugar makes
      # `.shared` and `.shared()` ONE AST, so this is honoured rather
      # than refused -- and it is probed because L9's four dropped call
      # forms were argument-less too. The difference is that there is no
      # second spelling for this one to be confused with: the honoured
      # form IS the argument-less form.
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared)",
      refused: false, phrase: ""),
    ResolverProbe(tag: "append-override-is-honoured",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = appendOverride(\"authoritative\")))",
      refused: false, phrase: ""),
    ResolverProbe(tag: "append-force-is-honoured",
      # An append at the TOP rung is authoritative and still not
      # destructive -- the property §5 says the priority ladder alone
      # cannot express. Honoured, deliberately, beside `replaceForce`
      # below which is refused.
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = appendForce(\"insisted\")))",
      refused: false, phrase: ""),
    # ---- REFUSED -----------------------------------------------------
    ResolverProbe(tag: "misspelled-point",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingPartys = append(\"x\")))",
      refused: true,
      phrase: "declares no contribution point `relyingPartys`"),
    ResolverProbe(tag: "misspelled-point-names-what-is-available",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingPartys = append(\"x\")))",
      refused: true,
      phrase: "it converges `relyingParties`, `fixtureUsers`"),
    ResolverProbe(tag: "point-that-is-a-plain-config-key",
      # The owner declares no other `config:` key here, so this probe
      # names one that does not exist at all; its value is that the
      # refusal text is the SAME one a misspelling gets, which is what
      # makes the message actionable rather than two near-identical
      # errors.
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "externalDomain = append(\"x\")))",
      refused: true,
      phrase: "declares no contribution point `externalDomain`"),
    ResolverProbe(tag: "resolver-on-a-service-that-is-not-shared",
      enableLine: "    enable stack(sso = dss11owner.sso.plain.shared())",
      refused: true,
      phrase: "there is no shared-service declaration for " &
        "`dss11owner.sso.plain`"),
    ResolverProbe(tag: "resolver-on-a-name-that-is-not-a-service",
      # MEASURED, and the diagnostic is Nim's own rather than L3's
      # `liftedMemberRefusal`. L3's refusal -- which would also name the
      # members the lifted handle type HAS -- fires from a `when not
      # compiles(...)` guard the consumer-body walker emits for
      # `<dep>.<member>.<member2>` references, and a reference whose tail
      # is a `.shared(...)` CALL does not take that guard: measured at
      # this tree, the message is `undeclared field: 'nosuch' for type
      # ...SsoHandle`. The name is still refused BY NAME and the type is
      # named, so the probe asserts what the author really sees; the
      # missing alternatives list is recorded as a finding rather than
      # asserted away.
      enableLine: "    enable stack(sso = dss11owner.sso.nosuch.shared())",
      refused: true, phrase: "undeclared field: \'nosuch\'"),
    ResolverProbe(tag: "replace-is-refused",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = replace(\"x\")))",
      refused: true,
      # THE HELPER'S OWN OUTPUT, not a re-typed fragment of it. This was
      # the FOURTH copy of §5.1's refusal wording: the round that
      # factored the other three into `sharedServiceReplaceRefusal()`
      # left it, and a one-word edit to the helper reddened this binary
      # while the two in-process tests stayed green -- which is the
      # definition of a copy free to drift.
      #
      # It could not simply `check sharedServiceReplaceRefusal() in
      # err.msg` the way those two do, because what it matches is a
      # substring of a COMPILER DIAGNOSTIC captured from a subprocess
      # rather than an exception message in this process. The fix is to
      # derive the PHRASE instead: the table is a `const`, the helper is
      # a `proc` over a `&` chain of literals, so it reads in the VM.
      #
      # The whole text, not a slice of it: stage 1 interpolates the
      # helper verbatim between its own subject and its own stage note,
      # so the full string really is present, and matching all of it is
      # what makes the coupling total.
      phrase: sharedServiceReplaceRefusal()),
    ResolverProbe(tag: "replace-force-is-refused-too",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = replaceForce(\"x\")))",
      refused: true, phrase: "D-SS9"),
    ResolverProbe(tag: "unknown-operation-head",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = incl(\"x\")))",
      refused: true, phrase: "is not a contribution operation"),
    ResolverProbe(tag: "bare-value-names-no-operation",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = \"x\"))",
      refused: true,
      phrase: "a contribution states its OPERATION at the call site"),
    ResolverProbe(tag: "operation-with-no-members",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = append()))",
      refused: true, phrase: "contributes nothing"),
    ResolverProbe(tag: "two-contributions-to-one-point",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "relyingParties = append(\"a\"), relyingParties = append(\"b\")))",
      refused: true, phrase: "contributes to `relyingParties` twice"),
    ResolverProbe(tag: "positional-argument-names-no-point",
      enableLine: "    enable stack(sso = dss11owner.sso.idp.shared(" &
        "append(\"x\")))",
      refused: true,
      phrase: "takes `<point> = <operation>(<members>)` arguments"),
    ResolverProbe(tag: "declaration-is-not-a-handle",
      # §4.6's closing paragraph: "The activity names the service; the
      # resolver yields a handle to an instance of it; the two are
      # different types and should not be spellable interchangeably."
      # The diagnostic is Nim's own overload-resolution error, left to
      # the compiler for the reason L3 left the type-mismatch case to it:
      # Nim names both the type it got and the type it expected, which
      # is what "naming what is available" means for a mismatch.
      enableLine: "    enable stack(sso = dss11owner.sso.idp)",
      refused: true, phrase: "type mismatch")]

  ExpectedRefusals = 13
  ExpectedHonoured = 6
    ## Counted here so a probe deleted from the set above is a FAILURE
    ## rather than a smaller run that still passes. The two numbers are
    ## asserted against the set's own contents below.

proc consumerFor(probe: ResolverProbe): string =
  ConsumerPreamble & probe.enableLine & "\n"

suite "D-SS11 §4.6 — the probe set is what it says it is":
  test "the set carries both honoured and refused probes, in the counts named":
    var refused = 0
    var honoured = 0
    for probe in ResolverProbes:
      if probe.refused:
        inc refused
        check probe.phrase.len > 0
      else:
        inc honoured
        check probe.phrase.len == 0
    check refused == ExpectedRefusals
    check honoured == ExpectedHonoured
    check refused + honoured == ResolverProbes.len

  test "every probe has a distinct tag":
    var tags: seq[string] = @[]
    for probe in ResolverProbes:
      check probe.tag notin tags
      tags.add(probe.tag)
    check tags.len == ResolverProbes.len

suite "D-SS11 §4.6 — a resolver compiles, and a near miss is refused by name":
  test "every honoured probe compiles CLEAN":
    for probe in ResolverProbes:
      if probe.refused:
        continue
      let result = checkConsumerWithProducer(OwnerSelector, OwnerRecipe,
        consumerFor(probe), "dss11-ok-" & probe.tag)
      if not result.ok:
        echo "probe ", probe.tag, " failed to compile:\n", result.output
      check result.ok

  test "every refused probe FAILS to compile, with its phrase present":
    for probe in ResolverProbes:
      if not probe.refused:
        continue
      let result = checkConsumerWithProducer(OwnerSelector, OwnerRecipe,
        consumerFor(probe), "dss11-no-" & probe.tag)
      if result.ok:
        echo "probe ", probe.tag, " compiled CLEAN and should not have"
      check not result.ok
      if not result.mentions(probe.phrase):
        echo "probe ", probe.tag, " was refused without its phrase `",
          probe.phrase, "`:\n", result.output
      check result.mentions(probe.phrase)

suite "D-SS11 §4.6 — the resolver is spelled on a declaration, not freely":
  test "`shared()` on something that is not a `<package>.<service>` chain is refused":
    # Not reachable through a recipe's `enable` site, so it is probed as
    # a direct call: the macro's own shape refusal has to exist for the
    # same reason every other refusal here does -- a `shared()` that
    # accepted any expression would resolve against a const name built
    # from nonsense and report Nim's "undeclared identifier" instead.
    let source = """
import repro_project_dsl

let bad = shared("dss11owner.sso.idp")
echo bad.serviceName
"""
    let result = checkRecipeSource(source, "dss11-not-a-chain")
    check not result.ok
    check result.mentions("is a resolver on a SERVICE DECLARATION")

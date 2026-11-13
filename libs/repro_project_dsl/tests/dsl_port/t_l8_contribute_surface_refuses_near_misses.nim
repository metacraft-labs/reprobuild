## Shared-Development-Services L8 — THE `contribute:` SURFACE: every
## spelling it accepts is honoured, and every plausible misspelling,
## near-miss and wrong-shape spelling is REFUSED BY NAME.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real `nim` this repo
## is built with and asserts on its real diagnostic, through the same
## `checkRecipeSource` helper L1's setter-surface test uses. See
## `service_block_compile_probe.nim` for why the in-process `compiles`
## spelling cannot be used here: measured, it answers *false* for every
## `package` block -- well-formed or not -- so both a refusal and its
## control would be vacuous.
##
## § THE STANDING HUNT THIS FILE IS
##
## The campaign's dominant finding is "constructs that are declared, look
## wired, and are silently dropped". A block-structured DSL section is
## the ideal habitat: an unrecognised head inside a section body is
## normally skipped by a `case ... else: discard` arm and the author sees
## a clean compile that contributes nothing. So the `contribute:` walker
## enumerates what it accepts and refuses everything else, and this file
## is the probe set that says so.
##
## THE SIZE OF THE PROBE SET IS A CONSTANT, NOT A SENTENCE: `AllProbes`
## below is the set, every loop iterates it, and a case of its own
## asserts its length. Three prose numbers for one set is how a probe set
## silently shrinks -- L7's review found exactly that in L7's own file.
##
## Each refusal probe is a ONE-LINE EDIT to the well-formed recipe whose
## own compile is the first case here, and each asserts the edit actually
## changed the source: a `replace` whose needle has drifted silently
## returns the input, which would turn a refusal test into a second run
## of the control.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl

package l8ProbeOwner:
  config:
    relyingParties: seq[string] = @["owner-default"]

package l8ProbeConsumer:
  contribute:
    append:
      l8ProbeOwner.relyingParties = "consumer-member"
"""

const Needle = """  contribute:
    append:
      l8ProbeOwner.relyingParties = "consumer-member"
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
  Probe(tag: "dotted-head", honoured: false,
    replacement: """  contribute.append:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["contribute", "declaration head, not a member"]),

  Probe(tag: "head-argument", honoured: false,
    replacement: """  contribute "named":
    append:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["no head", "read by nothing"]),

  Probe(tag: "operation-head-argument", honoured: false,
    replacement: """  contribute:
    append override:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["read by", "indented body"]),

  Probe(tag: "misspelled-append", honoured: false,
    replacement: """  contribute:
    appened:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["appened", "`append`", "`replaceforce`"]),

  Probe(tag: "add-is-not-an-operation", honoured: false,
    replacement: """  contribute:
    add:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["There is no `add`"]),

  Probe(tag: "set-is-not-an-operation", honoured: false,
    replacement: """  contribute:
    set:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["no `set`"]),

  Probe(tag: "remove-is-open-not-spelled", honoured: false,
    replacement: """  contribute:
    remove:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["D-SS9", "`remove`"]),

  Probe(tag: "misspelled-append-override", honoured: false,
    replacement: """  contribute:
    appendOverrides:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["appendOverrides", "`appendoverride`"]),

  Probe(tag: "bare-assignment-without-an-operation", honoured: false,
    replacement: """  contribute:
    l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @["has no operation", "SECOND axis"]),

  Probe(tag: "one-segment-key", honoured: false,
    replacement: """  contribute:
    append:
      relyingParties = "consumer-member"
""",
    mentions: @["relyingParties", "names no owner"]),

  Probe(tag: "four-segment-key", honoured: false,
    replacement: """  contribute:
    append:
      l8ProbeOwner.sso.deep.relyingParties = "consumer-member"
""",
    mentions: @["four-segment", "names no slot"]),

  Probe(tag: "non-assignment-inside-an-operation", honoured: false,
    replacement: """  contribute:
    append:
      l8ProbeOwner.relyingParties
""",
    mentions: @["every statement is an assignment"]),

  Probe(tag: "non-block-under-contribute", honoured: false,
    replacement: """  contribute:
    discard
""",
    mentions: @["accepts only operation blocks", "has no operation"]),

  Probe(tag: "operation-block-that-contributes-nothing", honoured: false,
    replacement: """  contribute:
    append:
      ## only a comment
      discard
""",
    mentions: @["would contribute nothing"]),

  Probe(tag: "normalised-spelling-is-honoured", honoured: true,
    replacement: """  contribute:
    appendoverride:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @[]),

  Probe(tag: "capitalised-spelling-is-honoured", honoured: true,
    replacement: """  contribute:
    Append:
      l8ProbeOwner.relyingParties = "consumer-member"
""",
    mentions: @[]),

  Probe(tag: "seq-literal-value-is-honoured", honoured: true,
    replacement: """  contribute:
    append:
      l8ProbeOwner.relyingParties = @["a", "b"]
""",
    mentions: @[]),

  Probe(tag: "two-segment-key-is-honoured", honoured: true,
    replacement: """  contribute:
    replaceForce:
      l8ProbeOwner.relyingParties = @["only-this"]
""",
    mentions: @[])
]

suite "L8 `contribute:` surface — the control":

  test "the well-formed recipe compiles":
    # Without this, every refusal below could be passing for a reason
    # that has nothing to do with the construct under test.
    let probe = checkRecipeSource(WellFormed, "l8-contribute-control")
    check probe.ok

  test "the probe set's size is read from the set, not from prose":
    check AllProbes.len == 18
    var refusals = 0
    var honoured = 0
    for p in AllProbes:
      if p.honoured: inc honoured else: inc refusals
    check refusals == 14
    check honoured == 4

suite "L8 `contribute:` surface — every near-miss is honoured or named":

  test "each probe is either honoured or refused BY NAME":
    for p in AllProbes:
      let source = WellFormed.replace(Needle, p.replacement)
      # The edit must have landed: a drifted needle would silently make
      # this a second run of the control.
      check source != WellFormed
      let probe = checkRecipeSource(source, "l8-contribute-" & p.tag)
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

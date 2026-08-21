## NLF-DOC-5 — a malformed `@directive` fails at recipe compile time.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-DOC-5**: "`## @id BadID` and
## `## @nonsense` both fail at recipe compile time. **Catches a hand-rolled
## scanner instead of the canonical `parseDocComment`.**"
##
## Design §4.2:
##
## > **Use the canonical parser.** `parseDocComment`
## > (`libs/repro_dsl_stdlib/.../configurables/doc_directives.nim`) is the one
## > implementation of directive extraction, and it runs **at
## > macro-expansion time** so a malformed `@id` or an unknown directive is a
## > *compile* error rather than a runtime surprise. A `lockFile` declaration
## > MUST call it.
##
## ## Why this catches a hand-rolled scanner specifically
##
## A scanner written for `lockFile` would do the easy thing: strip the `##`
## markers, join the lines, store the text. It would produce a perfectly
## reasonable description for every case below, and every one of them would
## compile. The four assertions here are the behaviours a scanner has no
## reason to implement and the canonical parser already has:
##
##   * `@id` values are validated against `[a-z][a-z0-9-]*`;
##   * an unknown `@name` is rejected rather than kept as description text;
##   * a reserved-future directive is rejected with a "not yet supported"
##     diagnostic rather than silently accepted;
##   * a well-formed `@id` is EXTRACTED — removed from the displayed
##     description — rather than left in it.
##
## The last one is the control, and it is the one that rules out the other
## easy wrong implementation: rejecting everything containing an `@`.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `lock_file_compile_probe`'s header. The compiler is real and the text
## asserted on is its real output.

import std/[strutils, unittest]

import ./lock_file_compile_probe

const Header = "import repro_dsl_stdlib/prelude\n\n"

suite "NLF-DOC-5 a malformed directive is a recipe compile error":

  test "`## @id BadID` fails, naming the rule it broke":
    let probe = checkRecipeSource(Header & """
## Tools that run on the build machine.
## @id BadID
lockFile hostTooling
""", "doc5-badid")
    check not probe.ok
    check "invalid @id" in probe.output
    # The rule, so an author can fix it without reading the parser.
    check "[a-z][a-z0-9-]*" in probe.output

  test "`## @nonsense` fails, and lists what IS supported":
    let probe = checkRecipeSource(Header & """
## Tools that run on the build machine.
## @nonsense whatever
lockFile hostTooling
""", "doc5-unknown")
    check not probe.ok
    check "unknown directive @nonsense" in probe.output
    check "supported: @id" in probe.output

  test "a reserved-future directive fails as not yet supported":
    # `@deprecated` is in `ReservedFutureDirectives`. A scanner that treated
    # unknown directives as description text would accept it silently, and
    # the day the directive lands every recipe that used it early would
    # change meaning without changing.
    let probe = checkRecipeSource(Header & """
## Tools that run on the build machine.
## @deprecated use hostTools
lockFile hostTooling
""", "doc5-future")
    check not probe.ok
    check "reserved for a future revision" in probe.output

  test "the CONTROL: a well-formed `@id` compiles and is EXTRACTED":
    # Rules out "reject anything with an @", which would pass all three
    # assertions above. The directive line must be accepted AND removed from
    # the displayed description — `Configurable-System.md` §"Comment
    # Attachment" rule 7, and the reason the description is what a listing can
    # print verbatim.
    #
    # Two details here are load-bearing, and both were found by mutating the
    # scanner away and watching this control keep passing:
    #
    #   * the assertion is in a `static:` block, because the probe runs `nim
    #     check`, which type-checks the module without executing its
    #     module-init code — so a RUN-TIME `doAssert` over the registry never
    #     fires and reports a pass against a scanner that stored `@id
    #     host-tools` verbatim;
    #   * it reads `lockFileDescriptionInScope`, the FULL captured text, not
    #     the in-scope LISTING, which prints only each description's first
    #     line. A directive is never on the first line, so the listing view
    #     reports extraction that did not happen.
    let probe = checkRecipeSource(Header & """
## Tools that run on the build machine.
## @id host-tools
lockFile hostTooling

import std/strutils
const captured = lockFileDescriptionInScope("hostTooling")
static:
  doAssert captured == "Tools that run on the build machine.",
    "description was: " & captured
  doAssert "@id" notin captured,
    "the @id directive was not extracted: " & captured
  doAssert "host-tools" notin captured,
    "the @id VALUE was not extracted: " & captured
""", "doc5-control")
    if not probe.ok:
      checkpoint("the well-formed directive was rejected:\n" & probe.output)
    check probe.ok

  test "the diagnostic names the lock file it belongs to":
    # A recipe declaring several lock files gets several doc comments; a
    # diagnostic that named none of them would send the author looking.
    let probe = checkRecipeSource(Header & """
## The good one.
lockFile hostTooling

## The bad one.
## @id NotValid
lockFile targetThing
""", "doc5-names")
    check not probe.ok
    check "lock file `targetThing`" in probe.output

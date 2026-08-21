## NLF-DOC-3 — the Comment-Attachment rules, applied to `lockFile`.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-DOC-3**: "Multiple consecutive
## `##` lines concatenate; a non-comment statement between comment and
## declaration clears the buffer; a trailing `##` does not attach."
##
## Design §4.2 makes following the EXISTING contract a requirement rather than
## an aspiration:
##
## > **Requirement.** The `lockFile` declaration MUST follow that contract
## > rather than a parallel one.
##
## and names the source: `Configurable-System.md` §"Comment Attachment" "gives
## the seven precise rules a form must satisfy — lead-only attachment, newline
## concatenation, a non-comment statement clearing the pending buffer, source
## position preserved from the **first** `##` line of the run, and
## `@directive` lines extracted and removed from the displayed description."
##
## ## What this file tests and what it deliberately does not
##
## `attachLeadDoc` implements the ATTACHMENT half — which lines attach, in
## what order, and from which position. It does NOT implement directive
## extraction: that is `parseDocComment`, the canonical parser, and §4.2
## requires the `lockFile` macro to call it rather than re-implement it.
## Splitting them is what makes NLF-DOC-5 able to catch a hand-rolled scanner:
## a scanner that also parsed directives would have no reason to call the
## canonical parser at all.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## `attachLeadDoc` is the production proc the `lockFile` macro calls; the
## inputs are line arrays, which is the form it takes in production too (the
## macro splits the recipe source and hands it over).

import std/[strutils, unittest]

import repro_lock_files

proc linesOf(text: string): seq[string] =
  text.strip(leading = true, trailing = false).splitLines()

suite "NLF-DOC-3 doc-comment attachment rules":

  test "a single leading line attaches":
    let src = linesOf("""
## Tools that run on the build machine.
lockFile hostTools
""")
    let doc = attachLeadDoc(src, 1)
    check doc.text == "Tools that run on the build machine."
    check doc.line == 1

  test "multiple consecutive lines CONCATENATE, newline-joined and in order":
    # In order, and the order is asserted rather than just the membership: a
    # scan that collects upward and forgets to reverse produces the same set
    # of lines and a description that reads backwards.
    let src = linesOf("""
## Tools that run on the build machine: code generators, compilers,
## anything whose output is consumed during the build rather than shipped.
lockFile hostTools
""")
    let doc = attachLeadDoc(src, 2)
    check doc.text ==
      "Tools that run on the build machine: code generators, compilers,\n" &
      "anything whose output is consumed during the build rather than shipped."
    check doc.line == 1

  test "a non-comment statement between comment and declaration CLEARS it":
    let src = linesOf("""
## This paragraph belongs to something else.
let unrelated = 1
lockFile hostTools
""")
    let doc = attachLeadDoc(src, 2)
    check doc.text == ""
    check doc.line == 0

  test "and so does a blank line":
    # The stricter reading of lead-only attachment, and the one that cannot
    # silently pick up an unrelated paragraph from further up the file.
    let src = linesOf("""
## A paragraph about something else entirely.

lockFile hostTools
""")
    let doc = attachLeadDoc(src, 2)
    check doc.text == ""

  test "a TRAILING `##` does not attach":
    # The comment BELOW the declaration belongs to whatever follows it, if
    # anything. The scan only moves upward, so this holds by construction —
    # asserted anyway, because "holds by construction" is a property of
    # today's implementation and this is the rule.
    let src = linesOf("""
lockFile hostTools
## This is not hostTools' description.
""")
    let doc = attachLeadDoc(src, 0)
    check doc.text == ""
    check doc.line == 0

  test "only the run IMMEDIATELY above attaches, not an earlier one":
    let src = linesOf("""
## An earlier paragraph.
lockFile targetRuntime
## The one that belongs to hostTools.
lockFile hostTools
""")
    let second = attachLeadDoc(src, 3)
    check second.text == "The one that belongs to hostTools."
    let first = attachLeadDoc(src, 1)
    check first.text == "An earlier paragraph."

  test "the leading marker and ONE following space are stripped, no more":
    # Indentation inside a description is meaningful — a description may
    # contain an indented list — so exactly one separator space is removed.
    let src = linesOf("""
##   indented continuation
lockFile hostTools
""")
    let doc = attachLeadDoc(src, 1)
    check doc.text == "  indented continuation"

  test "a declaration at the top of a file has no run above it":
    let src = linesOf("""
lockFile hostTools
""")
    let doc = attachLeadDoc(src, 0)
    check doc.text == ""
    check doc.line == 0

## NLF-DOC-4 — the recorded position is the FIRST `##` line and ITS column.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-DOC-4**: "Position is the first
## `##` line and its column — not the declaration's line with column 0, which
## is what the existing variant path does and what copying it would
## reproduce."
##
## Design §4.2 singles this rule out by name:
##
## > **Capture position from the first comment line**, not from the
## > declaration. This is Comment-Attachment rule 6, and it is the rule most
## > easily got wrong — the existing variant path emits `descriptionColumn =
## > 0` and the declaration's line rather than the comment run's, while
## > `eval_config.nim` does it correctly. Follow `eval_config.nim`.
##
## ## The two wrong answers this file distinguishes between
##
## A test that only checked "the line is not the declaration's" would pass
## against an implementation that recorded the LAST comment line — which is
## off by one for every multi-line description, and every description in
## §4.2's own example is multi-line. So the declarations below are positioned
## so that the first line, the last line, and the declaration line are three
## DIFFERENT numbers, and the column is non-zero and distinguishable from 0.
##
## Line numbers are computed from a recorded anchor rather than written as
## literals, because a literal line number in a test is invalidated by any
## edit above it and is then usually "fixed" by updating the literal — which
## silently converts the assertion into a restatement of whatever the
## implementation currently does.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The declarations below are real `lockFile` declarations expanded by the
## real macro, and the positions are read out of the real registry.

import std/[unittest]

import repro_dsl_stdlib/lock_file_decl
import repro_lock_files

template lineHere(): int = instantiationInfo().line
  ## The line this template is INSTANTIATED on. Every expected position below
  ## is recorded through it rather than written as a literal, because a
  ## literal line number is invalidated by any edit above it and is then
  ## usually "fixed" by updating the literal — which silently converts the
  ## assertion into a restatement of whatever the implementation does.

const ThisFile = currentSourcePath()
  ## Captured at module scope. Inside a `unittest` `test` block
  ## `currentSourcePath()` reports `unittest.nim`, because the body is a
  ## template instantiation there.

const FirstCommentLine = lineHere() + 1
## First line of the description, and the line the position must report.
## Second line, which an off-by-one implementation would report instead.
## Third line, immediately above the declaration.
lockFile docPositioned
const DeclarationLine = lineHere() - 1

proc declOf(name: string): LockFileDecl =
  for d in lockFileDeclarations():
    if d.name == name: return d
  LockFileDecl()

suite "NLF-DOC-4 the position is the first comment line":

  test "the declaration was captured at all":
    let d = declOf("docPositioned")
    check d.name == "docPositioned"
    check d.description.len > 0

  test "the recorded line is the FIRST `##` line of the run":
    let d = declOf("docPositioned")
    check d.sourceLine == FirstCommentLine

  test "and it is NOT the declaration's own line":
    # The defect §4.2 names: "the existing variant path emits … the
    # declaration's line rather than the comment run's".
    let d = declOf("docPositioned")
    check d.sourceLine != DeclarationLine

  test "and it is NOT the LAST comment line either":
    # The off-by-one an implementation that recorded the run's END would
    # produce. Every description in §4.2's own example is multi-line, so this
    # is the common case rather than a corner.
    let d = declOf("docPositioned")
    check d.sourceLine != DeclarationLine - 1

  test "the column is the comment's column, not 0":
    # The other half of §4.2's correction: "the existing variant path emits
    # `descriptionColumn = 0`". The declarations here sit at the left margin,
    # so their `#` is at column 1 — which is exactly one apart from the wrong
    # answer, and is why the assertion is on the value rather than on
    # non-zeroness alone.
    let d = declOf("docPositioned")
    check d.sourceColumn == 1

  test "the description is the whole run, in order":
    let d = declOf("docPositioned")
    check d.description ==
      "First line of the description, and the line the position must report.\n" &
      "Second line, which an off-by-one implementation would report instead.\n" &
      "Third line, immediately above the declaration."

  test "the source file is this file":
    let d = declOf("docPositioned")
    check d.sourceFile == ThisFile

## Fixture: a test binary that writes ordinary output on stdout from a
## suite body, then still has to hand a runner a usable protocol document.
##
## This is the hazard `t_protocol_document_survives_suite_body_echo.nim`
## regression-tests. It is a FIXTURE, not a suite: it lives under
## `tests/fixtures/`, which `scripts/generate_test_edges.nim` excludes, so
## nothing builds or runs it except that test, which compiles it into a
## scratch directory.
##
## The three stdout-bearing protocol modes (`--list`, `--list-json`,
## `--catalog -`) share fd 1 with whatever the program itself prints. A
## suite body is ordinary code that runs during registration — in EVERY
## mode, including the protocol ones, because registration is how the
## catalog is built. So an `echo` there interleaves with the document.
##
## The noise below is deliberately adversarial in four different ways, one
## per line, so a consumer's recovery is exercised rather than merely
## reached:
##
##   1. output before any suite has been entered at all;
##   2. output from the suite body before the first `test` registration —
##      i.e. before `unittest` has even parsed the protocol flags, which it
##      does lazily at the first `test`;
##   3. a partial line with no terminating newline, so the document does
##      not begin at a line boundary;
##   4. a line shaped like the document itself (`{"tests"…`), so a
##      marker-scanning recovery has to reject a decoy before it finds the
##      real payload.
##
## The two cases are trivial and always pass: what is under test is the
## binary's ENUMERABILITY, not its results.

import std/unittest

echo "fixture noise: before any suite"

suite "echoing suite":
  echo "fixture noise: suite body, before the first test"
  stdout.write "fixture noise: a partial line with no newline -> "

  test "first case":
    check true

  echo "fixture noise: suite body, between two tests"
  echo "{\"tests\": \"decoy that is not a catalog\"}"

  test "second case":
    check true

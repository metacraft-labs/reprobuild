## DA-1i — the `--evidence` help text names the HAZARD, not only the behaviour.
##
## An operator choosing `--evidence=reads-only` is accepting a specific,
## nameable risk. A risk described only in a spec directory is not one they
## were given the chance to accept, so DA-1i treats the user-facing text as
## part of the milestone rather than as follow-up documentation.
##
## THE HAZARD TABLE IS NORMATIVE AND MUST APPEAR IN THE SAME SHAPE IN THREE
## PLACES: `reprobuild-specs/CLI/build.md` §"Dependency Evidence Scope" (the
## source, and not in this repository), `docs/dependency-collection.md`, and
## the help text. Its value is that it is NARROWER than "probes are unsafe" —
## two shapes of change are still caught and two are not — so a copy that
## keeps the flag and drops the rows is worse than no copy at all: it tells an
## operator the mode exists without telling them what it costs.
##
## The fourth row and the sentence under it are the ones most likely to be
## edited away, because row 1 reads as though it already covered row 4. It
## does not: a file that EXISTED but could not be OPENED is not "a file the
## build read", because it is not recorded at all. Both in-repo copies are
## checked for that sentence specifically.
##
## MOCK POLICY — NO MOCKS. The assertions read the real `renderUsage` output
## and the real committed documentation file.

import std/[os, strutils, unittest]

import repro_cli_support

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "cannot locate reprobuild repo root")

proc missing(haystack: string; needles: openArray[string]): seq[string] =
  for needle in needles:
    if not haystack.contains(needle):
      result.add(needle)

## The four rows, reduced to the phrases that carry them — ONE LIST PER COPY,
## because the help text is prose and the document is a markdown table and
## requiring identical bytes would force one of them into the other's shape.
## What must be identical is the CLAIMS, not the words.
##
## EACH NEEDLE CARRIES ITS ROW'S CLAIM RATHER THAN ONE COMMON WORD, and that
## is not stylistic. Measured: with `"modified"` and `"deleted"` as the
## needles, deleting row 2 from the document left this suite GREEN (the word
## occurs again in an unrelated paragraph about scratch files that "can be
## deleted"), and striking row 1's clause from the help text left it green too
## (the caveat sentence below the table QUOTES row 1 verbatim, so the word
## survives its own row's deletion). A needle that its own row's deletion
## cannot move is a check that cannot fail — the defect class this campaign's
## APPENDIX names twice. Every needle below was measured to occur EXACTLY ONCE
## in the copy it grades, and each row's deletion was measured to redden.
const HelpHazardRows = [
  "Still detected: a recorded file is modified",  # row 1: still detected
  "a recorded file is deleted",                   # row 2: still detected
  "shadows one earlier in a search path",         # row 3: NOT detected
  "becomes openable",                             # row 4: NOT detected
]

const DocHazardRows = [
  "the build read is **modified**",               # row 1: still detected
  "the build read is **deleted**",                # row 2: still detected
  "shadows one earlier in a search path",         # row 3: NOT detected
  "becomes openable",                             # row 4: NOT detected
]

suite "DA-1i the operator is told what reads-only costs":

  test "the build synopsis offers the flag":
    let usage = renderUsage("repro")
    if not usage.contains("--evidence=full|reads-only"):
      echo "`repro --help` does not offer `--evidence=full|reads-only`. A ",
        "flag an operator cannot discover is a flag that only appears in ",
        "somebody's shell history."
    check usage.contains("--evidence=full|reads-only")

  test "the help text carries all four hazard rows":
    let usage = renderUsage("repro")
    let absent = missing(usage, HelpHazardRows)
    if absent.len > 0:
      echo "the `--evidence` help text is missing ", absent.len,
        " of the four normative hazard rows: ", absent,
        "\n  The table's value is that it is NARROWER than \"probes are ",
        "unsafe\" — an operator who is told only that the mode is faster ",
        "has not been told what it costs."
    check absent.len == 0

  test "the help text says row 1 does not cover row 4":
    ## The sentence the milestone marks normative, because without it a reader
    ## concludes "a file the build read is modified" already handles the
    ## unreadable-becomes-readable case. It does not, and the reason is that
    ## the file is not recorded at all.
    let usage = renderUsage("repro")
    if not usage.contains("not recorded at all"):
      echo "the `--evidence` help text does not say that an unopenable file ",
        "is NOT RECORDED AT ALL, so a reader will take row 1 (\"a recorded ",
        "file is modified\") to cover row 4. It does not."
    check usage.contains("not recorded at all")

  test "the help text does not sell it as a speed feature":
    ## DA-1i is explicit that the win must not be overstated: the failed
    ## lookups this drops are largely elidable SOUNDLY by content-addressed-
    ## root elision at no correctness cost. The mode exists for
    ## ninja-comparability.
    let usage = renderUsage("repro")
    let absent = missing(usage, ["NOT merely faster", "ninja", "not speed"])
    if absent.len > 0:
      echo "the `--evidence` help text is missing ", absent,
        ". A text that offers a correctness trade as a speed knob invites ",
        "the trade to be made for the wrong reason."
    check absent.len == 0

  test "the help text says what is NOT degraded":
    ## Artifacts and publishing are unaffected — the degraded thing is the
    ## up-to-dateness check, not the product. An operator who thinks the
    ## output bytes are suspect will throw away work that is perfectly good.
    let usage = renderUsage("repro")
    let absent = missing(usage,
      ["correct and publishable", "staleness check", "--evidence=full"])
    if absent.len > 0:
      echo "the `--evidence` help text is missing ", absent
    check absent.len == 0

  test "the help text states the consumer rule and the cache-key rule":
    ## Both halves of "how a teammate is protected": a narrowed capture is
    ## refused by a build that requires full evidence, AND the scope is not in
    ## the cache key, so a full-evidence result stays usable by everyone.
    ## Stating only the first would read as "reads-only poisons the cache".
    let usage = renderUsage("repro")
    let absent = missing(usage,
      ["refused by a build that requires full evidence",
       "not part of the cache key"])
    if absent.len > 0:
      echo "the `--evidence` help text is missing ", absent
    check absent.len == 0

  test "both copies name the SESSION-WIDE blast radius of a refusal":
    ## THE SECOND HAZARD THIS FLAG CARRIES, and the one an operator meets as a
    ## build that mysteriously stopped caching.
    ##
    ## Refusing a narrowed capture is graded `mesUnknownScopeLoss` — Level 2 on
    ## `Failure-Semantics.md`'s ladder — and Level 2 sets the scheduler's
    ## session-wide `sessionCachePublishDisabled`, so the FIRST refusal turns
    ## every later action-cache lookup in that session into a miss. Level 1
    ## (narrow invalidation) is structurally unavailable here: a `reads-only`
    ## record cannot name the lookups it dropped, so there is no path set to
    ## invalidate instead.
    ##
    ## Both operator-facing copies said only "recomputes locally", which reads
    ## as a per-action cost and understates it by the whole session. A cost an
    ## operator is not told is a cost they did not accept — the same argument
    ## that made the hazard table part of this milestone rather than a
    ## follow-up. Graded on BOTH copies because either one alone leaves an
    ## operator who read the other one surprised.
    let usage = renderUsage("repro")
    let doc = readFile(repoRoot() / "docs" / "dependency-collection.md")
    const Needle = "every later cache lookup in that session"
    for (name, text) in {"the --evidence help text": usage,
                         "docs/dependency-collection.md": doc}:
      if not text.contains(Needle):
        echo name, " does not say that a refusal costs ", Needle,
          ". It is graded as an unknown-scope loss, which disables cache " &
          "lookups for the WHOLE session, not just the refused action — an " &
          "operator told only \"recomputes locally\" will read the result " &
          "as a caching bug rather than as the cost of the flag they chose."
      check text.contains(Needle)
    # And the recovery, which is what makes the paragraph actionable rather
    # than merely alarming: opting into the reduced scope accepts such records.
    check usage.contains("--evidence=reads-only")
    check doc.contains("--evidence=reads-only")

suite "DA-1i the committed documentation carries the same table":

  test "docs/dependency-collection.md carries all four rows and the caveat":
    ## The second of the three normative copies. The spec copy
    ## (`reprobuild-specs/CLI/build.md`) lives in a sibling repository and is
    ## deliberately not reached from here — a test that read across a repo
    ## boundary would be red on any checkout that does not have the sibling.
    let doc = readFile(repoRoot() / "docs" / "dependency-collection.md")
    let absent = missing(doc, DocHazardRows)
    if absent.len > 0:
      echo "docs/dependency-collection.md is missing ", absent.len,
        " of the four normative hazard rows: ", absent
    check absent.len == 0
    check doc.contains("not recorded at all")
    check doc.contains("--evidence=reads-only")

  test "the documentation states the same one-directional rule":
    let doc = readFile(repoRoot() / "docs" / "dependency-collection.md")
    check doc.contains("one-directional")
    # And the recovery, which is what turns a scary paragraph into an
    # actionable one.
    check doc.contains("--evidence=full")

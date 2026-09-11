## Every value `repro attest` can exit with is written down, and the ones
## already written down never change meaning.
##
## ## Why this gate exists
##
## An exit code is the only part of a verdict a shell script reads. That
## makes it a contract, and a contract nobody enumerated is one that
## drifts: a command grows an outcome, the outcome grows a code, and the
## reference page keeps describing the set that existed before. The
## caller who reads the page then writes a branch that is wrong in
## exactly the case the new code was added for.
##
## ## Why a gate that greps a markdown file for numbers is not enough
##
## It is the easiest shape in this repository to write and one of the
## easiest to satisfy by accident. Searching a document for "`4`" is
## satisfied by the digit appearing anywhere — in a flag's default, in a
## version number, in a sentence about something else entirely. Worse, a
## document may say a thing twice and disagree with itself, and a
## substring search takes whichever occurrence it meets first. So:
##
##   * the search is SCOPED to the exit-code section and the section is
##     located by its heading, not by proximity;
##   * a second such section is REFUSED rather than merged, because a
##     document with two of them can show a reader one answer and this
##     parser another;
##   * a code documented TWICE inside the one section is REFUSED for the
##     same reason — last-writer-wins is how a lie followed by the truth
##     passes a parser while an operator reading top-down meets the lie;
##   * a bullet with no prose after the number does not count as
##     documentation of anything;
##   * a bullet inside a fenced block is an EXAMPLE and not the contract,
##     so it is not read as documentation — otherwise the contract could
##     be satisfied by a sample of itself;
##   * and the relation asserted is SET EQUALITY in both directions, so a
##     code the command can return and the page omits fails, and so does
##     a code the page describes and the command cannot produce.
##
## The numbers themselves are pinned as LITERALS. Asserting
## `AttestExitUsage == AttestExitUsage` is the shape that passes whatever
## the constant is changed to, and the defect this gate exists for was
## exactly a channel that said one thing while another said another.
##
## ## The two documents
##
## The command's own `--help` output is in this repository and is checked
## unconditionally: wherever this test runs, an exit code added without
## being documented there reddens. The CLI reference page lives in the
## sibling specification checkout, which is not present in every
## environment; when that checkout is absent entirely the page's case
## skips, but when it is present the page must exist and must agree —
## deleting the file is not a way to get the assertion to stop applying.
##
## ## Mocking
##
## None. Both documents are read from disk as they ship.

import std/[algorithm, os, strutils, tables, unittest]

import repro_attest_verify
import repro_cli_support/attest

const
  ExitCodeHeading = "## Exit codes"

let thisDir = currentSourcePath().parentDir

proc findUpFile(startDir, rel: string): string =
  var dir = startDir
  for _ in 0 .. 8:
    let candidate = dir / rel
    if fileExists(candidate): return candidate
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir: break
    dir = parent
  ""

proc findUpDir(startDir, rel: string): string =
  var dir = startDir
  for _ in 0 .. 8:
    let candidate = dir / rel
    if dirExists(candidate): return candidate
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir: break
    dir = parent
  ""

proc parseIntOrNone(s: string): int =
  ## The token's integer value, or -1 when it is not a bare integer.
  if s.len == 0: return -1
  for c in s:
    if c notin {'0' .. '9'}: return -1
  parseInt(s)

proc documentedInReference(md: string): Table[int, string] =
  ## The exit codes the reference page's own exit-code section lists, and
  ## the prose attached to each. Bullets are `- \`N\` — …`; a bullet's
  ## continuation lines are folded into its prose.
  ##
  ## Fenced blocks are skipped, in both directions. A bullet inside a
  ## fence renders as an *example* rather than as the contract, so
  ## counting it would let the contract be satisfied by a sample — the
  ## same shape as a bullet moved to another section, one step smaller.
  ## And an illustrative block that happened to show a code this command
  ## cannot return would otherwise fail the set equality below for no
  ## reason. The fence state is tracked across the whole document rather
  ## than inside the section, so a heading quoted inside a fence does not
  ## open or close one either.
  result = initTable[int, string]()
  var sections = 0
  var inSection = false
  var inFence = false
  var current = -1
  for rawLine in md.splitLines:
    let line = rawLine
    if line.strip().startsWith("```"):
      inFence = not inFence
      current = -1
      continue
    if inFence: continue
    if line.startsWith("## "):
      if line.strip() == ExitCodeHeading:
        inc sections
        doAssert sections == 1,
          "the reference page opens a second `" & ExitCodeHeading &
            "` section; a document with two of them can tell a reader one " &
            "thing and this parser another"
        inSection = true
        current = -1
      else:
        inSection = false
        current = -1
      continue
    if not inSection: continue
    if line.startsWith("- `"):
      let close = line.find('`', 3)
      if close < 0:
        current = -1
        continue
      let code = parseIntOrNone(line[3 ..< close])
      if code < 0:
        current = -1
        continue
      doAssert code notin result,
        "the reference page documents exit code " & $code & " twice; " &
          "whichever entry is read second would silently replace the one a " &
          "reader meets first"
      var prose = line[close + 1 .. ^1].strip()
      # The bullet's separator, whichever dash the page uses.
      for dash in ["—", "-", "–"]:
        if prose.startsWith(dash):
          prose = prose[dash.len .. ^1].strip()
          break
      result[code] = prose
      current = code
      continue
    if current >= 0 and line.startsWith("  ") and line.strip().len > 0:
      result[current] = result[current] & " " & line.strip()
      continue
    current = -1

proc documentedInUsage(usage: string): Table[int, string] =
  ## The exit codes the command's own `--help` lists. The block opens on
  ## a line reading `Exit codes:` and each entry is `  N  prose`.
  result = initTable[int, string]()
  var blocks = 0
  var inBlock = false
  var current = -1
  for line in usage.splitLines:
    if line.strip() == "Exit codes:":
      inc blocks
      doAssert blocks == 1,
        "the usage text opens a second exit-code block; the one a user " &
          "reads and the one this parser reads would not have to agree"
      inBlock = true
      current = -1
      continue
    if not inBlock: continue
    if line.len == 0:
      inBlock = false
      current = -1
      continue
    let fields = line.strip().splitWhitespace()
    if line.startsWith("  ") and not line.startsWith("   ") and
       fields.len >= 2 and parseIntOrNone(fields[0]) >= 0:
      let code = parseIntOrNone(fields[0])
      doAssert code notin result,
        "the usage text lists exit code " & $code & " twice"
      result[code] = line.strip()[fields[0].len .. ^1].strip()
      current = code
      continue
    if current >= 0 and line.startsWith("   "):
      result[current] = result[current] & " " & line.strip()
      continue
    inBlock = false
    current = -1

proc codeSet(t: Table[int, string]): seq[int] =
  for k in t.keys: result.add k
  result.sort()

suite "the attest exit codes are documented and stable":

  # -- stability ------------------------------------------------------

  test "the existing codes keep their values, and the new one is appended":
    # Literals, because a comparison against the constant that produced
    # the value passes whatever that constant becomes.
    check ord(aecAccepted) == 0
    check ord(aecRejected) == 1
    check ord(aecUsage) == 2
    check ord(aecAcceptedNoRootOfTrust) == 3
    check ord(aecAcceptedUnauthenticatedManifest) == 4

    # The names the rest of the codebase uses are the same values, so
    # neither spelling can drift away from the other.
    check AttestExitAccepted == ord(aecAccepted)
    check AttestExitRejected == ord(aecRejected)
    check AttestExitUsage == ord(aecUsage)
    check AttestExitAcceptedNoRootOfTrust == ord(aecAcceptedNoRootOfTrust)
    check AttestExitAcceptedUnauthenticatedManifest ==
      ord(aecAcceptedUnauthenticatedManifest)

    # The four that predate this change occupy the four lowest ordinals,
    # so the fifth is an addition rather than a renumbering.
    check ord(aecAcceptedUnauthenticatedManifest) > ord(aecAcceptedNoRootOfTrust)
    check ord(aecAcceptedNoRootOfTrust) > ord(aecUsage)
    check ord(aecUsage) > ord(aecRejected)
    check ord(aecRejected) > ord(aecAccepted)

  test "every decision maps to a code, and the successes are not 0 twice":
    var codes: seq[int] = @[]
    for d in VerdictDecision:
      let code = ord(attestExitCodeFor(d))
      check code notin codes
      codes.add code
    # Exactly one decision exits 0, and it is the unqualified one.
    check ord(attestExitCodeFor(vdAccepted)) == 0
    var zeros = 0
    for d in VerdictDecision:
      if ord(attestExitCodeFor(d)) == 0: inc zeros
    check zeros == 1

  # -- documented, in the command itself ------------------------------

  test "the command's own usage documents exactly the codes it can return":
    let listed = documentedInUsage(renderAttestUsage())
    var expected: seq[int] = @[]
    for c in AttestExitCode: expected.add ord(c)
    expected.sort()
    check listed.codeSet == expected
    check expected.len >= 5

    for code, prose in listed:
      check prose.len > 0
      if prose.len == 0: echo "usage documents ", code, " with no prose"

    # Each decision's code is described by naming that decision, so a
    # decision added without its own entry cannot pass.
    for d in VerdictDecision:
      let code = ord(attestExitCodeFor(d))
      check listed.hasKey(code)
      if listed.hasKey(code):
        check ("`" & $d & "`") in listed[code]
        if ("`" & $d & "`") notin listed[code]:
          echo "usage entry for ", code, " does not name ", $d, ": ",
            listed[code]

  # -- the reference parser, on documents written for it ---------------

  test "the reference parser reads the contract's own section and nothing else":
    # A parser over a markdown file is the easiest thing here to satisfy
    # by accident, so its scope is pinned on documents constructed for
    # the purpose rather than only through the page that ships. These
    # assertions hold wherever this test runs — no sibling checkout is
    # involved.
    const Contract = """
## Exit codes

- `0` — success.
- `1` — a failure.
"""
    let base = documentedInReference(Contract)
    check base.codeSet == @[0, 1]

    # Text present in the FILE but not in the contract's section: the
    # entry is in a different section, so the parser does not see it.
    check documentedInReference(Contract & """
## Notes

- `7` — documented somewhere else entirely.
""").codeSet == @[0, 1]

    # Text present in the SECTION but inside a fence: it renders as an
    # example of a contract rather than as the contract.
    check documentedInReference("""
## Exit codes

- `0` — success.
- `1` — a failure.

```
- `7` — what a future version might add.
```
""").codeSet == @[0, 1]

    # …and the same entry outside the fence IS read, so the emptiness
    # above is the fence's doing and not a parser that reads nothing.
    check documentedInReference("""
## Exit codes

- `0` — success.
- `1` — a failure.
- `7` — what a future version might add.
""").codeSet == @[0, 1, 7]

    # A fence that opens before the section does not swallow it silently
    # into a pass: the section's own bullets stop being read.
    check documentedInReference("""
```
## Exit codes

- `0` — success.
```

- `1` — a failure.
""").codeSet.len == 0

  # -- documented, in the CLI reference -------------------------------

  test "the CLI reference documents exactly the codes the command can return":
    # The reference page lives in the sibling specification checkout. If
    # that checkout is absent altogether there is nothing to read; if it
    # is present the page must be there, so removing the file is not a
    # way out of this assertion.
    let specsRoot = findUpDir(thisDir, ".." / "reprobuild-specs")
    if specsRoot.len == 0:
      skip()
    else:
      let docPath = findUpFile(thisDir,
        ".." / "reprobuild-specs" / "CLI" / "attest.md")
      check docPath.len > 0
      if docPath.len > 0:
        let md = readFile(docPath)
        check ExitCodeHeading in md
        let listed = documentedInReference(md)

        var expected: seq[int] = @[]
        for c in AttestExitCode: expected.add ord(c)
        expected.sort()

        # Set equality, both directions: a code the command can return
        # and the page omits fails, and so does a code the page invents.
        check listed.codeSet == expected
        if listed.codeSet != expected:
          echo "documented: ", listed.codeSet, " can be returned: ", expected

        for code, prose in listed:
          check prose.len > 0
          if prose.len == 0:
            echo "the page lists ", code, " with nothing said about it"

        for d in VerdictDecision:
          let code = ord(attestExitCodeFor(d))
          check listed.hasKey(code)
          if listed.hasKey(code):
            check ("`" & $d & "`") in listed[code]
            if ("`" & $d & "`") notin listed[code]:
              echo "the entry for ", code, " does not name ", $d, ": ",
                listed[code]

        # The page states the promise the numbers above rest on.
        check "appended rather than a renumbering" in md

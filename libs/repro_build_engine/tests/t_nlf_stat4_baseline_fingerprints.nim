## NLF-STAT-4 — a workspace declaring nothing is unchanged.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-STAT-4**
## (`Named-Lock-Files-Test-Corpus.md` §6): "An existing workspace with no
## lock-file declarations, built before and after the feature lands. Expect:
## byte-identical action fingerprints. Catches: a default-path regression —
## the feature altering identity for every existing user."
##
## The corpus entry also says this is "the one case in the corpus that must run
## against **both** the pre-change and post-change implementation, so it needs
## recorded baseline fingerprints as a fixture". The fixture is
## `fixtures/nlf_stat4_baseline_fingerprints.tsv`, recorded from
## `nlf_stat4_baseline_corpus.nim` on reprobuild `dev` at `b6de037fe`, BEFORE
## NLF-M4 changed anything. This module is the assertion half: it recomputes
## the corpus against the live engine and requires the bytes to match.
##
## ## What this gate means AFTER NLF-M7, which is not what it meant before
##
## Through NLF-M4, M5 and M6 the fixture was frozen at the pre-campaign values
## and this file's job was to keep it there. **NLF-M7 moved it, once, on
## purpose.** §7's keying became effective — the governing lock identity now
## enters `weakFingerprint` — and `Named-Lock-Files.milestones.org` NLF-M7
## names that as the milestone's own exit criterion: "the exit criterion is not
## 'unchanged' here but 'changed exactly where designation differs, and nowhere
## else'."
##
## So this file is no longer the whole gate; it is one half of it. It holds the
## post-M7 values and catches any FURTHER movement. The other half —
## `t_workspace_declaring_nothing_unchanged` — holds the frozen M4 record and
## checks that the one move was exactly the keying and nothing else, row by
## row. Read them together: this one says "nothing has moved since M7", that
## one says "what moved at M7 was only this".
##
## Failing this test is still not "the fixture is stale". It is the migration
## gate reporting that something has changed the fingerprint of an edge in a
## workspace that declares no lock files, which for existing users is a full
## rebuild.
##
## Test-double policy: NO mocks, doubles, or fakes. The corpus is built from
## the engine's real public constructors and the recorded digest is the real
## `weakFingerprint` the action cache keys on.

import std/[os, strutils, unittest]

import ./nlf_stat4_baseline_corpus

proc fixturePath(): string =
  currentSourcePath().parentDir() / BaselineFixtureRelPath

proc dataLines(text: string): seq[string] =
  result = @[]
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    result.add(line)

suite "NLF-STAT-4 baseline action fingerprints":

  test "the baseline corpus covers every engine edge kind":
    # A migration gate is only as wide as its corpus. If a new
    # `BuildActionKind` is added and the corpus is not extended, the gate
    # silently stops covering it — the §7.2 failure shape in miniature.
    check assertEveryEdgeKindCovered() == ""

  test "every action fingerprint is byte-identical to the recorded baseline":
    let path = fixturePath()
    require fileExists(path)
    let expected = dataLines(readFile(path))
    let actual = dataLines(baselineCorpusText())

    # Report row-by-row rather than as one opaque blob: a whole-file
    # inequality tells a future reader nothing about WHICH edge moved, and
    # "which edge kind" is the whole diagnostic value of the case.
    check actual.len == expected.len
    let shared = min(actual.len, expected.len)
    for i in 0 ..< shared:
      if actual[i] != expected[i]:
        checkpoint("baseline row " & $(i + 1) & " changed" &
          "\n  recorded: " & expected[i] &
          "\n  current:  " & actual[i])
      check actual[i] == expected[i]
    for i in shared ..< expected.len:
      checkpoint("baseline row dropped: " & expected[i])
      check false
    for i in shared ..< actual.len:
      checkpoint("baseline row added: " & actual[i])
      check false

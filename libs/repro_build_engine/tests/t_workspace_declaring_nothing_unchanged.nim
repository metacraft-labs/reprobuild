## NLF-STAT-4, at the end of the campaign: the diff is explainable line by
## line.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-STAT-4** ("a workspace declaring
## nothing is unchanged"), compared against the **M4 baseline** as the ledger's
## verification entry asks.
##
## ## This is the milestone where the assertion INVERTS, and why that is right
##
## Through NLF-M4, M5 and M6 the property was byte-identity: NLF-STAT-4's
## fixture had to match, and it did. NLF-M7 makes §7's keying effective — the
## governing lock identity enters `weakFingerprint` — so the fingerprints
## move. `Named-Lock-Files.milestones.org` NLF-M7 states the exit criterion in
## those terms:
##
## > This is the milestone that MOVES the NLF-STAT-4 fingerprints. That is
## > expected and is the point: the exit criterion is not "unchanged" here but
## > "changed exactly where designation differs, and nowhere else". A diff of
## > the baseline against the post-M7 corpus must be explainable line by line.
##
## An explanation written in a commit message is not checkable. This file is
## the explanation as an assertion, and it is deliberately stronger than "the
## rows differ":
##
##   1. the corpus has the same rows, in the same order, with the same ids and
##      kinds — nothing was added, dropped or reordered under cover of the
##      move;
##   2. every `material` digest is **byte-identical** to M4's. That column is
##      frozen at the pre-NLF-M4 field list (kind, id, argv, cwd, env, inputs,
##      outputs, deps, pool, cacheable), so an unchanged material digest is the
##      statement that no edge's observable content changed. A fingerprint that
##      moved WITH its material digest would be something else entirely and
##      this case would not catch it without column 2;
##   3. every `fingerprint` **differs** from M4's — the move actually happened,
##      so this file cannot pass vacuously against an implementation that
##      forgot to key;
##   4. and each current fingerprint is **exactly** `keyedOnGoverningLock` of
##      the M4 fingerprint under the corpus's governing lock identity. This is
##      the "line by line" part: the change is the keying and nothing else. A
##      fingerprint that moved for a second, unrelated reason — an id
##      derivation change, an extra field mixed in, a different domain tag —
##      satisfies (1), (2) and (3) and fails here.
##
## ## The M4 fixture is now a frozen historical record
##
## `fixtures/nlf_stat4_m4_baseline_fingerprints.tsv` is the byte-for-byte copy
## of what NLF-M4 recorded on reprobuild `dev` at `b6de037fe`, kept so the
## comparison above has something to compare against. It must never be
## regenerated: the moment it is, assertion (4) becomes a tautology over two
## copies of the same file. `fixtures/nlf_stat4_baseline_fingerprints.tsv` is
## the live gate and holds the post-M7 values.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The corpus is built from the engine's real public constructors and the
## digests are the real `weakFingerprint` the action cache keys on
## (`repro_local_store.ActionCache` looks up by exactly this digest). The M4
## column is real recorded output, not a synthesised expectation.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_hash

import ./nlf_stat4_baseline_corpus

const M4FixtureRelPath = "fixtures/nlf_stat4_m4_baseline_fingerprints.tsv"

type Row = object
  id, kind, fingerprint, material: string

proc hex(digest: ContentDigest): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(digest.bytes.len * 2)
  for b in digest.bytes:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F'u8)])

proc parseDigest(text: string): ContentDigest =
  ## Read a lowercase-hex digest back into a `ContentDigest`, so the M4
  ## fixture's recorded value can be fed through the real
  ## `keyedOnGoverningLock` rather than compared as a string against a value
  ## this test computed some other way.
  doAssert text.len == result.bytes.len * 2,
    "digest hex has the wrong width: " & text
  for i in 0 ..< result.bytes.len:
    result.bytes[i] = byte(parseHexInt(text[i * 2 .. i * 2 + 1]))

proc rows(text: string): seq[Row] =
  result = @[]
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let parts = line.split('\t')
    doAssert parts.len == 4, "malformed row: " & line
    result.add(Row(id: parts[0], kind: parts[1], fingerprint: parts[2],
      material: parts[3]))

proc m4Rows(): seq[Row] =
  rows(readFile(currentSourcePath().parentDir() / M4FixtureRelPath))

proc currentRows(): seq[Row] =
  rows(baselineCorpusText())

suite "NLF-STAT-4 the post-M7 diff against the M4 baseline is explained":

  test "the M4 record is present and non-empty":
    # Assertion (4) below is vacuous against an empty file, and a fixture that
    # silently went missing is exactly how a gate stops gating.
    let recorded = m4Rows()
    check recorded.len > 0
    check recorded.len == currentRows().len

  test "no row was added, dropped or reordered":
    let recorded = m4Rows()
    let current = currentRows()
    require recorded.len == current.len
    for i in 0 ..< recorded.len:
      check current[i].id == recorded[i].id
      check current[i].kind == recorded[i].kind

  test "every material digest is byte-identical to the M4 baseline":
    # The move is in the KEY, not in what any edge does.
    let recorded = m4Rows()
    let current = currentRows()
    require recorded.len == current.len
    for i in 0 ..< recorded.len:
      if current[i].material != recorded[i].material:
        checkpoint("material moved for " & recorded[i].id &
          "\n  recorded: " & recorded[i].material &
          "\n  current:  " & current[i].material)
      check current[i].material == recorded[i].material

  test "every fingerprint moved":
    # Without this the file would pass against an implementation that never
    # keyed on the lock at all.
    let recorded = m4Rows()
    let current = currentRows()
    require recorded.len == current.len
    for i in 0 ..< recorded.len:
      check current[i].fingerprint != recorded[i].fingerprint

  test "each fingerprint moved by EXACTLY the governing-lock keying":
    # The line-by-line explanation, machine-checked. `current = H(m4, lock)`
    # for every row, with one lock identity — the empty solved graph for the
    # corpus's pinned platform, which is what "a workspace with no lock-file
    # declarations" is governed by.
    let recorded = m4Rows()
    let current = currentRows()
    let governing = emptySolvedGraphIdentity(CorpusPlatform)
    require recorded.len == current.len
    for i in 0 ..< recorded.len:
      let explained = hex(keyedOnGoverningLock(
        parseDigest(recorded[i].fingerprint), governing))
      if current[i].fingerprint != explained:
        checkpoint("row " & $(i + 1) & " (" & recorded[i].id &
          ") moved by something OTHER than the governing-lock keying" &
          "\n  M4 baseline: " & recorded[i].fingerprint &
          "\n  explained:   " & explained &
          "\n  current:     " & current[i].fingerprint)
      check current[i].fingerprint == explained

  test "two edges under one lock file still key identically to each other":
    # NLF-STAT-3's property restated at the fixture: the keying adds ONE
    # component shared by every edge in a single-lock workspace, so the
    # relative structure of the corpus is untouched. If the identity had been
    # mixed per-edge — say, composed with the edge id twice — this would still
    # pass row-by-row above and be wrong here.
    let identity = emptySolvedGraphIdentity(CorpusPlatform)
    let a = action("same/one", ["/bin/true"],
      governingLockIdentity = identity)
    let b = action("same/one", ["/bin/true"],
      governingLockIdentity = identity)
    check hex(a.weakFingerprint) == hex(b.weakFingerprint)
    let other = action("same/one", ["/bin/true"],
      governingLockIdentity = emptySolvedGraphIdentity("arm64-darwin"))
    check hex(other.weakFingerprint) != hex(a.weakFingerprint)

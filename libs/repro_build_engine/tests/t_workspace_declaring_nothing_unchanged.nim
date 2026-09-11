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
##   4. and each current fingerprint is **exactly** the composition of the two
##      keyings that have landed since M4, applied to the M4 fingerprint in the
##      order `action()` applies them — the edge's environment declaration
##      first, the corpus's governing lock identity outside it. This is the
##      "line by line" part: the change is those keyings and nothing else. A
##      fingerprint that moved for a third, unrelated reason — an id derivation
##      change, an extra field mixed in, a different domain tag — satisfies
##      (1), (2) and (3) and fails here.
##   5. and no baseline edge declares a passthrough variable. (4) reads each
##      row's environment from the LIVE corpus, so every field it reads needs
##      an anchor in the frozen record or the explanation absorbs a change
##      instead of catching it. `env` has one — column 2 — and
##      `envPassthrough` does not, because the material field list was frozen
##      before that field existed. (5) is that missing anchor, stated as the
##      fact it currently is. Without it, adding a passthrough to a corpus
##      edge moves the fingerprint, moves the explanation with it, and passes.
##
## ## The SECOND keying, and why it is in the explanation rather than a failure
##
## Assertion (4) read `keyedOnGoverningLock` alone until reprobuild `dev`
## `09896ec01`, "Key an action on the environment it is given" (#101), made an
## action's environment DECLARATION part of its weak fingerprint. That is a
## different campaign from Named-Lock-Files and it is required independently:
## `Caching-Architecture.md` §"BuildXL-Inspired Fingerprinting" puts **relevant
## environment** in the weak fingerprint's field list beside tool identity and
## declared inputs, and `Hermetic-Builds-And-Path-Independence.md`
## §"Environment Normalization" makes the environment surface "part of the
## action identity" that "must be explicit". Without it two actions differing
## only in an environment Reprobuild itself chose were one cache entry and the
## second was served the first one's result.
##
## The SHAPE of the keying — a declared variable keyed by value, a passthrough
## variable keyed by name only — is `keyedOnActionEnvironment`'s own contract,
## pinned by `t_declared_env_is_in_the_cache_key`, not something the two
## clauses above settle. `Hermetic-Builds-And-Path-Independence.md` argues that
## split for `PATH` specifically in §"The action's `PATH`", which is on the
## spec's feature branches and not yet on `latest`; do not read the citation
## above as covering it.
##
## Exactly one corpus row moves for it — `stat4/compile-main`, the only
## baseline edge that declares an environment (`CC`, `LANG`). That is the
## signature of the change rather than a coincidence: `keyedOnActionEnvironment`
## is the identity on an empty declaration, so the other twelve rows are
## untouched and `fixtures/nlf_stat4_baseline_fingerprints.tsv` moved on one
## line.
##
## NLF-STAT-4 is not violated by this, and the distinction is worth stating
## because "the migration gate went red" is otherwise indistinguishable from
## "the gate was edited until it was green". `Named-Lock-Files-Test-Corpus.md`
## §7 scopes the case to "byte-identical action fingerprints **across the
## change**" — the change being the Named-Lock-Files feature, whose delta this
## file still pins exactly against the frozen M4 record. A later keying from
## another spec is not an NLF default-path regression; it is a second
## explainable term, and it is in the explanation here so that a *third*
## unexplained one is still caught.
##
## ## The M4 fixture is now a frozen historical record
##
## `fixtures/nlf_stat4_m4_baseline_fingerprints.tsv` is the byte-for-byte copy
## of what NLF-M4 recorded on reprobuild `dev` at `b6de037fe`, kept so the
## comparison above has something to compare against. It must never be
## regenerated: the moment it is, assertion (4) becomes a tautology over two
## copies of the same file. `fixtures/nlf_stat4_baseline_fingerprints.tsv` is
## the live gate and holds the current values — post-M7 and, since `09896ec01`,
## post-environment-keying.
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

  test "no baseline row declares a passthrough variable":
    # Assertion (4) explains each row's move using that row's OWN environment
    # declaration. Reading `env` from the live corpus is safe because the
    # `material` column above freezes it byte-for-byte against M4: an edge
    # whose declared environment changed fails that test before reaching this
    # one. `envPassthrough` has no such anchor — the material field list was
    # frozen before the field existed — so a passthrough quietly added to a
    # corpus edge would be ABSORBED by the explanation instead of caught by
    # it, which is the one way (4) could be made to pass vacuously.
    #
    # Every baseline edge declares none, so pinning that here costs nothing
    # and closes the hole. If a baseline edge ever must name a passthrough
    # variable, the M4 record needs a column for it; relaxing this check
    # instead would silently widen what (4) is willing to explain.
    for a in baselineCorpusActions():
      if a.envPassthrough.len > 0:
        checkpoint("baseline edge " & a.id &
          " acquired a passthrough set the M4 record cannot anchor: " &
          a.envPassthrough.join(", "))
      check a.envPassthrough.len == 0

  test "each fingerprint moved by EXACTLY the two keyings that landed":
    # The line-by-line explanation, machine-checked.
    # `current = H(H(m4, env), lock)` for every row: the environment mix
    # inside, the lock mix outside, which is the order `action()` composes
    # them in and the only order that reproduces the bytes.
    #
    # One lock identity for every row — the empty solved graph for the
    # corpus's pinned platform, which is what "a workspace with no lock-file
    # declarations" is governed by. Per-row environment, because that is what
    # an environment declaration IS; twelve of the thirteen rows declare none
    # and `keyedOnActionEnvironment` is the identity on the empty declaration,
    # so twelve rows still read `H(m4, lock)` exactly as they did before #101.
    let recorded = m4Rows()
    let current = currentRows()
    let corpus = baselineCorpusActions()
    let governing = emptySolvedGraphIdentity(CorpusPlatform)
    require recorded.len == current.len
    require recorded.len == corpus.len
    for i in 0 ..< recorded.len:
      let explained = hex(keyedOnGoverningLock(
        keyedOnActionEnvironment(parseDigest(recorded[i].fingerprint),
          corpus[i].env, corpus[i].envPassthrough),
        governing))
      if current[i].fingerprint != explained:
        checkpoint("row " & $(i + 1) & " (" & recorded[i].id &
          ") moved by something OTHER than the lock and environment keyings" &
          "\n  M4 baseline: " & recorded[i].fingerprint &
          "\n  declared env: " & corpus[i].env.join(", ") &
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

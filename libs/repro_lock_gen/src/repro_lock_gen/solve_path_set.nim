## ``repro_lock_gen/solve_path_set`` — the solve edge's PATH SET, and the
## two-phase lookup over it.
##
## Named-Lock-Files NLF-M6, design §5.7; `Locking-And-Solver.md` §"Solver Cache"
## §§"Strong fingerprint" and "Lookup", both amended 2026-08-21.
##
## ## What a path set is here
##
## > The **strong fingerprint** covers the metadata facts the solve observed
## > while running — its **path set**, in the same sense as any other monitored
## > action.
##
## One entry per retrieved metadata object the solve consulted, each carrying:
##
##   * the object's **kind** (`MetadataObjectKind`) — the NLF-M6 folded
##     criterion, without which a curator snapshot index and a package's
##     version list are the same observation;
##   * the **filter** the solve's conclusion depends on — an interval for an
##     enumeration, raw otherwise;
##   * the **digest of the filtered members**, which is the fact actually
##     compared at lookup.
##
## The BuildXL precedent §5.7 names is exact: `ObservedPathSet` stores
## `ObservedAccessedFileNames` and `EnumeratePatternRegex` alongside the path,
## so "I enumerated D, but only this subset mattered" is a recorded, replayable
## fact rather than something recomputed at lookup time. This module stores and
## replays the filter for the same reason: a filter recomputed at lookup would
## be recomputed from the CURRENT state, and a filter derived from the state it
## is meant to be checking cannot detect a change in that state.
##
## ## Two phases
##
## > Lookup is two-phase: **one weak fingerprint may have several recorded path
## > sets**, tried in order against live metadata, under a bounded candidate
## > budget.
##
## Phase 1 is the weak fingerprint (`canonicalSolveInputs`), which selects a
## directory. Phase 2 walks the path sets recorded under it, newest first,
## replaying each against the metadata objects wave 1 just retrieved; the first
## whose every observation still matches is a hit and yields its recorded lock
## document.
##
## **Where several path sets under one weak fingerprint come from**, since the
## amendment's own example does not survive contact with this implementation:
## the amendment says "a `lowest` solve and a `highest` solve over the same
## constraints record *different* path sets", but the SAME section puts "the
## solver **strategy** in force" inside the weak fingerprint, so those two
## solves have different weak fingerprints and cannot share one. The
## amendment's other example does hold — "two solves that consulted different
## mirrors" — and so does the case this implementation actually exercises: one
## weak fingerprint accumulates a path set per distinct upstream STATE it has
## been solved against. Publish 1.3 into a `>=1.2` gap and the `lowest` solve
## records a second path set; withdraw 1.3 and the FIRST one matches again. See
## the NLF-M6 test `t_materiality_interval_covers_the_gap`.
##
## ## Why this is not in `libs/repro_build_engine/src/repro_build_engine.nim`
##
## The NLF-M6 ledger's Key Source Files names the engine for "observed-input
## recording, two-phase lookup". It cannot be, and this is the FOURTH stale
## Key-Source-Files entry in that file (NLF-M3, NLF-M4, NLF-M5 precede it):
##
##   * the engine's recorded observations are `FileFingerprint`s —
##     path + metadata + optional content hash (`repro_local_store`
##     `ActionResultRecord.inputs`). A filtered enumeration over a semver
##     interval is not expressible in that record, and widening it would put a
##     version-comparison rule inside the action cache;
##   * deriving the interval needs the solver (semver order, parsed ranges, the
##     selection, `UnifiedSolution.selected`), and **the engine must not import
##     the solver** — `repro_lock/identity.nim` records the constraint and its
##     cost: the solver loads `libclingo` through a `{.dynlib.}` FFI at
##     module-init, so an engine that imported it would give every engine
##     binary a clingo runtime dependency.
##
## So the same structural argument that put `repro_lock_gen` above both
## libraries at NLF-M5 puts this file in it. The engine's own two-phase
## structure is untouched and still governs every ordinary edge, including the
## `bakMetadataFetch` edges upstream of the solve; what is added here is the
## solve edge's own second phase, over an observation class the file
## fingerprint cannot carry.
##
## ## Test-double policy
##
## Nothing here is a double. The store is a real directory tree, the metadata
## objects are the real files wave 1 retrieved over a real socket, and the
## digest is the real `repro_hash` BLAKE3.

import std/[algorithm, os, strutils]

import repro_hash
import repro_solver

import metadata_objects

const
  PathSetCandidateBudget* = 12
    ## How many recorded path sets one weak fingerprint may be tried against.
    ##
    ## Twelve, which is BuildXL's default for
    ## `ITwoPhaseFingerprintStore.ListPublishedEntriesByWeakFingerprint` and is
    ## taken rather than invented — §5.7 names the mechanism and its budget
    ## together. The budget is what keeps a weak fingerprint that attracts many
    ## upstream states from turning every lookup into an unbounded replay; past
    ## it the solve simply runs, which is correct but slower.

  PathSetSchema* = "reprobuild.solve-path-set.v1"

type
  SolveObservation* = object
    ## One consulted metadata object, filtered.
    kind*: MetadataObjectKind
    subject*: string
      ## The object's key within its kind — package name, shard letter,
      ## `<package>@<version>`, or empty for the repository-wide kinds.
    objectPath*: string
      ## Where wave 1 landed the object. Replay reads THIS file, not the URL:
      ## the observation is over what the solve read, and what the solve read
      ## is what the fetch edge wrote.
    filter*: MaterialityFilterKind
    low*, high*: string
    highInclusive*: bool
    selection*: string
      ## Diagnostic only — never compared. Recorded because an invalidation
      ## that cannot say what the previous answer was is hard to act on.
    memberDigest*: string
      ## The fact. Lowercase hex over the filtered member list (for an
      ## enumeration) or over the whole retrieved body (for a document).
    reason*: string
      ## Why `mfRaw`, when it is.

  SolvePathSet* = object
    observations*: seq[SolveObservation]

  PathSetLookup* = object
    ## The outcome of phase 2.
    hit*: bool
    index*: int
      ## Which recorded path set matched, `-1` on a miss. Recorded so a test
      ## can distinguish "matched the entry we just wrote" from "matched an
      ## older entry", which is the property the two-phase structure exists for.
    lockDocument*: string
    candidatesTried*: int
    missReason*: string

proc digestOfText(text: string): ContentDigest =
  ## The hash under which every observation in this module is recorded.
  ##
  ## `hdMetadataEnvelope`, not `hdActionFingerprint`: these digests are over
  ## RETRIEVED METADATA, which is exactly the domain that tag names, and
  ## domain-separating them from action fingerprints is what keeps a path-set
  ## digest from ever being mistaken for one. Computed here over `repro_hash`
  ## directly rather than through the engine's `weakFingerprintFromText`, so
  ## this module stays a leaf over `repro_hash` + `repro_solver` and does not
  ## drag the build engine into the path-set representation.
  var payload = newSeq[byte](text.len)
  for i, ch in text:
    payload[i] = byte(ord(ch))
  blake3DomainDigest(payload, hdMetadataEnvelope)

proc hexOf(digest: ContentDigest): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(digest.bytes.len * 2)
  for b in digest.bytes:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F'u8)])

proc framed(label: string; items: openArray[string]): string =
  ## Length-prefixed framing — the §1.3 hazard, which for a cache key "does not
  ## fail loudly: it produces two different keys for one lock file".
  result = label & "[" & $items.len & "]"
  for item in items:
    result.add("\x1f" & item)
  result.add("\x1e")

proc digestOfMembers*(members: openArray[string]): string =
  ## The filtered-enumeration fingerprint. Framed, so `["1.2", "1.4"]` and
  ## `["1.21", ".4"]` cannot collide.
  hexOf(digestOfText(framed("members", members)))

proc digestOfBody*(body: string): string =
  ## The whole-content fingerprint used for the non-enumeration kinds.
  hexOf(digestOfText("body\x1f" & body))

proc observeObject*(kind: MetadataObjectKind; subject, objectPath: string;
                    iv: ConsultedInterval): SolveObservation =
  ## Take one observation over the object at `objectPath`.
  ##
  ## A MISSING object is observed as an empty enumeration / empty body rather
  ## than skipped. That is the `AbsentPathProbe` shape §5.7 points at for the
  ## negative half of the recorded fact: "nothing was there" is a fact about
  ## upstream, and a lookup that skipped it would treat the object appearing
  ## later as no change at all.
  result = SolveObservation(kind: kind, subject: subject,
    objectPath: objectPath, filter: iv.kind, low: iv.low, high: iv.high,
    highInclusive: iv.highInclusive, selection: iv.selection,
    reason: iv.reason)
  let body =
    if fileExists(objectPath): readFile(objectPath) else: ""
  if isEnumerationKind(kind):
    result.memberDigest = digestOfMembers(
      filterMembers(parseVersionList(body), iv))
  else:
    # A document has no members, so no interval applies to it whatever the
    # solve's strategy was. Recording it as `mfRaw` is not a fallback here —
    # it is the accurate classification, and conflating the two would make the
    # raw-fallback count unreadable.
    result.filter = mfRaw
    result.low = ""
    result.high = ""
    result.highInclusive = false
    result.reason = "a " & $kind & " is a document, not an enumeration"
    result.memberDigest = digestOfBody(body)

proc replayObservation*(obs: SolveObservation): string =
  ## Recompute `memberDigest` against the CURRENT contents of `obs.objectPath`,
  ## replaying the RECORDED filter.
  ##
  ## The filter comes off the record and is not re-derived. A re-derived filter
  ## would be derived from the state being checked, so an upstream change that
  ## moved the selection would move the filter with it and the comparison would
  ## match — a cache that never invalidates, which is exactly the failure mode
  ## NLF-M6's exit criteria call out as indistinguishable from a working filter
  ## unless both directions are measured.
  let body =
    if fileExists(obs.objectPath): readFile(obs.objectPath) else: ""
  if isEnumerationKind(obs.kind) and obs.filter == mfInterval:
    let iv = ConsultedInterval(packageName: obs.subject, kind: obs.filter,
      selection: obs.selection, low: obs.low, high: obs.high,
      highInclusive: obs.highInclusive, reason: obs.reason)
    digestOfMembers(filterMembers(parseVersionList(body), iv))
  elif isEnumerationKind(obs.kind):
    let iv = ConsultedInterval(packageName: obs.subject, kind: mfRaw,
      selection: obs.selection, reason: obs.reason)
    digestOfMembers(filterMembers(parseVersionList(body), iv))
  else:
    digestOfBody(body)

proc renderObservation(obs: SolveObservation): string =
  "kind=" & $obs.kind & "\x1f" & "subject=" & obs.subject & "\x1f" &
    "path=" & obs.objectPath & "\x1f" & "filter=" & $obs.filter & "\x1f" &
    "low=" & obs.low & "\x1f" & "high=" & obs.high & "\x1f" &
    "highIncl=" & (if obs.highInclusive: "1" else: "0") & "\x1f" &
    "selection=" & obs.selection & "\x1f" &
    "digest=" & obs.memberDigest & "\x1f" & "reason=" & obs.reason

proc renderPathSet*(ps: SolvePathSet): string =
  ## The on-disk form. One observation per line, in recorded order (which
  ## `deriveConsultedIntervals` fixes by package name, then the object plan's
  ## own order for the non-package kinds), so a path set is diffable.
  result = PathSetSchema & "\n"
  for obs in ps.observations:
    result.add(renderObservation(obs) & "\n")

proc parsePathSet*(text: string): SolvePathSet =
  ## Read a recorded path set. A line whose schema or field set is not
  ## recognised makes the whole entry unusable, and an unusable entry is
  ## SKIPPED at lookup rather than treated as matching — a cache entry that
  ## cannot be read is not evidence that nothing changed.
  result = SolvePathSet(observations: @[])
  var first = true
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0: continue
    if first:
      first = false
      if line != PathSetSchema:
        return SolvePathSet(observations: @[])
      continue
    var obs = SolveObservation()
    var seen = 0
    for field in line.split('\x1f'):
      let at = field.find('=')
      if at < 0: continue
      let key = field[0 ..< at]
      let value = field[at + 1 .. ^1]
      inc seen
      case key
      of "kind":
        var matched = false
        for k in MetadataObjectKind:
          if $k == value:
            obs.kind = k
            matched = true
        if not matched: return SolvePathSet(observations: @[])
      of "subject": obs.subject = value
      of "path": obs.objectPath = value
      of "filter":
        obs.filter = if value == $mfInterval: mfInterval else: mfRaw
      of "low": obs.low = value
      of "high": obs.high = value
      of "highIncl": obs.highInclusive = value == "1"
      of "selection": obs.selection = value
      of "digest": obs.memberDigest = value
      of "reason": obs.reason = value
      else: discard
    if seen == 0: continue
    result.observations.add(obs)

proc pathSetDigest*(ps: SolvePathSet): string =
  ## A stable identity for one path set — the strong fingerprint's material.
  ## Used to recognise a re-record of an identical path set so the store does
  ## not grow one entry per invocation.
  var lines: seq[string] = @[]
  for obs in ps.observations:
    lines.add(renderObservation(obs))
  hexOf(digestOfText(framed("pathset", lines)))

# ---------------------------------------------------------------------------
# The store
# ---------------------------------------------------------------------------

proc pathSetDir*(root, weakHex: string): string =
  root / "solve-path-sets" / weakHex

proc recordedEntries(dir: string): seq[string] =
  ## Recorded entry stems, NEWEST FIRST.
  ##
  ## Newest first because a lookup should try the most recently observed
  ## upstream state before an older one: the common case is that nothing moved
  ## since the last solve. `lookupActionResultImpl` walks its records with the
  ## same `countdown` for the same reason.
  result = @[]
  if not dirExists(dir): return
  var stems: seq[string] = @[]
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let (_, name, ext) = splitFile(path)
    if ext == ".pathset":
      stems.add(name)
  stems.sort()
  for i in countdown(stems.high, 0):
    result.add(stems[i])

proc lookupPathSet*(root, weakHex: string): PathSetLookup =
  ## Phase 2: replay each recorded path set against live metadata.
  ##
  ## Returns the FIRST match. "First" is well defined because the entries are
  ## ordered and the order is newest-first; a set-valued answer would leave the
  ## caller choosing between two lock documents with no rule to choose by.
  result = PathSetLookup(hit: false, index: -1, lockDocument: "",
    candidatesTried: 0, missReason: "no recorded path set")
  let dir = pathSetDir(root, weakHex)
  let stems = recordedEntries(dir)
  if stems.len == 0:
    return
  for stem in stems:
    if result.candidatesTried >= PathSetCandidateBudget:
      result.missReason = "candidate budget of " & $PathSetCandidateBudget &
        " path sets exhausted"
      return
    inc result.candidatesTried
    let psPath = dir / (stem & ".pathset")
    let lockPath = dir / (stem & ".lock")
    if not fileExists(lockPath):
      # The pair is written lock-first, so a path set without its lock is a
      # torn write. Skipping it is the only safe reading: a hit that produced
      # no document would be a hit that cannot be served.
      continue
    let ps = parsePathSet(readFile(psPath))
    if ps.observations.len == 0:
      continue
    var matched = true
    for obs in ps.observations:
      if replayObservation(obs) != obs.memberDigest:
        matched = false
        result.missReason = "observation over " & $obs.kind & " '" &
          obs.subject & "' no longer matches"
        break
    if matched:
      return PathSetLookup(hit: true, index: parseInt(stem),
        lockDocument: readFile(lockPath),
        candidatesTried: result.candidatesTried, missReason: "")
  if result.missReason == "no recorded path set":
    result.missReason = "no recorded path set still matches live metadata"

proc recordPathSet*(root, weakHex: string; ps: SolvePathSet;
                    lockDocument: string): int =
  ## Publish a path set + its lock document under `weakHex`. Returns the entry
  ## index, or the index of the existing identical entry.
  ##
  ## Identical path sets are NOT duplicated. Without that, a workspace that
  ## re-solves for an unrelated reason would add an entry per invocation and
  ## walk the candidate budget down to nothing — the store would then look
  ## healthy while silently having stopped caching.
  let dir = pathSetDir(root, weakHex)
  createDir(dir)
  let wanted = pathSetDigest(ps)
  var next = 0
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let (_, name, ext) = splitFile(path)
    if ext != ".pathset": continue
    let idx = try: parseInt(name) except ValueError: -1
    if idx >= next: next = idx + 1
    if pathSetDigest(parsePathSet(readFile(path))) == wanted:
      # Refresh the lock document so a re-record after a byte-identical
      # replay cannot leave a stale document behind an identical path set.
      writeFile(dir / (name & ".lock"), lockDocument)
      return idx
  let stem = align($next, 4, '0')
  # Lock document FIRST: `lookupPathSet` skips a path set whose lock is
  # missing, so a crash between the two writes costs a re-solve rather than a
  # hit that cannot be served.
  writeFile(dir / (stem & ".lock"), lockDocument)
  writeFile(dir / (stem & ".pathset"), renderPathSet(ps))
  next

proc recordedPathSetCount*(root, weakHex: string): int =
  ## How many path sets one weak fingerprint carries. Read by the NLF-M6 tests
  ## that assert the two-phase structure is real rather than a single-entry
  ## store under a longer name.
  recordedEntries(pathSetDir(root, weakHex)).len

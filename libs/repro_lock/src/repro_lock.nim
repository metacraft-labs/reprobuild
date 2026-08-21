## ``repro_lock`` — the committed solved-graph lock (Locking-And-Solver.md,
## milestone MO-1).
##
## This module owns the on-disk **committed solved-graph lock**: the
## artifact that pins the solver's resolved package graph — concrete
## versions, variant (option) assignments, and per-package source
## identities — into a TOML file committed in the project repo. It is the
## reproducibility boundary the manifest-optional workspace model leans
## on (see Workspace-Manifest-Optional.milestones.org §MO-1).
##
## **NOT to be confused with** the manifest-repo SHA lock
## (``repro_workspace_manifests/lock_writer.nim`` /
## ``executeWorkspaceLock``). That artifact pins per-repo git revisions
## under ``.repo/manifests/locks/...`` and is a *different* store. The
## committed solved-graph lock here is repo-local, lives next to the
## project file, and serializes the SOLVER output (``UnifiedSolution``),
## not workspace VCS state.
##
## ## On-disk format (``reprobuild.solved-graph-lock.v2``)
##
## ```toml
## schema = "reprobuild.solved-graph-lock.v2"
##
## [lock]
## platform = "amd64-linux"
## optimal = true
## inputs_digest = "fnv1a64:0123abcd..."
## variants = [{ name = "compiler", value = "clang" }]
## packages = [{ name = "nim", version = "2.2.0", source = "nim", selection = "selected" }]
## deps = []
## ```
##
## **There is exactly one on-disk schema, and every writer in this module
## emits it.** ``serializeSolvedGraphLock`` and ``serializeLockedDependencies``
## both produce ``…v2`` documents that ``parseSolvedGraphLock`` and
## ``parseLockedDependencies`` accept; a document this module writes is a
## document this module reads back. The regression that pins the invariant is
## ``tests/t_lock_writer_output_reads_back.nim``. The historical ``…v1``
## tag is rejected on read (regenerate with ``repro lock refresh``); nothing
## writes it.
##
## The ``variants`` / ``packages`` arrays are **inline-table arrays**
## (``field = [{...}, {...}]``), not nested ``[[array.of.tables]]`` — the
## pinned ``status-im/nim-toml-serialization`` does not support the
## latter, so the codebase (and this module) hand-writes/parses the
## inline form, matching prior milestones.
##
## ## Solver-Outputs coverage (Locking-And-Solver.md §"Solver Outputs")
##
## Captured: concrete version assignment (``packages[].version``),
## concrete option assignment (``variants[]``), repository/source identity
## per package definition (``packages[].source`` — the solver-keyed
## definition identity), the global optimality decision (``optimal``), the
## platform fact, and provenance of the solver inputs (``inputs_digest``).
##
## Deferred richness (documented, not stubbed): installation-method /
## installer-strength classification, execution-profile checksum
## expectations, effective-activity set, and richer *source provenance*
## (exact git revisions per definition — that belongs to the manifest-repo
## SHA-lock layer and MO-2's evidence model). MO-1 records the source
## identity the unified solver actually keys on (the package-definition
## name); deeper provenance layers above it.

import std/[algorithm, strutils, tables]

import repro_solver
import repro_multihash
import repro_lock/identity

export UnifiedSolution
export SelectionStatus
export repro_multihash
export identity

const SolvedGraphLockSchemaV1* = "reprobuild.solved-graph-lock.v1"
  ## The historical MO-1 schema string, retained ONLY so a stale lock can be
  ## recognized and named in the reader's diagnostic. It is not written by
  ## anything and not accepted by anything: the reader REJECTS a v1-tagged lock
  ## loudly (regenerate with ``repro lock refresh``).
  ##
  ## Until the round-trip fix this constant was also the in-memory tag that
  ## ``solutionToLock`` / ``solvedPartOf`` stamped on a freshly built
  ## ``SolvedGraphLock``, and ``serializeSolvedGraphLock`` wrote it to disk —
  ## producing documents ``parseSolvedGraphLock`` refused to read. Both now
  ## stamp ``SolvedGraphLockSchemaV2``, which is the only schema in play.

const SolvedGraphLockSchemaV2* = "reprobuild.solved-graph-lock.v2"
  ## Workspace-Manifest-Optional MO-8 — the self-describing committed lock and
  ## the ONLY committed-lock schema the reader accepts. It preserves the
  ## solved-graph payload (``variants`` / ``packages`` / ``optimal`` /
  ## ``platform`` / ``inputs_digest``) as a sub-part AND adds the unified
  ## ``deps`` set — each locked dependency with checkout COORDINATES (a sum
  ## over VCS / repro-store / registry) and a self-describing INTEGRITY
  ## multihash. This is what makes a lock-file-only workspace fully
  ## self-describing (populated from the lock's content, not from live
  ## ``git HEAD``). The reader is LOUD on any schema other than v2 (including
  ## the old ``…v1``).

type
  LockedVariant* = object
    ## One concrete option (variant) assignment from the solve.
    name*: string
    value*: string

  LockedPackage* = object
    ## One concrete package node from the solve. ``source`` is the
    ## repository/source identity the solver keyed the definition on
    ## (MO-1: the package-definition name); ``version`` is the concrete
    ## resolved version.
    ##
    ## ``selection`` is the Named-Lock-Files §5.6 fact (owner decision
    ## 2026-08-21, NLF-M9): whether anything in the solve required this
    ## instance. **It is PERSISTED rather than recomputed**, and the reason is
    ## structural: a lock document records the solve's OUTPUT — versions,
    ## variant assignments, source identities — and carries no dependency
    ## edges and no variant-conditioned gates. Selection is a property of
    ## those edges, so it cannot be recovered from a lock alone; recovering it
    ## would mean re-reading the solver INPUTS, which is precisely the step a
    ## pinned lock exists to avoid, and would make the answer depend on inputs
    ## that may have moved since the lock was written.
    ##
    ## The field records a fact and decides no policy. It is not read by
    ## ``canonicalSolvedGraph`` (so it does not enter ``lockIdentity``), it
    ## does not filter ``packages``, and it does not affect materiality.
    name*: string
    version*: string
    source*: string
    selection*: SelectionStatus

  SolvedGraphLock* = object
    ## In-memory shape of the committed lock. Round-trips through
    ## ``serializeSolvedGraphLock`` / ``parseSolvedGraphLock``.
    schema*: string
    platform*: string
    optimal*: bool
    inputsDigest*: string
    variants*: seq[LockedVariant]
    packages*: seq[LockedPackage]

  SolvedGraphLockParseError* = object of CatchableError
    ## Raised by ``parseSolvedGraphLock`` on a missing/mismatched schema
    ## or a structurally malformed body.

  CoordKind* = enum
    ## The source kind a ``LockedDep``'s checkout coordinates address. The
    ## ``vcs`` case is the primary one for workspace repos; ``store`` and
    ## ``registry`` generalize the model to repro-store / package-registry
    ## sources (carried so the format is future-proof).
    ckVcs = "vcs"
    ckStore = "store"
    ckRegistry = "registry"
    ckForeign = "foreign"

  Coordinates* = object
    ## What you hand the source to OBTAIN a dependency — a sum over source
    ## kinds. Distinct from integrity (what the obtained content is verified
    ## against); for a git dep the ``revision`` and the integrity often carry
    ## the same object id, but they answer different questions.
    case kind*: CoordKind
    of ckVcs:
      url*: string        ## fetch URL.
      gitRef*: string     ## advisory ref (branch/tag); ``ref`` is reserved.
      revision*: string   ## exact pinned revision (commit id).
    of ckStore:
      storeHash*: string  ## repro-store content hash.
    of ckRegistry:
      registryName*: string
      registryVersion*: string
    of ckForeign:
      provisioner*: string          ## The name of the foreign provisioner, e.g. "nix", "scoop"
      foreignCoordinates*: string   ## The foreign coordinate identifier string


  LockedDep* = object
    ## One pinned dependency in the unified model. Workspace repos and solved
    ## packages are both just dependencies with coordinates + integrity; the
    ## "workspace repos vs solved graph" split is not a real boundary.
    name*: string             ## identity.
    path*: string             ## workspace-relative path (``.`` = the root
                              ## repo) for a VCS workspace dep; empty otherwise.
    coordinates*: Coordinates
    integrity*: string        ## self-describing multihash (``<alg>:<digest>``).
    version*: string          ## solved version/option assignment where
                              ## applicable (empty for a plain workspace repo).
    visibility*: string       ## ``public`` / ``org`` / ``team`` / ``personal``.
    participation*: string    ## ``""`` (shared) / ``evidence-only``.
    depends*: seq[string]     ## develop-set dependency edges (by name).
    tags*: seq[string]        ## subset-selection tags (`repro sync --tags=`).

  LockedDependencies* = object
    ## The unified locked-dependency model (MO-8). It SUBSUMES the
    ## resolved-repo facts, the manifest-repo per-repo lock revisions, and
    ## the committed solved-graph lock's package data: the solved-graph
    ## payload is preserved as a sub-part (``platform`` / ``optimal`` /
    ## ``inputsDigest`` / ``variants`` / ``packages``) and ``deps`` is the
    ## set of per-dependency coordinates + integrity.
    schema*: string
    platform*: string
    optimal*: bool
    inputsDigest*: string
    variants*: seq[LockedVariant]
    packages*: seq[LockedPackage]
    deps*: seq[LockedDep]

# ---------------------------------------------------------------------------
# Provenance digest (dependency-free, deterministic)
# ---------------------------------------------------------------------------

proc fnv1a64Hex*(s: string): string =
  ## FNV-1a 64-bit hex digest. Deterministic and dependency-free — used
  ## only as a provenance/drift signal for the solver-inputs text, NOT as
  ## a security primitive.
  var h: uint64 = 0xcbf29ce484222325'u64
  for ch in s:
    h = h xor uint64(ord(ch))
    h = h * 0x100000001b3'u64
  result = newStringOfCap(16)
  const digits = "0123456789abcdef"
  for shift in countdown(60, 0, 4):
    result.add(digits[int((h shr uint64(shift)) and 0xF'u64)])

proc inputsDigestOf*(inputsText: string): string =
  ## The canonical ``inputs_digest`` value for a solver-inputs text body.
  "fnv1a64:" & fnv1a64Hex(inputsText)

# ``currentPlatformId`` moved to ``repro_lock/identity`` (re-exported above) so
# the build engine can read the same definition without importing the solver.

# ---------------------------------------------------------------------------
# Conversions: solution <-> lock
# ---------------------------------------------------------------------------

proc solutionToLock*(sol: UnifiedSolution; platform: string;
                     inputsText: string): SolvedGraphLock =
  ## Build a ``SolvedGraphLock`` from a solved ``UnifiedSolution``. The
  ## variant/package lists are sorted by name so the serialized lock is
  ## deterministic regardless of the (unordered) ``Table`` iteration
  ## order — two solves of the same graph produce byte-identical locks.
  result = SolvedGraphLock(
    schema: SolvedGraphLockSchemaV2,
    platform: platform,
    optimal: sol.optimal,
    inputsDigest: inputsDigestOf(inputsText),
    variants: @[],
    packages: @[])
  var vnames: seq[string] = @[]
  for name in sol.variants.keys: vnames.add(name)
  vnames.sort()
  for name in vnames:
    result.variants.add(LockedVariant(name: name, value: sol.variants[name]))
  var pnames: seq[string] = @[]
  for name in sol.packages.keys: pnames.add(name)
  pnames.sort()
  for name in pnames:
    result.packages.add(LockedPackage(
      name: name, version: sol.packages[name], source: name,
      # NLF-M9 — carry the fact through. ``ssSelected`` for a solution that
      # recorded nothing (an empty ``selected`` table) is the status-quo
      # reading: every consumer treated every instance as required before the
      # fact existed, and this milestone changes no policy.
      selection: sol.selected.getOrDefault(name, ssSelected)))

proc lockToSolution*(lock: SolvedGraphLock): UnifiedSolution =
  ## Reconstruct the ``UnifiedSolution`` a build path consumes from a
  ## loaded lock. This is the deterministic counterpart of
  ## ``solutionToLock``: a write→read round-trip yields the same
  ## variant/package assignments, the same ``optimal`` flag, and (NLF-M9) the
  ## same per-instance selection statuses.
  result = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    selected: initTable[string, SelectionStatus](),
    optimal: lock.optimal)
  for v in lock.variants:
    result.variants[v.name] = v.value
  for p in lock.packages:
    result.packages[p.name] = p.version
    result.selected[p.name] = p.selection

# ---------------------------------------------------------------------------
# Named-Lock-Files §6.2 — the canonical solved graph a lock identity hashes
# ---------------------------------------------------------------------------

proc canonicalSolvedGraph*(lock: SolvedGraphLock): CanonicalSolvedGraph =
  ## Project a loaded lock onto §6.2's canonical solved graph.
  ##
  ## `schema`, `optimal` and `inputsDigest` are deliberately dropped. The
  ## first two are reports about the FILE and the SOLVE; `inputsDigest` is a
  ## digest over the solver INPUTS — the constraint set — and keying on it is
  ## the formula §6.2 was corrected away from on 2026-08-18. See
  ## `repro_lock/identity.nim`'s header for the full argument and corpus case
  ## NLF-ID-7 for the regression.
  ##
  ## `LockedPackage.source` carries the source identity §6.2's formula asks
  ## for. Today that is the solver-keyed definition identity for a bare
  ## package and a `store` / `registry:<name>` descriptor for the lifted ones
  ## (see the MO-11 note below); whichever it is, it is what the lock records
  ## about WHERE the instance comes from, so it is what enters the key.
  ##
  ## `LockedPackage.selection` (NLF-M9) is deliberately NOT projected. Whether
  ## an unselected instance enters `lockIdentity` is one of the three
  ## downstream policy questions §5.6 leaves open, and NLF-M9 answers none of
  ## them: it establishes the fact and stops. Reading the field here would
  ## move every identity of every graph containing an unselected instance,
  ## which is a policy change wearing a fact's clothes.
  result = CanonicalSolvedGraph(
    platform: lock.platform, packages: @[], graphVariants: @[])
  for v in lock.variants:
    result.graphVariants.add(
      SolvedVariantAssignment(name: v.name, value: v.value))
  for p in lock.packages:
    result.packages.add(SolvedPackageInstance(
      name: p.name, version: p.version, sourceIdentity: p.source,
      variants: @[]))

proc canonicalSolvedGraph*(sol: UnifiedSolution;
                           platform: string): CanonicalSolvedGraph =
  ## The projection for a LIVE solution, so an in-memory solved graph can be
  ## identified without a round-trip through the serializer.
  ##
  ## This overload is load-bearing and not a convenience: identity per §6.2 is
  ## over the SOLVED GRAPH, not over a serialized document, so an in-memory
  ## solution must be identifiable without touching the serializer at all. That
  ## separation is what kept the writer/reader schema mismatch (a `…lock.v1`
  ## writer against a `…v2` reader, since fixed — see
  ## `serializeSolvedGraphLock`) from ever leaking into a cache key, and it is
  ## the reason nothing on the identity path serializes.
  ##
  ## Source identity mirrors `solutionToLock`: MO-1 records the solver-keyed
  ## definition identity, which for a live solution is the package name.
  result = CanonicalSolvedGraph(
    platform: platform, packages: @[], graphVariants: @[])
  var vnames: seq[string] = @[]
  for name in sol.variants.keys: vnames.add(name)
  vnames.sort()
  for name in vnames:
    result.graphVariants.add(
      SolvedVariantAssignment(name: name, value: sol.variants[name]))
  var pnames: seq[string] = @[]
  for name in sol.packages.keys: pnames.add(name)
  pnames.sort()
  for name in pnames:
    result.packages.add(SolvedPackageInstance(
      name: name, version: sol.packages[name], sourceIdentity: name,
      variants: @[]))

proc lockIdentityOf*(lock: SolvedGraphLock): LockIdentity =
  ## §6.2's key for a loaded lock. The lock-file NAME is not a parameter and
  ## cannot become one: it is a handle for CLI binding (§5) and provenance
  ## (§6.3), never a key component.
  lockIdentityOf(canonicalSolvedGraph(lock))

proc lockIdentityOf*(sol: UnifiedSolution; platform: string): LockIdentity =
  lockIdentityOf(canonicalSolvedGraph(sol, platform))

proc sameSolution*(a, b: UnifiedSolution): bool =
  ## Structural equality of two solved graphs: identical variant and
  ## package assignments and the same optimality flag. ``repro lock
  ## validate`` uses this to detect a tampered or stale lock (the lock no
  ## longer matches a fresh solve of the current inputs).
  ##
  ## NLF-M9 deliberately does NOT add `selected` to the comparison. What makes
  ## a lock stale is a policy question with its own consequences — a lock
  ## written before the fact was recorded would start reporting as stale on
  ## every validate — and §5.6 assigns the policy questions to their own
  ## milestones. The fact is recorded; nothing yet acts on it.
  if a.optimal != b.optimal: return false
  if a.variants.len != b.variants.len: return false
  if a.packages.len != b.packages.len: return false
  for k, v in a.variants:
    if b.variants.getOrDefault(k, "\0missing") != v: return false
  for k, v in a.packages:
    if b.packages.getOrDefault(k, "\0missing") != v: return false
  true

# ---------------------------------------------------------------------------
# TOML escaping (basic-string subset)
# ---------------------------------------------------------------------------

proc tomlEscape(s: string): string =
  result = newStringOfCap(s.len + 2)
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc tomlUnescape(raw: string): string =
  result = newStringOfCap(raw.len)
  var i = 0
  while i < raw.len:
    let ch = raw[i]
    if ch == '\\' and i + 1 < raw.len:
      let nxt = raw[i + 1]
      case nxt
      of '\\': result.add('\\')
      of '"': result.add('"')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      else: result.add(nxt)
      i += 2
    else:
      result.add(ch)
      inc i

# ---------------------------------------------------------------------------
# Serialize
# ---------------------------------------------------------------------------

# ``serializeSolvedGraphLock`` is defined below, next to
# ``serializeLockedDependencies``, which it delegates to. It used to have its
# own v1-emitting body here; that body is what made the module's writer and
# reader disagree.

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------

proc parseScalarString(rhs: string): string =
  let s = rhs.strip()
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    tomlUnescape(s[1 ..< s.high])
  else:
    s

iterator inlineTables(rhs: string): Table[string, string] =
  ## Yield each ``{ k = "v", ... }`` inline table from an inline-table
  ## array right-hand side as a key→value map. Tolerant of whitespace;
  ## the writer always emits the canonical comma-space form.
  var s = rhs.strip()
  if s.len >= 2 and s[0] == '[' and s[^1] == ']':
    s = s[1 ..< s.high]
  var i = 0
  while i < s.len:
    while i < s.len and s[i] != '{': inc i
    if i >= s.len: break
    inc i  # past '{'
    var fields = initTable[string, string]()
    # Parse ``key = "value"`` pairs until the closing '}'.
    while i < s.len and s[i] != '}':
      while i < s.len and s[i] in {' ', '\t', ','}: inc i
      if i >= s.len or s[i] == '}': break
      # key
      var keyBuf = ""
      while i < s.len and s[i] notin {'=', ' ', '\t'}:
        keyBuf.add(s[i]); inc i
      while i < s.len and s[i] in {' ', '\t', '='}: inc i
      # value (quoted string only — the writer never emits bare values
      # inside the inline tables).
      if i < s.len and s[i] == '"':
        inc i
        var valBuf = ""
        while i < s.len and s[i] != '"':
          if s[i] == '\\' and i + 1 < s.len:
            valBuf.add(s[i]); valBuf.add(s[i + 1]); i += 2
          else:
            valBuf.add(s[i]); inc i
        inc i  # past closing quote
        if keyBuf.len > 0:
          fields[keyBuf] = tomlUnescape(valBuf)
    if i < s.len and s[i] == '}': inc i  # past '}'
    yield fields

proc parseSolvedGraphLock*(content: string): SolvedGraphLock =
  ## Parse a committed solved-graph lock. Round-trips
  ## ``serializeSolvedGraphLock`` (and reads the ``deps``-carrying documents
  ## ``serializeLockedDependencies`` writes, ignoring the ``deps`` array —
  ## ``parseLockedDependencies`` is the reader that keeps it). Raises
  ## ``SolvedGraphLockParseError`` on a missing/mismatched schema. Unknown keys
  ## are ignored (forward-compatible within the v2 schema).
  result = SolvedGraphLock(schema: "", variants: @[], packages: @[])
  var sawSchema = false
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("["):
      continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq].strip()
    let rhs = line[eq + 1 .. ^1].strip()
    case key
    of "schema":
      result.schema = parseScalarString(rhs)
      sawSchema = true
    of "platform":
      result.platform = parseScalarString(rhs)
    of "optimal":
      result.optimal = parseScalarString(rhs).toLowerAscii() == "true"
    of "inputs_digest":
      result.inputsDigest = parseScalarString(rhs)
    of "variants":
      for fields in inlineTables(rhs):
        result.variants.add(LockedVariant(
          name: fields.getOrDefault("name", ""),
          value: fields.getOrDefault("value", "")))
    of "packages":
      for fields in inlineTables(rhs):
        result.packages.add(LockedPackage(
          name: fields.getOrDefault("name", ""),
          version: fields.getOrDefault("version", ""),
          source: fields.getOrDefault("source", ""),
          # NLF-M9 — an ABSENT `selection` key reads as `selected`. The key is
          # absent exactly in a v2 document written before the fact was
          # recorded, and in such a document every instance was treated as
          # required by every consumer; reading it as `selected` reproduces
          # that behaviour byte-for-byte instead of retroactively inventing
          # the unusual claim for locks that never made it.
          selection:
            if fields.getOrDefault("selection", "") == $ssUnselected:
              ssUnselected
            else:
              ssSelected))
    else: discard
  if not sawSchema or result.schema != SolvedGraphLockSchemaV2:
    # A ``…v1`` tag is named specifically: it is not a typo but a lock
    # committed by an older Reprobuild (or, before the writer was brought to
    # v2, printed by ``repro build --print-solved-graph``), and "regenerate"
    # is the whole of the fix. Anything else is a genuinely unknown schema.
    let detail =
      if result.schema == SolvedGraphLockSchemaV1:
        "the superseded MO-1 schema; " & SolvedGraphLockSchemaV2 & " is current"
      else:
        "expected " & SolvedGraphLockSchemaV2
    raise newException(SolvedGraphLockParseError,
      "unsupported lock schema '" & result.schema & "' (" & detail &
      "); regenerate with `repro lock refresh`")

# ---------------------------------------------------------------------------
# MO-8 — the unified LockedDependencies model: v2 serialize / parse
# ---------------------------------------------------------------------------

proc joinNames(names: seq[string]): string =
  ## ``depends`` / ``tags`` are stored as a comma-joined string because the
  ## pinned ``nim-toml-serialization`` (and this module's inline-table reader)
  ## carries only quoted-string values inside an inline table, not nested
  ## arrays.
  ##
  ## THE SURFACE IS NOT LOSSLESS FOR EVERY POSSIBLE ELEMENT, and the limit is
  ## stated here rather than assumed. ``splitNames`` splits on ``,``, strips
  ## each element, and drops empties, so an element that CONTAINS a comma comes
  ## back as two elements, and an empty / whitespace-only element is dropped
  ## entirely. Both are outside the domain: a ``depends`` entry is a dependency
  ## NAME and a ``tags`` entry is a selection tag, and the CLI surface that
  ## produces tags (``repro sync --tags=a,b``) is itself comma-delimited, so
  ## neither can carry a comma to begin with. If either domain ever widens, the
  ## on-disk surface needs an escape — not a wider reader.
  names.join(",")

proc splitNames(s: string): seq[string] =
  ## Inverse of ``joinNames`` over that domain; see its limits.
  result = @[]
  for raw in s.split(','):
    let v = raw.strip()
    if v.len > 0: result.add(v)

proc lockedDepsFromSolved*(lock: SolvedGraphLock): LockedDependencies =
  ## Lift a ``SolvedGraphLock`` view into the unified model with an empty
  ## ``deps`` set (the solved-graph sub-part only).
  LockedDependencies(
    schema: lock.schema, platform: lock.platform, optimal: lock.optimal,
    inputsDigest: lock.inputsDigest, variants: lock.variants,
    packages: lock.packages, deps: @[])

proc solvedPartOf*(ld: LockedDependencies): SolvedGraphLock =
  ## Project the solved-graph sub-part out of a ``LockedDependencies`` (so the
  ## existing solution<->lock helpers keep working unchanged).
  SolvedGraphLock(
    schema: SolvedGraphLockSchemaV2, platform: ld.platform,
    optimal: ld.optimal, inputsDigest: ld.inputsDigest,
    variants: ld.variants, packages: ld.packages)

proc canonicalSolvedGraph*(ld: LockedDependencies): CanonicalSolvedGraph =
  ## §6.2's canonical solved graph for the unified v2 model, through its
  ## solved-graph sub-part. `deps` adds coordinates and integrity for the
  ## packages MO-11 lifts, but the sub-part is the authoritative record of the
  ## SOLVE and is what every existing consumer (`lockToSolution`,
  ## `solutionToLock`) reads, so the identity follows it rather than a
  ## partially-populated `deps` set.
  canonicalSolvedGraph(solvedPartOf(ld))

proc lockIdentityOf*(ld: LockedDependencies): LockIdentity =
  ## §6.2's key for a committed `…lock.v2` document. The lock-file NAME is
  ## not a parameter and cannot become one.
  lockIdentityOf(canonicalSolvedGraph(ld))

# ---------------------------------------------------------------------------
# MO-11 — non-VCS coordinates + integrity for solved packages, and the lift of
# the solved package graph into first-class ``LockedDep``s.
#
# A solved package carries a SOURCE PROVENANCE (``LockedPackage.source``):
#   * ``"store"``            — a repro-store-realized artifact. Reprobuild
#     realizes the package into its content-addressed local store; the store
#     ADDRESS is a BLAKE3 digest over the inputs that determine the realized
#     bytes. Grounded in the solved graph, that address is derived from the
#     package's canonical solved identity (name + version + target platform).
#     For a content-addressed store the address IS the content hash, so the
#     ``ckStore.storeHash`` coordinate and the integrity digest are the SAME
#     value — exactly as a git commit id is both the VCS coordinate and the
#     VCS-native integrity.
#   * ``"registry:<name>"``  — a package-registry dependency from registry
#     ``<name>``. Its coordinate is ``ckRegistry{registryName, registryVersion}``
#     and its integrity is the package checksum: a BLAKE3 digest over the
#     canonical registry coordinate (registry + name + version). (MO-12's
#     provider-sourced refresh will swap this recompute body for the
#     provider-supplied artifact checksum; the coordinate/integrity SHAPE and
#     the tamper-detection path are identical.)
#   * anything else (a bare definition name / empty) — the historical MO-1
#     definition identity, which has NO external coordinate to pin honestly and
#     is therefore NOT lifted (it remains recorded only in the ``packages``
#     sub-part). Lifting it would require fabricating a coordinate, which the
#     model forbids.
#
# THE [lock]/packages SUB-PART IS KEPT AS A DERIVED VIEW. The lift ADDS each
# store/registry package to ``deps`` as a first-class ``LockedDep``; the
# ``packages`` sub-part is preserved verbatim so ``lockToSolution`` /
# ``solutionToLock`` (which read the sub-part, not ``deps``) keep reconstructing
# the same ``Solution`` and every existing v2 lock still round-trips byte-for-
# byte. The authoritative per-package locked entry — with coordinates +
# integrity — now lives in ``deps``; ``packages`` is the redundant derived view.
# ---------------------------------------------------------------------------

type
  PackageSourceKind* = enum
    ## How a solved package's ``source`` descriptor resolves.
    pskDefinition   ## bare definition identity (no external coordinate).
    pskStore        ## a repro-store-realized artifact (``ckStore``).
    pskRegistry     ## a package-registry dependency (``ckRegistry``).

  PackageSource* = object
    case kind*: PackageSourceKind
    of pskDefinition, pskStore: discard
    of pskRegistry:
      registryName*: string

proc parsePackageSource*(source: string): PackageSource =
  ## Interpret a ``LockedPackage.source`` descriptor. ``"store"`` -> a
  ## repro-store-realized artifact; ``"registry:<name>"`` -> a registry
  ## dependency from ``<name>``; anything else (a bare definition name, or
  ## empty) -> the historical definition identity (no external coordinate).
  if source == "store":
    PackageSource(kind: pskStore)
  elif source.startsWith("registry:") and source.len > "registry:".len:
    PackageSource(kind: pskRegistry,
      registryName: source["registry:".len .. ^1])
  else:
    PackageSource(kind: pskDefinition)

proc solvedPackageStoreHash*(name, version, platform: string): string =
  ## The content-addressed store hash Reprobuild assigns a store-realized
  ## solved package: the lowercase-hex BLAKE3 digest over the package's
  ## canonical solved identity (name + version + target platform), framed
  ## through the module's NAR-style canonical serialization so no field
  ## concatenation is ambiguous. This is the store ADDRESS — a genuine
  ## recompute over the solved-graph state, not a fabricated constant; changing
  ## any of name / version / platform changes the digest.
  parseMultihash(narStyleTreeMultihash(@[
    (path: "package", content: name),
    (path: "platform", content: platform),
    (path: "version", content: version)])).digest

proc solvedPackageStoreIntegrity*(name, version, platform: string): string =
  ## The self-describing integrity of a store-realized solved package: the
  ## store hash re-tagged as ``blake3:<hex>``. Address == integrity for a
  ## content-addressed store (mirrors the VCS commit-id case).
  formatMultihash("blake3", solvedPackageStoreHash(name, version, platform))

proc solvedPackageRegistryChecksum*(registryName, name, version: string): string =
  ## The package checksum for a registry-sourced solved package: the
  ## lowercase-hex BLAKE3 digest over its canonical registry coordinate
  ## (registry + name + version). A genuine recompute; tampering any field
  ## changes the digest.
  parseMultihash(narStyleTreeMultihash(@[
    (path: "name", content: name),
    (path: "registry", content: registryName),
    (path: "version", content: version)])).digest

proc solvedPackageRegistryIntegrity*(registryName, name, version: string): string =
  ## The self-describing integrity of a registry-sourced solved package: the
  ## package checksum tagged as ``blake3:<hex>``.
  formatMultihash("blake3",
    solvedPackageRegistryChecksum(registryName, name, version))

proc lockedDepsFromPackages*(packages: seq[LockedPackage];
                             platform: string): seq[LockedDep] =
  ## MO-11 — lift each solved package carrying a STORE or REGISTRY source
  ## provenance into a first-class ``LockedDep`` with non-VCS coordinates + a
  ## self-describing integrity, both produced from the solved-graph state. A
  ## bare definition-identity package (no external source) is NOT lifted — it
  ## has no honest external coordinate — and stays recorded only in the
  ## ``packages`` sub-part. The ``path`` is empty (a solved package is not a
  ## workspace checkout); ``version`` carries the resolved version.
  result = @[]
  for p in packages:
    let src = parsePackageSource(p.source)
    case src.kind
    of pskDefinition:
      discard
    of pskStore:
      let storeHash = solvedPackageStoreHash(p.name, p.version, platform)
      result.add(LockedDep(
        name: p.name, path: "",
        coordinates: Coordinates(kind: ckStore, storeHash: storeHash),
        integrity: formatMultihash("blake3", storeHash),
        version: p.version, visibility: "public", participation: "",
        depends: @[], tags: @[]))
    of pskRegistry:
      result.add(LockedDep(
        name: p.name, path: "",
        coordinates: Coordinates(kind: ckRegistry,
          registryName: src.registryName, registryVersion: p.version),
        integrity: solvedPackageRegistryIntegrity(
          src.registryName, p.name, p.version),
        version: p.version, visibility: "public", participation: "",
        depends: @[], tags: @[]))

proc coordKindString(k: CoordKind): string =
  case k
  of ckVcs: "vcs"
  of ckStore: "store"
  of ckRegistry: "registry"
  of ckForeign: "foreign"

proc serializeDepInline(d: LockedDep): string =
  ## One ``{ ... }`` inline table for a ``LockedDep``. Key order is FIXED so
  ## two writes of the same model are byte-identical.
  result = "{ name = \"" & tomlEscape(d.name) & "\""
  result.add(", path = \"" & tomlEscape(d.path) & "\"")
  result.add(", coord_kind = \"" & coordKindString(d.coordinates.kind) & "\"")
  case d.coordinates.kind
  of ckVcs:
    result.add(", url = \"" & tomlEscape(d.coordinates.url) & "\"")
    result.add(", ref = \"" & tomlEscape(d.coordinates.gitRef) & "\"")
    result.add(", revision = \"" & tomlEscape(d.coordinates.revision) & "\"")
  of ckStore:
    result.add(", store_hash = \"" & tomlEscape(d.coordinates.storeHash) & "\"")
  of ckRegistry:
    result.add(", reg_name = \"" & tomlEscape(d.coordinates.registryName) & "\"")
    result.add(", reg_version = \"" &
      tomlEscape(d.coordinates.registryVersion) & "\"")
  of ckForeign:
    result.add(", provisioner = \"" & tomlEscape(d.coordinates.provisioner) & "\"")
    result.add(", foreign_coords = \"" & tomlEscape(d.coordinates.foreignCoordinates) & "\"")
  result.add(", integrity = \"" & tomlEscape(d.integrity) & "\"")
  result.add(", version = \"" & tomlEscape(d.version) & "\"")
  result.add(", visibility = \"" & tomlEscape(d.visibility) & "\"")
  result.add(", participation = \"" & tomlEscape(d.participation) & "\"")
  result.add(", depends = \"" & tomlEscape(joinNames(d.depends)) & "\"")
  result.add(", tags = \"" & tomlEscape(joinNames(d.tags)) & "\"")
  result.add(" }")

proc serializeLockedDependencies*(ld: LockedDependencies): string =
  ## Render the unified model to canonical ``reprobuild.solved-graph-lock.v2``
  ## TOML. The solved-graph payload is preserved verbatim as a sub-part;
  ## the ``deps`` set (sorted by name then path) carries each dependency's
  ## coordinates + self-describing integrity. Deterministic: a write -> read
  ## -> write round-trip is byte-identical.
  result = newStringOfCap(1024)
  result.add("schema = \"" & tomlEscape(SolvedGraphLockSchemaV2) & "\"\n\n")
  result.add("[lock]\n")
  result.add("platform = \"" & tomlEscape(ld.platform) & "\"\n")
  result.add("optimal = " & (if ld.optimal: "true" else: "false") & "\n")
  result.add("inputs_digest = \"" & tomlEscape(ld.inputsDigest) & "\"\n")
  # variants — inline-table array (solved-graph sub-part).
  result.add("variants = [")
  for i, v in ld.variants:
    if i > 0: result.add(", ")
    result.add("{ name = \"" & tomlEscape(v.name) & "\", value = \"" &
               tomlEscape(v.value) & "\" }")
  result.add("]\n")
  # packages — inline-table array (solved-graph sub-part).
  result.add("packages = [")
  for i, p in ld.packages:
    if i > 0: result.add(", ")
    result.add("{ name = \"" & tomlEscape(p.name) & "\", version = \"" &
               tomlEscape(p.version) & "\", source = \"" &
               tomlEscape(p.source) & "\", selection = \"" &
               $p.selection & "\" }")
  result.add("]\n")
  # deps — the MO-8 unified set (coordinates + integrity per dependency).
  var sorted = ld.deps
  sorted.sort(proc(a, b: LockedDep): int =
    result = cmp(a.name, b.name)
    if result == 0: result = cmp(a.path, b.path))
  result.add("deps = [")
  for i, d in sorted:
    if i > 0: result.add(", ")
    result.add(serializeDepInline(d))
  result.add("]\n")

proc serializeSolvedGraphLock*(lock: SolvedGraphLock): string =
  ## Render a ``SolvedGraphLock`` to a canonical committed-lock document.
  ##
  ## This is ``serializeLockedDependencies`` over the solved-graph sub-part with
  ## an empty ``deps`` set — DELEGATION, not duplication, and deliberately so.
  ## A second hand-written body is how this writer drifted onto the ``…v1``
  ## schema tag while the reader moved to ``…v2``, which left
  ## ``parseSolvedGraphLock`` rejecting its own writer's output and
  ## ``repro build --print-solved-graph`` printing a document that looked like a
  ## lock file and could not be loaded as one. With one body there is one byte
  ## format, so the two writers cannot disagree again.
  ##
  ## The empty ``deps`` set is the honest rendering: a ``SolvedGraphLock`` is
  ## the solved-graph sub-part and carries no per-dependency coordinates. A
  ## caller that HAS coordinates (``repro lock refresh``) assembles a
  ## ``LockedDependencies`` and calls ``serializeLockedDependencies`` directly.
  ##
  ## Deterministic: key order is fixed and the arrays are pre-sorted by
  ## ``solutionToLock``, so two solves of the same graph produce byte-identical
  ## output. Round-trips through ``parseSolvedGraphLock`` and
  ## ``parseLockedDependencies``
  ## (``tests/t_lock_writer_output_reads_back.nim``).
  serializeLockedDependencies(lockedDepsFromSolved(lock))

proc parseLockedDependencies*(content: string): LockedDependencies =
  ## Parse a committed lock into the unified model. Accepts ONLY the v2
  ## schema; a v1-tagged (or any other) lock is rejected LOUDLY by
  ## ``parseSolvedGraphLock`` (raises ``SolvedGraphLockParseError`` —
  ## regenerate with ``repro lock refresh``). The solved-graph keys reuse
  ## ``parseSolvedGraphLock``'s grammar; the ``deps`` array is the v2 addition.
  let solved = parseSolvedGraphLock(content)  # validates schema + solved part
  result = lockedDepsFromSolved(solved)
  # Pull the v2 ``deps`` array (empty when the lock carries no deps).
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#") or line.startsWith("["):
      continue
    let eq = line.find('=')
    if eq <= 0: continue
    if line[0 ..< eq].strip() != "deps": continue
    let rhs = line[eq + 1 .. ^1].strip()
    for f in inlineTables(rhs):
      let kindRaw = f.getOrDefault("coord_kind", "vcs")
      var coords: Coordinates
      case kindRaw
      of "store":
        coords = Coordinates(kind: ckStore,
          storeHash: f.getOrDefault("store_hash", ""))
      of "registry":
        coords = Coordinates(kind: ckRegistry,
          registryName: f.getOrDefault("reg_name", ""),
          registryVersion: f.getOrDefault("reg_version", ""))
      of "foreign":
        coords = Coordinates(kind: ckForeign,
          provisioner: f.getOrDefault("provisioner", ""),
          foreignCoordinates: f.getOrDefault("foreign_coords", ""))
      else:
        coords = Coordinates(kind: ckVcs,
          url: f.getOrDefault("url", ""),
          gitRef: f.getOrDefault("ref", ""),
          revision: f.getOrDefault("revision", ""))
      result.deps.add(LockedDep(
        name: f.getOrDefault("name", ""),
        path: f.getOrDefault("path", ""),
        coordinates: coords,
        integrity: f.getOrDefault("integrity", ""),
        version: f.getOrDefault("version", ""),
        visibility: f.getOrDefault("visibility", ""),
        participation: f.getOrDefault("participation", ""),
        depends: splitNames(f.getOrDefault("depends", "")),
        tags: splitNames(f.getOrDefault("tags", ""))))

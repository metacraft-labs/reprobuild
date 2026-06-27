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
## ## On-disk format (``reprobuild.solved-graph-lock.v1``)
##
## ```toml
## schema = "reprobuild.solved-graph-lock.v1"
##
## [lock]
## platform = "amd64-linux"
## optimal = true
## inputs_digest = "fnv1a64:0123abcd..."
## variants = [{ name = "compiler", value = "clang" }]
## packages = [{ name = "nim", version = "2.2.0", source = "nim" }]
## ```
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

export UnifiedSolution
export repro_multihash

const SolvedGraphLockSchemaV1* = "reprobuild.solved-graph-lock.v1"
  ## The historical MO-1 schema string. NO LONGER a valid committed-lock
  ## schema: the reader REJECTS a v1-tagged lock loudly (regenerate with
  ## ``repro lock refresh``). Retained only as the in-memory tag of the
  ## solved-graph sub-part (``SolvedGraphLock``); never read from disk and
  ## never written to a committed lock.

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
    name*: string
    version*: string
    source*: string

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
    groups*: seq[string]      ## manifest-group membership.

  LockedDependencies* = object
    ## The unified locked-dependency model (MO-8). It SUBSUMES the
    ## resolved-repo facts, the manifest-repo per-repo lock revisions, and
    ## the committed solved-graph lock's package data: the v1 solved-graph
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

proc currentPlatformId*(): string =
  ## The platform fact recorded in the lock and checked by ``validate``.
  ## MO-1 uses the build host's ``cpu-os`` identity (e.g. ``amd64-linux``).
  hostCPU & "-" & hostOS

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
    schema: SolvedGraphLockSchemaV1,
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
      name: name, version: sol.packages[name], source: name))

proc lockToSolution*(lock: SolvedGraphLock): UnifiedSolution =
  ## Reconstruct the ``UnifiedSolution`` a build path consumes from a
  ## loaded lock. This is the deterministic counterpart of
  ## ``solutionToLock``: a write→read round-trip yields the same
  ## variant/package assignments and the same ``optimal`` flag.
  result = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: lock.optimal)
  for v in lock.variants:
    result.variants[v.name] = v.value
  for p in lock.packages:
    result.packages[p.name] = p.version

proc sameSolution*(a, b: UnifiedSolution): bool =
  ## Structural equality of two solved graphs: identical variant and
  ## package assignments and the same optimality flag. ``repro lock
  ## validate`` uses this to detect a tampered or stale lock (the lock no
  ## longer matches a fresh solve of the current inputs).
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

proc serializeSolvedGraphLock*(lock: SolvedGraphLock): string =
  ## Render a ``SolvedGraphLock`` to canonical TOML. Key order is fixed
  ## and the arrays are pre-sorted by ``solutionToLock``, so two solves of
  ## the same graph produce byte-identical output.
  result = newStringOfCap(512)
  result.add("schema = \"" & tomlEscape(SolvedGraphLockSchemaV1) & "\"\n\n")
  result.add("[lock]\n")
  result.add("platform = \"" & tomlEscape(lock.platform) & "\"\n")
  result.add("optimal = " & (if lock.optimal: "true" else: "false") & "\n")
  result.add("inputs_digest = \"" & tomlEscape(lock.inputsDigest) & "\"\n")
  # variants — inline-table array.
  result.add("variants = [")
  for i, v in lock.variants:
    if i > 0: result.add(", ")
    result.add("{ name = \"" & tomlEscape(v.name) & "\", value = \"" &
               tomlEscape(v.value) & "\" }")
  result.add("]\n")
  # packages — inline-table array.
  result.add("packages = [")
  for i, p in lock.packages:
    if i > 0: result.add(", ")
    result.add("{ name = \"" & tomlEscape(p.name) & "\", version = \"" &
               tomlEscape(p.version) & "\", source = \"" &
               tomlEscape(p.source) & "\" }")
  result.add("]\n")

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
  ## ``serializeSolvedGraphLock``. Raises ``SolvedGraphLockParseError`` on
  ## a missing/mismatched schema. Unknown keys are ignored
  ## (forward-compatible within the v1 schema).
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
          source: fields.getOrDefault("source", "")))
    else: discard
  if not sawSchema or result.schema != SolvedGraphLockSchemaV2:
    raise newException(SolvedGraphLockParseError,
      "unsupported lock schema '" & result.schema & "' (expected " &
      SolvedGraphLockSchemaV2 & "); regenerate with `repro lock refresh`")

# ---------------------------------------------------------------------------
# MO-8 — the unified LockedDependencies model: v2 serialize / parse
# ---------------------------------------------------------------------------

proc joinNames(names: seq[string]): string =
  ## ``depends`` / ``groups`` are stored as a comma-joined string because the
  ## pinned ``nim-toml-serialization`` (and this module's inline-table reader)
  ## carries only quoted-string values inside an inline table, not nested
  ## arrays. The list semantics are identical; only the surface differs.
  names.join(",")

proc splitNames(s: string): seq[string] =
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
    schema: SolvedGraphLockSchemaV1, platform: ld.platform,
    optimal: ld.optimal, inputsDigest: ld.inputsDigest,
    variants: ld.variants, packages: ld.packages)

proc coordKindString(k: CoordKind): string =
  case k
  of ckVcs: "vcs"
  of ckStore: "store"
  of ckRegistry: "registry"

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
  result.add(", integrity = \"" & tomlEscape(d.integrity) & "\"")
  result.add(", version = \"" & tomlEscape(d.version) & "\"")
  result.add(", visibility = \"" & tomlEscape(d.visibility) & "\"")
  result.add(", participation = \"" & tomlEscape(d.participation) & "\"")
  result.add(", depends = \"" & tomlEscape(joinNames(d.depends)) & "\"")
  result.add(", groups = \"" & tomlEscape(joinNames(d.groups)) & "\"")
  result.add(" }")

proc serializeLockedDependencies*(ld: LockedDependencies): string =
  ## Render the unified model to canonical ``reprobuild.solved-graph-lock.v2``
  ## TOML. The v1 solved-graph payload is preserved verbatim as a sub-part;
  ## the ``deps`` set (sorted by name then path) carries each dependency's
  ## coordinates + self-describing integrity. Deterministic: a write -> read
  ## -> write round-trip is byte-identical.
  result = newStringOfCap(1024)
  result.add("schema = \"" & tomlEscape(SolvedGraphLockSchemaV2) & "\"\n\n")
  result.add("[lock]\n")
  result.add("platform = \"" & tomlEscape(ld.platform) & "\"\n")
  result.add("optimal = " & (if ld.optimal: "true" else: "false") & "\n")
  result.add("inputs_digest = \"" & tomlEscape(ld.inputsDigest) & "\"\n")
  # variants — inline-table array (v1 sub-part).
  result.add("variants = [")
  for i, v in ld.variants:
    if i > 0: result.add(", ")
    result.add("{ name = \"" & tomlEscape(v.name) & "\", value = \"" &
               tomlEscape(v.value) & "\" }")
  result.add("]\n")
  # packages — inline-table array (v1 sub-part).
  result.add("packages = [")
  for i, p in ld.packages:
    if i > 0: result.add(", ")
    result.add("{ name = \"" & tomlEscape(p.name) & "\", version = \"" &
               tomlEscape(p.version) & "\", source = \"" &
               tomlEscape(p.source) & "\" }")
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
        groups: splitNames(f.getOrDefault("groups", ""))))

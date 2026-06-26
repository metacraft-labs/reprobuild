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

export UnifiedSolution

const SolvedGraphLockSchemaV1* = "reprobuild.solved-graph-lock.v1"
  ## The only schema this MO-1 reader/writer understands. The reader
  ## rejects any other ``schema`` value so a forward-incompatible lock is
  ## a loud failure rather than a silent mis-parse.

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
  if not sawSchema or result.schema != SolvedGraphLockSchemaV1:
    raise newException(SolvedGraphLockParseError,
      "not a " & SolvedGraphLockSchemaV1 & " lock (schema = '" &
      result.schema & "')")

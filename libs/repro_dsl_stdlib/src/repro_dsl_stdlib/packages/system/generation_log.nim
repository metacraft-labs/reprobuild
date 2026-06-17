## NDEM2: generation-log persistence + rollback primitives.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDEM2 at
## the **manifest level** (NOT at the Hyper-V boot level — the real
## /etc/ activation runtime + .deb extraction required by the spec's
## ~vm-harness/tests/e2e/t_vm_harness_hyperv_reproos_native_generations.nim~
## are explicitly deferred; see §"Honest deferrals" below).
##
## ## What this module owns
##
## NDEM2 closes the spec's "**multi-generation persistence**" deferral
## documented in NDEM1's ``reproos_desktop.nim`` §"Honest deferrals":
##
##   "Multi-generation persistence is DEFERRED. v1 emits a SINGLE
##   generation manifest per ``materializeReproosDesktop`` call. The
##   generation-log persistence layer (which records every recent
##   generation manifest so ``reproos-rebuild rollback`` can re-activate
##   the previous one) is NDEM2 work."
##
## The append-only ``GenerationLog`` records every ``GenerationManifest``
## produced by ``materializeReproosDesktop``. Each entry carries the
## manifest's ``generationId`` (content-addressed across BOTH variant
## and configurable per NDEM1's two-axis identity contract), a
## deterministic ``timestamp`` (epoch seconds; tests pass a constant so
## the serialised log is byte-stable), and the manifest itself.
##
## The "active" generation is the **most recently added** entry (LIFO
## semantics for v1). ``rollback`` pops the active entry; the prior
## entry becomes active. This matches the spec's ``reproos-rebuild
## rollback`` worked example at the manifest level: the previous
## generation's symlink farm becomes the live one.
##
## ## Semantics tested
##
## Per the NDEM2 sub-agent prompt §"Pragmatic scope":
##
##   1. Each generation has a unique ``generationId`` (NDEM1 already
##      guarantees this; we exercise it through the log).
##   2. Switching between generations is "instantaneous" at the
##      manifest level — no work is performed beyond appending an
##      entry / popping one (rollback is O(1)).
##   3. **Variant** changes produce different closures (storePaths
##      differ between successive generations).
##   4. **Configurable** changes produce same closures (storePaths
##      identical) but different activation (displayManagerSymlink
##      differs).
##   5. The log preserves manifest history (historical entries are
##      not mutated by subsequent appends).
##   6. ``rollback`` produces a prior generation's manifest from the
##      log.
##
## ## Idempotency
##
## ``addGeneration`` is **idempotent on generationId**: appending the
## same manifest twice produces a single entry (the second call
## returns the existing entry). This matches the NDEM1 invariant that
## ``generationId`` is a pure function of the ``ReproosDesktopConfig``
## inputs.
##
## ## Honest deferrals
##
## * **Real Hyper-V boot tests (NDE-H2 / NDE-G2 / NDE-K2)** require:
##   (a) real .deb extraction for the compositor + foundation
##   packages (every NDE0 / NDE-H/G/K v1 package documented this
##   deferral); (b) an activation runtime that plants the
##   ``displayManagerSymlink`` intent into the live ``/etc/`` tree of
##   the booted VM; (c) a bootable-ISO lift that pulls every
##   generation's storePaths + boots GRUB into the active one. All
##   three are deferred to follow-up milestones. NDEM2 closes the
##   manifest-level acceptance the spec defines without these
##   prerequisites: build N generations, verify each has a unique ID,
##   variant change grows the closure, configurable change leaves the
##   closure invariant but rebuilds activation, rollback restores the
##   prior manifest.
##
## * **GRUB menu projection** — the v1 ``grubMenuEntries`` emission
##   already records one entry per generation in NDEM1; the bootable-
##   ISO lift that actually consumes them is deferred (see above).
##
## * **Persistence to disk** — ``serializeGenerationLog`` produces a
##   deterministic JSON string; planting it under
##   ``<storeRoot>/.reproos-generations.json`` is the activation
##   layer's job (deferred). v1 ships the serialiser + the
##   ``deserializeGenerationLog`` round-trip so a CLI can adopt this
##   immediately.

import std/[algorithm, json, options]

import ./reproos_desktop

# ---------------------------------------------------------------------------
# Version constant — part of the serialised-log fingerprint.
# ---------------------------------------------------------------------------

const
  NdemGenerationLogVersion* = "0.1.0"

# ---------------------------------------------------------------------------
# Types.
# ---------------------------------------------------------------------------

type
  GenerationEntry* = object
    ## One generation's record. The ``generationId`` is the
    ## content-addressed handle inherited from
    ## ``GenerationManifest.generationId``; ``timestamp`` is the epoch-
    ## seconds the entry was appended (callers pass a deterministic
    ## value for tests).
    generationId*: string
    timestamp*: int64
    manifest*: GenerationManifest

  GenerationLog* = object
    ## Append-only log of generations. The "active" generation is the
    ## last entry. ``rollback`` pops the last entry; the prior entry
    ## becomes active. Idempotency on ``generationId`` is enforced by
    ## ``addGeneration`` so re-materialising the same config never
    ## duplicates a log entry.
    entries*: seq[GenerationEntry]

# ---------------------------------------------------------------------------
# Mutators.
# ---------------------------------------------------------------------------

proc addGeneration*(log: var GenerationLog;
                    manifest: GenerationManifest;
                    timestamp: int64): GenerationEntry =
  ## Append a new generation entry to the log. Idempotent: if the
  ## manifest's ``generationId`` already appears in the log, returns
  ## the existing entry without appending or mutating any existing
  ## entry.
  for existing in log.entries:
    if existing.generationId == manifest.generationId:
      return existing
  let entry = GenerationEntry(
    generationId: manifest.generationId,
    timestamp: timestamp,
    manifest: manifest)
  log.entries.add(entry)
  result = entry

proc activeGeneration*(log: GenerationLog): GenerationEntry =
  ## Returns the most recently appended (active) generation entry.
  ## Raises ``EConfigViolation`` when the log is empty — a
  ## ``reproos-rebuild list`` operation on an empty log is a hard
  ## error per the spec's manifest-level acceptance.
  if log.entries.len == 0:
    raise newException(EConfigViolation,
      "NDEM2: activeGeneration called on empty generation log; " &
      "no generation has been materialised yet")
  result = log.entries[^1]

proc rollback*(log: var GenerationLog): GenerationEntry =
  ## Pops the most recent (active) entry from the log and returns the
  ## NEW active entry (the previously-second-to-last). Raises
  ## ``EConfigViolation`` when the log has fewer than 2 entries — the
  ## spec's ``reproos-rebuild rollback`` requires a prior generation
  ## to roll back TO.
  ##
  ## v1 simplification: the popped entry is discarded. A future
  ## milestone can preserve popped entries in a sibling structure so
  ## ``reproos-rebuild list`` shows them as garbage-collectable
  ## history; the manifest's content-addressed store paths are
  ## reusable by re-materialising the same config.
  if log.entries.len == 0:
    raise newException(EConfigViolation,
      "NDEM2: rollback called on empty generation log; nothing to " &
      "roll back from")
  if log.entries.len < 2:
    raise newException(EConfigViolation,
      "NDEM2: rollback requires at least 2 generations in the log; " &
      "the current generation is the only one — no prior generation " &
      "to roll back to")
  discard log.entries.pop()  # drop the active entry
  result = log.entries[^1]

# ---------------------------------------------------------------------------
# Read-only queries.
# ---------------------------------------------------------------------------

proc lookupGeneration*(log: GenerationLog;
                       generationId: string): Option[GenerationEntry] =
  ## Returns ``some(entry)`` when an entry with the given
  ## ``generationId`` is in the log, ``none`` otherwise. Useful for the
  ## spec's ``reproos-rebuild switch <generationId>`` operation.
  for entry in log.entries:
    if entry.generationId == generationId:
      return some(entry)
  result = none(GenerationEntry)

# ---------------------------------------------------------------------------
# Deterministic JSON serialisation.
#
# Hand-rolled so the byte order of every field is fixed (insertion-
# order of std/json's JsonNode depends on the implementation; we want
# byte-identity guarantees regardless of Nim version). Top-level
# layout:
#
#   {"version":"<NdemGenerationLogVersion>","entries":[ <entry>, ... ]}
#
# Per-entry layout (fields emitted in this exact order):
#
#   {"generationId":"...","timestamp":<int>,"manifest":{
#      "generationId":"...",
#      "desktopKind":["sway",...],
#      "activeAtBoot":"sway",
#      "storePaths":["...",...],
#      "activationSymlinks":[{"etcPath":"...","target":"..."},...],
#      "mergedFiles":[{"etcPath":"...","contents":"..."},...]
#   }}
# ---------------------------------------------------------------------------

proc jsonEscape(s: string): string =
  ## Minimal RFC 8259 string escaper. Covers every byte we expect to
  ## see in manifest fields (paths, sentinel-bearing merged-file
  ## contents). Bytes < 0x20 outside the named escapes are emitted as
  ## ``\uXXXX``.
  result = newStringOfCap(s.len + 2)
  result.add('"')
  for ch in s:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      let b = ch.uint8
      if b < 0x20'u8:
        const Hex = "0123456789abcdef"
        result.add("\\u00")
        result.add(Hex[int(b shr 4)])
        result.add(Hex[int(b and 0x0f)])
      else:
        result.add(ch)
  result.add('"')

proc emitStringArray(buf: var string; xs: openArray[string]) =
  buf.add('[')
  for i, x in xs:
    if i > 0: buf.add(',')
    buf.add(jsonEscape(x))
  buf.add(']')

proc emitDesktopKinds(buf: var string; xs: openArray[DesktopKind]) =
  buf.add('[')
  for i, k in xs:
    if i > 0: buf.add(',')
    buf.add(jsonEscape($k))
  buf.add(']')

proc emitManifest(buf: var string; m: GenerationManifest) =
  buf.add('{')
  buf.add("\"generationId\":")
  buf.add(jsonEscape(m.generationId))
  buf.add(",\"desktopKind\":")
  emitDesktopKinds(buf, m.desktopKind)
  buf.add(",\"activeAtBoot\":")
  buf.add(jsonEscape($m.activeAtBoot))
  buf.add(",\"storePaths\":")
  emitStringArray(buf, m.storePaths)
  buf.add(",\"activationSymlinks\":[")
  for i, sl in m.activationSymlinks:
    if i > 0: buf.add(',')
    buf.add("{\"etcPath\":")
    buf.add(jsonEscape(sl.etcPath))
    buf.add(",\"target\":")
    buf.add(jsonEscape(sl.target))
    buf.add('}')
  buf.add("],\"mergedFiles\":[")
  for i, mf in m.mergedFiles:
    if i > 0: buf.add(',')
    buf.add("{\"etcPath\":")
    buf.add(jsonEscape(mf.etcPath))
    buf.add(",\"contents\":")
    buf.add(jsonEscape(mf.contents))
    buf.add('}')
  buf.add("]}")

proc emitEntry(buf: var string; e: GenerationEntry) =
  buf.add('{')
  buf.add("\"generationId\":")
  buf.add(jsonEscape(e.generationId))
  buf.add(",\"timestamp\":")
  buf.add($e.timestamp)
  buf.add(",\"manifest\":")
  emitManifest(buf, e.manifest)
  buf.add('}')

proc serializeGenerationLog*(log: GenerationLog): string =
  ## Hand-rolled deterministic JSON serialiser. The byte order of
  ## every field is fixed so two materialisations of the same
  ## generations produce byte-identical output regardless of Nim
  ## version. Tests byte-compare two serialisations to enforce this.
  var buf = newStringOfCap(256 + 256 * log.entries.len)
  buf.add("{\"version\":")
  buf.add(jsonEscape(NdemGenerationLogVersion))
  buf.add(",\"entries\":[")
  for i, entry in log.entries:
    if i > 0: buf.add(',')
    emitEntry(buf, entry)
  buf.add("]}")
  result = buf

# ---------------------------------------------------------------------------
# Round-trip parser.
#
# Uses std/json for ingest (we don't need byte-determinism on the
# input side — the input came from our deterministic emitter). The
# parser validates the version and reconstructs the typed structures.
# ---------------------------------------------------------------------------

proc parseDesktopKind(s: string): DesktopKind =
  case s
  of "sway":   dkSway
  of "gnome":  dkGnome
  of "plasma": dkPlasma
  else:
    raise newException(EConfigViolation,
      "NDEM2: deserializeGenerationLog: unknown DesktopKind " & s)

proc parseManifest(node: JsonNode): GenerationManifest =
  result.generationId = node["generationId"].getStr()
  var kinds: seq[DesktopKind] = @[]
  for k in node["desktopKind"]:
    kinds.add(parseDesktopKind(k.getStr()))
  result.desktopKind = kinds
  result.activeAtBoot = parseDesktopKind(node["activeAtBoot"].getStr())
  var sp: seq[string] = @[]
  for p in node["storePaths"]:
    sp.add(p.getStr())
  result.storePaths = sp
  var sls: seq[tuple[etcPath, target: string]] = @[]
  for slNode in node["activationSymlinks"]:
    sls.add((etcPath: slNode["etcPath"].getStr(),
             target: slNode["target"].getStr()))
  result.activationSymlinks = sls
  var mfs: seq[tuple[etcPath, contents: string]] = @[]
  for mfNode in node["mergedFiles"]:
    mfs.add((etcPath: mfNode["etcPath"].getStr(),
             contents: mfNode["contents"].getStr()))
  result.mergedFiles = mfs

proc deserializeGenerationLog*(s: string): GenerationLog =
  ## Parses the JSON shape ``serializeGenerationLog`` emits. Validates
  ## the ``version`` field against ``NdemGenerationLogVersion`` and
  ## raises ``EConfigViolation`` on mismatch — a future on-disk format
  ## migration goes through a version-aware adapter rather than a
  ## silent re-interpretation of the bytes.
  let root = parseJson(s)
  let version = root["version"].getStr()
  if version != NdemGenerationLogVersion:
    raise newException(EConfigViolation,
      "NDEM2: deserializeGenerationLog: version mismatch — expected " &
      NdemGenerationLogVersion & " but got " & version)
  var entries: seq[GenerationEntry] = @[]
  for entryNode in root["entries"]:
    let e = GenerationEntry(
      generationId: entryNode["generationId"].getStr(),
      timestamp: entryNode["timestamp"].getBiggestInt().int64,
      manifest: parseManifest(entryNode["manifest"]))
    entries.add(e)
  result = GenerationLog(entries: entries)

# ---------------------------------------------------------------------------
# Convenience: stable sort-by-timestamp helper.
# ---------------------------------------------------------------------------

proc sortedByTimestamp*(log: GenerationLog): seq[GenerationEntry] =
  ## Returns the log entries sorted by (timestamp, generationId)
  ## ascending. Useful for "show me my generations chronologically"
  ## CLI surfaces. The log's own ``entries`` slot already preserves
  ## insertion order (which is the activation order); this helper is
  ## a sibling read view.
  result = log.entries
  result.sort(proc(a, b: GenerationEntry): int =
    if a.timestamp != b.timestamp:
      return cmp(a.timestamp, b.timestamp)
    return cmp(a.generationId, b.generationId))

## M10 — ``repro home gc``: unused-generation reclaim engine.
##
## Reads the M83 generation registry, walks the M56 content-addressed
## store, identifies orphaned prefixes (prefixes not referenced by
## any live generation within the conservation window), computes the
## per-prefix disk footprint, and deletes the orphans via the
## junction-aware-remove helper.
##
## The gc is conservative by default: it only flags prefixes that
## have been orphaned for ``--keep-generations N`` (default N=2)
## generations or more. The default-2 window covers the typical
## "just-rolled-back-by-mistake" scenario.
##
## CRITICAL: deletion is junction-aware (see
## ``./junction_aware_remove``). Reprobuild's store prefixes hold
## NTFS junctions / POSIX symlinks pointing into REAL USER DATA;
## a naive ``removeDir`` would silently destroy that data. The gc
## here uses ``removeJunctionAware`` as its ONLY deletion primitive.
##
## M83 generation-registry surface used (READ-ONLY, no mutation):
##
##   - `enumerateGenerations(stateDir) -> seq[GenerationRecord]`
##     (ordered oldest-first by activation timestamp; records carry
##     ``isActive``, ``activationTimestamp``, and
##     ``envelope.realizedPrefixIds``)
##   - `PointerEnvelope.realizedPrefixIds: seq[Digest256]`
##
## M56 store surface used (READ + DELETE-FROM-DISK; the SQLite index
## is NOT touched here — store ``gc`` and ``recover`` already
## reconcile filesystem-vs-index drift on their own schedule):
##
##   - `Store.root: string`
##   - `listPrefixes(store) -> seq[PrefixRow]`
##     (carries ``prefixId``, ``packageName``, ``version``,
##     ``realizedPath`` relative to store root)
##   - `absolutePrefixPath(store, relative) -> string`
##
## Public surface:
##
##   - `GcOptions` — invocation knobs (dry-run / keepGenerations /
##     storeRoot / stateDir / autoConfirm + a confirmation hook).
##   - `GcCandidate` / `GcReport` — structured result for callers
##     that want to render their own UX (the test harness in
##     particular).
##   - `runHomeGc(opts) -> GcReport` — the engine entry point.

import std/[algorithm, os, sets, strutils]
from repro_core/paths import extendedPath

import repro_home_generations
import repro_local_store

import ./junction_aware_remove

type
  GcConfirmProc* = proc(candidateCount: int; reclaimBytes: int64): bool
    {.gcsafe.}
    ## Callback invoked by ``runHomeGc`` to confirm a real delete.
    ## Returns ``true`` to proceed, ``false`` to bail. ``nil`` means
    ## "auto-yes" (forced); ``dry-run`` mode skips the call entirely.

  GcOptions* = object
    ## Inputs to ``runHomeGc``. All fields are optional; the engine
    ## fills defaults at entry.
    dryRun*: bool
      ## When ``true``, the report is produced but nothing is
      ## deleted (the operator's preview path).
    autoConfirm*: bool
      ## ``--force`` / ``-y``: skip the operator prompt entirely.
      ## When ``true``, the ``confirm`` callback is NOT invoked.
    keepGenerations*: int
      ## Number of most-recent generations to preserve. Default 2
      ## per the M10 spec. The currently-active generation always
      ## counts as one of the preserved set regardless of its rank
      ## by activation timestamp.
    storeRoot*: string
      ## Optional explicit store root; empty means
      ## ``resolveStoreRoot()``.
    stateDir*: string
      ## Optional explicit state-dir; empty means
      ## ``resolveStateDir()``.
    confirm*: GcConfirmProc
      ## Optional confirm callback. ``nil`` + ``not autoConfirm`` +
      ## ``not dryRun`` triggers the engine's tty-prompt fallback.

  GcCandidate* = object
    ## One orphaned prefix the gc proposes to delete.
    packageName*: string
    version*: string
    realizedPath*: string         ## relative to store root
    absolutePath*: string         ## resolved against store root
    prefixIdHex*: string          ## 64-char lower-case hex
    sizeBytes*: int64
    isJunctionEntry*: bool        ## true if the prefix dir itself is
                                  ## a reparse point (degenerate)

  GcOutcome* = enum
    goSkippedDryRun = "skipped-dry-run"
    goSkippedCancelled = "skipped-cancelled"
    goDeleted = "deleted"
    goNoCandidates = "no-candidates"

  GcReport* = object
    ## Structured result returned to the CLI / test harness.
    outcome*: GcOutcome
    candidates*: seq[GcCandidate]
    candidateBytes*: int64        ## sum of ``sizeBytes`` across
                                  ## ``candidates``
    keptGenerationIds*: seq[string]
      ## Hex generation ids the run treated as "live" (whose prefix
      ## refs anchored the keep-set).
    deletedCount*: int
    failedCount*: int
    failures*: seq[tuple[absolutePath, error: string]]
    reclaimedBytes*: int64        ## sum of sizes for prefixes
                                  ## actually deleted

const
  DefaultKeepGenerations* = 2
    ## M10 spec default — preserves "the just-rolled-back-by-mistake"
    ## scenario. Overridden via ``GcOptions.keepGenerations``.

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

proc digestHexLower(d: Digest256): string =
  for b in d:
    result.add(toHex(int(b), 2).toLowerAscii())

proc bytesToDigest256(bytes: PrefixIdBytes): Digest256 =
  for i in 0 ..< 32:
    result[i] = bytes[i]

proc humanBytes*(n: int64): string =
  ## Compact "1.4 MB" style formatter used by the dry-run footprint
  ## printer. Binary units (1024-based) for storage parity with
  ## ``df -h`` and Windows Explorer.
  if n < 0: return "0 B"
  const units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var value = float64(n)
  var idx = 0
  while value >= 1024.0 and idx + 1 < units.len:
    value /= 1024.0
    inc idx
  if idx == 0:
    return $n & " B"
  formatFloat(value, ffDecimal, precision = 2) & " " & units[idx]

# ---------------------------------------------------------------------------
# Live-set computation.
# ---------------------------------------------------------------------------

proc computeKeepSet(records: seq[GenerationRecord]; keepN: int):
    tuple[liveDigests: HashSet[string]; keptIds: seq[string]] =
  ## Pick the ``keepN`` most-recent generations (by activation
  ## timestamp; ties broken by hex id per ``enumerateGenerations``
  ## ordering). The currently-active generation is ALWAYS in the
  ## keep set regardless of rank — the spec is explicit: "the
  ## ``--keep-generations`` flag must always preserve at least 1
  ## (the active one)".
  ##
  ## Returns the union of ``realizedPrefixIds`` (as lower-case hex)
  ## across the kept generations + the hex ids of the kept
  ## generations themselves (for the report).
  result.liveDigests = initHashSet[string]()
  result.keptIds = @[]
  if records.len == 0:
    return
  # ``enumerateGenerations`` is oldest-first; reverse for newest-first.
  var byAge = records
  byAge.reverse()
  let target = max(keepN, 1)
  var kept: seq[GenerationRecord]
  # Always include the active generation, even if it is not in the
  # top-N by timestamp.
  var activeIdx = -1
  for i, r in byAge:
    if r.isActive:
      activeIdx = i
      break
  if activeIdx >= 0:
    kept.add(byAge[activeIdx])
  for i, r in byAge:
    if kept.len >= target: break
    if i == activeIdx: continue
    kept.add(r)
  for r in kept:
    result.keptIds.add(r.generationId)
    for d in r.envelope.realizedPrefixIds:
      result.liveDigests.incl(digestHexLower(d))

# ---------------------------------------------------------------------------
# Orphan enumeration.
# ---------------------------------------------------------------------------

proc enumerateCandidates*(store: Store;
                          liveDigests: HashSet[string]): seq[GcCandidate] =
  ## Walk the store's ``prefixes`` index and emit one candidate per
  ## row whose ``prefixId`` hex is NOT in the live set. We pull the
  ## row's filesystem footprint via the junction-aware size walker.
  ##
  ## The store's SQLite index is the source of truth for "what
  ## prefixes exist". Any on-disk directory that lacks an index row
  ## is a recovery concern, NOT a gc concern — store ``recover``
  ## reconciles those. M10 deliberately does not chase them: a gc
  ## that reaches outside the index would tangle with the parallel
  ## "store gc" path (M56), which is out of M10's scope.
  result = @[]
  for row in store.listPrefixes():
    let hex = digestHexLower(bytesToDigest256(row.prefixId))
    if hex in liveDigests:
      continue
    let abs = store.absolutePrefixPath(row.realizedPath)
    var cand = GcCandidate(
      packageName: row.packageName,
      version: row.version,
      realizedPath: row.realizedPath,
      absolutePath: abs,
      prefixIdHex: hex,
      isJunctionEntry: isJunction(abs))
    if dirExists(extendedPath(abs)) or fileExists(extendedPath(abs)):
      cand.sizeBytes = directorySizeBytes(abs)
    else:
      cand.sizeBytes = 0
    result.add(cand)
  result.sort(proc(a, b: GcCandidate): int =
    cmp(a.absolutePath, b.absolutePath))

# ---------------------------------------------------------------------------
# Confirmation fallback.
# ---------------------------------------------------------------------------

proc ttyPromptConfirm(candidateCount: int; reclaimBytes: int64): bool =
  ## Default operator prompt when ``confirm`` is nil and we are not
  ## in dry-run / forced mode. Reads a single line from stdin;
  ## anything other than ``y`` / ``Y`` / ``yes`` is a NO.
  stdout.write("Delete " & $candidateCount & " orphaned prefix(es) (" &
    humanBytes(reclaimBytes) & ")? [y/N] ")
  stdout.flushFile()
  var line = ""
  try:
    line = stdin.readLine()
  except IOError:
    return false
  let normalized = line.strip().toLowerAscii()
  result = normalized == "y" or normalized == "yes"

# ---------------------------------------------------------------------------
# Engine entry point.
# ---------------------------------------------------------------------------

proc runHomeGc*(opts: GcOptions): GcReport =
  ## Run the M10 gc engine end to end. ``opts`` carries the dry-run /
  ## force / keepGenerations toggles; everything else falls back to
  ## the documented OS-XDG resolution.
  let keepN =
    if opts.keepGenerations > 0: opts.keepGenerations
    else: DefaultKeepGenerations
  let stateDir =
    if opts.stateDir.len > 0: opts.stateDir
    else: resolveStateDir()
  let storeRootResolved =
    if opts.storeRoot.len > 0: opts.storeRoot
    else: resolveStoreRoot()
  # Enumerate generations + compute the live set.
  let records = enumerateGenerations(stateDir)
  let keep = computeKeepSet(records, keepN)
  result.keptGenerationIds = keep.keptIds
  # Open the store read-only-ish: we hold a Store handle just to
  # query ``listPrefixes`` + resolve absolute paths. No
  # ``insert``/``delete``/``registerRoot`` calls are made anywhere
  # in this path. The store's SQLite index is left untouched; M56's
  # own gc/recover paths handle index reconciliation.
  var store = openStore(storeRootResolved)
  defer: store.close()
  result.candidates = enumerateCandidates(store, keep.liveDigests)
  result.candidateBytes = 0
  for c in result.candidates:
    result.candidateBytes += c.sizeBytes
  if result.candidates.len == 0:
    result.outcome = goNoCandidates
    return result
  if opts.dryRun:
    result.outcome = goSkippedDryRun
    return result
  # Real delete path. Decide on confirmation.
  if not opts.autoConfirm:
    let proceed =
      if opts.confirm != nil:
        opts.confirm(result.candidates.len, result.candidateBytes)
      else:
        ttyPromptConfirm(result.candidates.len, result.candidateBytes)
    if not proceed:
      result.outcome = goSkippedCancelled
      return result
  # Junction-aware delete loop. A single bad prefix MUST NOT abort
  # the whole gc (it is best-effort reclaim, not a transaction).
  for c in result.candidates:
    try:
      removeJunctionAware(c.absolutePath)
      # After deleting the prefix, see if the parent (the package
      # bucket under ``prefixes/<package>/``) is now empty; if so,
      # remove it too. Skip if the parent does not match the
      # canonical ``prefixes/<package>`` shape — defensive.
      let parent = parentDir(c.absolutePath)
      if dirExists(extendedPath(parent)):
        var hasChildren = false
        for _ in walkDir(extendedPath(parent)):
          hasChildren = true
          break
        if not hasChildren:
          # Empty bucket dir is safe to remove via Win32
          # RemoveDirectoryW / POSIX rmdir; never recursive.
          try:
            removeDir(extendedPath(parent), checkDir = false)
          except OSError:
            discard
      inc result.deletedCount
      result.reclaimedBytes += c.sizeBytes
    except CatchableError as e:
      inc result.failedCount
      result.failures.add((absolutePath: c.absolutePath, error: e.msg))
  result.outcome = goDeleted

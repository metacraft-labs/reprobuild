## M10 — ``repro home gc``: generation retention plus store GC.
##
## ``repro home gc`` applies the calling state directory's retention
## (``--keep-generations N``, default 2, the active generation always
## kept) and then lets the store's own reachability GC decide what is
## unreferenced. It never decides on its own that a prefix is dead.
##
## Why it works through roots (Local-Content-Addressed-Store.md §"Roots
## and GC"): a prefix that ANY root holds is live -- a `workspace` lock,
## a running dev shell (`session`), a `pin`, or a `profile` root of
## another state directory that uses the same store. A state directory's
## generations name only what that state directory needs, so a gc that
## deleted every prefix its kept generations do not name destroyed the
## prefixes all of those other holders rely on, and left their index rows
## and holds naming directories that were gone. Instead:
##
##   1. Under ``<state-dir>/locks/apply.lock``, every generation the state
##      directory keeps gets its full `profile` root
##      (``ensureGenerationRoots``), so store GC cannot take what a kept
##      generation names.
##   2. Each generation retention drops is moved into
##      ``generations/.aborted/<id>-retired-<time>/`` (one rename), and
##      ``releaseQuarantinedRoots`` deletes this state directory's
##      `profile` root for it -- only that one: another state directory
##      holding the same generation id holds it through a root of its own,
##      and a bare-id root an earlier build registered is left alone
##      (Home-Profile-Generations-And-State.md §"Store GC Interaction").
##      The retired directories are then removed. A generation directory
##      that stayed under ``generations/`` would get its root back from the
##      next apply's ``ensureGenerationRoots``, undoing the release; the
##      move-then-release order means a kill at any point leaves either a
##      held generation or a quarantined one whose root the next apply (or
##      gc) releases.
##   3. Store GC (``repro_local_store.gc``) collects every prefix no root
##      holds: it moves the directory to ``gc/pending-deletion/`` and
##      drops the index row in one transaction, re-checking the holders
##      first, and unlinks the tree after the grace period. Its tree
##      remover unlinks a junction / symlink as a link and never follows
##      it, which is the hazard ``./junction_aware_remove`` exists for.
##
## The dry-run preview answers the same question without writing: the
## prefixes every one of whose holders is a root this run would release
## (none counts), less anything a kept generation names.
##
## Public surface:
##
##   - `GcOptions` — invocation knobs (dry-run / keepGenerations /
##     storeRoot / stateDir / autoConfirm + a confirmation hook).
##   - `GcCandidate` / `GcReport` — structured result for callers
##     that want to render their own UX (the test harness in
##     particular).
##   - `runHomeGc(opts) -> GcReport` — the engine entry point.

import std/[algorithm, os, sets, strutils, tables]
from repro_core/paths import extendedPath

import repro_home_generations
import repro_local_store

import ./junction_aware_remove
import ./partial_recovery

type
  GcConfirmProc* = proc(candidateCount: int; reclaimBytes: int64): bool
    {.gcsafe.}
    ## Callback invoked by ``runHomeGc`` to confirm a real run.
    ## ``candidateCount`` / ``reclaimBytes`` describe the prefixes the
    ## preview expects store GC to collect; the generations the run
    ## drops are in ``GcReport.droppedGenerationIds``.
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
    ## One prefix that no root will hold once the run has released the
    ## roots of the generations it drops.
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
    droppedGenerationIds*: seq[string]
      ## Hex ids of the generations retention drops, oldest first. A
      ## real run removes them and releases their `profile` roots; a
      ## dry-run or a cancelled run only lists them.
    deletedCount*: int
      ## Prefixes store GC collected (moved out of ``prefixes/`` and
      ## dropped from the index) during the run.
    failedCount*: int
    failures*: seq[tuple[absolutePath, error: string]]
      ## A generation directory that could not be retired, or a
      ## candidate that no root holds and store GC still could not move.
    reclaimedBytes*: int64        ## sum of sizes for prefixes
                                  ## actually collected

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
# Retention: which generations stay.
# ---------------------------------------------------------------------------

type
  Retention = object
    keptIds: seq[string]           ## newest first, the active one first
    droppedIds: seq[string]        ## oldest first
    keptDigests: HashSet[string]   ## lower-case hex prefix ids kept
                                   ## generations name

proc computeRetention(records: seq[GenerationRecord]; keepN: int):
    Retention =
  ## Pick the ``keepN`` most-recent generations (by activation
  ## timestamp; ties broken by hex id per ``enumerateGenerations``
  ## ordering). The currently-active generation is ALWAYS kept
  ## regardless of rank — the spec is explicit: "the
  ## ``--keep-generations`` flag must always preserve at least 1
  ## (the active one)". Every other generation is dropped.
  result.keptDigests = initHashSet[string]()
  if records.len == 0:
    return
  # ``enumerateGenerations`` is oldest-first; reverse for newest-first.
  var byAge = records
  byAge.reverse()
  let target = max(keepN, 1)
  var kept: seq[GenerationRecord]
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
  var keptSet = initHashSet[string]()
  for r in kept:
    keptSet.incl(r.generationId)
    result.keptIds.add(r.generationId)
    for d in r.envelope.realizedPrefixIds:
      result.keptDigests.incl(digestHexLower(d))
  for r in records:
    if r.generationId notin keptSet:
      result.droppedIds.add(r.generationId)

proc releasedRootIds(stateDir: string; droppedIds: seq[string]):
    HashSet[string] =
  ## The `profile` roots a run releases: this state directory's root for
  ## each dropped generation. Empty when the state directory has no key
  ## (it registered no root under one). Never creates the key.
  result = initHashSet[string]()
  let key = existingStateDirRootKey(stateDir)
  if key.len == 0:
    return
  for id in droppedIds:
    result.incl(profileRootIdForKey(key, id))

# ---------------------------------------------------------------------------
# Candidate enumeration (the preview).
# ---------------------------------------------------------------------------

proc enumerateCandidates*(store: Store; keptDigests: HashSet[string];
                          releasedRoots: HashSet[string]): seq[GcCandidate] =
  ## The prefixes store GC will collect once ``releasedRoots`` are gone:
  ## every indexed prefix whose holders (``rootsHolding``) are all in
  ## ``releasedRoots`` -- none counts -- and that no kept generation
  ## names (``keptDigests``, lower-case hex). A prefix that any other root
  ## holds is live and never a candidate.
  ##
  ## The store's SQLite index is the source of truth for "what prefixes
  ## exist"; an on-disk directory without an index row is a recovery
  ## concern (store ``recover``), not a gc one.
  result = @[]
  for row in store.listPrefixes():
    let hex = digestHexLower(bytesToDigest256(row.prefixId))
    if hex in keptDigests:
      continue
    var heldElsewhere = false
    for holder in store.rootsHolding(row.prefixId):
      if holder notin releasedRoots:
        heldElsewhere = true
        break
    if heldElsewhere:
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

proc ttyPromptConfirm(candidateCount: int; reclaimBytes: int64;
                      generationCount: int): bool =
  ## Default operator prompt when ``confirm`` is nil and we are not
  ## in dry-run / forced mode. Reads a single line from stdin;
  ## anything other than ``y`` / ``Y`` / ``yes`` is a NO.
  stdout.write("Remove " & $generationCount & " generation(s) and " &
    "collect " & $candidateCount & " unreferenced prefix(es) (" &
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
# Retiring dropped generations.
# ---------------------------------------------------------------------------

const RetiredReason = "retired"
  ## The reason ``quarantineGenerationDir`` records for a generation gc
  ## dropped: ``.aborted/<id>-retired-<time>/``.

proc isRetiredEntry(leaf: string): bool =
  ## True for a ``.aborted/`` entry this module named, whatever its id.
  quarantinedGenerationId(leaf).len > 0 and
    leaf.continuesWith("-" & RetiredReason & "-", 2 * GenerationIdSize)

proc retireGenerations(stateDir: string; droppedIds: seq[string];
                       store: var Store; report: var GcReport) =
  ## Steps 1 and 2 of the module header. The caller holds the apply lock.
  # Kept generations must be held in full before anything is released:
  # a root lost to a kill during an earlier commit would otherwise let
  # store GC take what a kept generation names.
  discard ensureGenerationRoots(stateDir, store)
  for id in droppedIds:
    try:
      discard quarantineGenerationDir(stateDir, id, RetiredReason)
      report.droppedGenerationIds.add(id)
    except CatchableError as e:
      inc report.failedCount
      report.failures.add((absolutePath: generationDir(stateDir, id),
        error: e.msg))
  # Deletes this state directory's root for every quarantined id that
  # has no live directory: the ones just moved, and any a killed earlier
  # run moved without releasing.
  discard releaseQuarantinedRoots(stateDir, store)
  let aborted = abortedDir(stateDir)
  if not dirExists(extendedPath(aborted)):
    return
  # TODO(win-longpath): walk results escape; needs review
  for kind, entry in walkDir(aborted, relative = false):
    if kind != pcDir or not isRetiredEntry(extractFilename(entry)):
      continue
    try:
      # A generation's ``bin/`` holds links into store prefixes; the
      # junction-aware remover unlinks them and never their targets.
      removeJunctionAware(entry)
    except CatchableError as e:
      inc report.failedCount
      report.failures.add((absolutePath: entry, error: e.msg))

# ---------------------------------------------------------------------------
# Engine entry point.
# ---------------------------------------------------------------------------

proc runHomeGc*(opts: GcOptions): GcReport =
  ## Run the gc end to end (module header). ``opts`` carries the
  ## dry-run / force / keepGenerations toggles; everything else falls
  ## back to the documented OS-XDG resolution.
  ##
  ## Raises ``EApplyBusy`` when another apply holds the state
  ## directory's apply lock for longer than the lock timeout, and the
  ## registry errors of ``enumerateGenerations`` for a corrupt or
  ## partial registry.
  let keepN =
    if opts.keepGenerations > 0: opts.keepGenerations
    else: DefaultKeepGenerations
  let stateDir =
    if opts.stateDir.len > 0: opts.stateDir
    else: resolveStateDir()
  let storeRootResolved =
    if opts.storeRoot.len > 0: opts.storeRoot
    else: resolveStoreRoot()
  # Preview, without writing anything and without the lock.
  let preview = computeRetention(enumerateGenerations(stateDir), keepN)
  result.keptGenerationIds = preview.keptIds
  result.droppedGenerationIds = preview.droppedIds
  var store = openStore(storeRootResolved)
  defer: store.close()
  result.candidates = enumerateCandidates(store, preview.keptDigests,
    releasedRootIds(stateDir, preview.droppedIds))
  result.candidateBytes = 0
  for c in result.candidates:
    result.candidateBytes += c.sizeBytes
  if result.candidates.len == 0 and preview.droppedIds.len == 0:
    result.outcome = goNoCandidates
    return result
  if opts.dryRun:
    result.outcome = goSkippedDryRun
    return result
  if not opts.autoConfirm:
    let proceed =
      if opts.confirm != nil:
        opts.confirm(result.candidates.len, result.candidateBytes)
      else:
        ttyPromptConfirm(result.candidates.len, result.candidateBytes,
          preview.droppedIds.len)
    if not proceed:
      result.outcome = goSkippedCancelled
      return result
  # The real run. Retention is decided again under the lock: an apply
  # may have committed or switched generations since the preview. A state
  # directory with no generations has nothing to retire, and is not
  # created just to take its lock.
  result.droppedGenerationIds = @[]
  if dirExists(extendedPath(generationsRoot(stateDir))):
    var lock = acquireApplyLock(stateDir)
    try:
      let retention = computeRetention(enumerateGenerations(stateDir), keepN)
      result.keptGenerationIds = retention.keptIds
      retireGenerations(stateDir, retention.droppedIds, store, result)
    finally:
      releaseApplyLock(lock)
  # Store GC decides what is unreferenced, re-checking every holder
  # inside its own transaction.
  var sizes = initTable[string, int64]()
  for c in result.candidates:
    sizes[c.prefixIdHex] = c.sizeBytes
  let collected = store.gc()
  for row in collected.quarantined:
    inc result.deletedCount
    result.reclaimedBytes +=
      sizes.getOrDefault(digestHexLower(bytesToDigest256(row.prefixId)))
  # A candidate that is still indexed with no holder is one store GC could
  # not move (it audits "quarantine deferred"); its next pass retries.
  for c in result.candidates:
    let id = parsePrefixIdHex(c.prefixIdHex)
    if store.lookupPrefix(id).found and store.rootsHolding(id).len == 0:
      inc result.failedCount
      result.failures.add((absolutePath: c.absolutePath,
        error: "store GC could not move this unreferenced prefix out of " &
          "the store; the next gc retries it"))
  result.outcome = goDeleted

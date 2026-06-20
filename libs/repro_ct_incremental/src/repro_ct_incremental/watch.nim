## Watch-integration seam — the M2 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign.
##
## `repro watch --ct-incremental` (wired in `repro_cli_support`) needs a single,
## *pure* decision function it can call on every filesystem-change cycle: given a
## watched test edge, decide whether the test may be skipped because none of the
## functions it previously executed have changed, or must be re-run.
##
## This module provides exactly that seam, `watchTestEdgeDecision`, and keeps it
## free of any wall-clock or live-filesystem-watcher concerns so the M2 tests can
## drive it deterministically (no `sleep`, no race against an OS watcher). It is a
## thin, well-documented wrapper over the M1 engine:
##
##   1. Load the on-disk incremental cache (`loadCache`).
##   2. Call the M1 `decide` for the test edge.
##   3. Translate the `IncrementalDecision` into a `WatchEdgeDecision` that the
##      watch loop can act on (skip vs. re-run) and report.
##
## The watch loop owns the side effects: when the seam says "re-run", the loop
## re-executes the test, re-traces it, and calls the M1 `record` to refresh the
## cache. The seam itself performs no writes — it is referentially transparent
## given the cache file and the current source tree.

import std/strutils
import results

import engine
export engine

type
  WatchEdgeAction* = enum
    ## What the watch loop should do with the watched test edge this cycle.
    weaRun        ## Re-run the test edge (fresh, changed, or fail-safe error).
    weaSkip       ## Skip — no executed function changed since the last record.

  WatchEdgeDecision* = object
    ## The seam's verdict for one watched test edge on one change cycle.
    action*: WatchEdgeAction
    testId*: string
      ## The test edge's identity (echoed back for the report line).
    reason*: string
      ## Human-readable rationale, suitable for the watch report:
      ##   * ``weaSkip``  ⇒ ``unchanged`` (no executed function changed).
      ##   * ``weaRun``   ⇒ ``fresh`` (no cache entry), ``changed: a, b`` (the
      ##     executed functions that changed), or ``error: <msg>`` (a fail-safe
      ##     re-run forced by an unreadable cache — never a silent skip).
    changedFuncs*: seq[string]
      ## For a ``changed`` re-run, exactly the executed functions whose shallow
      ## hash changed (or which were removed). Empty otherwise.

  WatchCtIncrementalGate* = object
    ## The enable/disable gate for the `--ct-incremental` watch feature, as seen
    ## by the engine lib. Its zero value is the LEGACY default: `enabled == false`
    ## ⇒ the incremental decision machinery is never consulted and the watch loop
    ## follows its byte-for-byte legacy run path. This mirrors the
    ## `repro_cli_support` flag state but lets the engine-level no-regression
    ## guard be asserted without the (currently blocked) whole-project build.
    enabled*: bool

func runDecision(testId, reason: string;
                 changedFuncs: seq[string] = @[]): WatchEdgeDecision =
  WatchEdgeDecision(action: weaRun, testId: testId, reason: reason,
                    changedFuncs: changedFuncs)

func skipDecision(testId: string): WatchEdgeDecision =
  WatchEdgeDecision(action: weaSkip, testId: testId, reason: "unchanged")

proc watchTestEdgeDecision*(testId, traceDir, sourceRoot, cachePath: string):
    WatchEdgeDecision =
  ## Decide skip vs. re-run for the watched test edge `testId` this cycle.
  ##
  ## * `testId`     — the watched test edge's identity (used as the cache key).
  ## * `traceDir`   — where the test's CodeTracer trace lives (passed through to
  ##                  `decide` for API symmetry; the decision itself uses the
  ##                  cached deps + current source, per §16.7.4).
  ## * `sourceRoot` — the root the trace-recorded source paths resolve under.
  ## * `cachePath`  — the incremental cache JSON file (`record`'s output).
  ##
  ## Pure with respect to the cache file and the source tree: it performs no
  ## writes and no waiting. The watch loop calls it on every change cycle and
  ## acts on the returned `action`.
  ##
  ## Fail-safe: an unreadable/malformed cache forces a re-run (`weaRun`,
  ## ``error: …``) rather than a silent skip — losing the cache must never cause
  ## a test that should run to be skipped.
  let cacheRes = loadCache(cachePath)
  if cacheRes.isErr:
    return runDecision(testId, "error: " & cacheRes.error)
  let cache = cacheRes.value
  let decision = decide(testId, traceDir, sourceRoot, cache)
  case decision.kind
  of idRunFresh:
    runDecision(testId, "fresh")
  of idSkipUnchanged:
    skipDecision(testId)
  of idRerunChanged:
    runDecision(testId, "changed: " & decision.changedFuncs.join(", "),
                decision.changedFuncs)
  of idRerunNonDeterministic:
    # Spec §16.7: a non-deterministic test is always re-run. Reported distinctly
    # so the watch output shows WHY it ran despite an unchanged source.
    runDecision(testId, "non-deterministic")
  of idRerunFailSafe:
    # A conservative re-run forced by a missing/unreadable trace (or other guard)
    # — never a silent skip. The engine's diagnostic is surfaced verbatim.
    runDecision(testId, "error: " & decision.reason)

proc gatedWatchDecision*(gate: WatchCtIncrementalGate;
                         testId, traceDir, sourceRoot, cachePath: string):
    WatchEdgeDecision =
  ## The gate-aware wrapper the watch loop's no-flag path is modelled on. When
  ## the feature is DISABLED (the legacy default), this short-circuits to the
  ## legacy run verdict (`weaRun`, ``ct-incremental-disabled``) WITHOUT loading
  ## the cache or consulting the incremental engine at all — proving the no-flag
  ## path can never skip a test. Only when the gate is enabled does it delegate
  ## to the pure `watchTestEdgeDecision` seam.
  if not gate.enabled:
    return runDecision(testId, "ct-incremental-disabled")
  watchTestEdgeDecision(testId, traceDir, sourceRoot, cachePath)

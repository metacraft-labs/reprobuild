# Reprobuild ↔ Runquota integration: denial policy

## Audience

This document describes how reprobuild reacts when the runquota daemon (or
inline gate) refuses to grant a resource lease for an action's process
launch. It is the authoritative reference for what reprobuild *should* do
on denial; the implementation in `libs/repro_runquota/` and
`libs/repro_build_engine/` must match it.

## Background

Every action that reprobuild launches under runquota is preceded by a
lease *offer* to the runquota authority:

* The client (`repro_runquota.offerCandidates` or `waitForQueuedGrant`)
  describes the resources the action expects to use (CPU millicores,
  resident memory, IO slots, named-pool units).
* The authority either grants the lease immediately, places the lease in
  its queue (to be granted later when other leases release), or **denies**
  the lease outright.

A denial means the daemon decided the lease cannot be admitted at all.
The denial message names the budget that was exceeded — for example:

```
runquota denied lease: lease request exceeds machine memory budget: local
runquota denied lease: lease request exceeds shared CPU budget: local
runquota denied lease: lease request exceeds named-pool budget: cargo-network
```

Denials happen for one of two distinct reasons:

1. **Hard denial** — the request exceeds the *machine's static capacity*
   (e.g. asks for 32 GiB on a 16 GiB host). No amount of waiting will let
   the request through with the current daemon configuration. The
   operator must either grow the machine's budget, shrink the request,
   or reconfigure the daemon's named-pool caps.

2. **Soft / transient denial** — the request would exceed a budget that
   is currently saturated by other live leases. Once a competing lease
   releases its share, the same request would be admitted. (Today the
   daemon delivers most transient pressure as a *queued* decision rather
   than a denial; future daemons may introduce additional shapes of
   transient denial.)

From the client's perspective the two are not always distinguishable —
denial diagnostics describe the budget but not the future. Reprobuild
must therefore treat every denial uniformly.

## Policy

**Reprobuild MUST treat every runquota denial as a request to delay,
not as a build-stopping error.** The build does not fail because of a
denied lease.

Concretely:

1. On denial, reprobuild logs a clearly-attributed diagnostic (the
   daemon's denial message, the candidate's `commandStatsId`, and the
   attempt counter).

2. Reprobuild waits before re-attempting the same offer. The wait grows
   on successive denials of the same candidate (exponential backoff,
   bounded to a reasonable cap such as a few seconds) so that hot loops
   neither overload the daemon nor waste CPU.

3. Reprobuild re-offers the lease and keeps trying for as long as the
   build's overall deadline allows. The scheduler treats a still-denied
   candidate the same way it treats a queued candidate: the action stays
   in the runnable set, the pool reservation remains held, and other
   independent actions continue to make progress.

4. Reprobuild MUST NOT silently down-scale the lease request. The
   request shape is part of the recipe's resource declaration; lying
   about it would corrupt the daemon's accounting and surface as a
   silent over-commit. If the operator wants reduced requests they
   express that in the recipe.

5. Reprobuild MUST NOT bypass runquota and launch unqualified
   processes after a denial. The lease authority is the source of truth
   for admission; bypassing it would race against the leases the daemon
   has already granted to other clients and break shared-pool fairness.

6. When the entire build can make no further progress *only* because
   every remaining action's lease is being denied, reprobuild surfaces
   that as a build-engine deadlock — distinct from a per-action failure
   — so operators can recognise "the daemon's machine capacity is too
   small for this build" as a configuration problem rather than a code
   problem.

The implementation MUST NOT exit with `ReproRunQuotaError` on a denial.
That exception type is reserved for protocol-level failures (the daemon
crashed, the session lost framing, codec errors, etc.) — i.e. cases
where retrying with the same session cannot recover.

## Examples

### Helper-process mode (`runWithRunQuota`)

The synchronous path used by the runquota CLI helper acquires its lease
via `waitForQueuedGrant`. On denial it logs the diagnostic, sleeps for
the current backoff, and re-offers the candidate. The helper's caller
sees the same `ReproRunQuotaExecution` shape whether the lease was
granted on the first try or the fortieth.

### Inline batch path (`offerWithRunQuotaBatch`)

The build engine's inline launcher submits up to N candidates per round
trip. Granted candidates spawn their child immediately; queued
candidates carry a lease handle for `pollRunQuotaGrants`; **denied
candidates surface as a `rqokDeferred` offer**. The engine reinserts the
deferred action onto the ready queue with a backoff-stamped deadline so
the next scheduler tick re-offers it.

A denied candidate must never be turned into an `asFailed` ActionResult
solely because of the denial.

### Static capacity exceeded forever

If the request statically exceeds the daemon's machine budget (for
example a build that asks for 32 GiB on a 16 GiB host), reprobuild will
keep retrying. The operator notices the build is stuck via the progress
stream — every retry emits a denial diagnostic. The fix is to grow the
daemon's configured budget, lower the recipe's request, or run the
build on a larger host. Reprobuild does not autonomously decide that
its caller's resource declaration is "wrong".

## Diagnostics & observability

Every denial-and-retry cycle MUST emit at least the following on the
build's diagnostic stream:

* `runquota.denied` event with: candidate ID, command stats ID, daemon
  diagnostic text, current backoff (ms), attempt counter.
* When the backoff caps out, the diagnostic is escalated (e.g. flagged
  as a warning instead of an info-level event) so operators see the
  "stuck" state without grep'ing.
* The first successful grant after one or more denials emits a single
  `runquota.granted-after-retry` event with the total attempt count so
  post-hoc analysis can spot pressure hotspots.

## Test surface

Tests that assert a denied lease causes an `asFailed` ActionResult are
documenting the *legacy* fail-fast behaviour and must be rewritten.
Replacement coverage:

* "denied lease retries with backoff and eventually starts" — set up the
  daemon to deny the first N offers and grant the (N+1)-th, then assert
  `asSucceeded` plus the expected retry count in the diagnostic stream.
* "every denial emits a runquota.denied event" — counts the diagnostic
  events versus the synthetic denial schedule.
* "deadlock detection" — a build whose every action statically exceeds
  the machine budget surfaces a distinct error after a bounded number
  of retries, with a diagnostic that names the budget rather than the
  action.

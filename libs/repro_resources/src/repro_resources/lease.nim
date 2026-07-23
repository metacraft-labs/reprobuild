## L2 (Ephemeral-State-Leases.md §2.2 / §2.3): the per-consume-edge lease
## policy + the leased-dependency value.
##
## A *consumer* (a test-execution edge, or any resource/action) depends on
## a leased ephemeral state and declares, on that dependency, WHEN the
## state may be reaped once the consume finishes:
##
##   * `immediate`      — destroy as soon as this consume finishes (a
##                        now-deadline: reapable immediately).
##   * `delayed(ttl)`   — keep `ttl` after last use; every consume renews
##                        (deadline = now + ttl).
##   * `keep`           — never auto-reap (explicit teardown only). This is
##                        the semantics a bare `dependsOn` edge already has,
##                        so `keep` is the leased spelling of today's behaviour.
##
## This module is deliberately dependency-light (only std) so `instance.nim`
## can embed a `seq[LeasedDep]` on `ResourceInstance` without a cycle: the
## lease policy is a plain value, orthogonal to determinism (§2.1 — it says
## *when* a materialized state may be reaped, not *whether* its realization
## is reproducible).

import std/[options, times]

type
  LeaseKind* = enum
    ## The three lease policies of §2.2. `lkKeep` (never reap) is the
    ## default/`dependsOn`-equivalent; a policy value defaults to it so an
    ## unset `LeasePolicy` is the never-reap identity.
    lkKeep       ## never auto-reap (explicit teardown only) — bare-dep semantics
    lkImmediate  ## reapable as soon as the consume finishes (a now-deadline)
    lkDelayed    ## keep `ttl` after last use; renew on each consume

  LeasePolicy* = object
    ## A per-consume-edge lease policy. `ttl` is meaningful only for
    ## `lkDelayed`; it is ignored (and zero) for the other kinds.
    kind*: LeaseKind
    ttl*: Duration

  LeasedDep* = object
    ## A leased-consumption dependency: the consumer at hand CONSUMES the
    ## leased state at `address` under `policy`, pinning it as the holder
    ## `consumerId`. Distinct from a bare `dependsOn` address (which is a
    ## structural, never-reap edge): a `LeasedDep` ALSO implies the same
    ## ordering edge (the consumer depends on the state existing), so it
    ## feeds `topoOrder` exactly like a `dependsOn` entry, but additionally
    ## carries the renew/reap policy the reconciler applies to the store.
    address*: string        ## the leased state's resource address (the graph edge)
    consumerId*: string     ## this consumer's stable holder id (store `holders` key)
    policy*: LeasePolicy

# ---------------------------------------------------------------------------
# Policy constructors — the DSL vocabulary of §2.2.
# ---------------------------------------------------------------------------

proc immediate*(): LeasePolicy =
  ## `lease = immediate`: reapable as soon as this consume finishes.
  LeasePolicy(kind: lkImmediate)

proc delayed*(ttl: Duration): LeasePolicy =
  ## `lease = delayed(ttl)`: keep `ttl` after last use; renewed on each
  ## consume (deadline reset to `now + ttl`).
  LeasePolicy(kind: lkDelayed, ttl: ttl)

proc delayed*(minutes = 0; hours = 0; seconds = 0): LeasePolicy =
  ## Named-Runnable-Edges N0: the recipe-facing `delayed(minutes = 30)`
  ## sugar of the spec's DSL sketch (§4). Composes the `minutes`/`hours`/
  ## `seconds` keyword parts into a single `Duration` and forwards to the
  ## `Duration` overload above, so a recipe never has to spell
  ## `initDuration(...)` by hand. All parts default to zero, so
  ## `delayed(hours = 1)` and `delayed(minutes = 30, seconds = 15)` both
  ## type-check; an all-zero call yields a now-deadline `delayed` policy
  ## (equivalent to `immediate` for reap purposes).
  delayed(initDuration(minutes = minutes, hours = hours, seconds = seconds))

proc keep*(): LeasePolicy =
  ## `lease = keep`: never auto-reap. Same never-reap semantics a bare
  ## `dependsOn` edge already has.
  LeasePolicy(kind: lkKeep)

# ---------------------------------------------------------------------------
# The leased-dependency constructor (the `consumes` DSL entry, §5).
# ---------------------------------------------------------------------------

proc leased*(address: string; consumerId: string;
             policy: LeasePolicy): LeasedDep =
  ## Declare a leased consumption of the state at `address` under `policy`,
  ## held by `consumerId`. Attach the result to a resource's `consumes`
  ## seq (alongside bare `dependsOn`).
  LeasedDep(address: address, consumerId: consumerId, policy: policy)

proc leased*(address: string; policy: LeasePolicy): LeasedDep =
  ## Named-Runnable-Edges N0: the run-edge `consumes` spelling of the
  ## spec's DSL sketch (§3.2 / §4) — `leased("topology", delayed(...))`.
  ## The `consumerId` defaults to `address` (the leased state's own name),
  ## which is the natural stable holder id for a run-target consuming the
  ## group (spec §7 "the run-target's stable name is the natural
  ## consumerId"). N2's executor may rebind the holder to the run-edge's
  ## name before reconcile/renew; N0 only records the declaration.
  LeasedDep(address: address, consumerId: address, policy: policy)

# ---------------------------------------------------------------------------
# The policy -> deadline mapping (§2.3). This is the ONLY place a policy is
# turned into a wall-clock reap deadline; the reconciler composes these
# per-holder deadlines with a MAX (see reconcile.nim).
# ---------------------------------------------------------------------------

proc deadlineFrom*(policy: LeasePolicy; now: Time): Option[Time] =
  ## Map a lease policy, evaluated at `now`, to this holder's reap
  ## deadline:
  ##
  ##   * `immediate`   -> `some(now)`      (reapable as soon as the consume finishes)
  ##   * `delayed(ttl)`-> `some(now + ttl)`(kept `ttl` past this use)
  ##   * `keep`        -> `none(Time)`     (never a reap deadline — pins with no expiry)
  ##
  ## A `none` result means the holder pins the state with NO deadline, so a
  ## single `keep`/none holder makes the state's effective deadline `none`
  ## (never reap) regardless of other holders — the §2.3 keep-dominates rule.
  case policy.kind
  of lkImmediate: some(now)
  of lkDelayed:   some(now + policy.ttl)
  of lkKeep:      none(Time)

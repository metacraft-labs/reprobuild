## A cache-publish refusal that cannot be made without naming its reason.
##
## WHAT THIS IS. An action whose evidence the engine does not trust enough to
## bank still SUCCEEDS — its outputs are used by everything downstream — but
## its action-cache record is not published, so the next build re-runs it.
## ``CacheRefusal`` is the value that says "withhold this publish, and here is
## which class of evidence gap withheld it". The engine's ``EvidenceCollection``
## carries one.
##
## WHY IT IS ITS OWN MODULE, which is the whole point of the module and not an
## organisational preference.
##
## The refusal used to be two fields of ``EvidenceCollection``: a
## ``disableCacheHits: bool`` that decided, and a
## ``cacheIneligibilityReasons: set[CacheIneligibilityReason]`` that said which
## class decided. Seven sites refused a publish, and each had to write both.
## Nothing made them: the pairing was a doc comment ("SET THESE TOGETHER") in a
## twenty-thousand-line module where every writer could reach either field.
## It held at six sites and failed at the seventh, ``gradeKeyedInputSet``, and
## the failure was NOT cosmetic. ``determinismProbeAdmits`` gates on the exact
## set
##
##   ``reasons != {cirUnblessedEntropy}``
##
## because comparing output bytes can answer a determinism question and cannot
## answer a question about what the monitor SAW. That gate is only as truthful
## as the set is COMPLETE: a site that refused without naming its class told
## the probe that entropy was the sole refusal, and the probe then published a
## record the other refusal had already denied (reprobuild-pm issue
## ``2026-10-04-nothing-structurally-pairs-a-publish-refusal-with-its-reason``;
## the case is pinned in ``t_zero_evidence_edge_is_not_cacheable``).
##
## So the fix is to make "refused with no reason" UNREPRESENTABLE rather than
## discouraged:
##
##   * there is no flag. Whether a publish is withheld is DERIVED from the set
##     of named classes — ``refused`` is ``reasons != {}`` — so a refusal and
##     its reason cannot disagree, because there is only one fact;
##   * the set is a PRIVATE field, and the only writer is ``refuse``, whose
##     reason is a required argument. There is no way to reach "refused"
##     without supplying a class.
##
## The field has to live in a module of its own because that is the only
## privacy Nim has: an unexported field is still freely writable from anywhere
## in the module that declares it. Declared inside the engine module, the
## private field would have sealed nothing, which is why the issue's costing
## called the in-place version impossible.
## ``t_cache_refusal_always_names_its_reason`` asserts, with ``compiles``,
## that none of the bypasses (assigning the set, ``incl`` into it, constructing
## the object with a set, setting ``refused``) compiles from outside.
##
## THE ZERO VALUE IS "NOT REFUSED", and that is the correct default: Nim hands
## out the zero value for every ``var``, ``result`` and object field, and a
## fresh ``EvidenceCollection`` must publish unless some site decides
## otherwise. The empty set is also the one state whose reason list is
## legitimately empty, so the two readings coincide.
##
## WHAT THIS DOES NOT DECIDE. Which evidence warrants a refusal stays in the
## engine, at the sites that grade evidence. This module only guarantees that
## whatever they decide arrives with its name.

type
  CacheIneligibilityReason* = enum
    cirUnblessedEntropy = "unblessed-entropy"
    cirEntropyUnobservable = "entropy-unobservable"
    cirEntropyObservabilityUnknown = "entropy-observability-unknown"
    cirEmptyEvidence = "empty-evidence"
    cirMonitorLoss = "monitor-loss"
    cirMonitorFlushFailed = "monitor-flush-failed"
    cirMissingDependencyReport = "missing-dependency-report"
      ## A cacheable edge declared a recognized dependency report (a
      ## depfile) and produced none of the paths it declared, so it
      ## contributed no evidence at all. See the aggregate guard in
      ## ``collectEvidence``.
    cirEmptyKeyedInputSet = "empty-keyed-input-set"
      ## The edge DID observe something, and the engine's own subtractions
      ## — ``toolInputRoots`` and ``ignoredInputRoots`` — removed all of it,
      ## so the record would have been keyed on the weak fingerprint alone.
      ## Distinct from ``cirEmptyEvidence``, which is the monitor having
      ## seen nothing: the remedies differ (the elision, or the edge wanting
      ## ``cacheable = false``) and so must the class. See
      ## ``gradeKeyedInputSet`` and ``emptyKeyedInputSetDiagnostic``.
      ##
      ## APPEND NEW MEMBERS HERE. Nothing persists this enum — the set is a
      ## module-private diagnostic field whose only escape is ``$reason`` in
      ## ``traceCacheIneligibility`` — but ordinal order IS the order those
      ## strings are joined in, which several tests pin, so an insertion
      ## reshuffles reported text for no gain.

  CacheRefusal* = object
    ## Whether, and why, an action's cache publication is withheld. See the
    ## module header for why this has exactly one field and why it is
    ## private. The zero value is "not refused".
    reasons: set[CacheIneligibilityReason]
      ## Every class that refused this publish. Non-empty IS refused; there
      ## is deliberately no second field to disagree with it. Written only by
      ## ``refuse``.

proc refuse*(refusal: var CacheRefusal; reason: CacheIneligibilityReason) =
  ## Withhold the publication, naming ``reason`` as (one of) the classes that
  ## withheld it. Idempotent per reason, and cumulative across reasons: an
  ## action refused by two gates records both, which is what
  ## ``determinismProbeAdmits``'s exact-set comparison needs in order to tell
  ## "entropy alone" from "entropy and something the probe cannot close".
  refusal.reasons.incl(reason)

func refused*(refusal: CacheRefusal): bool =
  ## True iff at least one class refused the publication. Derived, never
  ## stored, so it cannot be true while ``reasons`` is empty.
  refusal.reasons != {}

func reasons*(refusal: CacheRefusal): set[CacheIneligibilityReason] =
  ## The classes that refused, as a value. Returning a copy is what keeps the
  ## field read-only from outside: there is no ``var`` accessor, so a caller
  ## cannot ``incl`` into or assign this set.
  refusal.reasons

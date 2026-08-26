## ``ext_codetracer_test`` — the CodeTracer-specific test layer.
##
## Normative specification:
##
## * ``codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md``
##   §17.1.2 "Layer 3 — ``ext_codetracer_test`` (owned by this
##   project)";
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Domain
##   Extensions" → "Generic test-execution extension", last paragraph.
##
## **THIS EXISTS SO THE GENERIC LAYER DOES NOT HAVE TO CARRY IT.**
## Every column below is a fact that only CodeTracer's runner has, and
## the split is load-bearing rather than tidy: OS-8 requires
## ``ext_test_execution`` to be populated by at least two different
## runners, and a schema that only this runner can fill has failed it.
## So the rule applied here is the converse of the one applied there —
## a column belongs in THIS table exactly when a second runner
## (pytest, cargo-nextest, go test) would have to invent a value for
## it, or store NULL forever.
##
## Two families live here:
##
## 1. The trace facts §17.1.2 names — ``recording_path``, ``trace_id``,
##    ``trace_format_version``, ``recorder``, ``replay_ok``. These are
##    NULL for a test that records no trace, which is every test in
##    reprobuild's own suite; they are here because the specification
##    names them and because a store that gained the columns later
##    would have to migrate every row.
##
## 2. The facts CodeTracer's Tier-1 binary protocol produces —
##    ``protocol_aware``, ``run_name``, ``body_hash``,
##    ``checkpoint_count``, ``status_disagreement``, ``harness_error``.
##    These are the ones that are non-NULL in an ordinary run, and each
##    is meaningless outside this protocol: ``run_name`` is the catalog's
##    own identifier and the ONLY string that may be handed to ``--run``
##    (rebuilding it from suite + name is not round-trip safe, which is
##    exactly why it cannot live in the generic layer's ``test_id``);
##    ``body_hash`` comes from the codetracer-nim ``std/unittest`` fork's
##    ``--list-json`` catalog; and ``status_disagreement`` is the
##    two-channel rule that this protocol's result document plus exit
##    code makes checkable.
##
## **EVERY COLUMN IS NULLABLE EXCEPT THE SPINE KEYS.** That is what
## makes "no CodeTracer-specific column is required to record a test
## outcome" (M20's gate) true by construction rather than by promise: a
## runner that never declares this extension at all still writes a
## complete generic row, and a runner that declares it may leave every
## column empty.
##
## **NO RUNQUOTA DEPENDENCY**, for the same reason
## ``test_execution_extension`` has none: pure identifiers, DDL text
## and column names.

const
  CodetracerTestExtensionId* = "codetracer_test"
    ## The registry ``extension_id``; RunQuota composes
    ## ``ext_codetracer_test`` from it. Decomposed rather than spelled,
    ## because ``isStorableIdentifier`` admits ``[a-z][a-z0-9_]*`` only
    ## and the dotted rendering is not an id.
  CodetracerTestExtensionOwner* = "codetracer"
    ## Unlike the generic layer's, this owner IS a single product. That
    ## asymmetry is the whole design: one table is owned by the build
    ## system that hosts every framework, the other by the one framework
    ## whose facts it carries.
  CodetracerTestSchemaVersion* = 1'i64

proc registeredCodetracerTestName*(): string =
  ## The dotted name prose uses, rendered from the three registry
  ## columns that actually store it.
  CodetracerTestExtensionOwner & ".test.v" & $CodetracerTestSchemaVersion

const codetracerTestCreateTable* = """
create table ext_codetracer_test (
  host_id text not null,
  execution_id text not null,
  recording_path text,
  trace_id text,
  trace_format_version text,
  recorder text,
  replay_ok integer,
  protocol_aware integer,
  run_name text,
  body_hash text,
  checkpoint_count integer,
  status_disagreement text,
  harness_error text,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions (host_id, execution_id)
);
"""
  ## Step 1 of the forward-only ladder: version 0 → version 1.

proc codetracerTestMigrations*(): seq[string] =
  @[codetracerTestCreateTable]

proc codetracerTestColumns*(): seq[string] =
  @["recording_path", "trace_id", "trace_format_version", "recorder",
    "replay_ok", "protocol_aware", "run_name", "body_hash",
    "checkpoint_count", "status_disagreement", "harness_error"]

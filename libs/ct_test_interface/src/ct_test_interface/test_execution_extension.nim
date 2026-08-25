## ``ext_test_execution`` — the FRAMEWORK-NEUTRAL test layer.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Domain
##   Extensions" → "Generic test-execution extension", and invariants
##   OS-3, OS-5, OS-8;
## * ``codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md``
##   §17.1.2 "Layer 2".
##
## **THIS LAYER IS OWNED BY NO TEST FRAMEWORK, AND THAT IS THE POINT.**
## OS-8: "The generic test layer MUST be populated by at least two
## different runners. A schema only one runner can populate has failed
## this." Everything here is a fact that *every* test framework has —
## an identifier for the case, an outcome from a fixed vocabulary, how
## long it took, which retry it was, what it said when it failed, and
## how much it wrote. Nothing here is peculiar to ``std/unittest``, to
## Nim, or to CodeTracer.
##
## Facts that ARE peculiar to a framework go one layer further out:
## CodeTracer's live in ``codetracer_test_extension``. The test for
## whether a column belongs here is not "does this runner have it" but
## "would pytest, cargo-nextest and go test all have it" — and the
## milestone that makes that question expensive to get wrong is M20,
## which adds the second runner.
##
## **NO RUNQUOTA DEPENDENCY.** This module is pure data: identifiers,
## DDL text and column names. It is imported by the reporter that
## speaks RQSP and, in M20, by a runner in another repository that
## must declare the IDENTICAL triple. Keeping it free of the client
## library is what lets a second runner reuse it without inheriting
## reprobuild's transport.
##
## **THE REGISTERED ID IS DECOMPOSED, NOT SPELLED**, exactly as
## ``ext_repro_action``'s is: RunQuota's registry composes the table
## name from the ``extension_id`` by concatenation, so
## ``isStorableIdentifier`` admits ``[a-z][a-z0-9_]*`` only and a dotted
## rendering such as ``reprobuild.test-execution.v1`` cannot be an id.
## The three parts are the three columns the registry already has.

const
  TestExecutionExtensionId* = "test_execution"
    ## The registry ``extension_id``. RunQuota composes the table name
    ## ``ext_test_execution`` from it; this constant is the only place
    ## any runner spells it.
  TestExecutionExtensionOwner* = "reprobuild"
    ## The DECLARING PRODUCT, and deliberately not a test framework.
    ##
    ## The specification says this table is "owned by no single test
    ## framework and populated by any of them". The registry's ``owner``
    ## column wants a product all the same, and the honest answer is the
    ## build system that hosts the frameworks rather than any one of
    ## them: a runner declaring ``owner = "codetracer"`` here would be
    ## the first step of exactly the capture OS-8 forbids. Every runner
    ## declares this same triple, which is why the constant is shared
    ## rather than copied.
  TestExecutionSchemaVersion* = 1'i64

  TestExecutionStatuses* = [
    "pass", "fail", "skip", "xfail", "xpass", "leak", "timeout"]
    ## The ``status`` vocabulary, verbatim from §"Generic test-execution
    ## extension". Enforced in the DDL below by a ``check`` constraint,
    ## so a runner that invents an eighth value is refused by the store
    ## rather than silently widening the vocabulary for everyone else.

proc registeredTestExecutionName*(): string =
  ## The dotted name prose uses, rendered from the three registry
  ## columns that actually store it.
  TestExecutionExtensionOwner & ".test-execution.v" & $TestExecutionSchemaVersion

const testExecutionCreateTable* = """
create table ext_test_execution (
  host_id text not null,
  execution_id text not null,
  test_id text not null,
  suite text,
  status text not null
    check (status in
      ('pass', 'fail', 'skip', 'xfail', 'xpass', 'leak', 'timeout')),
  duration_ms integer,
  attempt integer not null,
  retry_of text,
  error_message text,
  skip_reason text,
  stdout_len integer,
  stderr_len integer,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions (host_id, execution_id)
);
"""
  ## Step 1 of the forward-only ladder: version 0 → version 1.
  ##
  ## ``suite`` IS NULLABLE because a suite-less case is a real case —
  ## the codetracer-nim ``std/unittest`` fork catalogues one as
  ## ``::testname`` — and so is a framework with no suite concept at
  ## all. A ``not null`` here would force such a runner to write the
  ## empty string, which is a measurement ("the suite is named ''")
  ## rather than an absence.
  ##
  ## ``duration_ms`` IS NULLABLE for the reason §"executions" gives for
  ## the spine's own columns: "A figure the writer was not given MUST be
  ## stored as NULL, never as zero." It is also NOT a duplicate of the
  ## spine's ``duration_ms``: the spine measures the PROCESS, this
  ## measures the CASE, and under a runner that executes one case per
  ## process the difference is process startup, while under a runner
  ## that executes many cases per process the two are not comparable at
  ## all.
  ##
  ## ``retry_of`` names the ``test_id`` of the execution this one
  ## retries, NULL on a first attempt. ``attempt`` is 1-based.
  ##
  ## ``stdout_len``/``stderr_len`` are SIZES, NOT PAYLOADS, per the
  ## specification's column note. Payload storage is a runner
  ## configuration concern (§17.1.1) and deliberately not a column here.
  ##
  ## THEY ARE NULLABLE, AND THAT IS THE SPINE'S OWN RULE APPLIED HERE.
  ## §"executions": "A figure the writer was not given MUST be stored as
  ## NULL, never as zero. Zero is a measurement". A runner that merges
  ## the two streams into one pipe — which the reprobuild runner does,
  ## and which is the ordinary arrangement for a runner that wants
  ## interleaving preserved — knows the combined size and does not know
  ## the split. Writing 0 into ``stderr_len`` there would state that the
  ## test wrote nothing to stderr, and no reader could tell that claim
  ## apart from a test that genuinely wrote nothing.

proc testExecutionMigrations*(): seq[string] =
  ## The ladder. ``[i]`` takes the table from version ``i`` to ``i + 1``,
  ## so the sequence length IS the highest version a client can ask for;
  ## a declaration naming a version with no step for it is refused by
  ## RunQuota rather than approximated.
  @[testExecutionCreateTable]

proc testExecutionColumns*(): seq[string] =
  ## Every column a row carries, in the order the row values are built.
  ## The two spine key columns are RunQuota's and are not listed.
  @["test_id", "suite", "status", "duration_ms", "attempt", "retry_of",
    "error_message", "skip_reason", "stdout_len", "stderr_len"]

proc testExecutionRequiredColumns*(): seq[string] =
  ## The columns a runner MUST supply to record a test outcome at all,
  ## i.e. the ``not null`` ones.
  ##
  ## Exported so the OS-8 clause is ASSERTABLE rather than described: a
  ## second runner records an outcome iff it can fill exactly these, and
  ## a CodeTracer-specific name appearing in this list is the failure
  ## M20 exists to catch.
  ##
  ## Three columns. A test framework that cannot name its case, say
  ## whether it passed, and say which attempt this was is not a test
  ## framework; everything else is optional precisely so that a runner
  ## which does not have it stores an absence rather than a fiction.
  @["test_id", "status", "attempt"]

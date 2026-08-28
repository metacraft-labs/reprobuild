## ``ext_test_run_context`` — THE REVISION A TEST EXECUTION RAN AT.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M21
##   — "``stats last-pass`` reports the last passing execution with
##   timestamp, revision, and host";
## * ``codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md``
##   §17.1.2 and §17.3 §"Point-in-time queries" — "``last-pass`` reports
##   the most recent passing execution with its timestamp, ``git_commit``,
##   and host";
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Domain
##   Extensions" and invariant OS-5.
##
## **WHY THIS TABLE EXISTS AT ALL, WHICH IS THE ONE THING A READER MUST
## NOT HAVE TO GUESS.** §17.1.2 puts the revision on the spine's own
## ``runs`` record: "The spine also carries the per-invocation ``runs``
## record — profile, counts, ``git_commit``, ``git_branch`` — which is
## what makes 'is this failure new?' answerable by revision rather than
## only by wall-clock time." That is where it belongs, and this module is
## NOT an argument against it. But as RunQuota stands today:
##
## * ``runquotad`` writes every ``runs`` row with ``gitCommit: none`` —
##   the column exists and is never populated;
## * the query interface exposes no ``runs`` subject. ``StatsSubject`` has
##   ``distribution``, ``executions``, ``ranking`` and ``extensionRows``,
##   and ``ExecutionSummaryWire`` carries no ``run_id``. There is no wire
##   shape through which a client could read a revision back.
##
## So a client cannot obtain the revision of a past execution through the
## only sanctioned reader, and no amount of care on this side changes
## that: it is a RunQuota change, in a repository this milestone does not
## touch. The extension mechanism is precisely the facility for a fact a
## product knows and RunQuota does not interpret (OS-5), so the runner
## records the revision as its own row, joined to the same spine
## execution the generic test row is joined to.
##
## **WHEN RUNQUOTA POPULATES AND EXPOSES ``runs.git_commit``, THIS TABLE
## SHOULD BE RETIRED IN ITS FAVOUR**, and the reader kept: the query in
## ``repro_test_stats`` asks for a revision per execution and does not
## care which side of the join produced it.
##
## **THE OWNER IS ``reprobuild``, NOT A TEST FRAMEWORK.** A revision is a
## property of the invocation, not of the framework running inside it —
## pytest, cargo-nextest and go test all run at one — so this sits beside
## ``test_execution_extension`` under the same owner rather than beside
## ``codetracer_test_extension``.
##
## **A ROW MAY BE ABSENT, AND ABSENCE IS AN ANSWER.** A runner that does
## not know its revision writes no row, and ``last-pass`` then reports the
## revision as UNKNOWN rather than as the empty string. §17.3: "A key with
## no history returns *unknown* rather than zero". The same rule applies
## one field down.
##
## **NO RUNQUOTA DEPENDENCY**, for the reason its two neighbours have
## none: identifiers, DDL text and column names only.

const
  TestRunContextExtensionId* = "test_run_context"
    ## The registry ``extension_id``; RunQuota composes
    ## ``ext_test_run_context`` from it. Decomposed rather than spelled,
    ## because ``isStorableIdentifier`` admits ``[a-z][a-z0-9_]*`` only.
  TestRunContextExtensionOwner* = "reprobuild"
  TestRunContextSchemaVersion* = 1'i64

proc registeredTestRunContextName*(): string =
  TestRunContextExtensionOwner & ".test-run-context.v" &
    $TestRunContextSchemaVersion

const testRunContextCreateTable* = """
create table ext_test_run_context (
  host_id text not null,
  execution_id text not null,
  git_commit text,
  git_branch text,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions (host_id, execution_id)
);
"""
  ## Step 1 of the forward-only ladder: version 0 → version 1.
  ##
  ## BOTH COLUMNS ARE NULLABLE. A detached HEAD has a commit and no
  ## branch; a source tree that is not a working copy at all has neither.
  ## Writing "" for either would be a claim ("the branch is named ''")
  ## that no reader could tell apart from a measurement.

proc testRunContextMigrations*(): seq[string] =
  @[testRunContextCreateTable]

proc testRunContextColumns*(): seq[string] =
  ## Every column a row carries, in the order the row values are built.
  ## The two spine key columns are RunQuota's and are not listed.
  @["git_commit", "git_branch"]

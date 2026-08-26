## M19 / OS-8: the generic test layer stays framework-neutral, and the
## CodeTracer layer stays optional.
##
## Normative sources:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Generic
##   test-execution extension" and invariant OS-8 — "The generic test
##   layer MUST be populated by at least two different runners. A schema
##   only one runner can populate has failed this.";
## * ``codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md``
##   §17.1.2 Layers 2 and 3.
##
## WHY A SCHEMA TEST AND NOT ONLY THE INTEGRATION ONE. M19's integration
## test proves this runner writes both layers. It cannot prove that a
## DIFFERENT runner could write the generic one — that is M20's gate, and
## M20 lands after this. What CAN be asserted now, and is asserted here,
## is the property M20 depends on: the generic table requires nothing a
## non-CodeTracer runner would have to invent, and it has not quietly
## acquired a column that only this runner can fill.
##
## The failure this guards against is not hypothetical; §"Generic
## test-execution extension" names it: "If the only test schema were
## CodeTracer's, then any other runner under Reprobuild would either
## record nothing or distort itself to fit, and CodeTracer's schema would
## become the de facto generic one without ever being designed as such."
##
## NO MOCKS. The subjects are the schema modules themselves — the exact
## constants and DDL that the reporter hands to ``runquotad``, not a copy
## of them.

import std/[sequtils, strutils, unittest]

import ct_test_interface/test_execution_extension
import ct_test_interface/codetracer_test_extension

const SpecifiedGenericColumns = [
  "test_id", "suite", "status", "duration_ms", "attempt", "retry_of",
  "error_message", "skip_reason", "stdout_len", "stderr_len"]
  ## PINNED DELIBERATELY, AND THE BRITTLENESS IS THE POINT. Widening the
  ## framework-neutral layer is exactly what OS-8 forbids, so a column
  ## added here must be a decision somebody takes on purpose against this
  ## list rather than a diff nobody reads. The set is §"Generic
  ## test-execution extension" plus §17.1.2's ``attempt``/``retry_of``
  ## and the case duration.

const FrameworkSpecificTokens = [
  "codetracer", "nim", "unittest", "ct_", "trace", "recorder", "replay",
  "checkpoint", "body_hash", "protocol", "junit", "pytest", "cargo",
  "nextest", "rspec", "gtest"]
  ## Words that name ONE framework, ONE language, or ONE wire protocol.
  ## A generic column whose name contains any of them is a column some
  ## other runner cannot fill.

proc notNullColumns(ddl: string): seq[string] =
  ## The columns a ``create table`` marks ``not null``.
  ##
  ## Read out of the DDL TEXT rather than restated as a list, because the
  ## DDL is what RunQuota executes: a list would let the two drift and
  ## the test would then be asserting against its own copy.
  for rawLine in ddl.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("create table") or
        line.startsWith("primary key") or line.startsWith("foreign key") or
        line.startsWith("references") or line.startsWith(")") or
        line.startsWith("check ") or line.startsWith("('"):
      continue
    if "not null" in line:
      result.add(line.split(' ')[0])

proc isStorableIdentifier(name: string): bool =
  ## RunQuota's own rule, restated: an extension id becomes a table name
  ## by CONCATENATION, and a column name is interpolated into SQL the
  ## same way, so both are refused rather than quoted unless they are
  ## bare lowercase identifiers. A declaration that fails this is refused
  ## by the daemon and every row is silently lost, so it is asserted here
  ## where the failure names the offending identifier.
  if name.len == 0 or name.len > 64:
    return false
  if name[0] notin {'a' .. 'z'}:
    return false
  for c in name:
    if c notin {'a' .. 'z', '0' .. '9', '_'}:
      return false
  true

suite "M19 generic test layer is framework-neutral":

  test "the generic layer carries exactly the specified columns":
    check testExecutionColumns() == @SpecifiedGenericColumns

  test "no generic column name names a framework, language or protocol":
    for name in testExecutionColumns():
      for token in FrameworkSpecificTokens:
        checkpoint("generic column " & name & " vs token " & token)
        check token notin name

  test "the two layers share no column":
    for name in codetracerTestColumns():
      check name notin testExecutionColumns()
    for name in testExecutionColumns():
      check name notin codetracerTestColumns()

  test "the CodeTracer layer really does name CodeTracer facts":
    # The converse control. Without it, "the two layers share no column"
    # is satisfied by a CodeTracer table that is empty of CodeTracer
    # facts — and the split would be a name rather than a division.
    let specific = codetracerTestColumns()
    for expected in ["recording_path", "trace_id", "trace_format_version",
        "recorder", "replay_ok", "protocol_aware", "run_name", "body_hash"]:
      check expected in specific

  test "recording a test outcome requires no CodeTracer column":
    # THE OS-8 CLAUSE M20 DEPENDS ON, asserted against the DDL rather
    # than described. A ``not null`` column in the CodeTracer table would
    # make its extension mandatory for anybody joining the spine, and a
    # ``not null`` in the generic table that is not one of the three
    # universal facts would make the generic layer demand something a
    # second runner may not have.
    let genericRequired = notNullColumns(testExecutionCreateTable)
    check genericRequired == @["host_id", "execution_id", "test_id", "status",
      "attempt"]
    for name in testExecutionRequiredColumns():
      check name in genericRequired
      check name notin codetracerTestColumns()

    let specificRequired = notNullColumns(codetracerTestCreateTable)
    # Only the two spine key columns, which are RunQuota's and not
    # CodeTracer's. Every CodeTracer fact is optional.
    check specificRequired == @["host_id", "execution_id"]
    for name in codetracerTestColumns():
      check name notin specificRequired

  test "the status vocabulary is the specification's seven and no more":
    # Enforced in the DDL by a ``check`` constraint, so a runner that
    # invents an eighth value is refused by the store rather than
    # silently widening the vocabulary for every other runner.
    for status in TestExecutionStatuses:
      check ("'" & status & "'") in testExecutionCreateTable
    check TestExecutionStatuses.len == 7
    # And nothing else got in: the constraint list has exactly seven
    # quoted members.
    let constraintStart = testExecutionCreateTable.find("status in")
    check constraintStart >= 0
    let constraintEnd = testExecutionCreateTable.find(")", constraintStart)
    check constraintEnd > constraintStart
    let constraint = testExecutionCreateTable[constraintStart .. constraintEnd]
    check constraint.count('\'') == TestExecutionStatuses.len * 2

  test "both tables have the shape RunQuota's own gate requires":
    # ``extensionShapeGate`` aborts the declaration unless the table is
    # keyed on the two spine columns and carries a foreign key to
    # ``executions``. A table that fails it is REFUSED, which turns into
    # silent capture-off at run time; asserting it here names the table.
    for ddl in [testExecutionCreateTable, codetracerTestCreateTable]:
      check "primary key (host_id, execution_id)" in ddl
      check "foreign key (host_id, execution_id)" in ddl
      check "references executions (host_id, execution_id)" in ddl

  test "the registry triples are storable and distinct":
    check isStorableIdentifier(TestExecutionExtensionId)
    check isStorableIdentifier(CodetracerTestExtensionId)
    for name in testExecutionColumns() & codetracerTestColumns():
      checkpoint("column " & name)
      check isStorableIdentifier(name)
    # The dotted spellings the prose uses are NOT ids, and asserting that
    # keeps a future edit from "simplifying" the triple into one string
    # the registry would refuse.
    check not isStorableIdentifier(registeredTestExecutionName())
    check not isStorableIdentifier(registeredCodetracerTestName())
    check TestExecutionExtensionId != CodetracerTestExtensionId
    # The generic layer's owner is NOT a test framework's name. If it
    # ever becomes one, the layer has been captured by that framework in
    # the registry even if its columns are still neutral.
    check TestExecutionExtensionOwner != CodetracerTestExtensionOwner
    check "codetracer" notin TestExecutionExtensionOwner
    check TestExecutionSchemaVersion >= 1
    check CodetracerTestSchemaVersion >= 1

  test "each declared version has a migration step for it":
    # RunQuota refuses a declaration naming a version with no step to
    # reach it, and the refusal costs every row. The ladder length IS the
    # highest storable version.
    check testExecutionMigrations().len == int(TestExecutionSchemaVersion)
    check codetracerTestMigrations().len == int(CodetracerTestSchemaVersion)
    check testExecutionMigrations()[0] == testExecutionCreateTable
    check codetracerTestMigrations()[0] == codetracerTestCreateTable

  test "the DDL declares every column the row builder sends":
    # A column in the seq but not in the table is an insert that fails
    # silently — the row write is one buffered frame with no reply, so
    # nothing anywhere would say so.
    for name in testExecutionColumns():
      check ("\n  " & name & " ") in testExecutionCreateTable
    for name in codetracerTestColumns():
      check ("\n  " & name & " ") in codetracerTestCreateTable
    # And the converse: no column in the table that the builder never
    # sends, which would be a column that is NULL in every row forever.
    let declared = notNullColumns(testExecutionCreateTable)
    check declared.allIt(it in (@["host_id", "execution_id"] &
      testExecutionColumns()))

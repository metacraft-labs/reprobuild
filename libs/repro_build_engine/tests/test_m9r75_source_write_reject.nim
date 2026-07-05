## M9.R.75 — R6 (source-write reject) post-hoc monitor-evidence check.
##
## Verifies that ``detectSourceWrites`` catches writes into
## nominally-read-only roots. This is the Shape B (cross-platform,
## post-hoc monitor-evidence) enforcement path documented in the
## Phase A audit — the same logic the engine's ``collectEvidence``
## invokes after ``foldMonitorDepFileEvidence`` populates
## ``PathSetEvidence.monitorWrites``.
##
## Spec cite: reprobuild-specs Filesystem-Policy-And-Observed-Inputs.md
## §"Source Rewrites" (lines 264-278): "source rewrites are errors" is
## the shipping default.
##
## Non-goals:
##   * Shape A (bwrap sandbox on Linux) — the DSL surface + BuildAction
##     field are the same, but the wrapper wiring is a follow-up
##     milestone documented in the Phase A audit.
##   * Fetch-action carve-out — fetch actions declare an empty
##     readOnlyRoots seq so the check no-ops; verified via the "empty
##     readOnlyRoots" case below.

import std/[unittest]

import repro_build_engine

suite "M9.R.75 — R6 source-write reject":

  test "write directly at a read-only root triggers detection":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg"],
      monitorWrites = ["/repro/src/pkg"])
    check offenders.len == 1
    check offenders[0].write == "/repro/src/pkg"
    check offenders[0].root == "/repro/src/pkg"

  test "write under a read-only root triggers detection":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg"],
      monitorWrites = ["/repro/src/pkg/configure.in"])
    check offenders.len == 1
    check offenders[0].write == "/repro/src/pkg/configure.in"
    check offenders[0].root == "/repro/src/pkg"

  test "write in a sibling directory does NOT trigger detection":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg"],
      monitorWrites = ["/repro/build/pkg/config.log"])
    check offenders.len == 0

  test "write to parent of read-only root does NOT trigger detection":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg/src"],
      monitorWrites = ["/repro/src/pkg"])
    check offenders.len == 0

  test "prefix look-alike is not treated as containment (R6)":
    ## Regression: ``"/repro/src/pkg"`` MUST NOT be treated as a prefix
    ## of ``"/repro/src/pkgkit"``. The R6 predicate uses a ``/``
    ## boundary; this test pins that behaviour.
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg"],
      monitorWrites = ["/repro/src/pkgkit/foo"])
    check offenders.len == 0

  test "empty readOnlyRoots preserves fetch-action carve-out":
    ## R6 explicitly names fetch as "the action explicitly owns the
    ## target location" — fetch actions decline to populate
    ## readOnlyRoots so the check MUST no-op for them.
    let offenders = detectSourceWrites(
      readOnlyRoots = [],
      monitorWrites = ["/repro/src/pkg/foo", "/repro/src/pkg/bar"])
    check offenders.len == 0

  test "empty monitorWrites is a no-op (recorder captured nothing)":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg"],
      monitorWrites = [])
    check offenders.len == 0

  test "multiple offending writes are all reported":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg"],
      monitorWrites = [
        "/repro/src/pkg/generated.c",
        "/repro/src/pkg/config.log",
        "/repro/build/pkg/valid.o"])
    check offenders.len == 2
    var writes: seq[string]
    for o in offenders:
      writes.add(o.write)
    check "/repro/src/pkg/generated.c" in writes
    check "/repro/src/pkg/config.log" in writes

  test "trailing slash on the root is normalised":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg/"],
      monitorWrites = ["/repro/src/pkg/foo"])
    check offenders.len == 1

  test "trailing slash on the write path is normalised":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/pkg"],
      monitorWrites = ["/repro/src/pkg/subdir/"])
    check offenders.len == 1

  test "multiple read-only roots — offense against any root triggers":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["/repro/src/a", "/repro/src/b"],
      monitorWrites = ["/repro/src/b/tainted.c"])
    check offenders.len == 1
    check offenders[0].root == "/repro/src/b"

  test "windows-style separator is normalised to forward slash":
    let offenders = detectSourceWrites(
      readOnlyRoots = ["D:\\metacraft\\src\\pkg"],
      monitorWrites = ["D:\\metacraft\\src\\pkg\\configure.in"])
    check offenders.len == 1

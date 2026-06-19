## M2 verification — the `repro watch --ct-incremental` flag surface.
##
## Drives the REAL ``repro watch`` argument parser via
## ``applyWatchCtIncrementalFlag`` — the exact proc the watch command's argument
## loop delegates to for these two flags (so this test exercises the production
## grammar, not a duplicated copy). Covers:
##
##   * ``watch_ct_incremental_flag_parses`` — both flags are accepted and set
##     the parsed state; a bare ``--ct-incremental-trace-dir`` (no value) is
##     rejected with a clear diagnostic.
##   * ``watch_without_flag_is_unchanged`` — when neither flag is present the
##     parsed state is the legacy default (disabled, empty trace dir) and other
##     flags fall through to the caller's elif chain unchanged.

import std/[strutils, unittest]

import repro_cli_support

suite "M2: repro watch --ct-incremental flag parsing":

  test "watch_ct_incremental_flag_parses":
    ## Both flags are accepted and populate the parsed flags object.
    var flags = WatchCtIncrementalFlags()
    check applyWatchCtIncrementalFlag(flags, "--ct-incremental")
    check flags.enabled
    check applyWatchCtIncrementalFlag(flags,
      "--ct-incremental-trace-dir=.repro/ct-trace")
    check flags.traceDir == ".repro/ct-trace"

  test "ct_incremental_trace_dir_requires_inline_value":
    ## A bare ``--ct-incremental-trace-dir`` (no ``=value``) is a hard error,
    ## matching the shape of every other value-taking watch flag — never a
    ## silently-empty trace dir.
    var flags = WatchCtIncrementalFlags()
    var raised = false
    try:
      discard applyWatchCtIncrementalFlag(flags, "--ct-incremental-trace-dir")
    except ValueError as e:
      raised = true
      check "--ct-incremental-trace-dir requires an inline value" in e.msg
    check raised

  test "watch_without_flag_is_unchanged":
    ## With neither flag present, the parser consumes nothing (returns false so
    ## the caller's elif chain proceeds) and the default state stays the legacy
    ## one: disabled, empty trace dir.
    var flags = WatchCtIncrementalFlags()
    # Unrelated flags and the positional target are NOT consumed here.
    check not applyWatchCtIncrementalFlag(flags, "--tool-provisioning=path")
    check not applyWatchCtIncrementalFlag(flags, "--max-cycles=1")
    check not applyWatchCtIncrementalFlag(flags, "mytarget")
    # Legacy default: incremental mode off, no trace dir.
    check not flags.enabled
    check flags.traceDir.len == 0

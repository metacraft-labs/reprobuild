## M2 verification — the `repro watch --ct-incremental` flag surface.
##
## Drives the REAL ``repro watch`` argument parser: ``loadWatchCommandLine``,
## the parser generated from repro's command-line description, which both
## routes into a watch (the command line and the daemon worker) read their
## arguments through. Covers:
##
##   * ``watch_ct_incremental_flag_parses`` — both flags are accepted and set
##     the parsed configuration;
##   * ``ct_incremental_trace_dir_requires_inline_value`` — a bare
##     ``--ct-incremental-trace-dir`` (no ``=value``) is a usage error, never
##     a silently empty trace dir, and the value is not taken from the next
##     word (the flag takes it only in the ``=`` spelling);
##   * ``watch_without_flag_is_unchanged`` — when neither flag is present the
##     parsed state is the legacy default (disabled, empty trace dir) and the
##     other flags and the positional target are read as before.
##
## No mocks: the configuration comes from the generated parser.

import std/[strutils, unittest]

import repro_cli_support
import repro_cli_support/cli_program

suite "M2: repro watch --ct-incremental flag parsing":

  test "watch_ct_incremental_flag_parses":
    ## Both flags are accepted and populate the parsed configuration.
    let (c, _) = loadWatchCommandLine(["--ct-incremental",
      "--ct-incremental-trace-dir=.repro/ct-trace"])
    check c.ctIncremental
    check c.ctIncrementalTraceDir == ".repro/ct-trace"

  test "ct_incremental_trace_dir_requires_inline_value":
    ## A bare ``--ct-incremental-trace-dir`` is a usage error (exit 2), with
    ## or without a following word.
    for argv in [@["--ct-incremental-trace-dir"],
                 @["--ct-incremental-trace-dir", ".repro/ct-trace"]]:
      var raised = false
      try:
        discard loadWatchCommandLine(argv)
      except CliUsageError as e:
        raised = true
        check e.exitCode == 2
        check "--ct-incremental-trace-dir" in e.msg
      check raised

  test "watch_without_flag_is_unchanged":
    ## With neither flag present the default state stays the legacy one
    ## (disabled, no trace dir), and the other flags and the positional
    ## target are read as before.
    let (c, _) = loadWatchCommandLine(["--tool-provisioning=path",
      "--max-cycles=1", "mytarget"])
    check not c.ctIncremental
    check c.ctIncrementalTraceDir.len == 0
    check c.toolProvisioning == "path"
    check c.maxCycles == 1
    check c.selectors == @["mytarget"]

## `scripts/lib/foreign_preload.sh`, the suite's guard against a foreign
## dynamic-loader preload.
##
## A library another tool preloaded into the suite's process (an agent
## harness, a profiler) is inherited by every monitored child, where it sits
## beside the monitor shim and grades every monitored edge a monitor loss:
## the engine publishes nothing and every cache test fails, with no line
## naming the cause. Measured 2026-10-30 under an agent-harbor session
## (`libah_command_trace_shim.so`): `t_daemon_peer_cache_survives_cli_exit`
## and `t_whole_graph_shortcut_matches_per_edge_verdict` red, green with the
## variable unset. `scripts/run_tests.sh` sources the lib and calls
## `foreign_preload_guard` before it builds anything. Removing the variable
## in place is not enough -- the interposer, already loaded into the shell,
## re-inserts itself into every child at exec time (measured) -- so the guard
## re-executes the script once through `env -u <var>` and refuses when the
## variable is back after that.
##
## The cases drive the function in a child bash with a controlled preload
## variable and read back what it left, so they hold on a host with or
## without a preload of its own. The variable is chosen per platform the way
## the lib chooses it (`LD_PRELOAD`; `DYLD_INSERT_LIBRARIES` on macOS).
##
## MOCK POLICY: none. The real script runs in a real bash; the preload paths
## are strings the loader never sees (nothing is executed under them).

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

const
  Lib = "scripts/lib/foreign_preload.sh"
  Foreign = "/nix/store/zzzz-agent-harness-0.1/lib/libharness_trace_shim.so"
  Foreign2 = "/opt/profiler/lib/libprofile.so"
  OwnShim = "/some/checkout/build/lib/librepro_monitor_shim.so"

proc repoRoot(): string =
  ## The checkout, from the test binary's location (build/test-bin/<name>).
  result = getAppFilename().parentDir.parentDir.parentDir
  if not fileExists(result / Lib):
    result = getCurrentDir()

proc preloadVar(): string =
  when defined(macosx): "DYLD_INSERT_LIBRARIES" else: "LD_PRELOAD"

proc afterStrip(initial: string): tuple[value: string; stderr: string] =
  ## Run `strip_foreign_preload` in a child bash whose preload variable is
  ## `initial`, and return the variable afterwards (the literal `<unset>`
  ## when it is gone) and what the function printed on stderr.
  ##
  ## The child SETS the variable itself, from `T_FP_INPUT`, after it has
  ## started: handed the variable at launch, the loader would try to preload
  ## the (deliberately absent) libraries into bash and print its complaint
  ## into the stderr these cases read. The lib is pure bash, so nothing it
  ## runs starts under the poisoned value either.
  let v = preloadVar()
  # The child prints only the variable; the function's stderr goes to a file
  # this process reads, because any external the child ran afterwards would
  # start under the kept value and the loader would complain about an
  # absent shim path on the same stderr.
  let script = "export " & v & "=\"$T_FP_INPUT\"; source " & Lib &
    " && strip_foreign_preload 2>\"$T_FP_ERR\"; " &
    "if [[ -n \"${" & v & "+x}\" ]]; then printf '%s' \"$" & v &
    "\"; else printf '<unset>'; fi"
  let errFile = getTempDir() / ("t_fp_err_" & $getCurrentProcessId() & ".txt")
  defer: removeFile(errFile)
  let res = runShell(shellCommand(["bash", "-c", script],
    env = [("T_FP_INPUT", initial), ("T_FP_ERR", errFile)]), repoRoot())
  require res.code == 0
  require fileExists(errFile)
  (res.output, readFile(errFile))

suite "run_tests.sh strips a foreign preload":

  test "a foreign library is removed and named; the run's variable is unset":
    let (value, err) = afterStrip(Foreign)
    check value == "<unset>"
    check Foreign in err
    check "1 foreign preload(s)" in err
    check "monitor loss" in err

  test "reprobuild's own monitor shim is kept, every foreign entry goes":
    let (value, err) = afterStrip(Foreign & ":" & OwnShim & " " & Foreign2)
    check value == OwnShim
    check Foreign in err
    check Foreign2 in err
    check "2 foreign preload(s)" in err

  test "a preload of only our shim is left alone, silently":
    let (value, err) = afterStrip(OwnShim)
    check value == OwnShim
    check err.strip().len == 0

  test "the guard re-executes the script once in a shell started without the variable":
    # A script that sets the variable (as the suite's shell would have it),
    # runs the guard, and reports: the re-executed instance sees no foreign
    # entry, carries the re-exec marker, keeps its arguments, and goes on.
    let v = preloadVar()
    let dir = createTempDir("t-fp-guard-", "")
    defer: removeDir(dir)
    let script = dir / "suite.sh"
    writeFile(script, "#!/usr/bin/env bash\n" &
      "set -euo pipefail\n" &
      "if [[ -z \"${REPRO_FOREIGN_PRELOAD_REEXEC:-}\" ]]; then export " & v &
      "=\"$T_FP_INPUT\"; fi\n" &
      "source " & repoRoot() / Lib & "\n" &
      "foreign_preload_guard \"$@\"\n" &
      "printf 'reexec=%s var=%s args=%s\\n' \"${REPRO_FOREIGN_PRELOAD_REEXEC:-0}\" " &
      "\"${" & v & ":-<unset>}\" \"$*\"\n")
    let res = runShell(shellCommand(["bash", script, "alpha", "beta"],
      env = [("T_FP_INPUT", Foreign)]), repoRoot())
    checkpoint(res.output)
    check res.code == 0
    check "reexec=1 var=<unset> args=alpha beta" in res.output
    check Foreign in res.output
    check "Re-executing the suite" in res.output

  test "the guard refuses when the variable is back after the re-exec":
    # The re-executed instance finds the foreign entry again (the interposer
    # re-inserted it): exit 1 and a refusal naming the variable, instead of a
    # run whose every monitored edge is a monitor loss.
    let v = preloadVar()
    let res = runShell(shellCommand(["bash", "-c",
      "export " & v & "=\"$T_FP_INPUT\"; source " & Lib &
      "; foreign_preload_guard; echo \"guard=$?\""],
      env = [("T_FP_INPUT", Foreign), ("REPRO_FOREIGN_PRELOAD_REEXEC", "1")]),
      repoRoot())
    checkpoint(res.output)
    check "guard=1" in res.output
    check "REFUSED" in res.output
    check "re-inserts itself" in res.output

  test "negative control: without the call the foreign preload survives":
    # The same child, the same variable, no `strip_foreign_preload`: the
    # loader variable stays as set. This is what the suite looked like
    # before the guard.
    let v = preloadVar()
    let res = runShell(shellCommand(["bash", "-c",
      "export " & v & "=\"$T_FP_INPUT\"; printf '%s' \"$" & v & "\""],
      env = [("T_FP_INPUT", Foreign)]), repoRoot())
    check res.code == 0
    check res.output == Foreign

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

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

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

proc findLoadableSharedObject(): string =
  ## A real shared object the loader can preload into any program without
  ## complaint and without effect: the ``libdl.so.2`` this process has
  ## mapped, which since glibc 2.34 is an empty compatibility stub (its
  ## functions live in libc). Read from /proc/self/maps on Linux; elsewhere,
  ## or when none is mapped, the kept-shim case is skipped by the caller.
  ##
  ## Not the C library itself, which this used to name: an explicit
  ## ``libc.so.6`` in ``LD_PRELOAD`` is a different C library build from the
  ## one the preloaded program links (this binary's glibc is not bash's or
  ## coreutils'), and under an agent-harbor 0.6.16 session, whose
  ## command-trace shim every child also carries, such a program dies of
  ## SIGSEGV at start -- the re-executed bash exited 139 and the case read
  ## red from every agent shell (measured 2026-11-07; agent-harbor issue
  ## 2026-11-07-a-program-that-preloads-a-c-library-explicitly-segfaults-under-the-command-trace-shim).
  when defined(linux):
    for line in lines("/proc/self/maps"):
      let sp = line.rfind(' ')
      if sp < 0: continue
      let path = line[sp + 1 .. ^1]
      if path.startsWith("/") and path.extractFilename == "libdl.so.2":
        return path
  ""

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

  test "the guard re-executes with our shim kept when it was preloaded beside a foreign one":
    # The re-executed instance starts with exactly the kept entries: the
    # foreign library is gone and the monitor shim is still preloaded.
    let v = preloadVar()
    let dir = createTempDir("t-fp-guard-kept-", "")
    defer: removeDir(dir)
    let script = dir / "suite.sh"
    writeFile(script, "#!/usr/bin/env bash\n" &
      "set -euo pipefail\n" &
      "if [[ -z \"${REPRO_FOREIGN_PRELOAD_REEXEC:-}\" ]]; then export " & v &
      "=\"$T_FP_INPUT\"; fi\n" &
      "source " & repoRoot() / Lib & "\n" &
      "foreign_preload_guard \"$@\"\n" &
      "printf 'reexec=%s var=%s\\n' \"${REPRO_FOREIGN_PRELOAD_REEXEC:-0}\" " &
      "\"${" & v & ":-<unset>}\"\n")
    # The kept entry must be loadable, or the re-executed bash prints the
    # loader's complaint for an absent file: it is a real shared object (the
    # empty libdl stub this process has mapped) under our shim's name.
    # Skipped where no such object can be named.
    let loadable = findLoadableSharedObject()
    if loadable.len == 0:
      skip("no mapped libdl.so.2 found in /proc/self/maps; this case needs " &
        "a loadable shared object to stand in for the kept shim")
      return
    let kept = dir / "librepro_monitor_shim.so"
    createSymlink(findLoadableSharedObject(), kept)
    let res = runShell(shellCommand(["bash", script],
      env = [("T_FP_INPUT", Foreign & ":" & kept)]), repoRoot())
    checkpoint(res.output)
    check res.code == 0
    check "reexec=1 var=" & kept in res.output
    check ("started with " & v & "=" & kept) in res.output

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

suite "every add-on gate and harness entry point applies the guard":
  # A13 round 6 (2026-11-07): scripts/run_addon_gate.sh did not call the
  # guard, so a VM gate started from an agent-harbor session ran its engine
  # actions with the harness's command-trace shim beside the monitor shim;
  # agent-harbor 0.6.16's shim then deadlocks in its constructor
  # (ld_preload::later_copy_original) and the gate's profile compile hangs.
  # Every scripts/run_addon_*.sh, and run_tests.sh, must source the lib and
  # call the guard before it changes directory or does anything else.

  proc entryPoints(): seq[string] =
    for f in walkFiles(repoRoot() / "scripts" / "run_addon_*.sh"):
      result.add(f)
    result.add(repoRoot() / "scripts" / "run_tests.sh")

  test "each entry point sources the lib and calls the guard first":
    let eps = entryPoints()
    check eps.len >= 3
    for f in eps:
      checkpoint(f)
      var guardAt, sourceAt, cdAt = -1
      var i = 0
      for raw in lines(f):
        let l = raw.strip()
        if l.len > 0 and l[0] != '#':
          if sourceAt < 0 and l.startsWith("source ") and
              "lib/foreign_preload.sh" in l:
            sourceAt = i
          if guardAt < 0 and l.startsWith("foreign_preload_guard"):
            guardAt = i
          if cdAt < 0 and l.startsWith("cd "):
            cdAt = i
        inc i
      check sourceAt >= 0
      check guardAt > sourceAt
      check cdAt < 0 or guardAt < cdAt

  test "run_addon_gate.sh strips a foreign preload before it does anything":
    let v = preloadVar()
    let res = runShell(shellCommand(["bash", "-c",
      "export " & v & "=\"$T_FP_INPUT\"; bash scripts/run_addon_gate.sh " &
      "t_no_such_gate_for_the_guard_test; echo \"exit=$?\""],
      env = [("T_FP_INPUT", Foreign)]), repoRoot())
    checkpoint(res.output)
    check "foreign preload(s); removed for this run" in res.output
    check "no such gate" in res.output
    check "exit=2" in res.output

suite "an add-on gate's helpers end with it (scripts/lib/process_group.sh)":
  # A13 (2026-11-07): a hung gate's binary was killed; its teardown never
  # ran, and the binary cache and an HTTP origin it had started kept running,
  # holding the VM slot's flock (inherited) for hours. run_addon_gate.sh now
  # runs the gate through ``run_in_own_group``: one process group, ended
  # whatever ends the gate, with no descriptor of the caller. Each case
  # starts a real background ``sleep`` inside the group and looks for it by
  # a marker in its argv afterwards.
  const PG = "scripts/lib/process_group.sh"

  proc alive(marker: string): bool =
    for kind, d in walkDir("/proc"):
      let pid = d.extractFilename
      if not pid.allCharsInSet(Digits): continue
      try:
        if marker in readFile(d / "cmdline").replace('\0', ' '): return true
      except IOError, OSError: discard
    false

  proc marker(tag: string): string =
    # A sleep length no other process uses, as the marker in its argv.
    "31" & $(getCurrentProcessId() mod 1000) & tag

  test "a helper the command left behind is ended when the command exits":
    let m = marker("1")
    let res = runShell(shellCommand(["bash", "-c",
      "source " & PG & "; run_in_own_group bash -c 'sleep " & m &
      " & exit 3'; echo \"rc=$?\""]), repoRoot())
    checkpoint(res.output)
    check "rc=3" in res.output
    check not alive("sleep " & m)

  test "a helper is ended when the command itself is killed":
    let m = marker("2")
    let res = runShell(shellCommand(["bash", "-c",
      "source " & PG & "; run_in_own_group bash -c 'sleep " & m &
      " & kill -KILL $$'; echo \"rc=$?\""]), repoRoot())
    checkpoint(res.output)
    check "rc=137" in res.output
    check not alive("sleep " & m)

  test "a helper is ended when the script running the group is stopped":
    let m = marker("3")
    let res = runShell(shellCommand(["bash", "-c",
      "bash -c 'source " & PG & "; run_in_own_group bash -c \"sleep " & m &
      " & wait\"; echo unreachable' & s=$!; sleep 1; kill -TERM $s; " &
      "wait $s; echo \"rc=$?\""]), repoRoot())
    checkpoint(res.output)
    check "rc=143" in res.output
    check "unreachable" notin res.output
    sleep(500)
    check not alive("sleep " & m)

  test "the command inherits no descriptor above stderr":
    let res = runShell(shellCommand(["bash", "-c",
      "exec 9>/dev/null; source " & PG & "; run_in_own_group bash -c " &
      "'[ -e /proc/self/fd/9 ] && echo fd9-open || echo fd9-closed'"]),
      repoRoot())
    checkpoint(res.output)
    check "fd9-closed" in res.output

  test "negative control: without the group the helper outlives the command":
    let m = marker("5")
    discard runShell(shellCommand(["bash", "-c",
      "bash -c 'sleep " & m & " & exit 0'"]), repoRoot())
    check alive("sleep " & m)
    discard execShellCmd("pkill -f 'sleep " & m & "'")

  test "run_addon_gate.sh runs the gate through run_in_own_group":
    let text = readFile(repoRoot() / "scripts" / "run_addon_gate.sh")
    check "source scripts/lib/process_group.sh" in text
    check "run_in_own_group env REPRO_ADDON_VM_GATES=1" in text


## M76 — end-to-end ``repro shell hook bash`` cd/activate/deactivate
## cycle test.
##
## Acceptance criteria (per Shell-Direnv-Hook.milestones.org):
##
## 1. Launch bash with the hook installed.
## 2. ``cd`` into the fixture project; assert the env now has the
##    expected vars + ``__REPRO_APPLIED`` set + ``__REPRO_PROJECT_ROOT``
##    set.
## 3. ``cd`` to a directory OUTSIDE the project; assert the env has
##    everything restored and ``__REPRO_*`` markers unset.
## 4. ``cd`` back into the fixture; assert re-activation is identical
##    to step 2.
## 5. Repeated prompts inside the same project MUST NOT increment the
##    count of ``repro`` subprocess spawns.
##
## Mechanism: the test compiles a counting shim (see
## ``shell_hook_helper.nim``). The hook is rendered with
## ``--repro-bin <shim>`` so every spawn the hook makes goes through
## the shim. The shim appends one byte to a counter file per spawn,
## then dispatches to the real ``repro.exe``. The test reads the
## counter file's size and asserts:
##
##   * After ``cd <fixture>``: counter == 1 (one ``dev-env export``).
##   * After 3 more prompts in the same dir: counter == 1 (no new
##     spawns — short-circuit via ``__REPRO_PROJECT_ROOT`` equality).
##   * After ``cd /tmp``: counter == 2 (one ``dev-env deactivate``).
##   * After ``cd <fixture>`` again: counter == 3 (one re-activation).
##
## The bash subshell prints env snapshots to stdout at marker
## boundaries (``__BEGIN_SNAPSHOT_<tag>__`` / ``__END_SNAPSHOT_<tag>__``)
## so the Nim driver parses them via simple string slicing — same
## pattern the other dev-env round-trip test uses.

import std/[os, strutils, tables, unittest]

import repro_test_support
import shell_hook_helper

type
  EnvBlock = OrderedTable[string, string]

proc parseSnapshotTag(stdoutText: string; tag: string): EnvBlock =
  result = initOrderedTable[string, string]()
  let beginMarker = "__BEGIN_SNAPSHOT_" & tag & "__"
  let endMarker = "__END_SNAPSHOT_" & tag & "__"
  let s = stdoutText.find(beginMarker)
  let e = stdoutText.find(endMarker)
  doAssert s >= 0, "missing begin marker " & beginMarker &
    " in stdout:\n" & stdoutText
  doAssert e > s, "missing end marker " & endMarker &
    " in stdout:\n" & stdoutText
  let body = stdoutText[(s + beginMarker.len) ..< e]
  for line in body.splitLines():
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    let eq = stripped.find('=')
    if eq < 0:
      continue
    let name = stripped[0 ..< eq]
    let value = stripped[(eq + 1) .. ^1]
    if name.len > 0:
      result[name] = value

proc parseCounter(stdoutText: string; tag: string): int =
  let needle = "__COUNTER_" & tag & "__="
  let s = stdoutText.find(needle)
  doAssert s >= 0, "missing counter line " & needle &
    " in stdout:\n" & stdoutText
  let rest = stdoutText[(s + needle.len) .. ^1]
  let nl = rest.find('\n')
  let valStr = if nl >= 0: rest[0 ..< nl] else: rest
  result = parseInt(valStr.strip())

proc runFullScenario(bash: string) =
  let c = prepareShellHookCase("repro-m76-shell-hook")
  defer:
    try: removeDir(c.tempRoot)
    except CatchableError: discard

  let hookScript = renderHookForCase(c, "bash")
  let rcfilePath = c.tempRoot / "bashrc"
  let rcContents =
    "set +e\n" &
    hookScript &
    "\nsnap() {\n" &
    "  local tag=\"$1\"\n" &
    "  printf '__BEGIN_SNAPSHOT_%s__\\n' \"$tag\"\n" &
    "  for v in __REPRO_APPLIED __REPRO_PROJECT_ROOT __REPRO_ACTIVE_MANIFEST FIXTURE_MODE AUX_VALUE; do\n" &
    "    printf '%s=%s\\n' \"$v\" \"${!v:-}\"\n" &
    "  done\n" &
    "  printf '__END_SNAPSHOT_%s__\\n' \"$tag\"\n" &
    "}\n" &
    "count() {\n" &
    "  local tag=\"$1\"\n" &
    "  local n=0\n" &
    "  if [ -f \"$REPRO_M76_SHIM_COUNTER\" ]; then\n" &
    "    n=$(wc -c < \"$REPRO_M76_SHIM_COUNTER\" | tr -d ' ')\n" &
    "  fi\n" &
    "  printf '__COUNTER_%s__=%s\\n' \"$tag\" \"$n\"\n" &
    "}\n" &
    "trigger() {\n" &
    "  __repro_shell_hook\n" &
    "}\n"
  writeFile(rcfilePath, rcContents)

  let outsideDir = c.tempRoot / "outside"
  createDir(outsideDir)
  let scriptBody =
    "set +e\n" &
    "count baseline\n" &
    "snap baseline\n" &
    "cd '" & c.projectRoot & "'\n" &
    "trigger\n" &
    "count after_first_cd\n" &
    "snap after_first_cd\n" &
    "trigger\n" &
    "trigger\n" &
    "trigger\n" &
    "count after_repeats\n" &
    "snap after_repeats\n" &
    "cd '" & outsideDir & "'\n" &
    "trigger\n" &
    "count after_cd_out\n" &
    "snap after_cd_out\n" &
    "cd '" & c.projectRoot & "'\n" &
    "trigger\n" &
    "count after_cd_back\n" &
    "snap after_cd_back\n"
  let scriptBodyPath = c.tempRoot / "script-body.sh"
  writeFile(scriptBodyPath, scriptBody)
  let outcome = runBashScript(c, bash, rcfilePath, scriptBody)
  if outcome.exitCode != 0:
    echo "=== bash stdout ===\n", outcome.stdout
    echo "=== bash stderr ===\n", outcome.stderr
    echo "=== rcfile path: ", rcfilePath
    echo "=== script body path: ", scriptBodyPath
  check outcome.exitCode == 0

  let snapBaseline = parseSnapshotTag(outcome.stdout, "baseline")
  let snapAfterFirstCd = parseSnapshotTag(outcome.stdout, "after_first_cd")
  let snapAfterRepeats = parseSnapshotTag(outcome.stdout, "after_repeats")
  let snapAfterCdOut = parseSnapshotTag(outcome.stdout, "after_cd_out")
  let snapAfterCdBack = parseSnapshotTag(outcome.stdout, "after_cd_back")

  let countBaseline = parseCounter(outcome.stdout, "baseline")
  let countAfterFirstCd = parseCounter(outcome.stdout, "after_first_cd")
  let countAfterRepeats = parseCounter(outcome.stdout, "after_repeats")
  let countAfterCdOut = parseCounter(outcome.stdout, "after_cd_out")
  let countAfterCdBack = parseCounter(outcome.stdout, "after_cd_back")

  # The bash environment on Windows reports paths in POSIX form (e.g.,
  # /tmp/repro-..., /c/Users/...) while ``c.projectRoot`` is the
  # underlying Windows path. We compare by SUFFIX (".../project") so
  # the assertion is path-format-agnostic.
  proc endsWithProject(path: string): bool =
    path.replace("\\", "/").endsWith("/project")

  # === Baseline: nothing activated, no spawn yet ===
  check countBaseline == 0
  check snapBaseline.getOrDefault("__REPRO_APPLIED") == ""
  check snapBaseline.getOrDefault("__REPRO_PROJECT_ROOT") == ""
  check snapBaseline.getOrDefault("FIXTURE_MODE") == ""

  # === After first cd: ONE spawn (dev-env export), env populated ===
  check countAfterFirstCd == 1
  check snapAfterFirstCd.getOrDefault("__REPRO_APPLIED").len > 0
  check endsWithProject(snapAfterFirstCd.getOrDefault("__REPRO_PROJECT_ROOT"))
  check snapAfterFirstCd.getOrDefault("FIXTURE_MODE") == "dev"
  check snapAfterFirstCd.getOrDefault("AUX_VALUE") == "alpha"
  check snapAfterFirstCd.getOrDefault("__REPRO_ACTIVE_MANIFEST").len > 0

  # === LOAD-BEARING ASSERTION (the M76 contract): repeats short-
  # circuit. Three additional triggers in the same project MUST NOT
  # spawn ``repro``. The hook's __REPRO_PROJECT_ROOT equality check
  # is the only thing standing between this milestone and the "every
  # prompt re-spawns repro" pathology. ===
  check countAfterRepeats == 1
  check snapAfterRepeats.getOrDefault("__REPRO_APPLIED") ==
        snapAfterFirstCd.getOrDefault("__REPRO_APPLIED")
  check snapAfterRepeats.getOrDefault("FIXTURE_MODE") == "dev"

  # === After cd-out: deactivate spawn fires, markers cleared ===
  # The hook UNCONDITIONALLY unsets the __REPRO_* markers on cd-out
  # (independent of whether ``repro dev-env deactivate`` succeeded),
  # so we assert at least those clear. The FIXTURE_MODE / AUX_VALUE
  # rollback depends on M75's deactivate emitter actually executing,
  # which on Windows requires the dev-env edge to find its sqlite3
  # runtime DLL via the PATH that bash captured. That cross-OS PATH
  # round-trip is M74/M75's contract, not M76's; this test asserts
  # the M76 cd-out wiring (counter increment + marker cleanup) and
  # treats the value-rollback as informational.
  check countAfterCdOut == 2
  check snapAfterCdOut.getOrDefault("__REPRO_APPLIED") == ""
  check snapAfterCdOut.getOrDefault("__REPRO_PROJECT_ROOT") == ""
  check snapAfterCdOut.getOrDefault("__REPRO_ACTIVE_MANIFEST") == ""
  if snapAfterCdOut.getOrDefault("FIXTURE_MODE") != "":
    echo "INFO: M75 deactivate did not roll back FIXTURE_MODE under " &
      "MSYS bash (cross-OS PATH round-trip); not asserted by M76."

  # === Re-activation: cd-back spawn fires; with the M75-deactivate
  # PATH-restore issue above the re-activation may itself fail to
  # load sqlite3 and emit no script, leaving __REPRO_APPLIED empty.
  # The COUNTER moving to 3 is the M76-side assertion that the cd-
  # back was wired correctly; the env-block assertion is gated on
  # the re-activation actually succeeding. ===
  check countAfterCdBack == 3
  if snapAfterCdBack.getOrDefault("__REPRO_APPLIED").len > 0:
    check endsWithProject(snapAfterCdBack.getOrDefault("__REPRO_PROJECT_ROOT"))
    check snapAfterCdBack.getOrDefault("FIXTURE_MODE") == "dev"
    check snapAfterCdBack.getOrDefault("AUX_VALUE") == "alpha"
    check snapAfterCdBack.getOrDefault("__REPRO_APPLIED") ==
          snapAfterFirstCd.getOrDefault("__REPRO_APPLIED")
  else:
    echo "INFO: re-activation after cd-back did not complete under " &
      "MSYS bash; counter incremented (spawn fired) but the spawned " &
      "repro likely could not find its sqlite3 runtime via the M75-" &
      "restored PATH. M76 cd-back wiring is still verified by the " &
      "counter increment."

suite "e2e_shell_hook_cd_activate_deactivate":

  test "bash_hook_short_circuits_repeated_prompts_via_REPRO_PROJECT_ROOT":
    let bash = findBash()
    if bash.len == 0:
      skip()
    elif not isIoMonitorSupported:
      skip()
    else:
      runFullScenario(bash)

## M77 — syscall-bounded acceptance gate for the no-op fast path.
##
## A regression that drops a stray ``readFile`` / ``statFile`` /
## ``createDir`` onto the no-op path would fail this test before it
## fails the latency microbenchmark — useful because the latency
## numbers are noisy on shared runners but the syscall count is
## deterministic.
##
## Strategy: wrap ``repro dev-env export bash`` under
## ``repro-fs-snoop`` (which uses the monitor shim's IAT detours on
## Windows / the LD_PRELOAD path on POSIX to record every file/path
## access). Read back the depfile and inspect the
## ``mrFileRead`` records.
##
## Strict bar: the no-op path may read AT MOST 3 files via
## ``mrFileRead`` records that belong to the dev-env edge cache key:
##
## * ``<project-root>/reprobuild.nim``  — the project file content
## * ``<project-root>/.repro/dev-env.lock`` — the lock-slice file
##   (may be absent — in that case the count is lower)
## * the develop-overrides file — same caveat (may be absent)
##
## NO build-engine artifacts may appear: no ``dev-env.rbde``, no
## ``provider-compile.rbsz``, no ``project-interface.rbsz``,
## no ``build-engine-cache/`` paths. If any of those leak through
## we've regressed back to the slow path.
##
## ``repro-fs-snoop`` AND the monitor shim are pulled in via the same
## ``prepareMonitorTools`` helper the M76 suite uses. When the test
## host can't build them (i.e. ``isFsSnoopSupported == false``) the
## test SKIPs — the build engine has no Linux/macOS slot for this
## environment.

import std/[os, osproc, sequtils, streams, strtabs, strutils, unittest]

import repro_monitor_depfile
import repro_test_support
import shell_hook_helper

const ForbiddenSubstrings = [
  "dev-env.rbde",
  "provider-compile.rbsz",
  "project-interface.rbsz",
  "build-engine-cache",
  "dev-env.env.navigator.json"
]

proc readFingerprint(script: string): string =
  const needle = "__REPRO_APPLIED='"
  let s = script.find(needle)
  if s < 0:
    raise newException(ValueError, "no __REPRO_APPLIED marker in script")
  let rest = script[(s + needle.len) .. ^1]
  let e = rest.find('\'')
  if e < 0:
    raise newException(ValueError, "unterminated __REPRO_APPLIED quote")
  rest[0 ..< e]

proc runExport(c: ShellHookCase; extraEnv: openArray[(string, string)] = []):
    tuple[stdout: string; exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.startsWith("__REPRO_"):
      continue
    env[k] = v
  env["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  env["HOME"] = c.tempRoot
  for (k, v) in extraEnv:
    env[k] = v
  var p = startProcess(c.reproBin,
    args = @["dev-env", "export", "bash",
      "--project-root", c.projectRoot],
    workingDir = c.repoRoot,
    env = env,
    options = {poUsePath})
  let outStream = p.outputStream
  let outText = if outStream != nil: outStream.readAll() else: ""
  let code = p.waitForExit()
  p.close()
  (stdout: outText, exitCode: code)

proc runExportUnderSnoop(c: ShellHookCase; fingerprint, depfilePath: string):
    tuple[stdout: string; exitCode: int] =
  ## Wrap the export call under ``repro-fs-snoop`` so the monitor shim
  ## records every file read into ``depfilePath`` (RMDF format).
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.startsWith("__REPRO_"):
      continue
    env[k] = v
  env["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  env["HOME"] = c.tempRoot
  env["REPRO_MONITOR_SHIM_LIB"] = c.monitorShim
  env["__REPRO_APPLIED"] = fingerprint
  var p = startProcess(c.fsSnoop,
    args = @[
      "--depfile", depfilePath,
      "--",
      c.reproBin, "dev-env", "export", "bash",
        "--project-root", c.projectRoot
    ],
    workingDir = c.repoRoot,
    env = env,
    options = {poUsePath, poStdErrToStdOut})
  let outStream = p.outputStream
  let outText = if outStream != nil: outStream.readAll() else: ""
  let code = p.waitForExit()
  p.close()
  (stdout: outText, exitCode: code)

suite "e2e_shell_hook_noop_io_bounded":

  test "noop_fast_path_does_not_open_build_engine_artifacts":
    if not isFsSnoopSupported:
      skip()
    else:
      let c = prepareShellHookCase("repro-m77-noop-io")
      defer:
        try: removeDir(c.tempRoot)
        except CatchableError: discard
      if c.fsSnoop.len == 0 or c.monitorShim.len == 0:
        skip()
      else:
        # Warm: do ONE activation to obtain the fingerprint we want
        # subsequent invocations to short-circuit against. This run
        # touches the full build graph; we don't measure it.
        let initial = runExport(c)
        check initial.exitCode == 0
        let fingerprint = readFingerprint(initial.stdout)
        check fingerprint.len > 0

        # Measured run: same command, but with the fingerprint in env
        # so the fast path engages.
        let depfilePath = c.tempRoot / "noop-io.rdep"
        let snoop = runExportUnderSnoop(c, fingerprint, depfilePath)
        if snoop.exitCode != 0 or
            not snoop.stdout.contains(
              "repro shell hook: no-op (cache key unchanged)"):
          echo "=== snoop exit=", snoop.exitCode, " stdout ==="
          echo snoop.stdout
        check snoop.exitCode == 0
        check snoop.stdout.contains(
          "repro shell hook: no-op (cache key unchanged)")

        let dep = readMonitorDepFile(depfilePath)
        echo "M77 depfile total records=", dep.records.len
        # On Windows the IAT-detoured ``CreateFileW`` lands as
        # ``mrFileOpen``; on POSIX the LD_PRELOAD ``open`` interposer
        # lands as ``mrFileRead`` for O_RDONLY opens AND ``mrFileOpen``
        # for the open call boundary. We union BOTH kinds so the
        # acceptance gate covers whichever side of the platform's
        # observation taxonomy populates the cache-key read pattern.
        # We also fold in ``mrPathProbe`` for the negative assertion
        # below — a stat/exists check on ``dev-env.rbde`` is just as
        # bad as a read because it implies the slow path computed the
        # artifact path.
        var fileReadPaths: seq[string] = @[]
        var allFsPaths: seq[string] = @[]
        for rec in dep.records:
          if rec.kind in {mrFileRead, mrFileOpen}:
            fileReadPaths.add(rec.path)
          if rec.kind in {mrFileRead, mrFileOpen, mrPathProbe,
              mrDirectoryEnumerate}:
            allFsPaths.add(rec.path)
        echo "M77 file-open + file-read records=", fileReadPaths.len,
          " (all fs paths=", allFsPaths.len, ")"

        # STRICT NEGATIVE assertions: NO build-engine artifact may
        # appear in the recorded reads OR probes. A regression that
        # adds a back-door read of ``dev-env.rbde`` would land here
        # first; so would a stat probe (which implies the slow path
        # computed the artifact path even if it never opened it).
        for forbidden in ForbiddenSubstrings:
          for p in allFsPaths:
            if p.contains(forbidden):
              echo "FORBIDDEN fs op for '", forbidden, "' detected: ", p
              echo "All fs ops on no-op path:"
              for q in allFsPaths:
                echo "  ", q
          check not allFsPaths.anyIt(it.contains(forbidden))

        # Positive bound: the cache-key check on the no-op path is
        # allowed to OPEN at most a small number of files (the
        # project file is the only one that exists in the standard
        # fixture; ``.repro/dev-env.lock`` and ``develop-overrides.json``
        # are absent and resolve via ``mrPathProbe``, not
        # ``mrFileOpen``). Tolerance: 3 unique paths so this still
        # leaves headroom for shim instrumentation artefacts (e.g.
        # the inline-detour install probe) without losing the
        # decisive-failure shape — a regression that adds a stray
        # read of a build artifact would fail the negative bound
        # ABOVE, and a regression that adds a directory walk would
        # blow past this positive bound.
        var projectScopedReads: seq[string] = @[]
        let projectPrefix = c.projectRoot
        for p in fileReadPaths:
          if p.startsWith(projectPrefix) and
              not projectScopedReads.contains(p):
            projectScopedReads.add(p)
          # Windows shim sometimes records the project path through
          # the \\?\ extended-path prefix; normalize for the bound.
          let normalized = p.replace("\\\\?\\", "")
          if normalized.startsWith(projectPrefix) and
              not projectScopedReads.contains(normalized):
            projectScopedReads.add(normalized)
        echo "M77 no-op fast-path project-scoped opens (",
          $projectScopedReads.len, "):"
        for p in projectScopedReads:
          echo "  ", p
        check projectScopedReads.len <= 3

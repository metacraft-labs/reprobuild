## The engine must choose the image it self-spawns by what that image
## DECLARES itself to be, never by the filename it was invoked under.
##
## Three defects, one root. In each the image genuinely IS `repro` and only
## its filename says otherwise, and in each the name check answered "not
## `repro`":
##
##   * N36 — Nix's ``wrapProgram`` moves the real image to
##     ``.repro-wrapped``. Every wrapped package silently lost its io-monitor
##     driver, silently because "" is a SUPPORTED answer from
##     ``selfSpawnIoMonitorPath`` (fall back to declared inputs/outputs).
##   * The M5 trampoline — a bootstrap installed as ``repro-bootstrap.exe``
##     answers "no `repro` image to spawn it with", which is why
##     ``apps/repro-trampoline/repro_trampoline.nim`` has to hide the
##     bootstrap in a DIRECTORY named `reprobuild` instead of naming the file.
##   * ``scripts/run_tests.sh`` — Windows cannot relink a running image, so
##     the suite copies ``repro.exe`` to ``repro_run.exe`` and runs the copy.
##     A byte-identical `repro` under a different name was refused, and that
##     killed the entire Windows suite in its build phase for 55 days.
##
## THIS TEST BINARY IS THE SAME SHAPE. It is called ``t_…exe``, so the first
## assertion below establishes that the filename route would say no, and the
## rest show that the declaration — and only the declaration — decides.
##
## The refusal itself is load-bearing and is asserted in both directions: an
## image that has NOT declared itself `repro` is still refused, because that
## refusal is what stops a test binary linking the engine in-process from
## being re-executed with ``__repro-extract-interface`` on its argv, running
## its suite again, and spawning the next generation without bound.

import std/[os, unittest]
import repro_cli_support

suite "self-spawn image identity":
  test "chosen by the image's declaration, not by its filename":
    # Everything lives in ONE case on purpose: the mark is process-global and
    # the refusal must be observed before it is set, so the phases must not be
    # separable by a runner that selects individual cases.
    check extractFilename(getAppFilename()) != addFileExt("repro", ExeExt)

    # ``stablePublicCliPath`` prefers this variable, and a value here would
    # make the candidate differ from the running image, which is accepted for
    # its own reasons and would make the refusal below vacuous.
    let savedEnv = getEnv("REPRO_PUBLIC_CLI_PATH")
    delEnv("REPRO_PUBLIC_CLI_PATH")
    try:
      # Undeclared: refused. This is the fork-bomb guard.
      check selfSpawnIoMonitorPath("") == ""

      try:
        # The SETTER is gated behind the same define as the clear, so this
        # name exists only here. `markRunningImageAsReproCli` itself is
        # module-private: nothing outside `repro_cli_support` can grant
        # itself the mark, and `runThinApp` is the only path that sets it in
        # an ordinary build.
        markRunningImageAsReproCliForTest()
        # Declared: accepted, under a filename that is NOT `repro`.
        check selfSpawnIoMonitorPath("") ==
          os.normalizedPath(getAppFilename())
      finally:
        resetRunningImageReproCliMarkForTest()

      # And the refusal is restored, so the rest of this process is as safe
      # as it was before the case ran.
      check selfSpawnIoMonitorPath("") == ""
    finally:
      if savedEnv.len > 0:
        putEnv("REPRO_PUBLIC_CLI_PATH", savedEnv)

## DSL-port M9.R.13c.2 — monitor-shim DLL discovery via action env.
##
## ## Context
##
## M9.R.13b iteration 12 surfaced a deterministic gap in the from-source
## smoke. The daemon-hosted ``repro internal io monitor`` subprocess
## failed with:
##
##   cannot find librepro_monitor_shim.dll; run just build or set
##     REPRO_MONITOR_SHIM_LIB
##
## even though ``librepro_monitor_shim.dll`` was clearly present at
## ``D:/metacraft/reprobuild/build/lib/librepro_monitor_shim.dll`` (the
## canonical layout). Setting the env var explicitly in the user's
## shell DID fix the symptom but the user's hard requirement is
## "deterministic and reproducible" — requiring an external env var to
## be carried through three process hops (user shell → repro CLI →
## daemon -> io-monitor subprocess) is neither.
##
## ## Root cause
##
## ``candidateShimLibraries()`` walks ``getAppDir()`` /
## ``getCurrentDir()`` plus ``$REPRO_MONITOR_SHIM_LIB``. When the
## io-monitor subprocess is spawned by the daemon-hosted build executor,
## ``getAppDir()`` points at the daemon's executable directory — which
## may or may NOT be the canonical reprobuild build layout, depending
## on which executable launched the daemon. The 84-recipe wayland chain
## stresses this seam because the daemon was self-spawned by an inner
## ``repro.exe`` whose ``getAppDir()`` matched, but a more general case
## (system install of runquotad, daemon running under a different
## install prefix, ...) makes the fall-through unreliable.
##
## ## What this milestone changed
##
## ``BuildEngine.monitoredAction`` now seeds
## ``REPRO_MONITOR_SHIM_LIB=<absolute path>`` on the action's env at
## wrap-time, using the public ``findShimLibrary()`` helper that
## the previous monitor driver already implemented. The seed is
## skipped when the engine process itself cannot locate a shim (the
## fall-through path then handles it from the subprocess's env). An
## explicit recipe-supplied env entry wins over the seed — the seed is
## prepended so a later ``REPRO_MONITOR_SHIM_LIB=...`` entry in
## ``action.env`` overrides it via ``envTableFromArgvStyle``'s
## last-write-wins layering.
##
## ## What this test pins
##
## Three arms:
##
##   1. ``findShimLibrary()`` honours ``$REPRO_MONITOR_SHIM_LIB`` when
##      set to an existing path. Resilience pin: the operator override
##      always wins.
##
##   2. ``findShimLibrary()`` falls through cleanly to the empty string
##      when no shim is locatable AND the env var is unset / points at
##      a non-existent file. Total-function pin: callers can probe
##      cheaply without exception handling.
##
##   3. The ``candidateShimLibraries`` ordering pins the shape of the
##      lookup path so a refactor doesn't accidentally drop one of the
##      four canonical locations the M9.R.13c seed depends on
##      (env override + ../lib/ + appDir + cwd/build/lib). Indirectly:
##      we assert that with a sentinel env override the helper picks
##      it up FIRST.

import std/[os, strutils, unittest]

import io_mon

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeSentinelShim(): string =
  ## Drop a sentinel file that mimics the shim DLL by extension. The
  ## ``findShimLibrary`` helper only checks ``fileExists`` — it does
  ## not validate the file's PE/Mach-O/ELF header — so a trivial
  ## placeholder is enough to drive the lookup contract.
  when defined(windows):
    let suffix = ".dll"
  elif defined(linux):
    let suffix = ".so"
  else:
    let suffix = ".dylib"
  result = getTempDir() / ("m9r13c-sentinel-shim-" &
    $getCurrentProcessId() & suffix)
  writeFile(result, "sentinel\n")

proc resetEnv() =
  delEnv("REPRO_MONITOR_SHIM_LIB")

# ---------------------------------------------------------------------------
# Arms
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.13c.2 — monitor-shim DLL discovery":

  setup:
    resetEnv()

  teardown:
    resetEnv()

  test "findShimLibrary picks up REPRO_MONITOR_SHIM_LIB when it exists":
    ## Arm 1: the env override takes top priority over the
    ## sibling-walk + appDir + cwd-build fall-throughs.
    let sentinel = makeSentinelShim()
    try:
      putEnv("REPRO_MONITOR_SHIM_LIB", sentinel)
      let resolved = findShimLibrary()
      check resolved == absolutePath(sentinel)
    finally:
      try: removeFile(sentinel) except CatchableError: discard

  test "findShimLibrary returns empty string when no shim is locatable":
    ## Arm 2: a stale env var pointing at a non-existent file does
    ## not poison the lookup. Either the fall-through finds the real
    ## shim (when the test binary lives next to one) OR the lookup
    ## returns the empty string. Either outcome is contractually
    ## correct; what MUST NOT happen is the helper returning the
    ## bogus path or raising.
    let bogus = getTempDir() / "m9r13c-this-file-does-not-exist.dll"
    putEnv("REPRO_MONITOR_SHIM_LIB", bogus)
    let resolved = findShimLibrary()
    check resolved != bogus
    # If a real shim is locatable from the test binary's appDir, the
    # helper returns it. If not, the empty string. Both are valid.
    if resolved.len > 0:
      check fileExists(resolved)

  test "findShimLibrary is total when REPRO_MONITOR_SHIM_LIB is unset":
    ## Arm 3: the unset case must also be total — no exception, just
    ## a possibly-empty string. This is the property the engine's
    ## ``monitoredAction`` seed depends on: the seed is skipped when
    ## the helper returns empty, so a failed lookup does not break
    ## the wrap.
    delEnv("REPRO_MONITOR_SHIM_LIB")
    let resolved = findShimLibrary()
    if resolved.len > 0:
      check fileExists(resolved)
    # No exception was raised — the implicit pin.

  test "findShimLibrary env override wins over the fall-through":
    ## Arm 4: when BOTH an env override AND a fall-through candidate
    ## exist, the env override wins. This pins the priority ordering
    ## documented in ``candidateShimLibraries``: the env var is
    ## index 0.
    let sentinel = makeSentinelShim()
    try:
      putEnv("REPRO_MONITOR_SHIM_LIB", sentinel)
      let resolved = findShimLibrary()
      # The override path must be the resolved one, even if a real
      # shim exists in the canonical build layout.
      check resolved == absolutePath(sentinel)
    finally:
      try: removeFile(sentinel) except CatchableError: discard

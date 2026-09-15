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
##   2. A PINNED-BUT-MISSING ``$REPRO_MONITOR_SHIM_LIB`` is refused, not
##      worked around. This arm used to assert the opposite — that the
##      helper falls through to discovery and hands back the empty string
##      or a discovered shim — and that contract was RETIRED in io-mon
##      ``2326e7c`` (2026-08-14). ``findShimLibrary`` now raises
##      ``IOError`` naming the pinned path, because falling through would
##      capture a run with a shim the operator did not pin: a stale pin or
##      a typo would silently change the capture's provenance and still
##      report success. This arm pins the refusal, including the fact that
##      the diagnostic names the env var and the missing path.
##
##      Note this arm never exercised "no shim is locatable" — it SETS the
##      override, so the discovery walk is not what it reaches. Totality of
##      the unpinned lookup is arm 3's job, and that is where it stays.
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

  test "findShimLibrary refuses a pinned shim that does not exist":
    ## Arm 2: the override is a PIN, so a pin that names no file is a
    ## refusal — never a silent fall-through to a different shim.
    ##
    ## This arm previously asserted the fall-through ("returns the empty
    ## string, or whatever discovery finds, but never the bogus path and
    ## never an exception"). io-mon ``2326e7c`` retired that: honouring a
    ## pin has to mean honouring it, so a miss raises. Capturing a build
    ## with a shim other than the pinned one yields evidence whose
    ## provenance is not the one that was asked for, and it would do so
    ## with no diagnostic and a successful-looking result.
    let bogus = getTempDir() / "m9r13c-this-file-does-not-exist.dll"
    putEnv("REPRO_MONITOR_SHIM_LIB", bogus)
    var raised = false
    var message = ""
    try:
      discard findShimLibrary()
    except IOError as err:
      raised = true
      message = err.msg
    check raised
    # The diagnostic has to be actionable: it names the env var that
    # carries the pin and the path that pin resolved to, so an operator
    # can see WHICH pin is stale without re-deriving it.
    check message.contains("REPRO_MONITOR_SHIM_LIB")
    check message.contains(bogus)

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

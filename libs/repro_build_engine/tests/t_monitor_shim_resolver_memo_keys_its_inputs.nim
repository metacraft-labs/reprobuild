## ``resolveMonitorShimLibForInstall`` is memoised, and the memo must be
## keyed on its inputs rather than scoped to a lifetime.
##
## WHY THE MEMO EXISTS. ``launchChildEnv`` calls this resolver once per
## ACTION, and ``actionEnvResolver`` puts it on the WARM NO-OP path —
## where no action executes at all and the launch environment is wanted
## only so the observed-environment fingerprint can be evaluated.
## Measured on the 37-edge zlib fixture: 37 calls costing 1.1 ms of a
## 33.4 ms no-op, nearly all of it ``getAppDir`` (which on macOS is
## ``_NSGetExecutablePath`` plus a ``realpath`` of every path component).
## Memoising takes that to 0.4 ms.
##
## WHY THIS TEST. A memo whose key omits an input is not a speed-up, it
## is a wrong answer served quickly — and the process this runs in is a
## long-lived one. The user daemon chdirs per request
## (``enterDaemonRequestDirectory``) and applies and restores a
## per-request environment around every build, so a resolver that froze
## its first answer would hand every later build from a different project
## directory the shim path of the first. The two assertions below are the
## two inputs that a long-lived process actually changes: the operator
## pin, and the CURRENT DIRECTORY.
##
## The cwd case is exercised through a RELATIVE ``REPRO_MONITOR_SHIM_LIB``
## precisely because that is the one arm whose answer demonstrably moves
## with the cwd on this host: io-mon's own ``<cwd>/build/lib`` arm is LAST
## and is shadowed by ``<appDir>/../lib`` in a dev checkout, where those
## two paths name the same directory. A relative pin resolves against the
## cwd inside ``findShimLibrary`` itself, so the same process asking the
## same question from two directories must get two different absolute
## answers. A memo keyed only on the environment returns the first one
## twice and this test fails.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The resolver under test is the production
## ``repro_build_engine.resolveMonitorShimLibForInstall``; the shim
## libraries are real files in a real temporary directory and the cwd
## changes are real ``setCurrentDir`` calls. There is nothing here to
## fake: the defect this guards against is exactly a resolver that stops
## consulting the real filesystem and the real process state.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
from io_mon import ShimLibOverrideEnv

proc shimLeaf(): string =
  ## The leaf ``findShimLibrary`` probes for on this host.
  "librepro_monitor_shim." & HostDynamicLibraryExt

suite "monitor shim resolver memoisation":
  var root: string
  var previousCwd: string
  var previousOverride: string
  var overrideWasSet: bool

  setup:
    root = createTempDir("repro_shim_memo_", "")
    previousCwd = getCurrentDir()
    overrideWasSet = existsEnv(ShimLibOverrideEnv)
    previousOverride = getEnv(ShimLibOverrideEnv)

  teardown:
    setCurrentDir(previousCwd)
    if overrideWasSet:
      putEnv(ShimLibOverrideEnv, previousOverride)
    else:
      delEnv(ShimLibOverrideEnv)
    removeDir(root)

  test "a re-pointed operator override is not served from the memo":
    let first = root / "first"
    let second = root / "second"
    createDir(first)
    createDir(second)
    writeFile(first / shimLeaf(), "first")
    writeFile(second / shimLeaf(), "second")

    putEnv(ShimLibOverrideEnv, first / shimLeaf())
    let firstAnswer = resolveMonitorShimLibForInstall()
    check firstAnswer == first / shimLeaf()

    # Ask again with the SAME pin: this is the memo hit, and it has to
    # agree with the uncached answer or the memo is simply wrong.
    check resolveMonitorShimLibForInstall() == firstAnswer

    putEnv(ShimLibOverrideEnv, second / shimLeaf())
    check resolveMonitorShimLibForInstall() == second / shimLeaf()

  test "the same relative pin resolves per current directory":
    let a = root / "a"
    let b = root / "b"
    createDir(a)
    createDir(b)
    writeFile(a / shimLeaf(), "a")
    writeFile(b / shimLeaf(), "b")

    # A RELATIVE pin. `findShimLibrary` checks it with `fileExists` and
    # returns `absolutePath(override)`, both of which resolve against the
    # process cwd — so this one env value has two correct answers.
    putEnv(ShimLibOverrideEnv, shimLeaf())

    setCurrentDir(a)
    let fromA = resolveMonitorShimLibForInstall()
    check fromA.endsWith(shimLeaf())
    check sameFile(fromA, a / shimLeaf())

    setCurrentDir(b)
    let fromB = resolveMonitorShimLibForInstall()
    check sameFile(fromB, b / shimLeaf())

    # The point of the whole test: the second answer is not the first.
    check fromA != fromB

    # And coming back gives the first answer again — an invalidation that
    # only ever moves forward would pass the check above while still
    # being a broken cache.
    setCurrentDir(a)
    check sameFile(resolveMonitorShimLibForInstall(), a / shimLeaf())

  test "a memoised answer that has been deleted still raises for a bad pin":
    ## io-mon's pin contract: ``$REPRO_MONITOR_SHIM_LIB`` naming a file
    ## that does not exist RAISES rather than falling through to a
    ## discovered shim, so a stale pin cannot yield a capture from a shim
    ## the operator did not ask for. A memo is not allowed to soften that
    ## into "here is the path I remember".
    ##
    ## This is also the one case that proves the memo is LIVE rather than
    ## merely harmless: the first call is what puts the answer in the
    ## cache, and the deletion is what the cache would otherwise hide.
    let pinned = root / "pinned"
    createDir(pinned)
    writeFile(pinned / shimLeaf(), "pinned")
    putEnv(ShimLibOverrideEnv, pinned / shimLeaf())

    check resolveMonitorShimLibForInstall() == pinned / shimLeaf()

    removeFile(pinned / shimLeaf())
    expect IOError:
      discard resolveMonitorShimLibForInstall()

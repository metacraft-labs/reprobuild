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
## directory the shim path of the first. Two of the cases below are the
## two inputs that a long-lived process actually changes: the operator
## pin, and the CURRENT DIRECTORY.
##
## THE FOURTH CASE GUARDS THE ONE REFUSAL WITH A CORRECTNESS STAKE, and
## it is the reason this file re-execs itself. The resolver never caches
## an EMPTY answer. Empty means "monitoring not configured" and the
## caller turns it into a bypass, so a cached empty answer would freeze
## that bypass for every later action — silently un-monitoring edges
## whose recorded inputs then come out incomplete. This is not
## hypothetical: reprobuild BUILDS its own
## ``build/lib/librepro_monitor_shim.dylib``, so a build genuinely can
## go from "no shim" to "shim" part-way through, and the filesystem is
## the one input the key does not cover.
##
## A mutation that stores and serves the empty answer too passes the
## other three cases in this file. It is caught only by asking the
## resolver twice across a filesystem change, which needs BOTH of
## io-mon's discovery arms to miss on the first call — and one of them is
## ``<appDir>/../lib``. For a binary in ``build/test-bin`` that is
## ``build/lib``, which in any tree that has been built ALREADY CONTAINS
## THE SHIM, so the empty answer cannot occur in this process at all. The
## case therefore re-execs a COPY of this binary from a temporary
## directory, which is the only way to move ``getAppDir`` — it is
## ``_NSGetExecutablePath`` plus a ``realpath``, fixed for the life of a
## process and deliberately the one input the memo key leaves out.
## Deriving the answer from whether the ambient ``build/lib`` happens to
## hold a shim would make the case pass or fail on the state of the
## checkout rather than on the resolver.
##
## The child role is selected by an ARGV FLAG, not an environment
## variable, on purpose: an env marker is inherited by every descendant
## process, so a stray export would turn an ordinary run of this binary
## into a silent three-line no-op that still exits 0. An argv flag cannot
## be inherited, and the parent additionally refuses any child output
## that does not carry all three ``probe`` lines.
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

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_build_engine
from io_mon import ShimLibOverrideEnv

proc shimLeaf(): string =
  ## The leaf ``findShimLibrary`` probes for on this host.
  "librepro_monitor_shim." & HostDynamicLibraryExt

const
  NegativeProbeFlag = "--repro-internal-shim-memo-negative-probe"
    ## Private seam of THIS file; see the header for why it is an argv
    ## flag rather than an environment variable.
  RuntimeLibraryPathEnv = "REPROBUILD_RUNTIME_LIBRARY_PATH"
    ## The resolver's installed-package arm, unset for the child so the
    ## first call has to come back empty.
  ProbePrefix = "probe "

proc runNegativeCacheProbe() =
  ## THE CHILD ROLE. Runs in a copy of this binary placed at
  ## ``<root>/bin/`` with the cwd at ``<root>/work``, so BOTH discovery
  ## arms miss: ``<appDir>/../lib`` is ``<root>/lib`` (never created) and
  ## ``<cwd>/build/lib`` does not exist yet.
  ##
  ## It reports facts and asserts nothing. The assertions live in the
  ## parent, where a failure reddens a named ``unittest`` case instead of
  ## becoming an exit code the parent has to interpret.
  let workDir = getCurrentDir()
  let late = workDir / "build" / "lib" / shimLeaf()

  # FIRST: no shim anywhere the resolver looks. This must be empty, and
  # the parent checks that it is — a non-empty answer here would mean the
  # case had stopped testing anything, not that the resolver was fine.
  echo ProbePrefix, "first=", resolveMonitorShimLibForInstall()

  # The event the refusal exists for: the build produces the shim it will
  # itself monitor with, after the resolver has already answered once.
  createDir(workDir / "build" / "lib")
  writeFile(late, "a shim that appeared mid-build")

  # SECOND, in the SAME PROCESS with the SAME cwd and the SAME
  # environment — so the memo key is byte-identical to the first call's.
  # Only the filesystem moved, and the filesystem is not in the key.
  echo ProbePrefix, "second=", resolveMonitorShimLibForInstall()
  echo ProbePrefix, "expected=", late
  quit(0)

if paramCount() >= 1 and paramStr(1) == NegativeProbeFlag:
  runNegativeCacheProbe()

proc probeField(output, name: string): string =
  ## Pull one reported fact out of the child's output, or fail loudly
  ## with the whole output attached. A missing line means the child died
  ## before it got there, and that must never read as an empty answer.
  let wanted = ProbePrefix & name & "="
  for line in output.splitLines():
    if line.startsWith(wanted):
      return line[wanted.len .. ^1]
  raise newException(ValueError,
    "child printed no \"" & wanted & "\" line; its output was:\n" & output)

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

  test "an empty answer is not cached, so a shim built mid-build is found":
    ## The refusal with the correctness stake. See the header for why
    ## this needs a controlled ``appDir`` and therefore a child process.
    let binDir = root / "bin"
    let workDir = root / "work"
    createDir(binDir)
    createDir(workDir)
    # ``root / "lib"`` is DELIBERATELY NOT CREATED: it is the child's
    # ``<appDir>/../lib``, io-mon's first discovery arm, and the whole
    # point of re-execing is that this arm misses.
    check not dirExists(root / "lib")

    let childExe = binDir / extractFilename(getAppFilename())
    # WithPermissions: a plain ``copyFile`` drops the execute bit.
    copyFileWithPermissions(getAppFilename(), childExe)

    var childEnv = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      childEnv[key] = value
    # Both env inputs to the key are cleared, so the child's first call
    # reaches discovery and discovery has nothing to find. Whatever this
    # test process inherited must not decide the child's answer.
    childEnv.del(ShimLibOverrideEnv)
    childEnv.del(RuntimeLibraryPathEnv)

    let child = startProcess(childExe, workingDir = workDir,
      args = [NegativeProbeFlag], env = childEnv,
      options = {poStdErrToStdOut})
    let output = child.outputStream.readAll()
    let status = child.waitForExit()
    child.close()

    checkpoint("child output:\n" & output)
    check status == 0

    let first = probeField(output, "first")
    let second = probeField(output, "second")
    let expected = probeField(output, "expected")

    # The PRECONDITION, checked rather than assumed: if this is not
    # empty, the child found a shim somewhere and the case below proves
    # nothing. A green run must mean the empty answer really happened.
    check first == ""

    # THE ASSERTION. A resolver that cached the empty answer returns it
    # again here, because the key has not changed — only the filesystem
    # has. This is the check that a "store the empty answer too" memo
    # fails and the other three cases in this file do not.
    check second.len > 0
    # Guarded because ``sameFile("")`` raises: under the mutation this
    # case must report the failed check above, not die of an ``OSError``
    # in the assertion that follows it.
    if second.len > 0:
      check sameFile(second, expected)
      check sameFile(second, workDir / "build" / "lib" / shimLeaf())

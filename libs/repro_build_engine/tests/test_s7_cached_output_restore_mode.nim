## S7 — the CAS-restore configuration, made reachable and made safe.
##
## S5 removed the reason a restore could never succeed (an action recorded
## its own declared output as one of its inputs, so the lookup that could
## have restored a deleted file missed on the very file that was missing).
## What S5 left behind was that no ``repro build`` invocation could reach
## the configuration that restores: every ``BuildEngineConfig`` the CLI
## constructed hard-coded ``rebuildMissingOutputsOnCacheHit = true``, and
## six of seven also hard-coded ``deferLocalOutputBlobs = true``, so all 181
## published records on the reference host were ``opkMetadataOnly`` with no
## payload to restore from. A clean checkout with a fully warm cache still
## rebuilt everything.
##
## Flipping those two literals would have been the wrong fix, and this file
## is mostly about why. Restoring an action's DECLARED outputs is equivalent
## to re-running it ONLY when those outputs are the whole of its product.
## ``repro_cli_support.nim`` carries the precedent in a comment: a second
## ``develop --all`` into a different placement root took a shared cache
## entry, materialized only the receipt, cloned nothing, and the chained
## step then failed against a directory that was never created. It reported
## a cache hit while doing it.
##
## So the deliverable is a run-level opt-in (``enableCachedOutputRestore``)
## plus a per-action gate (``requireCompleteOutputEvidence``) that decides,
## from the monitor's own record of what the action WROTE, whether that
## action's declared outputs account for its product. An action that fails
## the gate publishes a record with no payloads, which cannot serve a
## restore, so it re-runs and produces its whole product again.
##
## Both directions are asserted. The gate being ON must not stop a hermetic
## action being restored (otherwise the feature is inert), and the gate
## being OFF must reproduce the mis-restore on demand (otherwise the guard
## is only asserted to be load-bearing). The last case in this file deletes
## an under-declared action's whole product, restores with the gate off, and
## checks that the undeclared half is STILL MISSING — the hazard, produced
## rather than argued.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[types, writer]

const UnitRoot =
  when defined(windows): "C:/repro-s7-unit"
  else: "/repro-s7-unit"

proc norm(path: string): string =
  path.replace('\\', '/')

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

proc readRecord(path: string): ActionResultRecord =
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  decodeActionResultRecord(bytes)

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 7777, threadId: 7777, path: path, detail: "")

proc fileWrite(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileWrite, observationKind: moFileWrite,
    osPid: 7777, threadId: 7777, path: path, detail: "")

proc writeRmdf(path: string; records: seq[MonitorRecord]) =
  ## Copy the encoded bytes into a fresh string rather than
  ## ``cast[string](encodeCanonical(...))`` — the spelling S5's fixture uses.
  ##
  ## *What is known, and what is not, because an earlier version of this
  ## comment asserted a mechanism that does not hold.* A truncated RMDF was
  ## observed once during development, with the engine reporting ``RMDF body
  ## length/trailer mismatch`` — which reads as a caching failure and is
  ## not one. The explanation offered at the time was that the cast
  ## reinterprets a temporary ``seq``'s buffer which is then freed before
  ## ``writeFile`` reads it. That explanation is WRONG: in both spellings
  ## the temporary lives to the end of the statement, and 400 iterations of
  ## each produced zero truncations, with S5's own suite green 6/6 across
  ## ten consecutive runs. So the cause of that one observation is not
  ## established and should not be cited as if it were.
  ##
  ## The copy stays regardless, on the grounds that survive the correction:
  ## ``cast[string]`` on a ``seq[byte]`` yields a string aliasing a payload
  ## it does not own, with a foreign ``cap`` and no NUL terminator, whose
  ## lifetime is then tied to a value the compiler is free to move. It is
  ## two lines to not depend on any of that.
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

const CopyTreeMarker = "--s7-copy-tree"

# The fixture action is a REAL child process, and it is this binary
# re-invoked with a marker argument rather than a shell one-liner.
#
# It has to be a real process: the whole question these cases ask is what a
# RE-RUN puts back that a restore does not, and an action whose extra file
# the test wrote itself cannot answer it. But it must not be
# ``cmd /C xcopy``. On the reference host the test suite leaks directories
# into the developer's persistent PATH past cmd.exe's 8 KB limit, which
# silently strips System32 out of a child's environment (recorded in this
# initiative's S2); a fixture that resolves ``cmd`` or ``xcopy`` through
# PATH then fails intermittently for a reason that has nothing to do with
# caching. Measured: the shell form of this fixture failed roughly one run
# in three here. ``getAppFilename()`` is absolute, so no lookup happens.
if commandLineParams().len >= 1 and commandLineParams()[0] == CopyTreeMarker:
  # Copy every file in ``src`` into ``out``, relative to the cwd the engine
  # launched us in. Declared outputs and undeclared ones alike.
  for entry in walkDir("src"):
    if entry.kind == pcFile:
      copyFile(entry.path, "out" / extractFilename(entry.path))
  quit(0)

proc copyTreeArgv(): seq[string] =
  @[getAppFilename(), CopyTreeMarker]

type Fixture = object
  workRoot: string
  cacheRoot: string
  action: BuildAction
  declaredOutput: string
  undeclaredOutput: string

proc makeFixture(tempRoot: string; withUndeclared: bool): Fixture =
  ## ``src/product.txt`` is the declared product. When ``withUndeclared``,
  ## ``src/extra.txt`` rides along: the action copies it too, the monitor
  ## records the write, and nothing declares it.
  let workRoot = tempRoot / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  writeFile(workRoot / "src" / "product.txt", "payload\n")
  var writes = @[fileWrite(workRoot / "out" / "product.txt")]
  var reads = @[fileRead(workRoot / "src" / "product.txt")]
  if withUndeclared:
    writeFile(workRoot / "src" / "extra.txt", "extra\n")
    reads.add(fileRead(workRoot / "src" / "extra.txt"))
    writes.add(fileWrite(workRoot / "out" / "extra.txt"))
  let rmdfPath = tempRoot / "copy.rdep"
  writeRmdf(rmdfPath, reads & writes)
  var act = action("copy-tree", copyTreeArgv(),
    cwd = workRoot,
    inputs = @["src/product.txt"],
    outputs = @["out/product.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  act.monitorDepfile = rmdfPath
  Fixture(
    workRoot: workRoot,
    cacheRoot: tempRoot / "cache",
    action: act,
    declaredOutput: workRoot / "out" / "product.txt",
    undeclaredOutput: workRoot / "out" / "extra.txt")

const InstallMarker = "--s7-install-tree"

if commandLineParams().len >= 1 and commandLineParams()[0] == InstallMarker:
  # The cmake/meson ``--install`` shape, reduced to its essentials: copy the
  # staged tree into the destination root, then touch the stamp that is the
  # only thing the edge DECLARES.
  createDir("build/out/usr")
  createDir(".repro")
  for entry in walkDir("src"):
    if entry.kind == pcFile:
      copyFile(entry.path, "build" / "out" / "usr" / extractFilename(entry.path))
  writeFile(".repro/install.stamp", "")
  quit(0)

proc makeInstallFixture(tempRoot: string): Fixture =
  ## The milestone's own motivating shape, from
  ## ``cmake_package.nim``'s ``cmake-install-<pkg>`` edge and
  ## ``meson_package.nim``'s install edge — both of which are in the tree
  ## today, both ``cacheable`` by default:
  ##
  ## * ``outputs = @[installStamp]`` — a stamp, and nothing else;
  ## * the real product is the staged tree under the destination root;
  ## * ``declaredOutputs = @[destRoot]`` — the M9.R.75 write root;
  ## * ``ignoredInputPrefixes`` names ``destRoot`` *and* the build directory
  ##   above it, because cmake probes files already present below the
  ##   destination before replacing them and would otherwise depend on its
  ##   own previous writes.
  ##
  ## The last bullet is the trap. It is a claim about the cache KEY, and if
  ## the restore gate reads it as a claim about the PRODUCT then the whole
  ## staged tree is exempt, the record publishes with payloads, and a later
  ## build restores the stamp alone.
  let workRoot = tempRoot / "work"
  let buildDir = workRoot / "build"
  let destRoot = buildDir / "out"
  createDir(workRoot / "src")
  createDir(destRoot / "usr")
  createDir(workRoot / ".repro")
  writeFile(workRoot / "src" / "libfoo.so", "elf\n")
  let rmdfPath = tempRoot / "install.rdep"
  writeRmdf(rmdfPath, @[
    fileRead(workRoot / "src" / "libfoo.so"),
    fileWrite(destRoot / "usr" / "libfoo.so"),
    fileWrite(workRoot / ".repro" / "install.stamp")])
  var act = action("cmake-install-foo", @[getAppFilename(), InstallMarker],
    cwd = workRoot,
    inputs = @["src/libfoo.so"],
    outputs = @[".repro/install.stamp"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    dependencyPolicy = automaticMonitorGatheringPolicy(@[buildDir, destRoot]),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  act.declaredOutputs = @[destRoot]
  act.monitorDepfile = rmdfPath
  Fixture(
    workRoot: workRoot,
    cacheRoot: tempRoot / "cache",
    action: act,
    declaredOutput: workRoot / ".repro" / "install.stamp",
    undeclaredOutput: destRoot / "usr" / "libfoo.so")

proc restoreConfig(cacheRoot: string; gate: bool): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  # The gated configuration is taken from the production helper and is NOT
  # re-asserted field by field afterwards. That matters for mutation
  # testing: a helper that stopped setting the gate has to make the gated
  # cases below fail, and a test that set the field itself would paper over
  # exactly that.
  result.enableCachedOutputRestore()
  result.bypassRunQuota = true
  if not gate:
    # The gate-off variant exists only to demonstrate the hazard the gate
    # stops. It is not a reachable CLI configuration:
    # ``enableCachedOutputRestore`` is the only way into restore mode and it
    # always turns the gate on.
    result.requireCompleteOutputEvidence = false

suite "S7 the CAS-restore configuration is reachable and gated":

  test "enableCachedOutputRestore sets all three knobs, and nothing else does":
    ## The three fields have to move together — see the proc's docstring for
    ## why any two of them is worse than none. Pinning that here means a
    ## future edit that drops one line from the helper fails a test rather
    ## than quietly producing a configuration that stores blobs it can never
    ## restore, or restores without the gate.
    var config = defaultBuildEngineConfig(UnitRoot / "cache")
    # The engine default has always been restore-CAPABLE; what it never had
    # was the gate. That asymmetry is the reason the helper exists.
    check not config.deferLocalOutputBlobs
    check not config.rebuildMissingOutputsOnCacheHit
    check not config.requireCompleteOutputEvidence

    config.enableCachedOutputRestore()
    check not config.deferLocalOutputBlobs
    check not config.rebuildMissingOutputsOnCacheHit
    check config.requireCompleteOutputEvidence

  test "an action's own declared outputs never count as unaccounted writes":
    ## The action wrote exactly what it said it would. Reporting that would
    ## make every action fail the gate.
    ##
    ## Both files are on disk, so the exclusion that does the work here is
    ## the declared-output one and not the survival check — a case whose
    ## outputs happen to be absent would pass against a filter that had
    ## dropped the declared-output rule entirely.
    let tempRoot = createTempDir("repro-s7-declared", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "out")
    writeFile(tempRoot / "out" / "app.exe", "app\n")
    writeFile(tempRoot / "out" / "app.pdb", "pdb\n")

    var act = action("link", @["link.exe"],
      cwd = tempRoot,
      inputs = @["src/a.obj"],
      outputs = @["out/app.exe", "out/app.pdb"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot / "out" / "app.exe",
      tempRoot / "out" / "app.pdb"]
    check act.undeclaredSurvivingWrites(evidence).len == 0

  test "an undeclared write that survives IS reported":
    ## The develop --all shape, reduced: the action produced something real
    ## that its declared outputs do not mention.
    let tempRoot = createTempDir("repro-s7-undeclared", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "out")
    writeFile(tempRoot / "out" / "app.exe", "app\n")
    writeFile(tempRoot / "out" / "sidecar.dat", "sidecar\n")

    var act = action("link", @["link.exe"],
      cwd = tempRoot,
      outputs = @["out/app.exe"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot / "out" / "app.exe",
      tempRoot / "out" / "sidecar.dat"]
    let reported = act.undeclaredSurvivingWrites(evidence)
    check reported.len == 1
    check reported.hasPath(tempRoot / "out" / "sidecar.dat")

  test "an undeclared write that did not survive is not reported":
    ## A tool that writes a scratch file and unlinks it has produced nothing
    ## a restore would have to reproduce. Without this the gate would fail
    ## essentially every real compiler, and a gate that never passes is a
    ## feature that is never used.
    let tempRoot = createTempDir("repro-s7-transient", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "out")
    writeFile(tempRoot / "out" / "app.exe", "app\n")

    var act = action("link", @["link.exe"],
      cwd = tempRoot,
      outputs = @["out/app.exe"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot / "out" / "app.exe",
      tempRoot / "out" / "link.tmp"]      # never created
    check act.undeclaredSurvivingWrites(evidence).len == 0

  test "a written DIRECTORY is not reported, but a file inside one is":
    ## The monitor records a directory creation as a write, so a real
    ## ``nim c`` edge reports ``build/``, ``build/bin/`` and everything above
    ## them, including the parent of its own declared output — measured
    ## through the real CLI on a one-file ``hello.nim``: 41 observed writes,
    ## of which the gate reports 15 once directories, transients and the
    ## declared binary are set aside. Counting directories would make the
    ## gate reject every action that creates one, which is every action.
    ##
    ## Skipping them loses nothing, and the second half of this case is why:
    ## a product that lives inside an undeclared directory is still caught,
    ## by the FILES in it. That is exactly the clone-tree shape.
    let tempRoot = createTempDir("repro-s7-dirs", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "out")
    createDir(tempRoot / "out" / "clone")
    writeFile(tempRoot / "out" / "app.exe", "app\n")
    writeFile(tempRoot / "out" / "clone" / "README", "cloned\n")

    var act = action("clone", @["git.exe"],
      cwd = tempRoot,
      outputs = @["out/app.exe"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot,                             # a directory, and an ancestor
      tempRoot / "out",                     # the declared output's parent
      tempRoot / "out" / "clone",           # an UNdeclared directory
      tempRoot / "out" / "app.exe",
      tempRoot / "out" / "clone" / "README"]
    let reported = act.undeclaredSurvivingWrites(evidence)
    check reported.len == 1
    check reported.hasPath(tempRoot / "out" / "clone" / "README")

  test "a write under a declared machine-local derived prefix is not reported":
    ## ``ignoredInputPrefixes`` is the recipe author's existing statement
    ## that a tree is derived state rather than product — it is what keeps a
    ## compiler's private incremental cache out of the action-cache KEY.
    ## Derived state a rebuild regenerates is not something a restore has to
    ## reproduce, so the same declaration answers both questions.
    let tempRoot = createTempDir("repro-s7-derived", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "out")
    createDir(tempRoot / "nimcache" / "app")
    writeFile(tempRoot / "out" / "app.exe", "app\n")
    writeFile(tempRoot / "nimcache" / "app" / "app.o", "obj\n")
    writeFile(tempRoot / "out" / "sidecar.dat", "sidecar\n")

    var act = action("compile", @["nim.exe"],
      cwd = tempRoot,
      outputs = @["out/app.exe"],
      cacheable = true,
      dependencyPolicy = automaticMonitorGatheringPolicy(@["nimcache"]),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot / "out" / "app.exe",
      tempRoot / "nimcache" / "app" / "app.o",
      tempRoot / "out" / "sidecar.dat"]
    let reported = act.undeclaredSurvivingWrites(evidence)
    # The exemption is scoped to the declared prefix and nothing else: the
    # sidecar beside the real output still fails the gate.
    check reported.len == 1
    check reported.hasPath(tempRoot / "out" / "sidecar.dat")

  test "a declared write ROOT does not exempt an undeclared product":
    ## The single most important negative in this file. ``declaredOutputs``
    ## is M9.R.75's write-ROOT declaration — a directory. Letting it exempt
    ## anything would make the gate blind to exactly the failure it exists
    ## for: the develop --all action's real product (a clone TREE) sat
    ## INSIDE its own write root, and only the receipt was declared.
    let tempRoot = createTempDir("repro-s7-writeroot", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "out" / "clone")
    writeFile(tempRoot / "out" / "receipt.txt", "receipt\n")
    writeFile(tempRoot / "out" / "clone" / "README", "cloned\n")

    var act = action("clone", @["git.exe"],
      cwd = tempRoot,
      outputs = @["out/receipt.txt"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.declaredOutputs = @[tempRoot / "out"]
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot / "out" / "receipt.txt",
      tempRoot / "out" / "clone" / "README"]
    let reported = act.undeclaredSurvivingWrites(evidence)
    check reported.len == 1
    check reported.hasPath(tempRoot / "out" / "clone" / "README")

  test "a derived prefix that covers the action's own product is NOT honoured":
    ## The counterexample this gate was rejected over, as a unit.
    ##
    ## ``ignoredInputPrefixes`` is not evidence that a tree is not product.
    ## ``cmake_package.nim`` says why its install edge carries one, verbatim:
    ## *"Treating either mutable tree as a discovered input makes the install
    ## edge depend on its own previous writes and miss on every warm build."*
    ## That is a claim about the cache KEY. Reading it as a claim about the
    ## PRODUCT exempts the staged install tree — which is the whole product
    ## of an edge whose only declared output is a stamp.
    ##
    ## So a prefix is honoured only where it is DISJOINT from what the
    ## action declares as its product. Both containment directions matter
    ## and both are exercised here: the destination root is named as a
    ## prefix directly, and the build directory ABOVE it is named too.
    let tempRoot = createTempDir("repro-s7-installshape", "")
    defer: removeDir(tempRoot)
    let buildDir = tempRoot / "build"
    let destRoot = buildDir / "out"
    createDir(destRoot / "usr")
    createDir(tempRoot / ".repro")
    writeFile(destRoot / "usr" / "libfoo.so", "elf\n")
    writeFile(buildDir / "CMakeCache.txt", "cache\n")
    writeFile(tempRoot / ".repro" / "install.stamp", "")

    var act = action("cmake-install-foo", @["cmake"],
      cwd = tempRoot,
      outputs = @[".repro/install.stamp"],
      cacheable = true,
      dependencyPolicy = automaticMonitorGatheringPolicy(@[buildDir, destRoot]),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.declaredOutputs = @[destRoot]
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot / ".repro" / "install.stamp",
      buildDir / "CMakeCache.txt",
      destRoot / "usr" / "libfoo.so"]

    # Neither prefix survives: ``destRoot`` IS the write root, and
    # ``buildDir`` CONTAINS it.
    check act.honouredDerivedPrefixes().len == 0
    let reported = act.undeclaredSurvivingWrites(evidence)
    check reported.hasPath(destRoot / "usr" / "libfoo.so")
    check reported.hasPath(buildDir / "CMakeCache.txt")

  test "a derived prefix disjoint from the product is still honoured":
    ## The other half, and the reason the rule is disjointness rather than
    ## "no prefix ever exempts": the nimcache declaration this milestone
    ## added to ``nim.nim`` has to survive, or ``--restore-cached-outputs``
    ## is inert for every monitored ``nim c`` edge.
    ##
    ## A ``nim c`` edge carries no ``declaredOutputs`` at all, and its
    ## nimcache (``build/nimcache/<name>``) contains none of its declared
    ## outputs (``build/bin/<name>.exe``). Disjoint, so honoured. Asserted
    ## against the real shape rather than an abstract one, because "the
    ## nimcache still works" is a claim about that specific geometry.
    let tempRoot = createTempDir("repro-s7-nimshape", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "build" / "bin")
    createDir(tempRoot / "build" / "nimcache" / "hello")
    writeFile(tempRoot / "build" / "bin" / "hello.exe", "mz\n")
    writeFile(tempRoot / "build" / "nimcache" / "hello" / "hello.c", "int\n")

    var act = action("compile", @["nim"],
      cwd = tempRoot,
      outputs = @["build/bin/hello.exe"],
      cacheable = true,
      dependencyPolicy =
        automaticMonitorGatheringPolicy(@["build/nimcache/hello"]),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var evidence = PathSetEvidence()
    evidence.declaredOutputs = act.outputs
    evidence.monitorWrites = @[
      tempRoot / "build" / "bin" / "hello.exe",
      tempRoot / "build" / "nimcache" / "hello" / "hello.c"]
    check act.honouredDerivedPrefixes().len == 1
    check act.undeclaredSurvivingWrites(evidence).len == 0

    # And the passthrough gap closes itself: point the same edge's nimcache
    # at its own output directory — which ``nim.c``'s explicit ``nimcache =``
    # argument does not stop anyone doing — and the prefix stops being
    # honoured rather than silently exempting the binary's neighbours.
    var overreaching = act
    overreaching.dependencyPolicy =
      automaticMonitorGatheringPolicy(@["build/bin"])
    check overreaching.honouredDerivedPrefixes().len == 0

  test "a hermetic action stores blobs and RESTORES a deleted output":
    ## The property the milestone is about, through the real ``runBuild``
    ## with the gate ON. If the gate blocked this, the whole feature would
    ## be inert, so this case is as load-bearing as the negative ones.
    let tempRoot = createTempDir("repro-s7-restore", "")
    defer: removeDir(tempRoot)
    let fx = makeFixture(tempRoot, withUndeclared = false)

    let config = restoreConfig(fx.cacheRoot, gate = true)
    let first = runBuild(graph([fx.action]), config)
    checkpoint(first.results[0].stderr)
    check first.results[0].status == asSucceeded
    check first.results[0].launched
    check fileExists(fx.declaredOutput)

    # The published record carries payloads — without them there is nothing
    # to restore FROM, and this is the assertion that would have failed for
    # every one of the 181 records the CLI published before S7.
    let record = readRecord(dependencyEvidencePath(fx.cacheRoot, fx.action.id))
    check record.outputPayloadKind == opkCasBlobs

    removeFile(fx.declaredOutput)
    check not fileExists(fx.declaredOutput)

    let second = runBuild(graph([fx.action]), config)
    check second.results[0].cacheDecision == cdHit
    check second.results[0].status == asCacheHit
    check not second.results[0].launched
    check second.results[0].reason == "restored"
    check fileExists(fx.declaredOutput)
    check readFile(fx.declaredOutput) == "payload\n"

  test "an under-declared action is withheld from the CAS and RE-RUNS":
    ## Same engine, same flag, an action whose real product exceeds its
    ## declaration. The gate must turn this into a rebuild, and the rebuild
    ## must put the WHOLE product back — including the half no record ever
    ## described.
    let tempRoot = createTempDir("repro-s7-gated", "")
    defer: removeDir(tempRoot)
    let fx = makeFixture(tempRoot, withUndeclared = true)

    let config = restoreConfig(fx.cacheRoot, gate = true)
    let first = runBuild(graph([fx.action]), config)
    checkpoint(first.results[0].stderr)
    check first.results[0].status == asSucceeded
    check fileExists(fx.declaredOutput)
    check fileExists(fx.undeclaredOutput)

    let record = readRecord(dependencyEvidencePath(fx.cacheRoot, fx.action.id))
    check record.outputPayloadKind == opkMetadataOnly

    # Named, not silent. A withheld record looks exactly like a cold cache
    # from the outside, so the reason has to be on the record's evidence or
    # the next person measures a mystery.
    check first.results[0].evidence.diagnostics.anyIt(
      "output payloads withheld (S7)" in it and "extra.txt" in it)

    removeFile(fx.declaredOutput)
    removeFile(fx.undeclaredOutput)

    let second = runBuild(graph([fx.action]), config)
    check second.results[0].cacheDecision == cdMiss
    check second.results[0].status == asSucceeded
    check second.results[0].launched
    check fileExists(fx.declaredOutput)
    check fileExists(fx.undeclaredOutput)
    check readFile(fx.undeclaredOutput) == "extra\n"

  test "the cmake/meson install shape is withheld and its TREE survives":
    ## End-to-end, through the real ``runBuild``, on the shape the milestone
    ## is actually about — and the shape that passed the gate when this work
    ## was first submitted. An edge whose declared output is a stamp, whose
    ## product is a staged tree, and whose ``ignoredInputPrefixes`` name the
    ## tree it stages into.
    ##
    ## Before the disjointness rule this case reproduced the hazard exactly:
    ## ``unaccounted=0``, ``opkCasBlobs``, second decision ``cdHit``, the
    ## stamp back and the install tree silently gone. Now it must withhold.
    let tempRoot = createTempDir("repro-s7-install", "")
    defer: removeDir(tempRoot)
    let fx = makeInstallFixture(tempRoot)

    let config = restoreConfig(fx.cacheRoot, gate = true)
    let first = runBuild(graph([fx.action]), config)
    checkpoint(first.results[0].stderr)
    check first.results[0].status == asSucceeded
    check fileExists(fx.declaredOutput)
    check fileExists(fx.undeclaredOutput)

    let record = readRecord(dependencyEvidencePath(fx.cacheRoot, fx.action.id))
    check record.outputPayloadKind == opkMetadataOnly
    check first.results[0].evidence.diagnostics.anyIt(
      "output payloads withheld (S7)" in it and "libfoo.so" in it)

    # Delete the WHOLE product, stamp and staged tree alike, exactly as a
    # clean checkout with a warm cache would present it.
    removeFile(fx.declaredOutput)
    removeFile(fx.undeclaredOutput)

    let second = runBuild(graph([fx.action]), config)
    checkpoint(second.results[0].stderr)
    check second.results[0].cacheDecision == cdMiss
    check second.results[0].status == asSucceeded
    check second.results[0].launched
    check fileExists(fx.declaredOutput)
    # The assertion the rejected version failed. A restore would have put
    # back the stamp and nothing else.
    check fileExists(fx.undeclaredOutput)
    check readFile(fx.undeclaredOutput) == "elf\n"

  test "without the gate the same action is mis-restored, product missing":
    ## The hazard, produced on demand rather than asserted in prose. This is
    ## byte-for-byte the previous case with ``requireCompleteOutputEvidence``
    ## off — the configuration a two-line "just flip the literals" fix would
    ## have shipped.
    ##
    ## The engine reports ``asCacheHit`` / ``cdHit`` / ``reason="restored"``
    ## and the build succeeds. Half the product is gone.
    let tempRoot = createTempDir("repro-s7-hazard", "")
    defer: removeDir(tempRoot)
    let fx = makeFixture(tempRoot, withUndeclared = true)

    let config = restoreConfig(fx.cacheRoot, gate = false)
    let first = runBuild(graph([fx.action]), config)
    checkpoint(first.results[0].stderr)
    check first.results[0].status == asSucceeded
    check fileExists(fx.undeclaredOutput)

    let record = readRecord(dependencyEvidencePath(fx.cacheRoot, fx.action.id))
    check record.outputPayloadKind == opkCasBlobs

    removeFile(fx.declaredOutput)
    removeFile(fx.undeclaredOutput)

    let second = runBuild(graph([fx.action]), config)
    check second.results[0].cacheDecision == cdHit
    check second.results[0].status == asCacheHit
    check second.results[0].reason == "restored"
    check fileExists(fx.declaredOutput)
    # The whole point. A green build, a reported cache hit, and a tree that
    # is missing something the action really produces.
    check not fileExists(fx.undeclaredOutput)

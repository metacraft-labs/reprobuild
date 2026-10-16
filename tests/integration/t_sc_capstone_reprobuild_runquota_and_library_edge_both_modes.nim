## Cross-Repo-Source-Consumption SC-7 — CAPSTONE: a consumer whose test needs a
## sibling from-source EXECUTABLE (the ``reprobuild -> runquota:runquotad`` shape)
## AND one that links a sibling from-source LIBRARY (the ``native-recorder ->
## native-backend`` cdylib shape), both consumed transparently FROM SOURCE — no
## ``direnv``, no ``cd ../sib && just build`` prebuild — in BOTH develop mode AND
## lock-pinned mode, and both invalidated on the producer's source.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §1.1 (the whole deferred-wiring gap
## this campaign closes), §6 (corrected lock semantics — the producer builds from
## its OWN committed lock in lock-pinned mode), §7.1 (``reprobuild -> runquota``
## executable edge) + §7.2 (``native-recorder -> native-backend`` library edge).
## Milestone: ``Cross-Repo-Source-Consumption.milestones.org`` §SC-7.
##
## This is the STRING-surface capstone. It is the union of SC-5 (develop mode,
## both channels) and SC-6 (lock-pinned mode, both channels) into ONE test that
## proves the campaign's exit criterion end-to-end: the same consumer ``repro.nim``
## (a single build action that (a) runs a sibling EXECUTABLE by BARE NAME and (b)
## compiles+links+runs a C program against a sibling LIBRARY) is consumed from
## source in BOTH modes with NOTHING prebuilt, and a producer source edit rebuilds
## the consumer in BOTH modes.
##
## The two modes differ ONLY in how the producers are materialized (§5): develop
## mode resolves them through ``.repro/develop-overrides.toml`` -> a sibling
## checkout built in place; lock-pinned mode resolves them through the consumer's
## committed ``repro.lock`` -> a VCS fetch of the pinned revision (SC-6's
## ``fetchLockPinnedProducer``). The consumer ``repro.nim`` + consuming action are
## BYTE-IDENTICAL across the two modes (§5 "Same ``repro.nim`` + ``repro.lock``;
## only materialization differs"); only the presence of the overrides file vs the
## lock, and the on-disk-sibling vs the fetch, change. That invariance is the
## capstone claim, and this test asserts it by driving the SAME consumer sources
## through both mode setups.
##
## Fixture (built ``./build/bin/repro``, black-box; the checked-in recipes under
## ``tests/fixtures/sc7-capstone/`` copied into a fresh tempdir, so nothing
## touches $HOME or the checkout):
##
##   <scratch>/
##     develop/
##       exeprod/                     sibling EXECUTABLE producer (built in place)
##       libprod/                     sibling LIBRARY producer   (built in place)
##       consumer/                    NO lock; .repro/develop-overrides.toml -> both
##     lockpinned/
##       remotes/exeprod.git          real git repo (the exe producer "remote")
##       remotes/libprod.git          real git repo (the library producer "remote")
##       consumer/                    NO override, NO sibling checkout; ONLY a
##                                    committed repro.lock pinning both producers
##
## The consumer sources (``consumerRepro`` + ``main.c``) are the SAME text in both
## trees. The one consumer action:
##   1. runs the sibling EXECUTABLE by bare name (``exeprod``) -> build/exe.txt
##      (resolves ONLY via the SC-2 PATH splice of the from-source producer's
##      build/bin — no host ``exeprod``, no prebuilt binary),
##   2. compiles + links + runs a C program that ``#include <greeting.h>`` and
##      calls ``scprodlib_greeting()`` -> build/consumed.txt
##      (resolves ONLY via the SC-3 aux-channel splice onto
##      CPATH/LIBRARY_PATH/LD_LIBRARY_PATH — no -I/-L, no LD_LIBRARY_PATH set here).
##
## Assertions (per mode, both modes exercised):
##   1. ``repro build`` on the consumer exits 0.
##   2. BOTH producers were materialized FROM SOURCE by THIS RUN, with NOTHING
##      prebuilt (develop: ../exeprod/build/bin/exeprod + ../libprod/build/lib/*.so
##      absent before; lock-pinned: both FETCHED into the workspace-local cache by
##      this run, NEITHER checked out beside the consumer).
##   3. The exe marker carries the executable producer's unique stamp AND the lib
##      marker carries the library producer's unique stamp — BOTH channels resolved
##      from source in the SAME build.
##   4. Source invalidation: editing the LIBRARY producer's C source (develop: edit
##      the checkout; lock-pinned: commit + refresh the pin) and rebuilding yields
##      the NEW library stamp — the producer was rebuilt from the edited source in
##      BOTH modes (§4.3 / §5.2 "a changed pin invalidates the consumer").
##
## Falsifiability (per §SC-7 "restoring any prebuild-dependence makes the
## no-prebuild run fail"): a NO-PREBUILD guard is asserted directly — with the
## producer sources present but NO produced artifact and NO override/lock entry
## for one producer, the consume step MUST fail (the bare-name exe is not on PATH
## / the library header+symbol are not on the aux channels), proving the consume
## genuinely depends on the from-source splice and cannot be satisfied by any
## ambient prebuild. This is exercised inline (the ``noProducerEdge`` block). The
## build-impl falsifiability (dropping the PATH / aux-channel splice makes the
## consume fail) is inherited from SC-2/SC-3/SC-5/SC-6's own falsifiable seams and
## is re-confirmed for SC-7 by disabling a splice and observing this test fail.
##
## Declared producers and tools: every consuming edge names the producers it
## consumes plus the tools it runs in its tool-identity refs, and each producer
## edge names the tools it runs, as the SC-2/SC-3/SC-5 fixtures do. Package-level
## ``uses:`` is the DISCOVERY set; ADMISSION (build + splice) follows the selected
## edge's own declaration (Cross-Repo-Source-Consumption.md §4.2b.3, since
## 776517b31 "build: scope producer tools to consuming actions"). Without the refs
## the producers are never built and the consume step fails, which is the
## "under-declaring fails loudly" case of §4.2b.4, not a splice defect.
##
## Skip rule: ``cc``/``sh``/``git`` missing on PATH, or ``./build/bin/repro``
## unbuilt, or a non-Linux host (the ``.so`` layout assumed here is Linux; kept
## Linux-only to stay hermetic, matching SC-3/SC-5/SC-6).

import std/[os, osproc, strutils, unittest]

import repro_lock

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

# The executable producer's UNIQUE stamp — the built ``exeprod`` binary echoes
# exactly this (spelled in ``tests/fixtures/sc7-capstone/exeprod/repro.nim``).
# It cannot appear unless the sibling was built from source AND its
# binary ran (via the SC-2 PATH splice).
const exeStamp = "SC7-EXEPRODUCER-STAMP-9d1e4b"

# The library producer's UNIQUE stamp — the library function returns exactly
# this. It cannot appear unless the sibling library was built from source AND its
# symbol was linked + loaded (via the SC-3 aux channels).
const libStamp = "SC7-LIBPRODUCER-STAMP-6c2f80"
# The EDITED library stamps for the source-invalidation arm (assertion 4), one
# per mode so a mode cannot accidentally observe the other's edited artifact.
const libStampDevEdited = "SC7-LIBPRODUCER-STAMP-DEV-EDITED-1a7c33"
const libStampLockEdited = "SC7-LIBPRODUCER-STAMP-LOCK-EDITED-4b9d21"

# ---- The fixture recipes. ----
#
# The producers' and consumers' ``repro.nim`` files, the library header and the
# consumer's ``main.c`` are CHECKED IN under ``tests/fixtures/sc7-capstone/``
# and copied into the scratch tree, rather than written from string literals:
#
#   exeprod/repro.nim          the sibling EXECUTABLE producer (the
#                              runquota:runquotad shape); its binary echoes
#                              ``exeStamp``
#   libprod/repro.nim          the sibling LIBRARY producer (the native-backend
#   libprod/greeting.h         cdylib shape); ``greeting.c`` is written by this
#                              test, because each arm stamps it differently
#   consumer/repro.nim         ONE action consuming BOTH producers: runs
#   consumer/main.c            ``exeprod`` by bare name (SC-2) and compiles,
#                              links and runs ``main.c`` against the library
#                              with no -I/-L and no LD_LIBRARY_PATH (SC-3); the
#                              SAME files in both modes -- that invariance IS
#                              the capstone claim (§5 "only materialization
#                              differs")
#   noedge-consumer/repro.nim  the falsifiability consumer: runs ``exeprod``
#                              with no override and no lock naming it
#
# WHY FILES. The engine keys a recipe's provider compile and interface
# extraction on the recipe's bytes and runs them recipe-relative, so a
# byte-identical recipe at another path is served from the action cache. With
# the texts fixed on disk and the builds sharing the run-wide action cache, the
# producers' recipe compiles are paid once rather than on every run. Every
# edge in these recipes is ``cacheable = false``, so the producers and the
# consumer still EXECUTE on every build: assertion (2) -- materialized from
# source by THIS run -- does not depend on what the cache holds.
#
# The execute edge of this test declares every file there as an input
# (``testFixtureArtifacts`` in ``repro.nim``), so editing one re-runs the test.
const FixtureRoot = ReprobuildRepoRoot / "tests" / "fixtures" / "sc7-capstone"

proc copyFixture(relPath, destDir: string) =
  ## Copy ``FixtureRoot / relPath`` to ``destDir`` under its own file name.
  createDir(destDir)
  copyFile(FixtureRoot / relPath, destDir / extractFilename(relPath))

proc libProducerSource(stamp: string): string =
  "#include \"greeting.h\"\n" &
  "const char *scprodlib_greeting(void) { return \"" & stamp & "\"; }\n"

proc q(value: string): string = quoteShell(value)

var runCounter = 0

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  ## The SC-7 capstone runs several integration builds in one test binary.
  ## Capture each build's full output to a log, but emit a heartbeat while the
  ## subprocess runs so the test runner's idle-output deadline does not mistake
  ## a live long build for a hang.
  inc runCounter
  let shBin =
    block:
      let found = findExe("sh")
      if found.len > 0: found else: "sh"
  let logPath = getTempDir() / ("sc7-run-" & $getCurrentProcessId() &
    "-" & $runCounter & ".log")
  let shellLine = command & " > " & q(logPath) & " 2>&1"
  stdout.writeLine("[sc7] start: " & command)
  flushFile(stdout)
  let process = startProcess(shBin,
    args = ["-c", shellLine],
    # Every call site below passes an explicit `cwd`, so this default is not
    # reached today — but it is the last place in this file where the process
    # working directory could become a fixture input, and a future caller that
    # omits the argument should get THIS CHECKOUT rather than wherever the
    # runner was launched.
    workingDir = (if cwd.len > 0: cwd else: ReprobuildRepoRoot),
    options = {poUsePath})
  var elapsedMs = 0
  while true:
    result.code = process.peekExitCode()
    if result.code != -1:
      break
    sleep(1000)
    elapsedMs += 1000
    if elapsedMs mod 30_000 == 0:
      stdout.writeLine("[sc7] still running after " & $(elapsedMs div 1000) &
        "s: " & command)
      flushFile(stdout)
  process.close()
  if fileExists(logPath):
    result.output = readFile(logPath)
    try: removeFile(logPath)
    except OSError: discard
  stdout.writeLine("[sc7] finished exit=" & $result.code & " after " &
    $(elapsedMs div 1000) & "s")
  flushFile(stdout)

proc buildCmdFor(reproAbs, consumerRoot: string): string =
  ## No ``--action-cache-root``: the build uses the run-wide root
  ## (``REPROBUILD_ACTION_CACHE_ROOT``, exported by ``scripts/run_tests.sh``),
  ## so the fixture recipes' compiles are served from it. Nothing this test
  ## asserts can be served from it: every edge in the fixture recipes is
  ## ``cacheable = false``.
  q(reproAbs) & " build " & q(consumerRoot / "repro.nim") &
    " --tool-provisioning=path --daemon=off --log=quiet" &
    " --progress=quiet --measure=none"

# ---- git helpers for the lock-pinned mode "remotes" (SC-6 shape). ----
proc gitRun(gitBin: string; args: openArray[string]; repoDir: string) =
  var cmd = q(gitBin)
  for a in args:
    cmd.add(" ")
    cmd.add(q(a))
  let r = execCmdEx(cmd, options = {poUsePath}, workingDir = repoDir)
  doAssert r.exitCode == 0, "git " & args.join(" ") & " failed: " & r.output

proc gitInit(repoDir, gitBin: string) =
  gitRun(gitBin, ["init", "--quiet"], repoDir)
  gitRun(gitBin, ["config", "user.email", "sc7@example.invalid"], repoDir)
  gitRun(gitBin, ["config", "user.name", "SC7 Fixture"], repoDir)
  gitRun(gitBin, ["add", "-A"], repoDir)
  gitRun(gitBin, ["commit", "--quiet", "-m", "sc7 producer"], repoDir)

proc gitCommitAll(repoDir, gitBin, message: string) =
  gitRun(gitBin, ["add", "-A"], repoDir)
  gitRun(gitBin, ["commit", "--quiet", "-m", message], repoDir)

proc gitHead(repoDir, gitBin: string): string =
  let r = execCmdEx(q(gitBin) & " -C " & q(repoDir) & " rev-parse HEAD",
    options = {poUsePath})
  doAssert r.exitCode == 0, "git rev-parse HEAD failed: " & r.output
  r.output.strip()

proc writeConsumerLock(consumerRoot, exeUrl, exeRev, libUrl, libRev: string;
                       tag: string) =
  ## The consumer's committed repro.lock pinning BOTH producers by VCS
  ## coordinates + git-native integrity (SC-6 shape). ``tag`` distinguishes the
  ## inputsDigest per revision so a refreshed pin is a distinct lock.
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(),
    optimal: true,
    inputsDigest: inputsDigestOf("sc7-fixture-" & tag))
  ld.deps.add(LockedDep(
    name: "exeprod", path: "",
    coordinates: Coordinates(kind: ckVcs, url: exeUrl, gitRef: "main",
      revision: exeRev),
    integrity: gitObjectMultihash("sha1", exeRev),
    visibility: "public"))
  ld.deps.add(LockedDep(
    name: "libprod", path: "",
    coordinates: Coordinates(kind: ckVcs, url: libUrl, gitRef: "main",
      revision: libRev),
    integrity: gitObjectMultihash("sha1", libRev),
    visibility: "public"))
  writeFile(consumerRoot / "repro.lock", serializeLockedDependencies(ld))

suite "SC-7: capstone — consume sibling exe AND lib from source in BOTH modes":

  test "t_sc_capstone_reprobuild_runquota_and_library_edge_both_modes":
    let ccBin = findExe("cc")
    let shBin = findExe("sh")
    let gitBin = findExe("git")
    if not defined(linux):
      checkpoint("skipped — SC-7 test fixture assumes the Linux .so layout")
      skip()
    elif ccBin.len == 0 or shBin.len == 0 or gitBin.len == 0 or
        not fileExists(reproBinary):
      checkpoint("skipped — cc/sh/git missing on PATH or repro unbuilt")
      skip()
    else:
      let repoRoot = ReprobuildRepoRoot
        ## NOT `getCurrentDir()`: the repo root is a property of
        ## THIS CHECKOUT, not of the directory the runner happened
        ## to be launched from.
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc7-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # No host ``exeprod`` may satisfy the bare name by accident, and this test
      # sets NO aux env var — the ONLY way both consume steps resolve is via the
      # from-source splices of the freshly-built/fetched sibling dirs.
      check findExe("exeprod").len == 0

      # ============================================================
      # MODE A — DEVELOP (SC-5 shape): overrides -> sibling checkouts built in
      # place. Nothing prebuilt.
      # ============================================================
      block developMode:
        let root = absolutePath(scratch / "develop")
        createDir(root)

        let exeProdRoot = root / "exeprod"
        copyFixture("exeprod" / "repro.nim", exeProdRoot)

        let libProdRoot = root / "libprod"
        copyFixture("libprod" / "repro.nim", libProdRoot)
        copyFixture("libprod" / "greeting.h", libProdRoot)
        writeFile(libProdRoot / "greeting.c", libProducerSource(libStamp))

        let consumerRoot = root / "consumer"
        copyFixture("consumer" / "repro.nim", consumerRoot)
        copyFixture("consumer" / "main.c", consumerRoot)
        createDir(consumerRoot / ".repro")
        writeFile(consumerRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "exeprod"
local_path = "../exeprod"
state = "editable"
created_at = "2026-07-03T00:00:00Z"

[[override]]
package = "libprod"
local_path = "../libprod"
state = "editable"
created_at = "2026-07-03T00:00:00Z"
""")

        # Nothing prebuilt: assertion (2) measures whether THIS run produced them.
        let exeProducerBinary = exeProdRoot / "build" / "bin" /
          addFileExt("exeprod", ExeExt)
        let libProducerLibrary = libProdRoot / "build" / "lib" / "libscprodlib.so"
        check not fileExists(exeProducerBinary)
        check not fileExists(libProducerLibrary)

        let exeMarker = consumerRoot / "build" / "exe.txt"
        let libMarker = consumerRoot / "build" / "consumed.txt"

        let buildCmd = buildCmdFor(reproAbs, consumerRoot)

        checkpoint("develop (1): " & buildCmd)
        let (code, output) = run(buildCmd, repoRoot)
        checkpoint("develop exit=" & $code)
        checkpoint(output)
        check code == 0

        # (2) BOTH producers were materialized from source BY THIS RUN.
        check fileExists(exeProducerBinary)
        check fileExists(libProducerLibrary)

        # (3) Both channels consumed from source in the SAME build.
        check fileExists(exeMarker)
        check fileExists(libMarker)
        if fileExists(exeMarker):
          let got = readFile(exeMarker).strip()
          checkpoint("develop exe.txt=" & got)
          check got == exeStamp
        if fileExists(libMarker):
          let got = readFile(libMarker).strip()
          checkpoint("develop consumed.txt=" & got)
          check got == libStamp

        # (4) Source invalidation (develop): edit the library producer's C source;
        # rebuilding must rebuild the producer from the edited source and re-run
        # the consume step with the NEW stamp.
        writeFile(libProdRoot / "greeting.c", libProducerSource(libStampDevEdited))
        if fileExists(libMarker): removeFile(libMarker)
        checkpoint("develop (2, after producer source edit): " & buildCmd)
        let (code2, output2) = run(buildCmd, repoRoot)
        checkpoint("develop exit2=" & $code2)
        checkpoint(output2)
        check code2 == 0
        check fileExists(libMarker)
        if fileExists(libMarker):
          let got = readFile(libMarker).strip()
          checkpoint("develop consumed.txt(after edit)=" & got)
          check got == libStampDevEdited

      # ============================================================
      # MODE B — LOCK-PINNED (SC-6 shape): NO override, NO sibling checkout; the
      # committed repro.lock pins both producers -> VCS fetch of the pinned rev.
      # ============================================================
      block lockPinnedMode:
        let root = absolutePath(scratch / "lockpinned")
        createDir(root)

        # Producer "remotes" live under <root>/remotes (NOT beside the consumer),
        # so ``findSiblingProjectFile`` can NOT bypass the fetch.
        let remotes = root / "remotes"
        createDir(remotes)

        let exeRemote = remotes / "exeprod"
        copyFixture("exeprod" / "repro.nim", exeRemote)
        gitInit(exeRemote, gitBin)
        let exeRev = gitHead(exeRemote, gitBin)

        let libRemote = remotes / "libprod"
        copyFixture("libprod" / "repro.nim", libRemote)
        copyFixture("libprod" / "greeting.h", libRemote)
        writeFile(libRemote / "greeting.c", libProducerSource(libStamp))
        gitInit(libRemote, gitBin)
        let libRev = gitHead(libRemote, gitBin)

        let consumerRoot = root / "consumer"
        copyFixture("consumer" / "repro.nim", consumerRoot)
        copyFixture("consumer" / "main.c", consumerRoot)
        writeConsumerLock(consumerRoot, exeRemote, exeRev, libRemote, libRev, "v1")

        # NO develop overrides, NO sibling checkout beside the consumer.
        check not fileExists(consumerRoot / ".repro" / "develop-overrides.toml")
        check not dirExists(parentDir(consumerRoot) / "exeprod")
        check not dirExists(parentDir(consumerRoot) / "libprod")

        let producerCache = consumerRoot / ".repro" / "cross-repo-producers"
        let exeFetched = producerCache / "exeprod" / exeRev / "repro.nim"
        let libFetched = producerCache / "libprod" / libRev / "repro.nim"
        check not fileExists(exeFetched)
        check not fileExists(libFetched)

        let exeMarker = consumerRoot / "build" / "exe.txt"
        let libMarker = consumerRoot / "build" / "consumed.txt"

        let buildCmd = buildCmdFor(reproAbs, consumerRoot)

        checkpoint("lock-pinned (1): " & buildCmd)
        let (code, output) = run(buildCmd, repoRoot)
        checkpoint("lock-pinned exit=" & $code)
        checkpoint(output)
        check code == 0

        # (2) BOTH producers were FETCHED by THIS RUN and NEITHER checked out
        # beside the consumer.
        check fileExists(exeFetched)
        check fileExists(libFetched)
        check not dirExists(parentDir(consumerRoot) / "exeprod")
        check not dirExists(parentDir(consumerRoot) / "libprod")

        # (3) Both channels consumed from the FETCHED source in the SAME build.
        check fileExists(exeMarker)
        check fileExists(libMarker)
        if fileExists(exeMarker):
          let got = readFile(exeMarker).strip()
          checkpoint("lock-pinned exe.txt=" & got)
          check got == exeStamp
        if fileExists(libMarker):
          let got = readFile(libMarker).strip()
          checkpoint("lock-pinned consumed.txt=" & got)
          check got == libStamp

        # (4) Changed pin -> re-fetch + rebuild from the NEW revision (§5.2 "a
        # changed pin invalidates the consumer").
        writeFile(libRemote / "greeting.c", libProducerSource(libStampLockEdited))
        gitCommitAll(libRemote, gitBin, "sc7 producer edit")
        let libRev2 = gitHead(libRemote, gitBin)
        check libRev2 != libRev
        writeConsumerLock(consumerRoot, exeRemote, exeRev, libRemote, libRev2, "v2")
        if fileExists(libMarker): removeFile(libMarker)

        checkpoint("lock-pinned (2, after refreshed pin): " & buildCmd)
        let (code2, output2) = run(buildCmd, repoRoot)
        checkpoint("lock-pinned exit2=" & $code2)
        checkpoint(output2)
        check code2 == 0
        let libFetched2 = producerCache / "libprod" / libRev2 / "repro.nim"
        check fileExists(libFetched2)  # the NEW revision was fetched
        check fileExists(libMarker)
        if fileExists(libMarker):
          let got = readFile(libMarker).strip()
          checkpoint("lock-pinned consumed.txt(after refreshed pin)=" & got)
          check got == libStampLockEdited

      # ============================================================
      # FALSIFIABILITY — no-prebuild guard (§SC-7 "restoring any
      # prebuild-dependence makes the no-prebuild run fail"). With the producer
      # sources present but NO override / NO lock entry for ``exeprod``, the
      # bare-name executable cannot be materialized from source and is not on
      # PATH — and there is NO ambient prebuild that could satisfy it — so the
      # consume step MUST fail. This proves the consume genuinely depends on the
      # from-source splice this campaign wires, not on any prebuilt artifact.
      # ============================================================
      block noProducerEdge:
        let root = absolutePath(scratch / "noedge")
        createDir(root)

        # A sibling exe producer checkout DOES exist beside the consumer (so this
        # is not merely "the sibling is missing"), but the consumer declares NO
        # override and NO lock entry for it — so ``resolveProducerBinding`` yields
        # ``pbkNotProducer`` and nothing is built/spliced for ``exeprod``.
        let exeProdRoot = root / "exeprod"
        copyFixture("exeprod" / "repro.nim", exeProdRoot)

        # A minimal consumer that ONLY runs the bare-name exe (no library, to
        # isolate the exe channel), with NO override + NO lock naming exeprod.
        let consumerRoot = root / "consumer"
        copyFixture("noedge-consumer" / "repro.nim", consumerRoot)

        let exeMarker = consumerRoot / "build" / "exe.txt"
        let buildCmd = buildCmdFor(reproAbs, consumerRoot)
        checkpoint("no-producer-edge (falsifiability): " & buildCmd)
        let (code, output) = run(buildCmd, repoRoot)
        checkpoint("no-producer-edge exit=" & $code)
        checkpoint(output)
        # exeprod is not a producer here (no override, no lock) and there is no
        # prebuilt / host binary -> the bare-name consume step must fail.
        check code != 0
        check not fileExists(exeMarker)

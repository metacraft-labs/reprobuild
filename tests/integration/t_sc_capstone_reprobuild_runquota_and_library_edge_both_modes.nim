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
## Fixture (built ``./build/bin/repro``, black-box; every path in a fresh tempdir
## so nothing touches $HOME):
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
# exactly this. It cannot appear unless the sibling was built from source AND its
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

# ---- The sibling EXECUTABLE producer repo (the runquota:runquotad shape). ----
const exeProducerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package exeprod:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable exeprod:
    name: "exeprod"

  build:
    discard shell(
      command = "mkdir -p build/bin && " &
        "printf '#!/bin/sh\necho """ & exeStamp & """\n' > build/bin/exeprod && " &
        "chmod +x build/bin/exeprod",
      actionId = "exeprod.build.exeprod",
      extraOutputs = @["build/bin/exeprod"])
"""

# ---- The sibling LIBRARY producer repo (the native-backend cdylib shape). ----
const libProducerHeader = """
#ifndef SCPRODLIB_GREETING_H
#define SCPRODLIB_GREETING_H
const char *scprodlib_greeting(void);
#endif
"""

proc libProducerSource(stamp: string): string =
  "#include \"greeting.h\"\n" &
  "const char *scprodlib_greeting(void) { return \"" & stamp & "\"; }\n"

const libProducerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package libprod:
  defaultToolProvisioning "path"

  uses:
    "sh"

  library scprodlib:
    kind: shared

  build:
    discard shell(
      command = "mkdir -p build/lib build/include && " &
        "cc -shared -fPIC -o build/lib/libscprodlib.so greeting.c && " &
        "cp greeting.h build/include/greeting.h",
      actionId = "libprod.build.scprodlib",
      extraInputs = @["greeting.c", "greeting.h"],
      extraOutputs = @["build/lib/libscprodlib.so", "build/include/greeting.h"],
      cacheable = false)
"""

# ---- The consuming C program. #include <greeting.h> (via CPATH), calls the
# library function (linked via -lscprodlib on LIBRARY_PATH, loaded via
# LD_LIBRARY_PATH), writes the returned stamp to build/consumed.txt. ----
const consumerSource = """
#include <stdio.h>
#include <greeting.h>
int main(void) {
  FILE *f = fopen("build/consumed.txt", "w");
  if (!f) return 2;
  fputs(scprodlib_greeting(), f);
  fclose(f);
  return 0;
}
"""

# ---- The consumer repo. ONE action consumes BOTH producers: invokes the sibling
# EXECUTABLE by bare name (SC-2) AND compiles/links/runs against the sibling
# LIBRARY (SC-3), WITHOUT any -I/-L path and WITHOUT any LD_LIBRARY_PATH — it only
# works if BOTH the SC-2 PATH splice and the SC-3 aux-channel splice fire. This
# SAME text is used verbatim in the develop-mode tree AND the lock-pinned tree —
# that invariance IS the capstone claim (§5 "only materialization differs"). ----
const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "exeprod"
    "libprod"

  build:
    discard shell(
      command = "mkdir -p build && " &
        "exeprod > build/exe.txt && " &
        "cc -o build/consume main.c -lscprodlib && " &
        "./build/consume",
      actionId = "consumer.build.consume",
      extraInputs = @["main.c"],
      extraOutputs = @["build/exe.txt", "build/consume", "build/consumed.txt"],
      cacheable = false)
"""

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

proc buildCmdFor(reproAbs, consumerRoot, cacheRoot: string): string =
  q(reproAbs) & " build " & q(consumerRoot / "repro.nim") &
    " --tool-provisioning=path --daemon=off --log=quiet" &
    " --progress=quiet --measure=none" &
    " --action-cache-root=" & q(cacheRoot)

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
        createDir(exeProdRoot)
        writeFile(exeProdRoot / "repro.nim", exeProducerRepro)

        let libProdRoot = root / "libprod"
        createDir(libProdRoot)
        writeFile(libProdRoot / "repro.nim", libProducerRepro)
        writeFile(libProdRoot / "greeting.h", libProducerHeader)
        writeFile(libProdRoot / "greeting.c", libProducerSource(libStamp))

        let consumerRoot = root / "consumer"
        createDir(consumerRoot)
        writeFile(consumerRoot / "repro.nim", consumerRepro)
        writeFile(consumerRoot / "main.c", consumerSource)
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

        # Hermetic action-cache root (SC-5/SC-6): a fresh empty per-test cache so
        # the test is immune to a co-tenant-bloated shared cache and does not
        # pollute it. (highest-precedence ``--action-cache-root``,
        # ``repro_cli_support.nim:377``.)
        let cacheRoot = absolutePath(scratch / "develop-cache")
        createDir(cacheRoot)
        let buildCmd = buildCmdFor(reproAbs, consumerRoot, cacheRoot)

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
        createDir(exeRemote)
        writeFile(exeRemote / "repro.nim", exeProducerRepro)
        gitInit(exeRemote, gitBin)
        let exeRev = gitHead(exeRemote, gitBin)

        let libRemote = remotes / "libprod"
        createDir(libRemote)
        writeFile(libRemote / "repro.nim", libProducerRepro)
        writeFile(libRemote / "greeting.h", libProducerHeader)
        writeFile(libRemote / "greeting.c", libProducerSource(libStamp))
        gitInit(libRemote, gitBin)
        let libRev = gitHead(libRemote, gitBin)

        let consumerRoot = root / "consumer"
        createDir(consumerRoot)
        writeFile(consumerRoot / "repro.nim", consumerRepro)
        writeFile(consumerRoot / "main.c", consumerSource)
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

        let cacheRoot = absolutePath(scratch / "lockpinned-cache")
        createDir(cacheRoot)
        let buildCmd = buildCmdFor(reproAbs, consumerRoot, cacheRoot)

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
        createDir(exeProdRoot)
        writeFile(exeProdRoot / "repro.nim", exeProducerRepro)

        let consumerRoot = root / "consumer"
        createDir(consumerRoot)
        # A minimal consumer that ONLY runs the bare-name exe (no library, to
        # isolate the exe channel), with NO override + NO lock naming exeprod.
        writeFile(consumerRoot / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "exeprod"

  build:
    discard shell(
      command = "mkdir -p build && exeprod > build/exe.txt",
      actionId = "consumer.build.consume",
      extraOutputs = @["build/exe.txt"],
      cacheable = false)
""")

        let exeMarker = consumerRoot / "build" / "exe.txt"
        let cacheRoot = absolutePath(scratch / "noedge-cache")
        createDir(cacheRoot)
        let buildCmd = buildCmdFor(reproAbs, consumerRoot, cacheRoot)
        checkpoint("no-producer-edge (falsifiability): " & buildCmd)
        let (code, output) = run(buildCmd, repoRoot)
        checkpoint("no-producer-edge exit=" & $code)
        checkpoint(output)
        # exeprod is not a producer here (no override, no lock) and there is no
        # prebuilt / host binary -> the bare-name consume step must fail.
        check code != 0
        check not fileExists(exeMarker)

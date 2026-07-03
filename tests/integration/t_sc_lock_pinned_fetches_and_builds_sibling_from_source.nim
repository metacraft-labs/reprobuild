## Cross-Repo-Source-Consumption SC-6 — lock-pinned VCS-sibling from-source
## consumption end-to-end (BOTH channels).
##
## With NO develop override, the consumer's committed ``repro.lock``
## (``repro_lock.nim:135-149``) pins a sibling PRODUCER project as a ``LockedDep``
## carrying its VCS ``Coordinates`` (``url`` + ``revision``) + ``integrity``.
## ``repro build`` on the consumer must — with the producer NOT checked out on
## disk anywhere beside the consumer — FETCH the producer's VCS at the pinned
## revision, VERIFY it against the locked integrity, build its executable AND
## library edge from the fetched source, and consume both, identically to
## develop mode from the consuming action's perspective.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §5.2 (lock-pinned mode) + §6
## (corrected lock semantics; the producer builds from its OWN committed lock).
## Milestone: ``Cross-Repo-Source-Consumption.milestones.org`` §SC-6.
##
## The gap SC-6 closes: before SC-6 the SC-2/SC-3 splice pre-pass only spliced a
## lock-pinned producer when its checkout was ALREADY on disk beside the consumer
## (``findSiblingProjectFile``); a sibling reachable ONLY through the pinned lock
## was never fetched, so lock-pinned consumption without a sibling checkout on
## disk could not build the producer from source. SC-6 adds
## ``fetchLockPinnedProducer`` (``repro_cli_support``) — a VCS fetch at the
## pinned revision + integrity verification, wired into the SC-2/SC-3 pre-pass'
## ``pbkLockPinned`` branch — so the producer's own repo source at the pinned
## revision is materialized and built.
##
## Fixture (built ``./build/bin/repro``, black-box; every path in a fresh
## tempdir so nothing touches $HOME):
##
##   <scratch>/
##     remotes/
##       exeprod.git/     a real git checkout (the exe producer "remote")
##                        repro.nim declares ``executable exeprod`` + build edge
##       libprod.git/     a real git checkout (the library producer "remote")
##                        repro.nim declares ``library scprodlib`` (shared)
##                        + greeting.{h,c}
##     consumer/          the CONSUMER project repo — NO develop override, NO
##                        sibling checkout on disk; ONLY a committed repro.lock
##                        pinning exeprod + libprod at their HEAD revisions with
##                        their git-sha1 integrities
##       repro.nim        ``uses: "exeprod"`` + ``uses: "libprod"`` in ONE action
##       main.c           #include <greeting.h>, calls scprodlib_greeting()
##       repro.lock       LockedDep pins for BOTH producers (url = the .git repo,
##                        revision = HEAD, integrity = git-sha1:<HEAD>)
##
## The one consumer action (identical to SC-5's, but resolved via the LOCK, not
## a develop override):
##   1. runs the sibling EXECUTABLE by bare name (``exeprod``) -> build/exe.txt
##      (resolves only via the SC-2 PATH splice of the FETCHED producer's
##      build/bin),
##   2. compiles + links + runs a C program against the sibling LIBRARY
##      (``cc main.c -lscprodlib`` then ``./build/consume``) -> build/consumed.txt
##      (resolves only via the SC-3 aux-channel splice of the FETCHED producer's
##      realized library/include dirs onto CPATH/LIBRARY_PATH/LD_LIBRARY_PATH).
##
## Assertions:
##   1. ``repro build`` on the consumer exits 0 (the producers were fetched at the
##      pinned revision, verified, built from source, and consumed).
##   2. Each producer was FETCHED into the workspace-local cache BY THIS RUN
##      (``consumer/.repro/cross-repo-producers/<name>/<rev>/repro.nim`` — absent
##      before), and NEITHER producer was checked out beside the consumer.
##   3. The exe marker carries the executable producer's unique stamp AND the lib
##      marker carries the library producer's unique stamp — proving BOTH channels
##      resolved from the FETCHED source in the SAME build.
##   4. A CHANGED pin (a new commit + refreshed lock revision/integrity)
##      re-fetches the new revision and consumes the NEW producer source: editing
##      the library producer, committing, refreshing the lock's revision +
##      integrity, and rebuilding yields the NEW library stamp.
##
## Falsifiability (per §SC-6):
##   * Integrity refuse: tampering the locked ``integrity`` to a wrong value makes
##     ``fetchLockPinnedProducer`` FAIL the fetch (``repro build`` exits non-zero,
##     the consume markers are not produced).
##   * Corrupted LockedDep: removing the producer's ``LockedDep`` entirely leaves
##     the producer unresolved (``pbkNotProducer``), so the bare-name executable
##     is not on PATH and the library header is not on CPATH → the consume step
##     fails.
##   Both are exercised inline (assertions 5 + 6). The build-impl falsifiability
##   (dropping the splice) is inherited from SC-2/SC-3's own falsifiable seams.
##
## Skip rule: ``cc``/``sh``/``git`` missing on PATH, or ``./build/bin/repro``
## unbuilt, or a non-Linux host (the ``.so`` layout assumed here is Linux; kept
## Linux-only to stay hermetic, matching SC-3/SC-5).

import std/[os, osproc, strutils, unittest]

import repro_lock

const reproBinary = "./build/bin/repro"

# The executable producer's UNIQUE stamp — the built ``exeprod`` binary echoes
# exactly this. It cannot appear unless the sibling was FETCHED at the pinned
# revision, built from source, AND its binary ran (via the SC-2 PATH splice).
const exeStamp = "SC6-EXEPRODUCER-STAMP-7f2a9c"

# The library producer's UNIQUE stamp — the library function returns exactly
# this. It cannot appear unless the sibling library was FETCHED, built from
# source, AND its symbol was linked + loaded (via the SC-3 aux channels).
const libStamp = "SC6-LIBPRODUCER-STAMP-d41b08"
# The EDITED library stamp for the refreshed-pin arm (assertion 4).
const libStampEdited = "SC6-LIBPRODUCER-STAMP-EDITED-9a3f57"

# ---- The sibling EXECUTABLE producer repo (SC-2 shape). ----
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

# ---- The sibling LIBRARY producer repo (SC-3 shape). ----
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

# ---- The consuming C program (SC-3 shape). ----
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

# ---- The consumer repo. ONE action consumes BOTH producers (SC-5 shape) but
# with NO develop override — resolution flows through the committed repro.lock. -
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

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc gitInit(repoDir, gitBin: string) =
  ## Turn a directory into a committed git repo whose HEAD is the producer
  ## revision the lock pins. A single deterministic commit; identity is set
  ## locally so the test does not depend on a host git config.
  proc git(args: openArray[string]) =
    var cmd = q(gitBin)
    for a in args:
      cmd.add(" ")
      cmd.add(q(a))
    let r = execCmdEx(cmd, options = {poUsePath}, workingDir = repoDir)
    doAssert r.exitCode == 0, "git " & args.join(" ") & " failed: " & r.output
  git(["init", "--quiet"])
  git(["config", "user.email", "sc6@example.invalid"])
  git(["config", "user.name", "SC6 Fixture"])
  git(["add", "-A"])
  git(["commit", "--quiet", "-m", "sc6 producer"])

proc gitHead(repoDir, gitBin: string): string =
  let r = execCmdEx(q(gitBin) & " -C " & q(repoDir) & " rev-parse HEAD",
    options = {poUsePath})
  doAssert r.exitCode == 0, "git rev-parse HEAD failed: " & r.output
  r.output.strip()

proc gitCommitAll(repoDir, gitBin, message: string) =
  proc git(args: openArray[string]) =
    var cmd = q(gitBin)
    for a in args:
      cmd.add(" ")
      cmd.add(q(a))
    let r = execCmdEx(cmd, options = {poUsePath}, workingDir = repoDir)
    doAssert r.exitCode == 0, "git " & args.join(" ") & " failed: " & r.output
  git(["add", "-A"])
  git(["commit", "--quiet", "-m", message])

proc writeConsumerLock(consumerRoot, exeUrl, exeRev, libUrl, libRev: string) =
  ## The consumer's committed repro.lock pinning BOTH producers by VCS
  ## coordinates + git-native integrity (the commit id IS the integrity for a
  ## content-addressed git checkout, ``gitObjectMultihash``).
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(),
    optimal: true,
    inputsDigest: inputsDigestOf("sc6-fixture"))
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

suite "SC-6: lock-pinned fetches and builds sibling from source":

  test "t_sc_lock_pinned_fetches_and_builds_sibling_from_source":
    let ccBin = findExe("cc")
    let shBin = findExe("sh")
    let gitBin = findExe("git")
    if not defined(linux):
      checkpoint("skipped — SC-6 test fixture assumes the Linux .so layout")
      skip()
    elif ccBin.len == 0 or shBin.len == 0 or gitBin.len == 0 or
        not fileExists(reproBinary):
      checkpoint("skipped — cc/sh/git missing on PATH or repro unbuilt")
      skip()
    else:
      let repoRoot = getCurrentDir()
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc6-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- The producer "remotes" — real git repos the lock pins. They live
      # under <scratch>/remotes, NOT one level up from the consumer, so there is
      # NO sibling checkout on disk beside the consumer and the ONLY way to reach
      # the producers is by fetching the pinned revision from the locked url. ----
      let remotes = absolutePath(scratch / "remotes")
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

      # ---- The CONSUMER project. NO develop override, NO sibling checkout —
      # ONLY a committed repro.lock pinning both producers. ----
      let consumerRoot = absolutePath(scratch / "consumer")
      createDir(consumerRoot)
      writeFile(consumerRoot / "repro.nim", consumerRepro)
      writeFile(consumerRoot / "main.c", consumerSource)
      writeConsumerLock(consumerRoot, exeRemote, exeRev, libRemote, libRev)

      # There must be NO develop overrides file (this is lock-pinned mode) and NO
      # sibling checkout beside the consumer that ``findSiblingProjectFile`` could
      # pick up (which would bypass the SC-6 fetch).
      check not fileExists(consumerRoot / ".repro" / "develop-overrides.toml")
      check not dirExists(parentDir(consumerRoot) / "exeprod")
      check not dirExists(parentDir(consumerRoot) / "libprod")

      # Nothing prebuilt, no host ``exeprod`` that could satisfy the bare name.
      check findExe("exeprod").len == 0

      let producerCache = consumerRoot / ".repro" / "cross-repo-producers"
      let exeFetched = producerCache / "exeprod" / exeRev / "repro.nim"
      let libFetched = producerCache / "libprod" / libRev / "repro.nim"
      check not fileExists(exeFetched)
      check not fileExists(libFetched)

      let exeMarker = consumerRoot / "build" / "exe.txt"
      let libMarker = consumerRoot / "build" / "consumed.txt"
      for m in [exeMarker, libMarker]:
        if fileExists(m):
          removeFile(m)

      # Hermetic action-cache root (see SC-2/SC-3/SC-5): a fresh empty per-test
      # cache under this test's scratch (highest-precedence
      # ``--action-cache-root`` flag, ``repro_cli_support.nim:377``) so the test
      # is immune to a co-tenant-bloated shared ``~/.cache/repro/action-cache``
      # (which would wedge the build on a full-file scan) and does not pollute it.
      let cacheRoot = absolutePath(scratch / "action-cache-root")
      createDir(cacheRoot)
      let buildCmd = q(reproAbs) & " build " & q(consumerRoot / "repro.nim") &
        " --tool-provisioning=path --daemon=off --log=quiet" &
        " --progress=quiet --report=none" &
        " --action-cache-root=" & q(cacheRoot)

      # ---- (1) Build the consumer. The SC-6 pre-pass must FETCH both producers
      # at the pinned revision, verify integrity, build them from source, and
      # splice the exe bin dir onto PATH + the lib dirs onto the aux channels. ----
      checkpoint("running (1): " & buildCmd)
      let (code, output) = run(buildCmd, repoRoot)
      checkpoint("exit=" & $code)
      checkpoint(output)
      check code == 0

      # (2) BOTH producers were FETCHED into the workspace-local cache BY THIS
      # RUN, and NEITHER was checked out beside the consumer.
      check fileExists(exeFetched)
      check fileExists(libFetched)
      check not dirExists(parentDir(consumerRoot) / "exeprod")
      check not dirExists(parentDir(consumerRoot) / "libprod")

      # (3) The consumer consumed BOTH from the fetched source.
      check fileExists(exeMarker)
      check fileExists(libMarker)
      if fileExists(exeMarker):
        let exeConsumed = readFile(exeMarker).strip()
        checkpoint("exe.txt=" & exeConsumed)
        check exeConsumed == exeStamp
      if fileExists(libMarker):
        let libConsumed = readFile(libMarker).strip()
        checkpoint("consumed.txt=" & libConsumed)
        check libConsumed == libStamp

      # ---- (4) Changed pin -> re-fetch + rebuild from the NEW revision. Edit the
      # library producer's source, commit (a new revision), refresh the consumer
      # lock to the new revision + integrity, and rebuild: the consumer must fetch
      # the NEW revision and consume the NEW library stamp (§5.2 "a changed pin
      # invalidates the consumer"). ----
      writeFile(libRemote / "greeting.c", libProducerSource(libStampEdited))
      gitCommitAll(libRemote, gitBin, "sc6 producer edit")
      let libRev2 = gitHead(libRemote, gitBin)
      check libRev2 != libRev
      writeConsumerLock(consumerRoot, exeRemote, exeRev, libRemote, libRev2)
      if fileExists(libMarker):
        removeFile(libMarker)

      checkpoint("running (2, after refreshed pin): " & buildCmd)
      let (code2, output2) = run(buildCmd, repoRoot)
      checkpoint("exit2=" & $code2)
      checkpoint(output2)
      check code2 == 0
      let libFetched2 = producerCache / "libprod" / libRev2 / "repro.nim"
      check fileExists(libFetched2)  # the NEW revision was fetched
      check fileExists(libMarker)
      if fileExists(libMarker):
        let libConsumed2 = readFile(libMarker).strip()
        checkpoint("consumed.txt(after refreshed pin)=" & libConsumed2)
        check libConsumed2 == libStampEdited

      # ---- (5) Falsifiability — integrity refuse. Tamper the locked integrity to
      # a wrong (but well-formed) value: ``fetchLockPinnedProducer`` must REFUSE
      # the fetch, so ``repro build`` fails and the consume markers are not
      # produced. Use a fresh consumer clone so the earlier verified cache does
      # not mask the tamper. ----
      block integrityRefuse:
        let tamperRoot = absolutePath(scratch / "consumer-tamper")
        createDir(tamperRoot)
        writeFile(tamperRoot / "repro.nim", consumerRepro)
        writeFile(tamperRoot / "main.c", consumerSource)
        # A well-formed but WRONG integrity for exeprod (a different sha).
        var ld = LockedDependencies(
          schema: "reprobuild.solved-graph-lock.v2",
          platform: currentPlatformId(), optimal: true,
          inputsDigest: inputsDigestOf("sc6-fixture-tamper"))
        ld.deps.add(LockedDep(
          name: "exeprod", path: "",
          coordinates: Coordinates(kind: ckVcs, url: exeRemote, gitRef: "main",
            revision: exeRev),
          integrity: "git-sha1:0000000000000000000000000000000000000000",
          visibility: "public"))
        ld.deps.add(LockedDep(
          name: "libprod", path: "",
          coordinates: Coordinates(kind: ckVcs, url: libRemote, gitRef: "main",
            revision: libRev2),
          integrity: gitObjectMultihash("sha1", libRev2),
          visibility: "public"))
        writeFile(tamperRoot / "repro.lock", serializeLockedDependencies(ld))
        let tamperCache = absolutePath(scratch / "tamper-cache")
        createDir(tamperCache)
        let tamperCmd = q(reproAbs) & " build " &
          q(tamperRoot / "repro.nim") &
          " --tool-provisioning=path --daemon=off --log=quiet" &
          " --progress=quiet --report=none" &
          " --action-cache-root=" & q(tamperCache)
        checkpoint("running (tamper): " & tamperCmd)
        let (tcode, toutput) = run(tamperCmd, repoRoot)
        checkpoint("tamper exit=" & $tcode)
        checkpoint(toutput)
        # The integrity check refuses the fetch -> build fails.
        check tcode != 0
        check not fileExists(tamperRoot / "build" / "exe.txt")
        check toutput.contains("integrity")

      # ---- (6) Falsifiability — corrupted/removed LockedDep. Drop the exeprod
      # LockedDep entirely: the selector resolves to ``pbkNotProducer`` (no
      # override, no lock entry), so the bare-name executable is not fetched / not
      # on PATH and the consume step fails. ----
      block missingLockedDep:
        let missRoot = absolutePath(scratch / "consumer-missing")
        createDir(missRoot)
        writeFile(missRoot / "repro.nim", consumerRepro)
        writeFile(missRoot / "main.c", consumerSource)
        var ld = LockedDependencies(
          schema: "reprobuild.solved-graph-lock.v2",
          platform: currentPlatformId(), optimal: true,
          inputsDigest: inputsDigestOf("sc6-fixture-missing"))
        # Only libprod is pinned; exeprod's LockedDep is intentionally absent.
        ld.deps.add(LockedDep(
          name: "libprod", path: "",
          coordinates: Coordinates(kind: ckVcs, url: libRemote, gitRef: "main",
            revision: libRev2),
          integrity: gitObjectMultihash("sha1", libRev2),
          visibility: "public"))
        writeFile(missRoot / "repro.lock", serializeLockedDependencies(ld))
        let missCache = absolutePath(scratch / "missing-cache")
        createDir(missCache)
        let missCmd = q(reproAbs) & " build " &
          q(missRoot / "repro.nim") &
          " --tool-provisioning=path --daemon=off --log=quiet" &
          " --progress=quiet --report=none" &
          " --action-cache-root=" & q(missCache)
        checkpoint("running (missing exeprod LockedDep): " & missCmd)
        let (mcode, moutput) = run(missCmd, repoRoot)
        checkpoint("missing exit=" & $mcode)
        checkpoint(moutput)
        # exeprod is unresolved -> the bare-name consume step fails.
        check mcode != 0
        check not fileExists(missRoot / "build" / "exe.txt")

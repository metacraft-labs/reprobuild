## Cross-Repo-Source-Consumption SC-10 — CAPSTONE for the TYPED consumer surface.
##
## A consumer consumes a sibling workspace PROJECT's exported ``executable … cli:``
## as a TYPED call ``producer.tool(args)`` (``sctypedexe.serve(socket = ...)``,
## the §9.5 worked-example shape) AND a sibling's exported ``library`` as a typed
## library reference (its schema imported into scope, its ``.so`` linked/loaded
## through the SC-3 aux channels) — BOTH consumed transparently FROM SOURCE (no
## ``direnv``, no ``cd ../sib && just build`` prebuild) in BOTH develop mode AND
## lock-pinned mode, and BOTH invalidated on the producer's source.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §9.4 (a typed call lowers to the
## SAME ``recordToolInvocation`` build action as a string ``uses:`` and resolves
## the producer through the SAME SC build-time seam) + §9.5 (the worked typed
## example: ``runquota.runquotad.serve(...)``). Milestone:
## ``Cross-Repo-Source-Consumption.milestones.org`` §SC-10.
##
## This is the TYPED analogue of SC-7 (the string-surface capstone). The
## difference is ENTIRELY in the consumer's ``repro.nim``: where SC-7 invoked the
## sibling executable by a bare-name ``shell(command = "exeprod > …")`` string,
## SC-10 invokes it as a TYPED call ``sctypedexe.serve(socket = …)`` whose command
## name (``serve``) and flag (``socket``) are checked at consumer MACRO EXPANSION
## against the producer's IMPORTED CLI schema (the SC-8 export-by-default contract
## + the SC-9 ``usesImportCode`` workspace-schema import). That typed call then
## lowers to the SAME ``recordToolInvocation`` action a string ref would, so the
## from-source producer build + splice + invalidation come entirely from
## SC-1..SC-6 (§9.4 "both modes come free from SC"). SC-10 asserts the whole path
## end-to-end through the typed surface.
##
## Two layers are proven jointly here:
##   * COMPILE-TIME (SC-8/SC-9): the consumer ``repro.nim`` typed calls only
##     compile because the sibling producer's ``executable sctypedexe: cli:``
##     schema was discovered (``../sctypedexe/repro.nim`` relative to the
##     consumer source) and imported at the consumer's macro expansion. A
##     MISTYPED command / flag is a COMPILE error (asserted by a compiled-in
##     falsifiability control, ``-d:scTyped10Mistyped``).
##   * BUILD-TIME (SC-1..SC-6): the typed call's lowered action resolves the
##     producer through the develop-override / ``LockedDep`` seam, builds the
##     sibling from source, splices the exe ``build/bin`` dir onto ``PATH`` and
##     the library dirs onto CPATH/LIBRARY_PATH/LD_LIBRARY_PATH, and folds the
##     producer's action-hash + source identity into the consumer cache key.
##
## Fixture (built ``./build/bin/repro``, black-box; every path in a fresh tempdir
## so nothing touches $HOME):
##
##   <scratch>/
##     develop/
##       sctypedexe/    sibling EXECUTABLE producer (executable … cli: + build:)
##       sctypedlib/    sibling LIBRARY producer     (library + build:)
##       consumer/      NO lock; .repro/develop-overrides.toml -> both siblings;
##                      repro.nim makes the TYPED calls
##     lockpinned/
##       sctypedexe/    sibling checkout (present for the SC-9 COMPILE-TIME typed
##                      schema import) — but resolved at BUILD TIME through the
##                      consumer's committed repro.lock LockedDep (pbkLockPinned),
##                      NOT a develop override
##       sctypedlib/    ditto
##       consumer/      NO override; a committed repro.lock pinning both producers
##                      -> the SC-6 lock-pinned resolution/build path
##
## The consumer ``repro.nim`` (the TYPED calls) + ``main.c`` are BYTE-IDENTICAL
## text across the two mode trees — that invariance IS the capstone claim (§5
## "same repro.nim + repro.lock; only materialization differs"); only the
## overrides-file-vs-lock and the resolution mode change.
##
## The one consumer action (a typed exe call + typed-linked library consume):
##   1. TYPED call ``sctypedexe.serve(socket = "build/exe.txt", …)`` -> lowers to
##      ``sctypedexe serve --socket build/exe.txt`` (resolved ONLY via the SC-2
##      PATH splice of the from-source producer's build/bin — no host binary, no
##      prebuilt binary). The producer script writes its unique stamp to the
##      ``--socket`` path.
##   2. a follow-on shell action compiles + links + runs a C program that
##      ``#include <greeting.h>`` and calls ``sctypedlib_greeting()`` -> the lib
##      producer's stamp lands in build/consumed.txt (resolved ONLY via the SC-3
##      aux-channel splice — no -I/-L, no LD_LIBRARY_PATH set here). The library
##      producer is named ``uses: "sctypedlib"`` so the SC-9 import brings its
##      package const into scope (the typed library reference) AND the SC-3 splice
##      threads its realized dirs onto the aux channels.
##
## Assertions (per mode, both modes exercised):
##   1. ``repro build`` on the consumer exits 0 (the typed calls compiled AND the
##      from-source producers built + spliced).
##   2. BOTH producers were materialized FROM SOURCE by THIS RUN, nothing
##      prebuilt (the exe binary + the lib .so were absent before this run).
##   3. The exe marker carries the executable producer's unique stamp (the TYPED
##      call resolved to the sibling's freshly-built binary via the PATH splice)
##      AND the lib marker carries the library producer's stamp (linked/loaded
##      via the aux channels).
##   4. Source invalidation: editing the LIBRARY producer's C source and
##      rebuilding yields the NEW library stamp — the producer was rebuilt from
##      the edited source (§4.3).
##
## Falsifiability (two independent arms, matching §SC-10's contract):
##   * COMPILE arm: a compiled-in control (``-d:scTyped10Mistyped``) that would
##     make the consumer typed-call a MISTYPED command (``sctypedexe.bogusverb``)
##     is asserted to NOT compile — the typed call is schema-checked at macro
##     expansion (proven here by ``compiles`` on the exact producer contract this
##     test ships, not the tempdir consumer).
##   * BUILD arm: a NO-PRODUCER-EDGE guard — a consumer that TYPED-calls
##     ``sctypedexe.serve(...)`` (still compiling, the sibling schema is present)
##     with NO override + NO lock entry (so ``resolveProducerBinding`` ->
##     ``pbkNotProducer`` and nothing is built/spliced) MUST fail the consume step
##     (the bare-name exe is not on PATH, no ambient prebuild can satisfy it),
##     proving the typed consume genuinely depends on the from-source SC splice.
##
## Skip rule: ``cc``/``sh``/``git`` missing on PATH, or ``./build/bin/repro``
## unbuilt, or a non-Linux host (the ``.so`` layout assumed here is Linux; kept
## Linux-only to stay hermetic, matching SC-3/SC-5/SC-6/SC-7).

import std/[os, osproc, strutils, unittest]

import repro_lock

# ---------------------------------------------------------------------------
# COMPILE-TIME falsifiability control (§SC-10 compile arm). We import the exact
# executable-producer contract this test ships (an ``executable sctypedexe:
# cli:`` with a ``serve`` command carrying a ``socket`` flag) as a same-file
# package and check that a MISTYPED typed call does NOT compile — the typed
# call is schema-checked at macro expansion, not run time. This is the
# compile-time half of the SC-10 falsifiability (the SC-9 workspace-import path
# is exercised by the tempdir consumer at ``repro build`` time; here we pin the
# schema-check property directly and cheaply, and make the mistyped path a
# hard compile error under ``-d:scTyped10Mistyped`` to reproduce falsifiability).
# ---------------------------------------------------------------------------
import repro_project_dsl

package sctyped10schema:
  defaultToolProvisioning "path"

  executable sctyped10schema:
    name: "sctyped10schema"
    cli:
      subcmd "serve":
        flag socket is string

# The valid typed call compiles against the imported schema.
when compiles(sctyped10schema.serve(socket = "/x")):
  const validServeCompiles = true
else:
  const validServeCompiles = false

# A mistyped command name is NOT a valid typed call (no ``bogusverb`` wrapper).
when compiles(sctyped10schema.bogusverb(socket = "/x")):
  const mistypedCommandCompiles = true
else:
  const mistypedCommandCompiles = false

# A mistyped flag on a real command is rejected (``serve`` has no ``nosuchflag``).
when compiles(sctyped10schema.serve(nosuchflag = "/x")):
  const mistypedFlagCompiles = true
else:
  const mistypedFlagCompiles = false

when defined(scTyped10Mistyped):
  # Falsifiability reproduction knob: force the mistyped call into the compiled
  # program. If the schema-check were absent this would compile away; with the
  # SC-8/SC-9 typed contract it is a HARD compile error, so building this test
  # with ``-d:scTyped10Mistyped`` fails — the compile-arm falsification.
  discard sctyped10schema.bogusverb(socket = "/x")

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

# The executable producer's UNIQUE stamp — the built ``sctypedexe`` script writes
# exactly this to its ``--socket`` path. It cannot appear unless the sibling was
# built from source AND its binary ran via the TYPED call (SC-2 PATH splice).
const exeStamp = "SC10-TYPED-EXEPRODUCER-STAMP-7f3a91"

# The library producer's UNIQUE stamp — the library function returns exactly
# this. It cannot appear unless the sibling library was built from source AND its
# symbol was linked + loaded (SC-3 aux channels).
const libStamp = "SC10-TYPED-LIBPRODUCER-STAMP-2e8c4d"
const libStampDevEdited = "SC10-TYPED-LIBPRODUCER-DEV-EDITED-9a1b57"
const libStampLockEdited = "SC10-TYPED-LIBPRODUCER-LOCK-EDITED-3d6e02"

# ---- The sibling EXECUTABLE producer repo. It exports an ``executable … cli:``
# TYPED contract (``serve`` + ``socket``) AND a ``build:`` that materializes a
# script at ``build/bin/sctypedexe``. When invoked ``sctypedexe serve --socket
# <path>`` (the lowering of the consumer's TYPED call) the script writes its
# stamp to <path>. ----
const exeProducerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package sctypedexe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable sctypedexe:
    name: "sctypedexe"
    cli:
      subcmd "serve":
        flag socket is string

  build:
    discard shell(
      command = "mkdir -p build/bin && " &
        "{ printf '#!/bin/sh\n'; " &
        "printf 'out=\"\"\n'; " &
        "printf 'while [ $# -gt 0 ]; do case \"$1\" in --socket) out=\"$2\"; shift 2;; *) shift;; esac; done\n'; " &
        "printf 'mkdir -p \"$(dirname \"$out\")\"\n'; " &
        "printf 'printf %s """ & exeStamp & """ > \"$out\"\n'; " &
        "} > build/bin/sctypedexe && " &
        "chmod +x build/bin/sctypedexe",
      actionId = "sctypedexe.build.sctypedexe",
      extraOutputs = @["build/bin/sctypedexe"])
"""

# ---- The sibling LIBRARY producer repo (native-backend cdylib shape). ----
const libProducerHeader = """
#ifndef SCTYPEDLIB_GREETING_H
#define SCTYPEDLIB_GREETING_H
const char *sctypedlib_greeting(void);
#endif
"""

proc libProducerSource(stamp: string): string =
  "#include \"greeting.h\"\n" &
  "const char *sctypedlib_greeting(void) { return \"" & stamp & "\"; }\n"

const libProducerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package sctypedlib:
  defaultToolProvisioning "path"

  uses:
    "sh"

  library sctypedlib:
    kind: shared

  build:
    discard shell(
      command = "mkdir -p build/lib build/include && " &
        "cc -shared -fPIC -o build/lib/libsctypedlib.so greeting.c && " &
        "cp greeting.h build/include/greeting.h",
      actionId = "sctypedlib.build.sctypedlib",
      extraInputs = @["greeting.c", "greeting.h"],
      extraOutputs = @["build/lib/libsctypedlib.so", "build/include/greeting.h"],
      cacheable = false)
"""

# ---- The consuming C program: #include <greeting.h> (via CPATH), calls the
# library function (linked via -lsctypedlib on LIBRARY_PATH, loaded via
# LD_LIBRARY_PATH), writes the returned stamp to build/consumed.txt. ----
const consumerSource = """
#include <stdio.h>
#include <greeting.h>
int main(void) {
  FILE *f = fopen("build/consumed.txt", "w");
  if (!f) return 2;
  fputs(sctypedlib_greeting(), f);
  fclose(f);
  return 0;
}
"""

# ---- The consumer repo. The FIRST action is a TYPED call over the sibling's
# exported ``executable sctypedexe`` (``serve`` + its ``socket`` flag, checked at
# macro expansion against the IMPORTED schema — SC-8/SC-9). It lowers to
# ``sctypedexe serve --socket build/exe.txt`` resolved ONLY via the SC-2 PATH
# splice. The SECOND action compiles/links/runs against the sibling LIBRARY
# ``sctypedlib`` (imported into scope by the SAME SC-9 branch; linked via the
# SC-3 aux-channel splice — NO -I/-L, NO LD_LIBRARY_PATH set here). This SAME text
# is used verbatim in BOTH mode trees (§5 "only materialization differs"). ----
const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "sctypedexe"
    "sctypedlib"

  build:
    # TYPED call over the sibling producer's exported ``executable sctypedexe``.
    # ``serve`` + ``socket`` are schema-checked at macro expansion (§9.5); the
    # typed wrapper yields a ``PublicCliCall`` which ``recordToolInvocation``
    # lowers to the SAME build action a string ref would, resolving the
    # from-source producer through the SC build-time seam (§9.4). The producer's
    # freshly-built ``sctypedexe`` binary is found via the SC-2 PATH splice.
    let serveCall = sctypedexe.serve(socket = "build/exe.txt")
    let served = recordToolInvocation(
      "consumer.serve", serveCall,
      extraOutputs = @["build/exe.txt"],
      cacheable = false)

    # Consume the sibling LIBRARY (``sctypedlib`` in scope via the SC-9 import;
    # linked/loaded via the SC-3 aux channels). Depends on the typed serve edge
    # so the exe channel and lib channel are one consumer graph.
    discard shell(
      command = "cc -o build/consume main.c -lsctypedlib && ./build/consume",
      actionId = "consumer.build.consume",
      deps = @[served.id],
      extraInputs = @["main.c"],
      extraOutputs = @["build/consume", "build/consumed.txt"],
      cacheable = false)
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

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
  gitRun(gitBin, ["config", "user.email", "sc10@example.invalid"], repoDir)
  gitRun(gitBin, ["config", "user.name", "SC10 Fixture"], repoDir)
  gitRun(gitBin, ["add", "-A"], repoDir)
  gitRun(gitBin, ["commit", "--quiet", "-m", "sc10 producer"], repoDir)

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
    inputsDigest: inputsDigestOf("sc10-typed-fixture-" & tag))
  ld.deps.add(LockedDep(
    name: "sctypedexe", path: "",
    coordinates: Coordinates(kind: ckVcs, url: exeUrl, gitRef: "main",
      revision: exeRev),
    integrity: gitObjectMultihash("sha1", exeRev),
    visibility: "public"))
  ld.deps.add(LockedDep(
    name: "sctypedlib", path: "",
    coordinates: Coordinates(kind: ckVcs, url: libUrl, gitRef: "main",
      revision: libRev),
    integrity: gitObjectMultihash("sha1", libRev),
    visibility: "public"))
  writeFile(consumerRoot / "repro.lock", serializeLockedDependencies(ld))

suite "SC-10: typed cross-project consumption end-to-end in BOTH modes":

  test "t_sc_typed_cross_project_consumption_both_modes":
    # ---- COMPILE-TIME falsifiability (SC-10 compile arm), independent of the
    # ``repro build`` runs below: the typed call is schema-checked at macro
    # expansion — a mistyped command / flag does NOT compile against the
    # producer's exported ``executable … cli:`` contract (§9.5). This reaching
    # ``[OK]`` at all means the valid typed call compiled and the mistyped ones
    # did not. ----
    check validServeCompiles
    check not mistypedCommandCompiles
    check not mistypedFlagCompiles

    let ccBin = findExe("cc")
    let shBin = findExe("sh")
    let gitBin = findExe("git")
    if not defined(linux):
      checkpoint("skipped — SC-10 test fixture assumes the Linux .so layout")
      skip()
    elif ccBin.len == 0 or shBin.len == 0 or gitBin.len == 0 or
        not fileExists(reproBinary):
      checkpoint("skipped — cc/sh/git missing on PATH or repro unbuilt")
      skip()
    else:
      let repoRoot = getCurrentDir()
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc10-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # No host ``sctypedexe`` may satisfy the bare name by accident; this test
      # sets NO aux env var — the ONLY way both consume steps resolve is via the
      # from-source splices of the freshly-built sibling dirs.
      check findExe("sctypedexe").len == 0

      # ============================================================
      # MODE A — DEVELOP (SC-5 shape): overrides -> sibling checkouts built in
      # place; the consumer's TYPED calls resolve to the from-source producers.
      # ============================================================
      block developMode:
        let root = absolutePath(scratch / "develop")
        createDir(root)

        let exeProdRoot = root / "sctypedexe"
        createDir(exeProdRoot)
        writeFile(exeProdRoot / "repro.nim", exeProducerRepro)

        let libProdRoot = root / "sctypedlib"
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
package = "sctypedexe"
local_path = "../sctypedexe"
state = "editable"
created_at = "2026-07-03T00:00:00Z"

[[override]]
package = "sctypedlib"
local_path = "../sctypedlib"
state = "editable"
created_at = "2026-07-03T00:00:00Z"
""")

        let exeProducerBinary = exeProdRoot / "build" / "bin" /
          addFileExt("sctypedexe", ExeExt)
        let libProducerLibrary = libProdRoot / "build" / "lib" / "libsctypedlib.so"
        check not fileExists(exeProducerBinary)
        check not fileExists(libProducerLibrary)

        let exeMarker = consumerRoot / "build" / "exe.txt"
        let libMarker = consumerRoot / "build" / "consumed.txt"

        let cacheRoot = absolutePath(scratch / "develop-cache")
        createDir(cacheRoot)
        let buildCmd = buildCmdFor(reproAbs, consumerRoot, cacheRoot)

        checkpoint("develop (1): " & buildCmd)
        let (code, output) = run(buildCmd, repoRoot)
        checkpoint("develop exit=" & $code)
        checkpoint(output)
        check code == 0

        # (2) BOTH producers materialized from source BY THIS RUN.
        check fileExists(exeProducerBinary)
        check fileExists(libProducerLibrary)

        # (3) Both channels consumed from source via the TYPED surface.
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

        # (4) Source invalidation (develop): edit the library producer's C
        # source; rebuilding must rebuild the producer + re-run the consume.
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
      # MODE B — LOCK-PINNED (SC-6 shape): NO develop override. The sibling
      # producer checkouts ARE present one level up from the consumer so the
      # SC-9 COMPILE-TIME typed schema import (``../sctypedexe/repro.nim``)
      # resolves; but they are RESOLVED AT BUILD TIME through the consumer's
      # committed repro.lock LockedDep (``pbkLockPinned``), NOT a develop
      # override — the SC-6 lock-pinned resolution/build path. The producers are
      # ALSO real git repos (with a real HEAD revision) so the committed lock's
      # coordinates+integrity are genuine.
      # ============================================================
      block lockPinnedMode:
        let root = absolutePath(scratch / "lockpinned")
        createDir(root)

        let exeProdRoot = root / "sctypedexe"
        createDir(exeProdRoot)
        writeFile(exeProdRoot / "repro.nim", exeProducerRepro)
        gitInit(exeProdRoot, gitBin)
        let exeRev = gitHead(exeProdRoot, gitBin)

        let libProdRoot = root / "sctypedlib"
        createDir(libProdRoot)
        writeFile(libProdRoot / "repro.nim", libProducerRepro)
        writeFile(libProdRoot / "greeting.h", libProducerHeader)
        writeFile(libProdRoot / "greeting.c", libProducerSource(libStamp))
        gitInit(libProdRoot, gitBin)
        let libRev = gitHead(libProdRoot, gitBin)

        let consumerRoot = root / "consumer"
        createDir(consumerRoot)
        writeFile(consumerRoot / "repro.nim", consumerRepro)
        writeFile(consumerRoot / "main.c", consumerSource)
        writeConsumerLock(consumerRoot, exeProdRoot, exeRev, libProdRoot,
          libRev, "v1")

        # NO develop overrides — resolution is through the committed lock.
        check not fileExists(consumerRoot / ".repro" / "develop-overrides.toml")
        check fileExists(consumerRoot / "repro.lock")

        let exeProducerBinary = exeProdRoot / "build" / "bin" /
          addFileExt("sctypedexe", ExeExt)
        let libProducerLibrary = libProdRoot / "build" / "lib" / "libsctypedlib.so"
        check not fileExists(exeProducerBinary)
        check not fileExists(libProducerLibrary)

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

        # (2) BOTH producers materialized from source BY THIS RUN (resolved via
        # the committed lock).
        check fileExists(exeProducerBinary)
        check fileExists(libProducerLibrary)

        # (3) Both channels consumed from source via the TYPED surface.
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

        # (4) Refreshed pin -> rebuild from the NEW revision (§5.2 "a changed
        # pin invalidates the consumer").
        writeFile(libProdRoot / "greeting.c", libProducerSource(libStampLockEdited))
        gitCommitAll(libProdRoot, gitBin, "sc10 producer edit")
        let libRev2 = gitHead(libProdRoot, gitBin)
        check libRev2 != libRev
        writeConsumerLock(consumerRoot, exeProdRoot, exeRev, libProdRoot,
          libRev2, "v2")
        if fileExists(libMarker): removeFile(libMarker)

        checkpoint("lock-pinned (2, after refreshed pin): " & buildCmd)
        let (code2, output2) = run(buildCmd, repoRoot)
        checkpoint("lock-pinned exit2=" & $code2)
        checkpoint(output2)
        check code2 == 0
        check fileExists(libMarker)
        if fileExists(libMarker):
          let got = readFile(libMarker).strip()
          checkpoint("lock-pinned consumed.txt(after refreshed pin)=" & got)
          check got == libStampLockEdited

      # ============================================================
      # FALSIFIABILITY — BUILD arm: no-producer-edge guard. The sibling exe
      # producer checkout IS present (so the consumer's TYPED call still
      # COMPILES — the SC-9 schema import resolves), but the consumer declares
      # NO override + NO lock entry for it -> ``resolveProducerBinding`` yields
      # ``pbkNotProducer`` and nothing is built/spliced. With NO ambient /
      # prebuilt / host binary, the TYPED serve call's lowered action cannot find
      # ``sctypedexe`` on PATH, so the consume step MUST fail. This proves the
      # TYPED consume genuinely depends on the from-source SC splice, not on any
      # prebuild — the build-time half of §SC-10 falsifiability.
      # ============================================================
      block noProducerEdge:
        let root = absolutePath(scratch / "noedge")
        createDir(root)

        let exeProdRoot = root / "sctypedexe"
        createDir(exeProdRoot)
        writeFile(exeProdRoot / "repro.nim", exeProducerRepro)

        let consumerRoot = root / "consumer"
        createDir(consumerRoot)
        # A consumer that ONLY TYPED-calls the exe (no library, to isolate the
        # exe channel), with NO override + NO lock naming sctypedexe.
        writeFile(consumerRoot / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "sctypedexe"

  build:
    let serveCall = sctypedexe.serve(socket = "build/exe.txt")
    discard recordToolInvocation(
      "consumer.serve", serveCall,
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
        # sctypedexe is not a producer here (no override, no lock) and there is
        # no prebuilt / host binary -> the TYPED serve consume step must fail.
        check code != 0
        check not fileExists(exeMarker)

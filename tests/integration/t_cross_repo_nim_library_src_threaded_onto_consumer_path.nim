## Cross-Repo-Source-Consumption SC-11 — the Nim library-source language
## channel: a sibling Nim ``library``'s importable ``src/`` root threaded onto
## the CONSUMER's ``nim c --path:`` via the new ``nimPathDirs`` aux channel.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.2a (the Nim library-source
## language channel: §4.2a.1 the ``nimPathDirs`` field, §4.2a.2 SC-3-splice
## discovery of the sibling ``src/``, §4.2a.3 the resolver projection onto
## ``nim c --path:``, §4.2a.4 the ``exportedPath`` convention default, §4.2a.5
## the reused SC-4 fold, §4.2a.6 mode-agnosticism) + §13 (remaining language
## channel).  Milestone: ``Cross-Repo-Source-Consumption.milestones.org`` §SC-11.
##
## The gap SC-11 closes: SC-2 shipped the EXECUTABLE channel (sibling
## ``executable`` on PATH) and SC-3 the C/C++ LIBRARY channel (sibling
## ``library`` through ``includeDirs``/``libDirs``/… → ``CPATH``/``LIBRARY_PATH``/…).
## There was NO channel for a Nim CONSUMER that ``import``s a sibling Nim
## LIBRARY: authoring ``uses: "<nim lib>"`` failed because the ``uses:``
## selector resolved as a PATH executable ("not found in PATH") and no Nim
## channel threaded the sibling's ``src/`` onto ``nim c --path:``. SC-11 adds
## the parallel Nim channel — a new SOURCE-LANGUAGE channel reusing the SC-1
## resolution, the SC-3 producer sub-build + splice, and the SC-4 fold.
##
## Fixture (built ``./build/bin/repro``, black-box; every path in a fresh
## tempdir so nothing touches $HOME):
##
##   <scratch>/
##     develop/
##       greetlib/            the sibling Nim LIBRARY producer (develop checkout)
##         repro.nim          declares ``library greetlib`` (NO exportedPath →
##                            convention default "src"); trivial build stamp
##         src/greetlib.nim   the importable module: ``proc greeting(): string``
##       consumer/            the CONSUMER project
##         repro.nim          ``uses: "greetlib"`` + a ``nim.c(...)`` edge that
##                            compiles ``src/app.nim`` which ``import greetlib``
##         src/app.nim        ``import greetlib`` — writes greeting() to a marker
##         .repro/develop-overrides.toml  maps greetlib → the sibling checkout
##     lockpinned/
##       remotes/greetlib.git a real git repo (the producer "remote")
##       consumer/            NO override, NO sibling on disk; ONLY a committed
##                            repro.lock pinning greetlib at HEAD (git-sha1)
##
## The consumer's ONE build action is a typed ``nim.c(...)`` edge: it compiles
## a Nim module that ``import greetlib`` and, at RUN time (via ``--run``-less
## design we just execute the produced binary in the same action) writes the
## sibling's ``greeting()`` value to ``build/app-out.txt``. Because ``app.nim``
## ``import greetlib`` with NO ``--path:../greetlib/src`` anywhere in the
## consumer sources, the compile succeeds ONLY if the engine threaded the
## sibling's ``src/`` onto the ``nim c --path:`` through the SC-11 channel.
##
## Assertions (develop mode AND lock-pinned mode, §4.2a.6):
##   1. ``repro build`` on the consumer exits 0 — ``import greetlib`` resolved.
##   2. The produced binary ran and wrote the sibling's unique ``greeting()``
##      stamp to the marker — proving the sibling ``src/`` was on ``--path:``
##      (no hardcoded ``../greetlib/src``).
##   3. Editing the sibling's ``src/greetlib.nim`` (develop) / refreshing the
##      pin (lock-pinned) rebuilds the consumer with the NEW stamp — the reused
##      SC-4 fold (§4.2a.5) invalidates on the sibling's source.
##
## Falsifiability (§SC-11): the consumer's ``repro.nim`` carries NO
## ``--path:../greetlib/src``, so without the SC-11 ``nimPathDirs`` channel the
## consumer's ``nim c`` cannot resolve ``import greetlib`` — the compile fails
## with "cannot open file: greetlib". This is exercised directly by a control
## consumer that names NO ``uses: "greetlib"`` (so no producer is spliced and
## no ``--path:`` is threaded): its identical ``import greetlib`` compile FAILS.
## That control reproduces the pre-SC-11 failure mode within the same test run.
##
## Skip rule: ``git`` missing on PATH, or ``./build/bin/repro`` unbuilt.
## (Cross-platform: no ``.so`` fixture — this is a pure-Nim-source channel — so
## it is NOT gated to Linux.)

import std/[os, osproc, strutils, unittest]

import repro_lock

const reproBinary = "./build/bin/repro"

# The sibling library's UNIQUE greeting stamp — the produced consumer binary
# writes exactly this. It cannot appear unless ``import greetlib`` resolved the
# sibling module through the threaded ``--path:`` AND the compiled binary ran.
const greetStamp = "SC11-GREETLIB-STAMP-3b7e1d"
const greetStampEdited = "SC11-GREETLIB-STAMP-EDITED-c9f204"

# ---- The sibling Nim LIBRARY producer repo. A pure Nim library: ``library
# greetlib`` with NO ``exportedPath`` (so the convention default ``"src"``
# applies, §4.2a.4) and its importable module under ``src/``. The trivial
# ``build:`` gives the producer sub-build a default action to run; the Nim
# source channel needs no realized ``.so``. ----
const producerReproTemplate = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package greetlib:
  defaultToolProvisioning "path"

  uses:
    "sh"

  library greetlib:
    kind: static

  build:
    discard shell(
      command = "mkdir -p build && printf built > build/greetlib.stamp",
      actionId = "greetlib.build.stamp",
      extraOutputs = @["build/greetlib.stamp"])
"""

proc producerModule(stamp: string): string =
  "proc greeting*(): string = \"" & stamp & "\"\n"

# ---- The CONSUMER's importable Nim module. It ``import greetlib`` with NO
# path qualifier — resolution depends ENTIRELY on the SC-11 ``--path:`` thread.
# The compiled binary writes the sibling's ``greeting()`` to a marker so the
# test observes that the RIGHT sibling source was threaded. ----
const consumerAppSource = """
import greetlib
import std/os

when isMainModule:
  writeFile("build/app-out.txt", greeting())
"""

# ---- The consumer repo. ONE typed ``nim.c(...)`` edge compiles ``app.nim``
# (which ``import greetlib``) and then runs the produced binary. ``uses:
# "greetlib"`` names the sibling producer; the SC-11 channel threads its
# ``src/`` onto the ``nim c --path:``. ``sh`` runs the produced binary. ----
const consumerReproWithGreetlib = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "clang"
    "sh"
    "greetlib"

  build:
    let compiled = nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      gccExe = "clang",
      parallelBuild = 1)
    discard shell(
      command = "mkdir -p build && ./build/bin/app",
      actionId = "consumer.run.app",
      extraInputs = @["build/bin/app"],
      extraOutputs = @["build/app-out.txt"],
      cacheable = false)
"""

# ---- The CONTROL consumer: identical ``import greetlib`` compile but with NO
# ``uses: "greetlib"`` — so NO producer is spliced and NO ``--path:`` is
# threaded. This reproduces the pre-SC-11 failure: ``import greetlib`` cannot
# be resolved and ``nim c`` fails. ----
const consumerReproNoGreetlib = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "clang"

  build:
    discard nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      gccExe = "clang",
      parallelBuild = 1)
"""

# ---- Producer-sub-build-scope fix (Bug 1): a pure-Nim LIBRARY producer whose
# DEFAULT action is a POOL-SERIALIZED test — the nim-pty shape. Its
# ``buildPool("greetlib.pty-serial", 1)`` + a test-execute edge routed through
# that pool models a producer whose default action, if run during a consumer
# build, would (a) require a producer-local pool the consumer's runquotad does
# not have (→ lease-deny → hang) and (b) WRITE a marker proving the test ran.
# The Bug-1 fix scopes the producer sub-build to the CONSUMED library — a pure
# Nim src library needs NO build — so this test edge is never materialized:
# the consumer build completes and the marker is NEVER written. ----
const producerReproPooledTestTemplate = """
import repro_project_dsl

package greetlib:
  defaultToolProvisioning "path"

  uses:
    "sh"

  library greetlib:
    kind: static

  build:
    # A pool-serialized "test" execute edge — mirrors nim-pty's
    # ``edge.testBinary.run(pool = "nim_pty.pty-serial")``. If the producer's
    # default action runs during a consumer build, this edge (a) needs the
    # ``greetlib.pty-serial`` pool the consumer daemon lacks and (b) writes the
    # marker below. The Bug-1 fix scopes the producer sub-build to the consumed
    # (pure-Nim) library, so this edge is never materialized.
    discard buildPool("greetlib.pty-serial", 1'u32)
    discard buildAction(
      id = "greetlib.test.pooled",
      call = inlineExecCall(@["sh", "-c",
        "mkdir -p build && printf ran > build/PRODUCER-TEST-RAN.marker"]),
      outputs = @["build/PRODUCER-TEST-RAN.marker"],
      pool = "greetlib.pty-serial",
      cacheable = false,
      toolIdentityRefs = @["sh"])
"""

proc writeProducerSrcPooled(root, stamp: string) =
  createDir(root / "src")
  writeFile(root / "repro.nim", producerReproPooledTestTemplate)
  writeFile(root / "src" / "greetlib.nim", producerModule(stamp))

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc gitInit(repoDir, gitBin: string) =
  proc git(args: openArray[string]) =
    var cmd = q(gitBin)
    for a in args:
      cmd.add(" ")
      cmd.add(q(a))
    let r = execCmdEx(cmd, options = {poUsePath}, workingDir = repoDir)
    doAssert r.exitCode == 0, "git " & args.join(" ") & " failed: " & r.output
  git(["init", "--quiet"])
  git(["config", "user.email", "sc11@example.invalid"])
  git(["config", "user.name", "SC11 Fixture"])
  git(["add", "-A"])
  git(["commit", "--quiet", "-m", "sc11 producer"])

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

proc gitHead(repoDir, gitBin: string): string =
  let r = execCmdEx(q(gitBin) & " -C " & q(repoDir) & " rev-parse HEAD",
    options = {poUsePath})
  doAssert r.exitCode == 0, "git rev-parse HEAD failed: " & r.output
  r.output.strip()

proc writeProducerSrc(root, stamp: string) =
  createDir(root / "src")
  writeFile(root / "repro.nim", producerReproTemplate)
  writeFile(root / "src" / "greetlib.nim", producerModule(stamp))

proc writeConsumer(root, reproText: string) =
  createDir(root / "src")
  writeFile(root / "repro.nim", reproText)
  writeFile(root / "src" / "app.nim", consumerAppSource)

proc buildCommand(reproAbs, consumerRoot, cacheRoot: string): string =
  q(reproAbs) & " build " & q(consumerRoot / "repro.nim") &
    " --tool-provisioning=path --daemon=off --log=quiet" &
    " --progress=quiet --measure=none" &
    " --action-cache-root=" & q(cacheRoot)

suite "SC-11: Nim library src threaded onto consumer nim c --path:":

  test "t_cross_repo_nim_library_src_threaded_onto_consumer_path":
    let gitBin = findExe("git")
    if not fileExists(reproBinary):
      checkpoint("skipped — ./build/bin/repro unbuilt")
      skip()
    elif gitBin.len == 0:
      checkpoint("skipped — git missing on PATH")
      skip()
    else:
      let repoRoot = getCurrentDir()
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc11-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ==================================================================
      # DEVELOP MODE — override → the sibling checkout's src/ (§4.2a.6, §5.1)
      # ==================================================================
      block developMode:
        let devRoot = absolutePath(scratch / "develop")
        createDir(devRoot)
        # The sibling library checkout, one level up from the consumer (the
        # ``../greetlib`` the develop override's ``local_path`` points at).
        let siblingRoot = devRoot / "greetlib"
        createDir(siblingRoot)
        writeProducerSrc(siblingRoot, greetStamp)
        # The consumer, with a develop override → the sibling checkout.
        let consumerRoot = devRoot / "consumer"
        createDir(consumerRoot)
        writeConsumer(consumerRoot, consumerReproWithGreetlib)
        createDir(consumerRoot / ".repro")
        writeFile(consumerRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "greetlib"
local_path = "../greetlib"
state = "editable"
created_at = "2026-07-04T00:00:00Z"
""")

        # The consumer sources carry NO hardcoded path to the sibling src.
        check "../greetlib" notin readFile(consumerRoot / "repro.nim")
        check "--path:" notin readFile(consumerRoot / "repro.nim")

        let marker = consumerRoot / "build" / "app-out.txt"
        if fileExists(marker): removeFile(marker)
        let cacheRoot = absolutePath(scratch / "dev-cache")
        createDir(cacheRoot)
        let cmd = buildCommand(reproAbs, consumerRoot, cacheRoot)

        # (1)+(2) build succeeds and the produced binary wrote the sibling's
        # greeting stamp — ``import greetlib`` resolved via the threaded path.
        checkpoint("develop build: " & cmd)
        let (code, output) = run(cmd, repoRoot)
        checkpoint("develop exit=" & $code)
        checkpoint(output)
        check code == 0
        check fileExists(marker)
        if fileExists(marker):
          let got = readFile(marker).strip()
          checkpoint("develop app-out.txt=" & got)
          check got == greetStamp

        # (3) editing the sibling src rebuilds the consumer with the NEW stamp.
        writeFile(siblingRoot / "src" / "greetlib.nim",
          producerModule(greetStampEdited))
        if fileExists(marker): removeFile(marker)
        checkpoint("develop rebuild after sibling edit: " & cmd)
        let (code2, output2) = run(cmd, repoRoot)
        checkpoint("develop exit2=" & $code2)
        checkpoint(output2)
        check code2 == 0
        check fileExists(marker)
        if fileExists(marker):
          let got2 = readFile(marker).strip()
          checkpoint("develop app-out.txt(after edit)=" & got2)
          check got2 == greetStampEdited

      # ==================================================================
      # LOCK-PINNED MODE — no override → fetched tree's src/ (§4.2a.6, §5.2)
      # ==================================================================
      block lockPinnedMode:
        let lpRoot = absolutePath(scratch / "lockpinned")
        createDir(lpRoot)
        let remotes = lpRoot / "remotes"
        createDir(remotes)
        # The producer "remote" — a real git repo, NOT beside the consumer, so
        # the ONLY way to reach it is fetching the pinned revision.
        let remote = remotes / "greetlib"
        createDir(remote)
        writeProducerSrc(remote, greetStamp)
        gitInit(remote, gitBin)
        let rev = gitHead(remote, gitBin)

        # The consumer — NO override, NO sibling on disk; ONLY a committed lock.
        let consumerRoot = lpRoot / "consumer"
        createDir(consumerRoot)
        writeConsumer(consumerRoot, consumerReproWithGreetlib)

        proc writeLock(root, url, revision: string) =
          var ld = LockedDependencies(
            schema: "reprobuild.solved-graph-lock.v2",
            platform: currentPlatformId(), optimal: true,
            inputsDigest: inputsDigestOf("sc11-fixture"))
          ld.deps.add(LockedDep(
            name: "greetlib", path: "",
            coordinates: Coordinates(kind: ckVcs, url: url, gitRef: "main",
              revision: revision),
            integrity: gitObjectMultihash("sha1", revision),
            visibility: "public"))
          writeFile(root / "repro.lock", serializeLockedDependencies(ld))
        writeLock(consumerRoot, remote, rev)

        check not fileExists(consumerRoot / ".repro" / "develop-overrides.toml")
        check not dirExists(parentDir(consumerRoot) / "greetlib")

        let marker = consumerRoot / "build" / "app-out.txt"
        if fileExists(marker): removeFile(marker)
        let cacheRoot = absolutePath(scratch / "lp-cache")
        createDir(cacheRoot)
        let cmd = buildCommand(reproAbs, consumerRoot, cacheRoot)

        # (1)+(2) build succeeds and the produced binary wrote the sibling's
        # greeting stamp — the FETCHED tree's src/ was threaded onto --path:.
        checkpoint("lock-pinned build: " & cmd)
        let (code, output) = run(cmd, repoRoot)
        checkpoint("lock-pinned exit=" & $code)
        checkpoint(output)
        check code == 0
        # The producer was fetched into the workspace-local cache by this run.
        let fetched = consumerRoot / ".repro" / "cross-repo-producers" /
          "greetlib" / rev / "repro.nim"
        check fileExists(fetched)
        check not dirExists(parentDir(consumerRoot) / "greetlib")
        check fileExists(marker)
        if fileExists(marker):
          let got = readFile(marker).strip()
          checkpoint("lock-pinned app-out.txt=" & got)
          check got == greetStamp

        # (3) a refreshed pin re-fetches the NEW revision and consumes the NEW
        # sibling stamp — the reused SC-4 fold invalidates on the pinned source.
        writeFile(remote / "src" / "greetlib.nim",
          producerModule(greetStampEdited))
        gitCommitAll(remote, gitBin, "sc11 producer edit")
        let rev2 = gitHead(remote, gitBin)
        check rev2 != rev
        writeLock(consumerRoot, remote, rev2)
        if fileExists(marker): removeFile(marker)
        checkpoint("lock-pinned rebuild after refreshed pin: " & cmd)
        let (code2, output2) = run(cmd, repoRoot)
        checkpoint("lock-pinned exit2=" & $code2)
        checkpoint(output2)
        check code2 == 0
        let fetched2 = consumerRoot / ".repro" / "cross-repo-producers" /
          "greetlib" / rev2 / "repro.nim"
        check fileExists(fetched2)
        check fileExists(marker)
        if fileExists(marker):
          let got2 = readFile(marker).strip()
          checkpoint("lock-pinned app-out.txt(after refreshed pin)=" & got2)
          check got2 == greetStampEdited

      # ==================================================================
      # FALSIFIABILITY — a CONTROL consumer that names NO ``uses: "greetlib"``
      # so no producer is spliced and no ``--path:`` is threaded. The
      # identical ``import greetlib`` compile FAILS (pre-SC-11 failure mode).
      # ==================================================================
      block falsifyControl:
        let ctlRoot = absolutePath(scratch / "control")
        createDir(ctlRoot)
        writeConsumer(ctlRoot, consumerReproNoGreetlib)
        let cacheRoot = absolutePath(scratch / "control-cache")
        createDir(cacheRoot)
        let cmd = buildCommand(reproAbs, ctlRoot, cacheRoot)
        checkpoint("control (no uses:greetlib) build: " & cmd)
        let (code, output) = run(cmd, repoRoot)
        checkpoint("control exit=" & $code)
        checkpoint(output)
        # No ``--path:`` threaded → ``import greetlib`` cannot be resolved.
        check code != 0
        check not fileExists(ctlRoot / "build" / "bin" / "app")
        check output.toLowerAscii.contains("greetlib")

  # ====================================================================
  # Bug 1 — producer sub-build scope: consuming a pure-Nim LIBRARY must
  # build (at most) that library's own artifact and must NEVER compile or
  # run the producer's test suite. A library-only producer's DEFAULT action
  # is its tests — here a POOL-SERIALIZED test edge (the nim-pty shape) whose
  # pool the CONSUMER's runquotad does not have. Before the fix, the producer
  # sub-build ran ``selectDefaultAction = true`` → the pooled test edge
  # lease-denied forever → the consumer build HUNG. After the fix, the pure-
  # Nim library needs no producer build, so the consumer build COMPLETES and
  # the producer's test-execute marker is NEVER written.
  #
  # Falsifiability: restore the producer sub-build to ``selectDefaultAction =
  # true`` (build unconditionally) and the marker appears (or the build hangs
  # / denies on ``greetlib.pty-serial``) — this assertion fails.
  # ====================================================================
  test "t_cross_repo_library_consumer_does_not_build_producer_tests":
    let gitBin = findExe("git")
    if not fileExists(reproBinary):
      checkpoint("skipped — ./build/bin/repro unbuilt")
      skip()
    else:
      let repoRoot = getCurrentDir()
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc11-bug1-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let devRoot = absolutePath(scratch / "develop")
      createDir(devRoot)
      # The sibling library producer whose DEFAULT action is a pool-serialized
      # test (the nim-pty shape).
      let siblingRoot = devRoot / "greetlib"
      createDir(siblingRoot)
      writeProducerSrcPooled(siblingRoot, greetStamp)
      # The consumer with a develop override → the sibling checkout.
      let consumerRoot = devRoot / "consumer"
      createDir(consumerRoot)
      writeConsumer(consumerRoot, consumerReproWithGreetlib)
      createDir(consumerRoot / ".repro")
      writeFile(consumerRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "greetlib"
local_path = "../greetlib"
state = "editable"
created_at = "2026-07-04T00:00:00Z"
""")

      let marker = consumerRoot / "build" / "app-out.txt"
      if fileExists(marker): removeFile(marker)
      let producerTestMarker = siblingRoot / "build" / "PRODUCER-TEST-RAN.marker"
      if fileExists(producerTestMarker): removeFile(producerTestMarker)
      let cacheRoot = absolutePath(scratch / "bug1-cache")
      createDir(cacheRoot)
      let cmd = buildCommand(reproAbs, consumerRoot, cacheRoot)

      # The consumer build COMPLETES (was: hang) — the pure-Nim library needs
      # no producer sub-build, so the producer's pooled test edge is never
      # materialized against the consumer's poolless runquotad.
      checkpoint("bug1 build: " & cmd)
      let (code, output) = run(cmd, repoRoot)
      checkpoint("bug1 exit=" & $code)
      checkpoint(output)
      check code == 0
      # The library consumption still resolves ``import greetlib`` via the
      # threaded ``src/`` — the consumer binary ran + wrote the stamp.
      check fileExists(marker)
      if fileExists(marker):
        check readFile(marker).strip() == greetStamp
      # The producer's POOLED TEST edge NEVER ran — its marker is absent.
      check not fileExists(producerTestMarker)
      # No producer-pool lease denial leaked into the consumer build.
      check not output.contains("greetlib.pty-serial")

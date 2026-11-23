## Which image may the engine re-execute with an INTERNAL verb
## (``internal io monitor``, ``__repro-extract-interface``,
## ``__repro-compile-provider``)?
##
## Distribution-And-Packaging.md §5.2 (reprobuild-pm): every self-spawn
## resolves its path through ``publicCliImagePath()``, and "the embedded-caller
## guard ... still applies to the result: the engine spawns the running image
## with an internal verb only when that image has declared itself `repro`".
## This module is that guard: the mark ``runThinApp("repro")`` sets, the
## predicate that reads it, and the resolver every internal-verb spawn site
## goes through.
##
## WHY IT IS ITS OWN MODULE. It used to live inside `repro_cli_support.nim`,
## which made it unreachable from the modules `repro_cli_support` itself
## imports. `repro_cli_support/home`, `infra` and `infra_host_registry` drive
## the profile compile, whose engine config wraps every action in
## ``<publicCliPath> internal io monitor`` — so they spawn an internal verb
## too, and they resolved that path with the bare ``publicCliImagePath()``. An
## embedded caller (a test binary calling ``compileAndAdaptHomeProfile``
## in-process) was therefore re-executed as its own monitor driver. A unittest
## binary does not implement ``internal io monitor --depfile <f> -- <cmd>``:
## it exited 0 without running the command or writing the capture, and the
## engine read the empty pre-created capture as "iomon file is too short"
## (reprobuild-pm issue
## 2026-10-27-windows-m76-differing-regular-file-case-fails-in-the-profile-compile).
## Those sites now resolve through ``selfSpawnIoMonitorPath`` below.

import std/os
from repro_core/source_root import publicCliImagePath
from repro_core/cli_images import reproLegacyEngineExeName

var runningImageIsReproCliFlag = false
  ## Set by ``markRunningImageAsReproCli`` — see ``runningImageIsReproCli``.

proc markRunningImageAsReproCli() =
  ## Record that the process this code is running in IS the `repro` CLI: the
  ## image that dispatches ``internal io monitor``,
  ## ``__repro-extract-interface`` and ``__repro-compile-provider``.
  ##
  ## Called from ``runThinApp`` when the entry point declares itself `repro`,
  ## which `apps/repro/repro.nim` does as a LITERAL in its own source
  ## (``quit runThinApp("repro")``). That literal is the CLI's own statement
  ## about what it is; the filename it happens to be invoked under is not.
  ##
  ## NOT EXPORTED, and that is the point. This is the DANGEROUS direction:
  ## setting the mark is what makes the engine willing to re-execute the
  ## running image with an internal verb, so an exported setter lets any
  ## module that links the engine be accepted as `repro` without ever having
  ## reached ``runThinApp("repro")`` — which is exactly the embedded test
  ## binary the refusal exists to stop, granting itself the permission by
  ## calling one proc. Its one caller, ``runThinApp`` in
  ## `repro_cli_support.nim`, reaches it through
  ## ``import repro_cli_support/self_spawn_image {.all.}``: a private-access
  ## import that is explicit and greppable, where an export would have been
  ## invisible at every call site. The counterpart clear
  ## (``resetRunningImageReproCliMarkForTest``) was already gated behind
  ## ``-d:reproImageIdentityTest`` for the weaker version of the same reason;
  ## the set is gated below under the same define, so the pair is symmetric
  ## and NO ordinary build can either set or clear the mark off the real
  ## dispatch path.
  runningImageIsReproCliFlag = true

when defined(reproImageIdentityTest):
  ## The test-only handles on the mark, both compiled ONLY under
  ## ``-d:reproImageIdentityTest``, which one test turns on for itself
  ## through its own ``.nim.cfg``.
  ##
  ## Two directions, one reason. The mark is what permits self-spawning: an
  ## image that can SET it is an image the engine will re-execute with an
  ## internal verb without that image ever having declared itself through
  ## ``runThinApp("repro")``, and an image that can CLEAR it and leaves it
  ## clear is fine — but one that sets it and leaves it set is the unbounded
  ## self-exec chain this whole predicate exists to prevent. So the
  ## regression test that must observe the refusal in BOTH directions gets
  ## both handles here and restores the refusal in a ``finally``, and no
  ## ordinary build has a way to reach either.

  proc markRunningImageAsReproCliForTest*() =
    ## Set the mark without going through ``runThinApp``. The only caller is
    ## the image-identity regression test, which has to observe the accept
    ## side of the predicate from a binary that is not named `repro` and
    ## cannot dispatch the real CLI to get there.
    markRunningImageAsReproCli()

  proc resetRunningImageReproCliMarkForTest*() =
    ## Undo ``markRunningImageAsReproCliForTest`` — called from the test's
    ## ``finally`` so the refusal is restored and the rest of the process is
    ## as safe as it was before the case ran.
    runningImageIsReproCliFlag = false

proc runningImageIsReproCli(): bool =
  ## Does the running image implement the internal verbs?
  ##
  ## This used to be asked as ``extractFilename(getAppFilename()) == "repro"``
  ## — a program identifying itself by the name it was invoked under — and
  ## that has now failed three times in three different disguises:
  ##
  ##   * N36: Nix's ``wrapProgram`` renames the real image to
  ##     ``.repro-wrapped`` and puts a shell wrapper at `repro`. Every wrapped
  ##     package therefore ran with ``getAppFilename()`` = ``.repro-wrapped``
  ##     and silently lost its io-monitor driver — silently, because "" is a
  ##     SUPPORTED answer here (fall back to declared inputs/outputs).
  ##   * The M5 trampoline: a bootstrap installed as ``repro-bootstrap.exe``
  ##     answers "no `repro` image to spawn it with", which is why
  ##     ``apps/repro-trampoline/repro_trampoline.nim`` is forced to hide the
  ##     bootstrap in a DIRECTORY named `reprobuild` rather than give the file
  ##     a distinct name.
  ##   * ``scripts/run_tests.sh``: Windows cannot relink a running image, so
  ##     the suite copies ``repro.exe`` to ``repro_run.exe`` and runs the copy
  ##     — a byte-identical `repro` that this predicate refused, killing the
  ##     entire Windows suite in its build phase for 55 days.
  ##
  ## In all three the image IS `repro` and only the filename says otherwise.
  ## So the question is answered from the image's own declaration instead.
  ## The old filename test is kept as an additional ACCEPT (it can only widen,
  ## never narrow, so it cannot regress a caller that relies on it) for images
  ## that reach the engine without going through ``runThinApp``.
  ##
  ## THIS IS WHAT MADE THE ENGINE RENAMEABLE. The engine image now installs as
  ## ``reprobuild`` (``repro`` on `PATH` is the thin daemon client), and it
  ## needed no change here: it declares itself with the literal ``"repro"`` in
  ## `apps/repro/repro.nim`, so the FIRST arm answers yes whatever the file is
  ## called. Had this still been a filename test, the rename would have broken
  ## provider compile LOUDLY (``providerCompileBuildAction`` raises "no `repro`
  ## image to spawn it with") and interface extraction SILENTLY (it falls back
  ## in-process).
  ##
  ## ``reprobuild`` IS DELIBERATELY *NOT* ADDED to the filename arm, and the
  ## restraint is the point. The arm exists only for images that reach the
  ## engine WITHOUT going through ``runThinApp``, and the real engine always
  ## goes through it — so adding the new name would buy nothing and would
  ## widen the fork-bomb hole by exactly one filename: an engine-linked binary
  ## that is not the CLI (`repro-standard-provider`,
  ## `repro-cmake-trycompile-provider`, any test binary) would be granted
  ## self-spawn permission by being *called* ``reprobuild``. The arm keeps
  ## the LEGACY name because a bootstrap tree still has a real engine there
  ## (`tools/multi-distro-harness/bootstrap-*.sh` compile one straight to
  ## ``<dir>/bin/repro``, with no thin client beside it).
  ##
  ## What still says NO — and is the whole reason this predicate exists — is
  ## the embedded caller: a TEST BINARY that links the engine in-process never
  ## calls ``runThinApp("repro")`` and is not named ``repro``, so it is still
  ## refused, and the unbounded self-exec chain that refusal prevents stays
  ## prevented.
  runningImageIsReproCliFlag or
    extractFilename(getAppFilename()) == reproLegacyEngineExeName()

proc spawnableWithInternalVerb*(candidate: string): bool =
  ## May ``candidate`` be spawned with an internal selector — ``internal io
  ## monitor``, ``__repro-extract-interface``, ``__repro-compile-provider``?
  ##
  ## Only ``repro`` implements those. The dangerous case is spawning THIS
  ## process's own image when it is something else: a test binary that links
  ## the engine in-process gets re-executed with arguments it does not
  ## understand, ignores them, runs its suite, re-enters the engine, and
  ## spawns itself again — an unbounded chain, one child per generation, that
  ## ends only when the machine runs out of processes or memory. Each
  ## generation also leaves a pid-named scratch directory behind.
  ##
  ## Checking only the ARGUMENT is not enough and that is why this exists as a
  ## separate predicate: ``publicCliPath`` looks explicit at the call site but
  ## is itself derived from ``getAppFilename()`` further up, so "the caller
  ## passed a path" is not evidence that the path is `repro`. The test is
  ## therefore about identity with the running image, not about provenance.
  ##
  ## A path that is NOT this image is left alone — a fixture may legitimately
  ## point at some other binary, and this predicate is not in the business of
  ## validating those.
  if candidate.len == 0:
    return false
  if os.normalizedPath(candidate) != os.normalizedPath(getAppFilename()):
    return true
  runningImageIsReproCli()

# Executable-Consolidation M1: the internal io-monitor driver is no longer a
# standalone monitor binary. ``repro`` self-spawns its own image with this
# subcommand selector (``repro internal io monitor …``). The
# executable path is ``getAppFilename()`` (more robust than argv[0]/sibling
# lookup) and the selector below is prepended by the build engine via
# ``BuildEngineConfig.monitorCliArgs``.
const internalIoMonitorArgs* = @["internal", "io", "monitor"]

proc selfSpawnIoMonitorPath*(publicCliPath = ""): string =
  ## Path to the running ``repro`` image used to self-spawn the internal
  ## io-monitor role, or "" when no such image can be named.
  ##
  ## "" is a SUPPORTED state, not an error: the engine documents an empty
  ## ``monitorCliPath`` as "no io-monitor driver wired" and falls back to the
  ## statically declared inputs/outputs (see ``monitorEvidenceRequired``).
  ##
  ## The name check on the last arm is the load-bearing part. This used to end
  ## at ``getAppFilename()`` unconditionally — and ``publicCliImagePath()``
  ## also ends there — so an embedded caller, meaning a TEST BINARY that links
  ## the engine in-process, had ITSELF wrapped as
  ## ``<test-binary> internal io monitor -- …``. A unittest binary does not
  ## implement that selector: it ignores the arguments, runs its suite, and
  ## re-enters here, wrapping itself again. One child per generation, growing
  ## without bound, each generation also leaving a pid-named scratch directory
  ## behind. It stops when the machine does.
  ##
  ## So the only images accepted are ones somebody has ASSERTED are `repro` —
  ## an explicit ``publicCliPath``, or ``REPRO_PUBLIC_CLI_PATH`` — plus the
  ## running image when it has DECLARED itself `repro`, which
  ## ``runThinApp("repro")`` does for the real CLI and a test binary linking
  ## the engine never does. See ``runningImageIsReproCli``: the assertion is
  ## the image's own, not the name it was invoked under.
  let candidate =
    if publicCliPath.len > 0:
      os.normalizedPath(publicCliPath)
    else:
      publicCliImagePath()
  if spawnableWithInternalVerb(candidate):
    return candidate
  ""

## The names of reprobuild's two user-facing CLI images, in ONE place.
##
## There are two, and which one a user reaches matters:
##
##   * ``repro`` — the THIN daemon client (`apps/repro-client/repro_client.nim`).
##     What ends up on ``PATH``. It links only ``repro_daemon_core``, hands a
##     routable ``repro build`` to the already-running per-user daemon, and
##     ``execv``s the engine image for everything else.
##   * ``reprobuild`` — the FULL CLI (`apps/repro/repro.nim`): the build
##     engine, the DSL runtime, every verb, and the image the daemon itself is
##     spawned from.
##
## WHY THE FULL CLI IS CALLED ``reprobuild``. It is the name of the product.
## The owner's decision, and the reason is that this image IS reprobuild — the
## engine, the DSL runtime and every verb — so naming it anything else would
## coin a second term for a thing that already has one. ``repro`` is the short
## command you type; ``reprobuild`` is the thing you are running.
##
## THREE ALTERNATIVES WERE CONSIDERED AND REJECTED, and the reasons are kept
## because each is a live constraint rather than a matter of taste:
##
##   * ``repro-daemon`` — already a live name for a DIFFERENT thing: the
##     resident server process, in log lines (`"restarting outdated daemon"`,
##     `"repro-daemon endpoint accepts connections"`), in
##     `UserDaemonConfig.daemonExe`, and in ``companionFullCliPath``'s standing
##     refusal to adopt a companion image. One name covering both "the resident
##     server" and "the full CLI" is the exact shape that produced the
##     ``wrapProgram`` digest defect recorded in
##     `nix/pkgs/by-name/re/reprobuild/package.nix` — two things named alike
##     and one digest comparison between them.
##   * ``repro-full`` — a RETIRED name with live refusals still attached.
##     ``companionFullCliPath`` returns "" expressly so that "a stale
##     `repro-full` lingering on PATH is never adopted as a companion", and
##     `t_local_daemons_control_plane_m1.nim` asserts that refusal. Reusing it
##     would make an invariant and its own subject the same string.
##   * ``repro-cli`` — shares the ``repro-cl`` prefix with the thin client's
##     former name ``repro-client``, so the two are ambiguous under tab
##     completion and near-identical in a diff: again, two confusable names for
##     two different images.
##
## ``reprobuild`` has none of those problems. It collides with no binary
## (`reprobuild-nix-daemon` and `reprobuild-sandbox-launcher` are distinct
## names), it is not a lifecycle word that could be read as a server, and it
## shares no prefix with ``repro-client``.
##
## THE FILENAME IS NOT WHAT MAKES AN IMAGE THE ENGINE. ``runningImageIsReproCli``
## answers that from the image's own declaration (`runThinApp("repro")` as a
## literal in `apps/repro/repro.nim`), not from ``getAppFilename()`` — see the
## three defects catalogued there. These constants are for LOCATING an image on
## disk (a sibling probe, a packaging assertion, a bootstrap lookup), never for
## deciding what a running image is allowed to do.

import std/os

const
  ReproThinClientName* = "repro"
    ## Basename of the thin daemon client — the command a user types.

  ReprobuildEngineName* = "reprobuild"
    ## Basename of the full CLI / build-engine image.

  ReproLegacyEngineName* = "repro"
    ## The engine's PRE-RENAME basename, kept as a name this repository still
    ## has to recognise rather than as an alias it produces.
    ##
    ## Two live layouts still put a full engine image at this name and must
    ## keep working:
    ##
    ##   * the bootstrap compiles (`tools/multi-distro-harness/bootstrap-*.sh`,
    ##     `tools/bootstrap-linux-smoke.sh`) run `nim c --out:<dir>/bin/repro
    ##     apps/repro/repro.nim` directly. There is no thin client in a
    ##     bootstrap tree, and there does not need to be: the engine alone is a
    ##     complete CLI.
    ##   * any install made before this rename.

proc reprobuildEngineExeName*(): string =
  addFileExt(ReprobuildEngineName, ExeExt)

proc reproThinClientExeName*(): string =
  addFileExt(ReproThinClientName, ExeExt)

proc reproLegacyEngineExeName*(): string =
  addFileExt(ReproLegacyEngineName, ExeExt)

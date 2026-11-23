## The names of reprobuild's two user-facing CLI images, and of the graph
## helper image the engine runs its own build-graph helpers with, in ONE
## place.
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

import std/[os, strutils]
from ./paths import extendedPath

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

const
  ReprobuildHelperName* = "reprobuild-helper"
    ## Basename of the GRAPH HELPER image (`apps/reprobuild-helper`): the
    ## image the build graph runs its own helper commands with
    ## (``internal compile-provider``, ``internal extract-interface``,
    ## ``internal compile-profile``, ``internal probe-profile-platforms``,
    ## ``internal dev-env-introspect``, ``internal render-dev-env-shell``,
    ## ``internal cmake-regenerate`` and their ``__repro-<role>`` spellings).
    ##
    ## WHY A THIRD IMAGE. Those helpers run INSIDE a monitored action, so
    ## everything their process does is evidence for the action. The engine
    ## links OpenSSL (``-d:ssl``, for its https cache paths), and on Windows
    ## the OpenSSL DLLs seed their stack-protector canary at load time
    ## through ``rand_s`` -> ``RtlGenRandom`` -> ``ProcessPrng``. Every
    ## engine process therefore reads entropy before ``main``, whatever verb
    ## it runs, and an action whose tree reads entropy is not published on
    ## its first run. The helper image is built from the same sources
    ## WITHOUT ``-d:ssl``, so it maps no OpenSSL and draws nothing at start,
    ## while the engine keeps TLS. The draw is removed, not waived.
    ##
    ## WHY THIS NAME. It is the engine's helper, so it carries the engine's
    ## name, and ``-helper`` says what it is for. It is not a lifecycle word
    ## (it serves no requests and stays up for nothing), and it shares the
    ## ``reprobuild-`` prefix only with images that are equally the engine's
    ## companions (``reprobuild-nix-daemon``, ``reprobuild-sandbox-launcher``).
    ##
    ## It always sits BESIDE the engine image, in every layout that ships
    ## one: ``build/bin``, a Nix package's ``bin``, a release archive's
    ## ``bin``, a self-installed prefix. See ``graphHelperImagePath``.

proc reprobuildEngineExeName*(): string =
  addFileExt(ReprobuildEngineName, ExeExt)

proc reproThinClientExeName*(): string =
  addFileExt(ReproThinClientName, ExeExt)

proc reproLegacyEngineExeName*(): string =
  addFileExt(ReproLegacyEngineName, ExeExt)

proc reprobuildHelperExeName*(): string =
  addFileExt(ReprobuildHelperName, ExeExt)

type
  GraphHelperImageMissingError* = object of IOError
    ## The graph helper image is not where it must be. Raised instead of
    ## running the helper commands in the engine: an engine process in the
    ## action's tree is exactly the start-up entropy draw the helper image
    ## exists to remove, so a silent fallback would bring the defect back
    ## without anyone seeing it.

proc graphHelperImagePath*(engineImage: string): string =
  ## Where the graph helper image of the engine at ``engineImage`` is: the
  ## file named ``reprobuildHelperExeName()`` in the same directory, or ""
  ## when ``engineImage`` is "". A name mapping only; whether the file
  ## exists is ``requireGraphHelperImage``'s question.
  ##
  ## ``engineImage`` is the path that re-enters the engine
  ## (``publicCliImagePath()``), which in every shipped layout is a file in
  ## the directory that holds the helper too: ``build/bin/reprobuild``, a Nix
  ## package's ``bin/.reprobuild-wrapped`` (makeWrapper's hidden image, in
  ## the same ``bin``), a portable Linux archive's ``bin/reprobuild``
  ## launcher, ``bin\reprobuild.exe`` in a Windows archive, or a test
  ## harness's renamed copy of the engine.
  if engineImage.len == 0:
    return ""
  parentDir(engineImage) / reprobuildHelperExeName()

proc requireGraphHelperImage*(engineImage: string; edge = ""): string =
  ## ``graphHelperImagePath(engineImage)``, or ``GraphHelperImageMissingError``
  ## naming the path it expected when the engine is there and its helper is
  ## not. ``edge`` names the action that needed it, for the message.
  ##
  ## Two states are left to the caller, as they were before the helper
  ## image existed: an ``engineImage`` of "" (the caller's "no engine
  ## image" state, which it reports itself) gives "", and an
  ## ``engineImage`` that names no file (a test's stand-in path, or an
  ## install with neither image) gives the mapped path, whose launch then
  ## fails naming it. Neither ever runs a helper command in the engine.
  result = graphHelperImagePath(engineImage)
  if result.len == 0:
    return
  if not fileExists(extendedPath(result)) and
      fileExists(extendedPath(engineImage)):
    raise newException(GraphHelperImageMissingError,
      (if edge.len > 0: "cannot schedule the " & edge & " edge: " else: "") &
      "the graph helper image " & result & " does not exist. The engine " &
      engineImage & " runs the build graph's helper commands with " &
      ReprobuildHelperName & ", which must be installed beside it (" &
      "`just build` / `scripts/build_apps.sh` build both, and every " &
      "package ships both). The helpers are not run in the engine instead: " &
      "the engine links OpenSSL, which reads entropy at start-up on " &
      "Windows and keeps the action from being cached.")

const
  MakeWrapperHiddenPrefix* = "."
  MakeWrapperHiddenSuffix* = "-wrapped"
    ## nixpkgs makeWrapper's name for the image a wrapper hides:
    ## ``wrapProgram <dir>/<name>`` moves the real image to
    ## ``<dir>/.<name>-wrapped`` and writes a shell script at ``<dir>/<name>``
    ## that exports the package's ``--set-default`` variables and then
    ## ``exec``s the hidden image (nixpkgs `setup-hooks/make-wrapper.sh`:
    ## ``hidden="$(dirname "$prog")/.$(basename "$prog")"-wrapped``).
    ## `nix/pkgs/by-name/re/reprobuild/package.nix` asserts the convention at
    ## build time, so a change in nixpkgs fails the package build.

proc makeWrapperPublicPath*(image: string): string =
  ## The wrapper script that makeWrapper put in front of ``image``:
  ## ``<dir>/<name>`` for ``<dir>/.<name>-wrapped``, or "" when ``image`` is
  ## not named as a hidden image. A name mapping only: whether that file
  ## exists, and whether it really wraps ``image``, is the caller's question.
  ##
  ## Use it where a path to this build is HANDED TO SOMETHING THAT WILL RUN IT
  ## LATER, outside this process's environment (a git hook body). Running the
  ## hidden image directly skips the wrapper's variables, among them
  ## ``REPROBUILD_SOURCE_ROOT``, and a recipe compile then has no reprobuild
  ## source tree of its own. Do NOT use it for a self-spawn: a child inherits
  ## the variables already, and the daemon digests the hidden image's own path
  ## (see package.nix, "Dependency-Attribution MAC-1").
  let name = extractFilename(image)
  if name.len <= MakeWrapperHiddenPrefix.len + MakeWrapperHiddenSuffix.len or
      not name.startsWith(MakeWrapperHiddenPrefix) or
      not name.endsWith(MakeWrapperHiddenSuffix):
    return ""
  image.parentDir / name[MakeWrapperHiddenPrefix.len ..
    ^(MakeWrapperHiddenSuffix.len + 1)]

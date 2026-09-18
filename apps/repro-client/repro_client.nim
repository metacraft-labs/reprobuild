## Dependency-Attribution MAC-1 — the thin daemon client, and the image
## installed on ``PATH`` AS ``repro``.
##
## ``repro`` hands a ``repro build`` invocation to the already-running per-user
## daemon and streams the result back. It does one other thing, and only that:
## when it cannot serve the invocation itself it ``execv``s the ENGINE image
## (``reprobuild``) with the caller's argv unchanged, so the fallback is the
## full CLI rather than a degraded imitation of it.
##
## THIS BINARY USED TO BE CALLED ``repro-client`` AND WAS OPT-IN. That name is
## retired. The saving below was real and measured from the day it was built,
## and it reached nobody: the benchmark harness, every script, and every user
## typing ``repro build`` got the engine image. An opt-in fast path nobody
## types delivers zero, so the owner's call is to make it the default. The
## name it took over from the engine is the whole content of that decision;
## see `libs/repro_core/src/repro_core/cli_images.nim` for why the engine is
## now ``reprobuild`` and not ``repro-daemon`` (a live name for the resident
## server) or ``repro-full`` (a retired name with live refusals attached).
##
## WHAT THE DEFAULT COSTS WHEN IT CANNOT ROUTE, stated before the saving so
## nobody reads the saving as unconditional. A non-routable invocation now pays
## one extra image load and module init before the engine's own: this binary's,
## measured at +2.0 ms (min) / +2.7 ms (median) on the zlib CMake benchmark
## no-op against the engine invoked directly. That is the price of the name,
## and it is paid by every interactive build, because an interactive build
## cannot be routed (see the progress-rendering paragraph below).
##
## WHY THIS EXISTS, MEASURED.
##
## The decomposition of a warm CMake no-op on macOS puts 11.6 ms — three
## times Ninja's ENTIRE no-op rebuild — in front of any build logic: image
## load, module initialisation and teardown. The engine is a very large image
## with ~12,000 dynamic-linker fixups against Ninja's 344 KB and 262, and
## ``reprobuild --version`` alone costs more than Ninja's whole no-op. No amount of
## daemon-side warming reaches that cost, because the daemon answers the cost
## of BUILD WORK DONE REPEATEDLY while the client pays image load and teardown
## on EVERY invocation. Linking only ``repro_daemon_core`` is what makes this
## binary small enough for that to matter.
##
## MEASURED ON THIS HOST (macOS arm64, the DEBUG images ``build_apps.sh``
## produces by default; a ``-d:release`` image is smaller, and the 16 MB figure
## quoted in the milestone is that one):
##
##   | image        | bytes      | dyld fixups (bind + rebase) | dylibs |
##   | reprobuild | 22,189,816 | 12,418 (274 + 12,144)       | 4      |
##   | repro        |    802,880 |    396 (134 + 262)          | 1      |
##
## Quote BOTH numbers or neither. "~130 fixups against ~12,000" compares this
## image's BIND count against the full image's TOTAL and reads as a 92x
## reduction; the like-for-like ratio is 31x. The bind counts alone are
## 134 against 274, which is barely a reduction at all — the win is rebases,
## i.e. image size, which is why ``--opt:size`` is on the entrypoint line.
##
## The single dylib is ``libSystem`` only, and that is not free: see
## ``--define:reproVendoredHash`` in ``apps/entrypoints.txt``. Without it this
## binary links ``libblake3`` and ``libxxhash`` out of the nix store and loads
## two more images before ``main``.
##
## THIS REVERSES A DELIBERATE REMOVAL, and the reversal is deliberate too.
## ``apps/repro/repro.nim`` records that the previous thin POSIX launcher was
## deleted because the ``dev-env export`` shell-hook fast path wanted ONE
## binary and the daemon was named as the replacement for the sub-5 ms path.
## That argument was about a launcher whose job was to decide, per invocation,
## which of several images to run — it duplicated CLI knowledge, and every
## verb it did not know about was a second place to change. This binary has
## the opposite shape: it knows about ONE verb, it duplicates NO CLI
## knowledge (see "WHAT THIS DOES NOT PARSE" below), and everything it does
## not recognise is handed to the full image unchanged. The earlier reason for
## removal therefore does not apply to it.
##
## WHAT THIS DOES NOT PARSE, WHICH IS THE WHOLE CORRECTNESS ARGUMENT.
##
## The request the daemon executes carries ``rawArgs`` — the caller's argv
## after ``build`` — and the daemon worker re-parses it with the SAME
## ``runBuildCommand`` the full image would have run (see
## ``installUserDaemonBuildExecutor``). So this binary does not parse targets,
## does not resolve tool provisioning, does not know what ``--variant`` means,
## and cannot answer a build question differently from the full image: it is
## not the thing answering. The three request fields the full client fills
## from its own parse — ``target``, ``toolProvisioning``, ``workRoot`` — are
## never read on the daemon side (they are request metadata only), so leaving
## them empty changes nothing that is executed.
##
## The one field with an observable consequence is ``projectRoot``, which the
## daemon records in the SESSION RECORD (``repro daemon sessions``) and echoes
## in build events that no client reads. The full client derives it by parsing
## the target; deriving it here would mean duplicating ``parseBuildTarget``,
## which is exactly the CLI knowledge this binary must not carry. It is left
## empty and the daemon's own documented fallback (``workingDir``) applies.
## For the common invocation shapes — ``repro build`` and ``repro build .``
## run from the project root — the two agree. When they disagree, the
## difference is confined to the daemon's session bookkeeping; no build
## output, exit code, cache decision or diagnostic depends on it.
##
## WHEN IT HANDS OVER, AND WHY EACH ARM IS THERE.
##
## ``shouldRouteToDaemon`` is deliberately CONSERVATIVE: every condition it
## tests is narrower than it strictly has to be, because being too narrow
## costs one ``execv`` while being too wide is a wrong answer. It routes only
## a ``build`` invocation that the full image would ALSO have routed to the
## daemon, and only when the full image's own client-side work on that path is
## provably empty:
##
##   * ``--print-solved-graph`` / ``--list-targets`` / ``--list-targets-json``
##     / ``--only`` return from ``runBuildCommand`` BEFORE the daemon
##     dispatch, so the full image runs them IN-PROCESS and writes their
##     output to its own stdout. Routing them to the daemon would send that
##     output to the daemon's log file instead, and the caller would see
##     nothing. This arm is not a nicety.
##   * ``--daemon`` in any spelling, and ``REPRO_DAEMON`` set at all, select
##     between ``auto``/``require``/``off`` with per-mode fallback semantics.
##     The full image owns that decision.
##   * ``--write-benchmark``, ``--write-stats`` and ``--stats-groups`` make the
##     full client do work of its own after the daemon answers (patching the
##     benchmark file) or convert a fallback into a hard error. Hand over.
##   * PROGRESS RENDERING is the real limit, and the reason the routable
##     surface is narrower than "every build". In daemon-hosted mode the full
##     client re-renders every forwarded progress event through its OWN
##     terminal renderer, so the bytes on stderr are produced client-side.
##     That renderer lives in ``repro_cli_support`` and is typed on the build
##     engine's ``BuildProgressEvent``; reproducing it here would be precisely
##     the duplicated client-side logic this design refuses. So this binary
##     routes only when the renderer has nothing to emit: progress explicitly
##     quiet, AND stderr not a terminal (which also makes the renderer's
##     ungated ANSI/OSC emissions inert). Widening this requires lifting the
##     progress renderer into a library both clients can link — a separate
##     change, not a thing to approximate here.
##
## EXIT CODES OF ITS OWN: 127 only, and only when ``execv`` of the full image
## fails. Every other exit code is the daemon-hosted build's or the full
## image's.
##
## HOW A USER REACHES IT: by typing ``repro``. Both images are members of
## ``repro.nim``'s ``apps`` collection, so ``.#apps`` / ``.#release`` build
## both, and every packaging route this repository has copies ``build/bin/*``
## wholesale — the Nix derivation's ``installPhase``, the ``.deb``/``.rpm``/
## pacman payloads, the release tarball, and ``install-on-distributions.sh``.
## So an install puts ``repro`` and ``reprobuild`` in the SAME bin directory,
## which is exactly what ``resolveFullCli``'s sibling probe resolves, with no
## environment variable set by anyone.
##
## THREE THINGS THAT PREVIOUSLY MADE THIS IMPOSSIBLE, AND WHAT EACH TURNED
## OUT TO REQUIRE. This header used to argue the rename could not be done.
## Two of the three arguments were about a defect that has since been fixed,
## and the third was a design question rather than an obstacle.
##
##   1. "The full image must be NAMED ``repro``, because
##      ``internalReproHelperCliPath`` returns "" for any other basename."
##      NO LONGER TRUE, and the fix predates this rename: N36 replaced the
##      filename test with the image's own DECLARATION. The engine passes
##      ``"repro"`` as a LITERAL in its own source (`apps/repro/repro.nim`:
##      ``quit runThinApp("repro")``), ``runThinApp`` sets the mark, and
##      ``runningImageIsReproCli`` reads the mark — so
##      ``internalReproHelperCliPath`` returns ``getAppFilename()`` whatever
##      the file is called. `libs/repro_cli_support/tests/
##      t_image_identity_is_declared_not_filename.nim` is the standing proof,
##      from a test binary called ``t_…``. The same literal is what
##      ``renderUsage`` prints, so the engine's usage text and every ``repro
##      …`` diagnostic still say ``repro`` too. Nothing had to learn a second
##      name; the rename is a FILENAME change and only that.
##   2. "Moving the engine breaks ``siblingTryCompileProviderPath`` /
##      ``siblingStandardProviderPath`` (silent degradation to per-project
##      provider compile) and the Nix ``wrapProgram`` loop that covers
##      ``$out/bin/*`` only." BOTH STILL TRUE, and both are avoided by NOT
##      MOVING ANYTHING. Because (1) removed the reason to relocate, the
##      engine is renamed IN PLACE: it stays in ``bin`` next to the Tier-2a/2b
##      provider binaries, and it stays inside the ``wrapProgram`` loop with
##      all ~19 ``--set-default`` variables. The thin client is in ``bin``
##      too, so it is wrapped as well and the engine it ``execv``s inherits
##      that environment.
##   3. "``bin/repro`` is already spoken for by ``apps/repro-trampoline``
##      (M5 SELF-HOST)." A GENUINE THREE-WAY QUESTION, and it composes —
##      see "LAYERING AGAINST THE TRAMPOLINE" below. Note also that the
##      trampoline is not installed as anything today: it is absent from
##      `apps/entrypoints.txt` and from ``repro.nim``'s ``apps`` collection,
##      and is built only as the test helper ``build/test-bin/
##      repro_trampoline``. The collision was between this binary and a
##      DOCUMENTED INTENT, not between two installed files.
##
## LAYERING AGAINST THE TRAMPOLINE: VERSION SELECTION OUTSIDE, DAEMON
## DISPATCH INSIDE.
##
##   PATH/repro (trampoline: which reprobuild?)
##     -> <selected prefix>/bin/repro (this binary: daemon or engine?)
##       -> <selected prefix>/bin/reprobuild  |  that version's daemon
##
## The order is forced, not chosen. The trampoline's whole job is to decide
## WHICH reprobuild runs before any reprobuild code runs, and its
## ``spsTampered`` hard-fail exists because "every version-selection bug this
## milestone exists to prevent looks exactly like a quiet fallback". A thin
## client placed OUTSIDE it would dispatch to whatever daemon happens to be
## resident — an engine of unknown version — and so would silently defeat the
## pin in exactly that way. Inside it, the selected prefix's own ``bin/repro``
## is this binary and its own ``bin/reprobuild`` is that version's engine, so
## the daemon is spawned from the pinned image and the pin holds.
##
## The trampoline therefore names BOTH halves of the version it selected: it
## runs the prefix's ``bin/repro`` and sets ``REPRO_PUBLIC_CLI_PATH`` to the
## prefix's ``bin/reprobuild``. One variable, read by this binary as its
## engine and by the engine as its own self-spawn path, which is what keeps
## the two answers from being derived separately. The cost of the layering is
## the trampoline's own process (it waits rather than ``execv``s, deliberately,
## because Windows has no ``execv``) — a cost its own header already accepts,
## and one that is now paid once on the outside rather than on the hot path.
##
## WHAT IS NOT DONE YET, so nobody reads a saving into a surface it lacks.
##
##   * INTERACTIVE TERMINAL BUILDS ARE STILL NOT SERVED, by construction —
##     see the progress-rendering paragraph above. An interactive ``repro
##     build`` therefore falls back, and pays the +2 ms handover. Widening
##     that surface needs the renderer lifted into a library both clients can
##     link. UNTIL THEN THE DEFAULT IS SLOWER FOR INTERACTIVE USE AND FASTER
##     FOR SCRIPTED USE; that is the trade the rename makes.
##   * THE BENCHMARK HARNESS DOES NOT ROUTE EITHER, as it stands.
##     ``scripts/cmake_generator_competitiveness_bench.py``'s ``repro_env``
##     sets ``REPROBUILD_LOG=quiet`` but NOT ``REPROBUILD_PROGRESS``, and the
##     engine's default progress mode is ``bpmBarLine`` rather than quiet, so
##     ``shouldRouteToDaemon`` refuses and the harness measures the engine
##     plus this binary's handover. It is left alone on purpose: setting
##     ``REPROBUILD_PROGRESS=quiet`` there would stop the harness measuring
##     progress rendering and make its numbers incomparable with the
##     historical series. Measure the routable surface explicitly instead.
##   * ``isProgressPayload`` SWALLOWS SLIGHTLY MORE than the full client's
##     ``tryRenderDaemonProgress`` does. That proc also requires the payload's
##     ``kind`` (and non-empty ``status``) to parse as the engine's enums, and
##     PRINTS the raw message when they do not; this one accepts any
##     ``{"event":"progress"}`` object. The two can only disagree when the
##     daemon emits a progress kind this client's peer does not know, i.e.
##     under daemon/client version skew — which is exactly what
##     ``startUserDaemon``'s staleness restart exists to prevent. Narrowing it
##     properly means parsing those enums, which means linking the engine.

import std/[json, os, posix, strutils, times]

import repro_core/cli_images
import repro_daemon_core

const
  FullCliEnvVar = "REPRO_FULL_CLI"
    ## Absolute path of the engine image. Set by the tests so the client never
    ## has to guess.
  PublicCliEnvVar = "REPRO_PUBLIC_CLI_PATH"
    ## The same override ``stablePublicCliPath`` honours in the engine, and
    ## what the M5 trampoline sets to the pinned prefix's ``bin/reprobuild``.
    ## Honoured here so one variable redirects both clients to the same bytes.
  BootstrapSiblingDir = "reprobuild"
    ## ``<bin>/../libexec/reprobuild/reprobuild`` — the layout
    ## ``apps/repro-trampoline`` documents for a bootstrap engine that must sit
    ## off ``PATH``. Kept as the LAST probe: it is what makes this binary
    ## correct in the M5 layout, and nothing else resolves there.
  MakeWrapperHiddenPrefix = "."
  MakeWrapperHiddenSuffix = "-wrapped"
    ## nixpkgs `setup-hooks/make-wrapper.sh`: ``hidden="$(dirname
    ## "$prog")/.$(basename "$prog")"-wrapped``. See ``resolveFullCli``.
  ExitExecFailed = 127

proc thinClientDir(): string =
  parentDir(getAppFilename())

proc resolveFullCli(): string =
  ## The engine image this client defers to. Empty when none can be named —
  ## the caller then has nothing to fall back to and says so.
  ##
  ## THE PATH MUST BE THE ONE THE ENGINE WOULD NAME FOR ITSELF, not merely a
  ## path to the same bytes, and three separate mechanisms depend on that:
  ##
  ##   * DAEMON IDENTITY. The path handed to ``startUserDaemon`` is the path
  ##     whose digest is compared against the running daemon's
  ##     (``expectedDaemonRunningDigestHex``). The engine passes
  ##     ``stablePublicCliPath()`` — i.e. its own ``getAppFilename()``. A
  ##     client naming different bytes concludes the daemon is stale and shuts
  ##     it down; the next invocation of the other client concludes the same in
  ##     reverse, and alternating the two restarts the daemon every time,
  ##     destroying the warm daemon this binary exists to exploit.
  ##   * PROVIDER RESOLUTION. ``siblingTryCompileProviderPath`` /
  ##     ``siblingStandardProviderPath`` resolve the Tier-2a/2b providers from
  ##     ``parentDir(publicCliPath)`` and degrade to per-project provider
  ##     compile — a large perf loss with NO error — when they are not there.
  ##     The daemon re-parses this client's request with the ``publicCliPath``
  ##     the request carries, so a path in the wrong directory degrades every
  ##     routed build silently.
  ##   * LOWERED-GRAPH IDENTITY. Provider commands are recorded with the paths
  ##     that resolved them, so two spellings of the same image are two
  ##     fingerprints and neither client hits the other's cache.
  ##
  ## Under Nix that path is NOT ``$out/bin/reprobuild``: ``wrapProgram`` has
  ## replaced that with a shell script and moved the real image to
  ## ``$out/bin/.reprobuild-wrapped``. The engine's own ``getAppFilename()``
  ## is therefore the hidden name, so the hidden name is probed FIRST. Its
  ## directory is still ``$out/bin``, so the providers are found and the env
  ## the wrapper set for THIS process is inherited across the ``execv``.
  ##
  ## The convention is makeWrapper's own and is asserted, not assumed:
  ## `nix/pkgs/by-name/re/reprobuild/package.nix` fails the build if the hidden
  ## image is not there, so a nixpkgs change surfaces as a build failure rather
  ## than as a daemon that restarts on every other invocation.
  let overridden = getEnv(FullCliEnvVar)
  if overridden.len > 0:
    return overridden
  let public = getEnv(PublicCliEnvVar)
  if public.len > 0:
    return
      if public.isAbsolute: normalizedPath(public)
      else: normalizedPath(getCurrentDir() / public)
  let dir = thinClientDir()
  let engineName = reprobuildEngineExeName()
  let hidden = dir /
    (MakeWrapperHiddenPrefix & ReprobuildEngineName & MakeWrapperHiddenSuffix)
  if fileExists(hidden):
    return hidden
  let sibling = dir / engineName
  # Guard against a layout in which this binary IS the engine: exec'ing
  # ourselves is an infinite loop, not a fallback.
  if fileExists(sibling) and sibling != getAppFilename():
    return sibling
  let libexec = parentDir(dir) / "libexec" / BootstrapSiblingDir / engineName
  if fileExists(libexec):
    return libexec
  ""

proc handOver(fullCli: string; args: seq[string]) {.noreturn.} =
  ## Replace this process with the engine image. ``execv`` rather than spawn:
  ## the caller's pid, its terminal, its signal disposition and its exit
  ## status must all belong to the process that does the work, and a wrapper
  ## that waited would re-add the spawn cost this binary exists to remove.
  if fullCli.len == 0:
    stderr.writeLine("repro: no " & ReprobuildEngineName &
      " image to fall back to (set " & FullCliEnvVar & ", or install " &
      ReprobuildEngineName & " next to this binary)")
    quit(ExitExecFailed)
  stdout.flushFile()
  stderr.flushFile()
  var argv = @[fullCli]
  argv.add(args)
  var cargs = allocCStringArray(argv)
  discard execv(cstring(fullCli), cargs)
  deallocCStringArray(cargs)
  stderr.writeLine("repro: cannot exec " & fullCli & ": " &
    $strerror(errno))
  quit(ExitExecFailed)

proc flagMatches(arg, name: string): bool =
  ## ``--flag`` and ``--flag=value``. The space form ``--flag value`` is
  ## caught by the same comparison on the flag token itself.
  arg == name or arg.startsWith(name & "=")

const
  ClientHandledFlags = [
    # Return from `runBuildCommand` before the daemon dispatch: the full
    # image runs these in-process and writes to its own stdout.
    "--print-solved-graph",
    "--list-targets",
    "--list-targets-json",
    "--only",
    # Select the daemon mode itself, with per-mode fallback semantics.
    "--daemon",
    # Leave client-side work after the daemon answers, or turn a fallback
    # into a hard error.
    "--write-benchmark",
    "--write-stats",
    "--stats-groups",
    # Client-side terminal rendering; see the module header. ``--progress``
    # is NOT in this list: it is handled by ``shouldRouteToDaemon`` directly,
    # because ``--progress=quiet`` selects the very mode that makes routing
    # safe while every other value forbids it.
    "--progress-bars"
  ]

proc isQuietValue(value: string): bool =
  value.strip().toLowerAscii() == "quiet"

proc progressEnvIsExplicitlyQuiet(): bool =
  ## Narrower than ``configuredBuildProgressMode``, on purpose. The full
  ## image also falls back to quiet when ``IN_AGENT_SHELL`` is set; treating
  ## that as routable would make this binary carry a second copy of a default
  ## that can change. Requiring the explicit value costs an ``execv`` in the
  ## implicit case and cannot be wrong.
  isQuietValue(getEnv("REPROBUILD_PROGRESS", ""))

proc stderrIsTerminal(): bool =
  isatty(cint(2)) == 1

proc shouldRouteToDaemon(args: seq[string]): bool =
  ## ``args`` is the full argv after the program name.
  if args.len == 0 or args[0] != "build":
    return false
  if getEnv("REPRO_DAEMON", "").len > 0:
    return false
  if stderrIsTerminal():
    # ``supportsAnsiProgress`` is then true in the full image, which makes
    # its progress renderer emit ANSI line-clears and OSC 9;4 terminal
    # progress REGARDLESS of the quiet mode — those writes are not gated on
    # the renderer being enabled. Nothing here may pretend to reproduce them.
    return false
  var quietFromFlag = false
  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      # Everything after `--` is forwarded to the action verbatim and is not
      # a build flag.
      break
    if arg == "--progress":
      # Space form. A missing or non-quiet value is the full image's problem
      # (it may even be an error); hand over either way.
      if i + 1 >= args.len or not isQuietValue(args[i + 1]):
        return false
      quietFromFlag = true
      inc i, 2
      continue
    if arg.startsWith("--progress="):
      # Every occurrence must be quiet. Requiring all of them rather than the
      # last makes the answer independent of the full image's last-wins order.
      if not isQuietValue(arg[len("--progress=") .. ^1]):
        return false
      quietFromFlag = true
      inc i
      continue
    for flag in ClientHandledFlags:
      if flagMatches(arg, flag):
        return false
    inc i
  if not quietFromFlag and not progressEnvIsExplicitlyQuiet():
    return false
  true

proc buildRunId(): string =
  let nowTime = getTime()
  "build-" & $getCurrentProcessId() & "-" & $nowTime.toUnix & "-" &
    $nowTime.nanosecond

proc isProgressPayload(payloadJson: string): bool =
  ## The full client swallows daemon-forwarded progress events — it renders
  ## them through its own renderer and returns without printing the event
  ## message. In quiet mode the render is a no-op, so the net effect is that
  ## the message never reaches the terminal. Reproduce the SWALLOW, which is
  ## the only observable part on this path.
  if payloadJson.len == 0:
    return false
  var node: JsonNode
  try:
    node = parseJson(payloadJson)
  except CatchableError:
    return false
  node.kind == JObject and node{"event"}.getStr == "progress"

proc streamDaemonBuild(fullCli: string; args: seq[string]): int =
  ## Raises on every failure so the caller can hand over. Nothing here may
  ## fall back on its own: once the daemon has accepted the request the build
  ## is running, and a second attempt from the full image would run it twice.
  let config = defaultUserDaemonConfig(devMode = true)
  # The same call the engine's own client makes, from the same library: it
  # spawns the daemon when absent and RESTARTS IT when its running image no
  # longer matches the on-disk engine. That staleness check is why this binary
  # must hand ``startUserDaemon`` the ENGINE's path and not its own — a daemon
  # serving from a thin client image cannot execute builds at all — and why
  # ``resolveFullCli`` has to name the SAME path the engine names for itself.
  discard startUserDaemon(fullCli, config)
  let request = UserDaemonBuildRequest(
    runId: buildRunId(),
    workingDir: getCurrentDir(),
    publicCliPath: fullCli,
    rawArgs: args[1 .. ^1],
    environment: daemonCarriedEnvironment(),
    attached: true,
    cancelOnDisconnect: true)
  let daemonResult = requestUserDaemonBuild(request, config.endpoint,
    proc(event: UserDaemonBuildEvent) =
      if event.kind == bekDiagnostic and isProgressPayload(event.payloadJson):
        return
      let isError = event.kind in {bekFinished, bekCancelled, bekUnsupported} and
        event.severity == "error"
      if (event.kind == bekDiagnostic or isError) and event.message.len > 0:
        # The full client clears its progress line here. With stderr not a
        # terminal and progress quiet that write is a bare "\r"; emit the
        # same byte so a redirected build's stderr is unchanged.
        stderr.write("\r")
        if isError or event.payloadJson.contains("\"stream\":\"stderr\""):
          stderr.write(event.message)
          if not event.message.endsWith("\n"):
            stderr.writeLine("")
        else:
          stdout.write(event.message)
          if not event.message.endsWith("\n"):
            stdout.writeLine(""))
  if not daemonResult.supported:
    # The daemon cannot execute builds. The full image treats this as a
    # fallback to direct mode; hand over and let it do exactly that.
    raise newException(UserDaemonClientError,
      "daemon-hosted build unsupported: " & daemonResult.message)
  daemonResult.exitCode

proc main(): int =
  let args = commandLineParams()
  let fullCli = resolveFullCli()
  if fullCli.len == 0 or not shouldRouteToDaemon(args):
    handOver(fullCli, args)
  try:
    return streamDaemonBuild(fullCli, args)
  except CatchableError:
    # Unreachable daemon, failed handshake, protocol mismatch, or a daemon
    # that cannot build. The full image re-attempts the daemon and falls back
    # to a direct build — the same two-step it performs when it is the one
    # that fails, so handing over preserves its behaviour exactly.
    handOver(fullCli, args)

when isMainModule:
  quit main()

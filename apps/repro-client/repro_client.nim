## Dependency-Attribution MAC-1 — the thin daemon client.
##
## ``repro-client`` hands a ``repro build`` invocation to the already-running
## per-user daemon and streams the result back. It does one other thing, and
## only that: when it cannot serve the invocation itself it ``execv``s the
## full ``repro`` image with the caller's argv unchanged, so the fallback is
## the full CLI rather than a degraded imitation of it.
##
## WHY THIS EXISTS, MEASURED.
##
## The decomposition of a warm CMake no-op on macOS puts 11.6 ms — three
## times Ninja's ENTIRE no-op rebuild — in front of any build logic: image
## load, module initialisation and teardown. ``repro`` is a very large image
## with ~12,000 dynamic-linker fixups against Ninja's 344 KB and 262, and
## ``repro --version`` alone costs more than Ninja's whole no-op. No amount of
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
##   | repro        | 22,189,816 | 12,418 (274 + 12,144)       | 4      |
##   | repro-client |    802,880 |    396 (134 + 262)          | 1      |
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
## WHAT IS NOT DONE YET, so nobody reads a saving into a binary nothing runs.
##
##   * NOTHING INSTALLS THIS. No packaging rule, dev-env hook or PATH
##     placement puts ``repro-client`` where ``repro`` is invoked from, and
##     ``REPRO_FULL_CLI`` is set only by the tests. Until that ships, the
##     measured saving is a property of the binary, not of anyone's prompt.
##     ``resolveFullCli``'s ``libexec/reprobuild/repro`` probe describes the
##     intended installed layout; no packaging rule produces it today.
##   * It is NOT a member of ``repro.nim``'s ``apps`` collection, so the
##     graph-owned ``.#apps`` / ``.#release`` path does not build it — only
##     ``scripts/build_apps.sh`` does, from ``apps/entrypoints.txt``.
##     (``attestation-agent`` has the same gap; see the entrypoints file.)
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

import repro_daemon_core

const
  FullCliEnvVar = "REPRO_FULL_CLI"
    ## Absolute path of the full ``repro`` image. Set by the packaging layer
    ## and by the tests so the client never has to guess.
  PublicCliEnvVar = "REPRO_PUBLIC_CLI_PATH"
    ## The same override ``stablePublicCliPath`` honours in the full image.
    ## Honoured here first so a caller that redirects one client redirects
    ## both.
  BootstrapSiblingDir = "reprobuild"
    ## ``<bin>/../libexec/reprobuild/repro`` — the layout
    ## ``apps/repro-trampoline`` already documents. The full image has to be
    ## NAMED ``repro``: the build engine schedules provider-compile and
    ## interface-extraction edges by self-spawning its own image, and
    ## ``internalReproHelperCliPath`` accepts only an image called ``repro``.
  ExitExecFailed = 127

proc thinClientDir(): string =
  parentDir(getAppFilename())

proc resolveFullCli(): string =
  ## The full ``repro`` image this client defers to. Empty when none can be
  ## named — the caller then has nothing to fall back to and says so.
  let overridden = getEnv(FullCliEnvVar)
  if overridden.len > 0:
    return overridden
  let public = getEnv(PublicCliEnvVar)
  if public.len > 0:
    return
      if public.isAbsolute: normalizedPath(public)
      else: normalizedPath(getCurrentDir() / public)
  let dir = thinClientDir()
  let libexec = parentDir(dir) / "libexec" / BootstrapSiblingDir /
    addFileExt("repro", ExeExt)
  if fileExists(libexec):
    return libexec
  let sibling = dir / addFileExt("repro", ExeExt)
  # Guard against a layout in which this binary IS ``repro``: exec'ing
  # ourselves is an infinite loop, not a fallback.
  if fileExists(sibling) and sibling != getAppFilename():
    return sibling
  ""

proc handOver(fullCli: string; args: seq[string]) {.noreturn.} =
  ## Replace this process with the full image. ``execv`` rather than spawn:
  ## the caller's pid, its terminal, its signal disposition and its exit
  ## status must all belong to the process that does the work, and a wrapper
  ## that waited would re-add the spawn cost this binary exists to remove.
  if fullCli.len == 0:
    stderr.writeLine("repro-client: no full repro image to fall back to " &
      "(set " & FullCliEnvVar & ", or install repro next to this binary)")
    quit(ExitExecFailed)
  stdout.flushFile()
  stderr.flushFile()
  var argv = @[fullCli]
  argv.add(args)
  var cargs = allocCStringArray(argv)
  discard execv(cstring(fullCli), cargs)
  deallocCStringArray(cargs)
  stderr.writeLine("repro-client: cannot exec " & fullCli & ": " &
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
  # The same call the full client makes, from the same library: it spawns the
  # daemon when absent and RESTARTS IT when its running image no longer
  # matches the on-disk ``repro``. That staleness check is why this binary
  # must hand ``startUserDaemon`` the FULL image's path and not its own — a
  # daemon serving from a thin client image cannot execute builds at all.
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

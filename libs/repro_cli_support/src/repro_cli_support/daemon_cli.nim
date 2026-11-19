## The per-user daemon's configuration from ``repro daemon``'s command line.
##
## ``repro daemon serve`` is the daemon process (``daemonProcessArgs`` in
## ``repro_daemon_core`` writes its words); every other ``repro daemon``
## subcommand is a client of it, and all of them take the daemon's flags.
## Its own module so a test binary that stands in for the daemon image reads
## its command line through the same generated parser and the same mapping
## as ``repro``, without linking the engine.

import std/os

import repro_daemon_core

import ./cli_program

proc userDaemonConfigOf*(d: ReproCommandLineDaemon): UserDaemonConfig =
  ## The daemon configuration `repro daemon`'s flags select, over the
  ## per-user defaults; without `--log` the log is
  ## `<state dir>/logs/repro-daemon.log`.
  result = defaultUserDaemonConfig()
  result.foreground = d.foreground
  result.devMode = d.dev
  result.systemScope = d.system
  if d.daemonExe.len > 0: result.daemonExe = d.daemonExe
  if d.sourceExe.len > 0: result.sourceExe = d.sourceExe
  if d.stagedGeneration.len > 0:
    result.stagedGenerationDir = d.stagedGeneration
  if d.previousStagedGeneration.len > 0:
    result.previousStagedGenerationDir = d.previousStagedGeneration
  if d.restartRunId.len > 0: result.restartRunId = d.restartRunId
  if d.endpoint.len > 0: result.endpoint = d.endpoint
  if d.stateDir.len > 0: result.stateDir = d.stateDir
  if d.stateRoot.len > 0: result.leaseStoreRoot = d.stateRoot
  if d.peerCache.len > 0: result.peerCacheSpec = d.peerCache
  if d.trustProfile.len > 0: result.trustProfile = d.trustProfile
  result.logPath =
    if d.log.len > 0: d.log
    else: result.stateDir / "logs" / "repro-daemon.log"

proc userDaemonConfigOfArgs*(argv: openArray[string]): UserDaemonConfig {.
    raises: [CatchableError].} =
  ## ``userDaemonConfigOf`` of the command line ``argv`` (without the image;
  ## a ``repro daemon ...`` command line), parsed by the generated parser.
  ## Raises ``CliUsageError`` when the parser refuses it and ``ValueError``
  ## when it is not a ``repro daemon`` command line.
  let conf = ReproCommandLine.load(argv)
  if conf.command != ReproCommandLineCommand.daemon:
    raise newException(ValueError, "not a `repro daemon` command line")
  userDaemonConfigOf(conf.daemon)

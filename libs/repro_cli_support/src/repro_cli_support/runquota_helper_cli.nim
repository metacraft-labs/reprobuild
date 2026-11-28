## The RunQuota helper's command line: ``repro internal runquota-helper``,
## also spelt ``__repro-runquota-helper``, parsed from repro's description.
##
## The build engine starts the helper as a child of whichever image it names
## (``helperCliArgs`` in ``repro_runquota`` writes the words). That image is
## the CLI, or, in the integration tests, a test binary that stands in for it
## and serves the helper role itself; both read the words here, through the
## generated parser, so the parent's values reach the helper through exactly
## the description the CLI parses. This module links the parser but not the
## engine, which is what keeps it usable from such a test binary.

import repro_runquota

import ./cli_program

proc runRunQuotaHelperOf*[T](c: T): int =
  ## The helper run from its configuration (the ``internal runquota-helper``
  ## or the ``__repro-runquota-helper`` command): the lease request and the
  ## command, as ``helperCliArgs`` wrote them. A negative count or size is a
  ## usage error (exit 2).
  for (name, value) in [("cpu", c.cpu), ("mem", c.mem),
                        ("pool-units", c.poolUnits),
                        ("pool-capacity", c.poolCapacity),
                        ("cpu-min", c.cpuMin), ("cpu-pref", c.cpuPref)]:
    if value < 0:
      stderr.writeLine("repro internal runquota-helper: --" & name &
        " must not be negative, got " & $value)
      return 2
  let request = ReproResourceRequest(
    label: c.label,
    commandStatsId: c.stats,
    cpuMilli: uint32(c.cpu),
    memoryBytes: uint64(c.mem),
    namedPool: c.pool,
    namedPoolUnits: uint32(c.poolUnits),
    namedPoolCapacity: uint32(c.poolCapacity),
    cpuMinMilli: uint32(c.cpuMin),
    cpuPreferredMilli: uint32(c.cpuPref))
  let command = ReproCommandSpec(
    argv: c.command,
    cwd: c.cwd,
    env: c.env,
    stdoutLimit: c.stdoutLimit,
    stderrLimit: c.stderrLimit,
    isolatedEnv: c.isolatedEnv,
    widthFlag: c.widthFlag)
  var memoryCap: ReproMemoryCapPolicy
  var problem = ""
  if not decodePolicyArg(c.memoryCap, memoryCap, problem):
    stderr.writeLine("repro internal runquota-helper: --memory-cap is not " &
      "a memory-cap policy (" & problem & "): " & c.memoryCap)
    return 2
  runRunQuotaHelper(request, command, c.resultPath, memoryCap)

proc selectsRunQuotaHelper*(argv: openArray[string]): bool =
  ## Whether ``argv`` (without the image) starts with the words of the
  ## helper's command line, in either spelling: what an image standing in
  ## for the CLI (the integration tests' fixtures) asks before it hands
  ## ``argv`` to ``runRunQuotaHelperArgs``.
  let words = RunQuotaHelperCommandWords
  (argv.len >= words.len and argv[0 ..< words.len] == @words) or
    (argv.len >= 1 and argv[0] == "__repro-runquota-helper")

proc runRunQuotaHelperArgs*(argv: openArray[string]): int =
  ## ``argv`` (without the image) parsed by the generated parser and, when
  ## it is the helper's command line, run (``runRunQuotaHelperOf``). Help
  ## and usage errors are answered as for any repro command line; another
  ## command is a usage error (exit 2).
  runReproArgs(argv, proc (conf: ReproCommandLine): int =
    case conf.command
    of ReproCommandLineCommand.reproRunquotaHelper:
      runRunQuotaHelperOf(conf.reproRunquotaHelper)
    of ReproCommandLineCommand.internal:
      if conf.internal.command == ReproCommandLineInternalCommand.runquotaHelper:
        runRunQuotaHelperOf(conf.internal.runquotaHelper)
      else:
        stderr.writeLine("repro: not the RunQuota helper's command line")
        2
    else:
      stderr.writeLine("repro: not the RunQuota helper's command line")
      2)

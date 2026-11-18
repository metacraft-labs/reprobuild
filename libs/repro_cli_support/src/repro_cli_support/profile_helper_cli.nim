## The profile helpers' command lines: ``repro internal compile-profile``
## and ``repro internal probe-profile-platforms`` (also spelt
## ``__repro-compile-profile`` and ``__repro-probe-profile-platforms``),
## parsed from repro's description.
##
## The profile edges (``repro_profile_compile/edge``) write the words; the
## CLI, or a test binary standing in for it, reads them here through the
## generated parser and runs the helper's body. Links the parser and the
## profile compiler, not the engine.

import repro_profile_compile/helper

import ./cli_program

proc runProfileCompileOf*[T](c: T): int =
  ## ``repro internal compile-profile`` from its configuration.
  runProfileCompileHelper(c.profile, c.binary, c.nimcache, c.repoRoot,
    c.verbose)

proc runProfilePlatformProbeOf*[T](c: T): int =
  ## ``repro internal probe-profile-platforms`` from its configuration.
  runProfilePlatformProbeHelper(c.profile, c.`out`, c.nimcache, c.repoRoot)

proc runProfileHelperArgs*(argv: openArray[string]): int =
  ## ``argv`` (without the image) parsed by the generated parser and, when it
  ## is one of the profile helpers' command lines, run. Help and usage
  ## errors are answered as for any repro command line; another command is
  ## a usage error (exit 2).
  runReproArgs(argv, proc (conf: ReproCommandLine): int =
    case conf.command
    of ReproCommandLineCommand.reproCompileProfile:
      runProfileCompileOf(conf.reproCompileProfile)
    of ReproCommandLineCommand.reproProbeProfilePlatforms:
      runProfilePlatformProbeOf(conf.reproProbeProfilePlatforms)
    of ReproCommandLineCommand.internal:
      case conf.internal.command
      of ReproCommandLineInternalCommand.compileProfile:
        runProfileCompileOf(conf.internal.compileProfile)
      of ReproCommandLineInternalCommand.probeProfilePlatforms:
        runProfilePlatformProbeOf(conf.internal.probeProfilePlatforms)
      else:
        stderr.writeLine("repro: not a profile helper's command line")
        2
    else:
      stderr.writeLine("repro: not a profile helper's command line")
      2)

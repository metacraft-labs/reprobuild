## The fixture's program, loading its configuration with confutils'
## ``cliConfiguration`` from the description its ``repro.nim`` declares:
## the command line, and the environment variable the description names.

import std/os
import confutils/clispec_config
import ../repro

static:
  doAssert $fixtureDslMode == "rdmThin",
    "repro.nim compiled in " & $fixtureDslMode & ", not the thin mode"

csm12ProgCliDescription(cliConfiguration, Csm12Prog)

try:
  let conf = Csm12Prog.load(commandLineParams(),
    CliSources(env: cliProcessEnv()))
  echo "mode=", fixtureDslMode, " jobs=", conf.jobs, " greeting=",
    conf.greeting, " color=", conf.color, " verbose=", conf.verbose
except CliUsageError as e:
  Csm12Prog.printError(e)
  quit 2

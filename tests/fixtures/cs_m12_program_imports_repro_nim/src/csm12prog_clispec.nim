## The fixture's program, parsing its command line with clispec's
## ``cliProgram`` from the description its ``repro.nim`` declares.

import clispec
import ../repro

static:
  doAssert $fixtureDslMode == "rdmThin",
    "repro.nim compiled in " & $fixtureDslMode & ", not the thin mode"

csm12ProgCliDescription(cliProgram, Csm12Prog)

try:
  let conf = Csm12Prog.load()
  echo "mode=", fixtureDslMode, " jobs=", conf.jobs, " greeting=",
    conf.greeting, " color=", conf.color, " verbose=", conf.verbose
except CliUsageError as e:
  Csm12Prog.printError(e)
  quit 2

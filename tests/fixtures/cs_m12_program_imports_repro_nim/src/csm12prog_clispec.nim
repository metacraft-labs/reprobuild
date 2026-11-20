## The fixture's program, parsing its command line with clispec's
## ``cliProgram`` from the description its ``repro.nim`` declares.

import std/os
import clispec
import ../repro

static:
  doAssert $fixtureDslMode == "rdmThin",
    "repro.nim compiled in " & $fixtureDslMode & ", not the thin mode"

csm12ProgCliDescription(cliProgram, Csm12Prog)

try:
  # ``load(argv)``: the exported ``load()`` overload that reads the
  # process's arguments itself does not compile in this clispec revision
  # (its body calls the exported name ``load*``).
  let conf = Csm12Prog.load(commandLineParams())
  echo "mode=", fixtureDslMode, " jobs=", conf.jobs, " greeting=",
    conf.greeting, " color=", conf.color, " verbose=", conf.verbose
except CliUsageError as e:
  Csm12Prog.printError(e)
  quit 2

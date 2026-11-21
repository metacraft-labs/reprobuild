## The baseline of ``tests/integration/test_cs_m12_thin_import_cost.nim``:
## ``tests/fixtures/cs_m12_program_imports_repro_nim/src/csm12prog_clispec.nim``
## with its command line written here instead of read from ``repro.nim``.
## The ``cliProgram`` body is the ``cli:`` section of that fixture's
## ``repro.nim``, verbatim (the test compares the two), and the constant and
## procedure it names are declared here, so the program parses the same
## command line and imports nothing of reprobuild. What it costs to compile
## is what the thin mode is measured against.

import std/os
import clispec

const DefaultJobs* = 4
  ## A ``cli:`` default read from an exported constant.

proc defaultGreeting*(): string =
  ## A ``cli:`` default read from an exported procedure.
  "hello"

cliProgram(Csm12Prog, "csm12prog", exported = true):
      help "The fixture's program"
      flag jobs is int, default = DefaultJobs, env = ["CSM12_JOBS"],
        help = "How many jobs to run"
      flag greeting is string, default = defaultGreeting(),
        help = "What to say"
      flag color is string, values = ["red", "green", "blue"],
        default = "red", help = "The colour to say it in"
      boolFlag verbose is bool, help = "Print more"
      # Reprobuild's own vocabulary: ignored by a plain generator.
      subTools "sh"

try:
  let conf = Csm12Prog.load(commandLineParams())
  echo "mode=none jobs=", conf.jobs, " greeting=", conf.greeting,
    " color=", conf.color, " verbose=", conf.verbose
except CliUsageError as e:
  Csm12Prog.printError(e)
  quit 2

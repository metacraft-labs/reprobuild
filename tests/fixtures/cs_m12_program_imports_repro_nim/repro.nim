## Fixture project of
## ``tests/integration/test_cs_m12_program_imports_repro_nim.nim``.
##
## The project's programs (``src/``) import this file with no mode define,
## so it compiles in the DSL's thin mode, and each instantiates the command
## line its ``executable`` declares (``csm12_progCliDescription``) with a CLI
## library. What only the engine's modes may compile is either guarded by
## ``when reproDslMode != rdmThin:`` (an engine-only import and declaration)
## or sits in a ``uses:`` and a ``build:`` body, which the thin mode does not
## compile. Both bodies are deliberately broken: each names an identifier
## nothing declares, so a mode that compiled them could not compile this
## file.

import reprobuild

when reproDslMode != rdmThin:
  # A standard-library package module: it uses the full DSL's types, so it
  # does not compile in the thin mode.
  import reprobuild/dsl/packages/sh
  type Csm12EngineOnly* = BuildActionDef

const fixtureDslMode* = reproDslMode
  ## The mode this file compiled in, for the programs to report.

const DefaultJobs* = 4
  ## A ``cli:`` default read from an exported constant.

proc defaultGreeting*(): string =
  ## A ``cli:`` default read from an exported procedure.
  "hello"

package csm12prog:
  uses:
    "sh"
    csm12UndeclaredUsesEntry

  executable "csm12-prog":
    name: "csm12prog"
    cli:
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

  build:
    csm12UndeclaredBuildStep(42)

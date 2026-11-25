## `csm8d-tool`: parses the command line `repro.nim` declares with clispec's
## `cliProgram`. `--printCompletion=<shell>` prints the completion script
## clispec gives it, which is what the packages must carry.
##
## When the test removes the `cli:` section, the description's template is
## not declared and the program prints a line and exits.

import std/os
import clispec
import ../repro

when declared(csm8dToolCliDescription):
  csm8dToolCliDescription(cliProgram, Csm8dTool)

  let conf = Csm8dTool.load(commandLineParams())
  if conf.printCompletion.len > 0:
    var shell: CliShell
    if not cliParseShell(conf.printCompletion, shell):
      quit 64
    stdout.write(Csm8dTool.completionScript(shell))
  else:
    echo "csm8d-tool"
else:
  echo "csm8d-tool has no description"

## `csm14-plain`: parses the command line `repro.nim` declares with clispec's
## `cliProgram` alone. `--printCompletion=<shell>` prints the completion
## script clispec gives it.

import std/os
import clispec
import ../repro

csm14PlainCliDescription(cliProgram, Csm14Plain)

let conf = Csm14Plain.load(commandLineParams())
if conf.printCompletion.len > 0:
  var shell: CliShell
  if not cliParseShell(conf.printCompletion, shell):
    quit 64
  stdout.write(Csm14Plain.completionScript(shell))
else:
  echo "csm14-plain"

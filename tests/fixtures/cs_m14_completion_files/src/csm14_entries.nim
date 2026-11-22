## `csm14-entries`: parses the command line `repro.nim` declares with
## clispec's `cliProgram` inside nim-entrypoints' `main:`, without the
## self-description entries. `--printCompletion=<shell>` prints the
## completion script clispec gives it.

import clispec, entrypoints
import ../repro

csm14EntriesCliDescription(cliProgram, Csm14Entries)

main:
  let conf = Csm14Entries.load(entryArgs())
  if conf.printCompletion.len > 0:
    var shell: CliShell
    if not cliParseShell(conf.printCompletion, shell):
      quit 64
    stdout.write(Csm14Entries.completionScript(shell))
  else:
    echo "csm14-entries"

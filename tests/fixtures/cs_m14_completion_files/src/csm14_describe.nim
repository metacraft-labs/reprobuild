## `csm14-describe`: parses the command line `repro.nim` declares through
## nim-entrypoints, and registers the self-description entries, so
## `--entrypoint=completion <shell>` prints its completion script.
##
## When the test removes the `cli:` section, the description's template is
## not declared and the program is a bare `main:`: its compile would still
## write an entry list if it were given the define.

import clispec, entrypoints, entrypoints/[clispec, describe]
import ../repro

when declared(csm14DescribeCliDescription):
  csm14DescribeCliDescription(cliProgramWithEntryPoint, Csm14Describe)

  describeProgram(Csm14Describe)

  main:
    let conf = Csm14Describe.load(entryArgs())
    echo "csm14-describe jobs=", conf.jobs
else:
  main:
    echo "csm14-describe has no description"

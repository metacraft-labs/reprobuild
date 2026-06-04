## Named-Targets M1 test fixtures for
## ``t_engine_target_export_table_records_ambiguity``.
##
## Two packages in one project each emit an edge whose implicit name
## is ``cli``. The M1 wiring records both qualified forms
## (``ambigPkgA:cli`` and ``ambigPkgB:cli``) and a single ambiguity
## row on the unqualified ``cli`` listing the candidate qualified
## forms. The unqualified-name lookup that M2 will implement consumes
## this row.

import repro_project_dsl

defineCliInterface ambigNimC, "test-ambig-nimC":
  subcmd "c":
    flag output is string,
      alias = "--out:",
      role = output,
      required = true
    pos source is string,
      role = input,
      position = 0
    outputs output

package ambigPkgA:
  uses:
    "nim >=2.2 <3.0"
  build:
    discard ambigNimC.c(source = "src/cli.nim", output = "bin/cli",
      actionId = "cli-a")

package ambigPkgB:
  uses:
    "nim >=2.2 <3.0"
  build:
    discard ambigNimC.c(source = "src/cli.nim", output = "bin/cli",
      actionId = "cli-b")

export ambigNimC
export buildAmbigPkgAPackage
export buildAmbigPkgBPackage

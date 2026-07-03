## Cross-Repo-Source-Consumption SC-9 fixture — a workspace PRODUCER project
## exporting an ``executable … cli:`` typed contract (export-by-default).
##
## Consumed as a TYPED call by the sibling consumer in
## ``tests/integration/t_sc_uses_import_resolves_workspace_project_schema.nim``
## via ``uses: "scprod9exe"``: the SC-9 ``usesImportCode`` extension discovers
## this sibling (``../scprod9exe/repro.nim`` relative to the consumer source),
## imports it, and the emitted ``scprod9exe.serve(...)`` / ``.status(...)``
## wrapper procs type-check against THIS schema at the consumer's macro
## expansion. Renaming a verb here is a COMPILE break at the consumer.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package scprod9exe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable scprod9exe:
    name: "scprod9exe"
    cli:
      subcmd "serve":
        flag socket is string
      subcmd "status":
        flag verbose is string

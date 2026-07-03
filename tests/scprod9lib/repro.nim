## Cross-Repo-Source-Consumption SC-9 fixture — a workspace PRODUCER project
## exporting a ``library`` typed contract (export-by-default). Consumed as a
## typed library accessor by the SC-9 test consumer via ``uses: "scprod9lib"``.

import repro_project_dsl

package scprod9lib:
  library scprod9lib:
    kind: shared

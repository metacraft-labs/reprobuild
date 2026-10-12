## `prek` moved to the reprobuild-packages catalog
## (`packages/interfaces/prek/repro.nim`). A `uses: "prek"` line resolves it
## from there (reprobuild-specs/Provisioning-Contributions.md, "Catalog Lookup
## And Provisioning").
##
## This module is a one-release stub, kept so a recipe that still imports
## `repro_dsl_stdlib/packages/prek` directly gets an error that says what to do
## instead of "cannot open file". Delete it in the release after the first
## release that ships it.

{.error: "repro_dsl_stdlib/packages/prek moved to reprobuild-packages " &
  "(packages/interfaces/prek/repro.nim); drop the import and rely on " &
  "uses: \"prek\", which resolves the package from the catalog.".}

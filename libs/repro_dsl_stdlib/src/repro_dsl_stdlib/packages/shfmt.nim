## `shfmt` moved to the reprobuild-packages catalog
## (`packages/interfaces/shfmt/repro.nim`). A `uses: "shfmt"` line resolves it
## from there (reprobuild-specs/Provisioning-Contributions.md, "Catalog Lookup
## And Provisioning").
##
## This module is a one-release stub, kept so a recipe that still imports
## `repro_dsl_stdlib/packages/shfmt` directly gets an error that says what to do
## instead of "cannot open file". Delete it in the release after the first
## release that ships it.

{.error: "repro_dsl_stdlib/packages/shfmt moved to reprobuild-packages " &
  "(packages/interfaces/shfmt/repro.nim); drop the import and rely on " &
  "uses: \"shfmt\", which resolves the package from the catalog.".}

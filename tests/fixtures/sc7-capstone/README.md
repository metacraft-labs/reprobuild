# SC-7 capstone fixture recipes

The checked-in sources of
`tests/integration/t_sc_capstone_reprobuild_runquota_and_library_edge_both_modes.nim`:
an executable producer (`exeprod`), a library producer (`libprod`, whose
`greeting.c` the test writes itself because each arm stamps it differently),
the consumer that uses both (`consumer`) and the falsifiability consumer that
names `exeprod` with no override or lock (`noedge-consumer`).

The test copies them into its scratch tree and never writes here. They are
files rather than string literals in the test so that the recipe bytes are the
same on every run: the engine keys its recipe compiles on those bytes, and the
run-wide action cache then serves the producers' provider compiles and
interface extractions instead of repeating them. The test's execute edge
declares every file here as an input (`testFixtureArtifacts` in `repro.nim`).

Every edge in these recipes is `cacheable = false`, so the producers and the
consumer execute on every build regardless of what the shared cache holds:
the test's "materialized from source by THIS run" assertions depend on it.

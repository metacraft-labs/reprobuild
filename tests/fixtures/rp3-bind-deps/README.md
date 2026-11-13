# RP3 bind-deps fixture recipes

Five provider recipes for `tests/integration/t_rp3_bind_deps_and_sharing.nim`:
one dependency (`dep`), a second version of it (`depv2`), two consumers that
reach it only through `useBoundDependency("dep")` (`consumer-a`,
`consumer-b`), and a consumer that binds nothing (`plain`).

Their provider binaries are build-graph edges
(`reprobuild.test_fixtures.rp3_provider_<name>` in `repro.nim`, output under
`build/test-fixtures/rp3-bind-deps/`), declared as typed inputs of the test's
execute edge. The test only runs them (Test-Fixtures-In-Build-Graph.md). It
never writes here.

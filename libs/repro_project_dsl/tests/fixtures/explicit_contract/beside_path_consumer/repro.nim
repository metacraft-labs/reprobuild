## A consumer that opts into an explicit `usesImportPath` and also names a
## workspace sibling the path holds no module for. The path still takes the
## selectors it has a module for (`fixture_probe`); the sibling resolves as a
## workspace project, so the recipe can declare that dependency at all.
import repro_project_dsl

package besidePathConsumer:
  usesImportPath "libs/repro_project_dsl/tests/fixtures/explicit_contract/consumer/contracts"
  uses:
    "fixture_probe"
    "fixture_minimal"

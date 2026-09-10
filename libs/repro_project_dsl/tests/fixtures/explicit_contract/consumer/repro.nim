import repro_project_dsl
import ./contracts/fixture_probe as explicitApi

package explicitContractConsumer:
  usesImportPath "libs/repro_project_dsl/tests/fixtures/explicit_contract/consumer/contracts"
  uses:
    "fixture_probe"

proc selectedContract*(): string = explicitApi.contractName

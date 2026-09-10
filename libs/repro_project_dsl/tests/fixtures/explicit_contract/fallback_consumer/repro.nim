import repro_project_dsl

package implicitContractConsumer:
  uses:
    "fixture_fallback"

package emptyImportPathConsumer:
  usesImportPath ""
  uses:
    "fixture_empty"

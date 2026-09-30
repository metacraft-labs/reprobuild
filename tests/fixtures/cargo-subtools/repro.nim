## Fixture for t_cargo_edge_reaches_declared_linker: a Rust binary whose
## link step needs a C linker. The recipe declares its C compiler in
## `uses:` the way a Rust recorder would, and nothing else ties that
## compiler to the cargo edge.
import repro_project_dsl

package cargo_subtools_fixture:
  defaultToolProvisioning "path"

  uses:
    "cargo"
    "rustc"
    "gcc"

  build:
    let binary = cargo.build(
      actionId = "cargo-subtools.build",
      extraInputs = @["Cargo.toml", "src"],
      extraOutputs = @["target/debug/cargo-subtools-fixture"])
    discard collect("default", @[binary])

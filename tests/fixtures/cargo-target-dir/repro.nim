## Fixture for t_cargo_target_dir_ownership_rebuild: a Rust binary whose crate sits
## one directory below the recipe root, built the way isonim-freya builds
## `rust/Cargo.toml`: `--manifest-path rust/Cargo.toml` from the root.
##
## The Rust sources are deliberately NOT declared as inputs. What keeps the
## edge honest after a source change is the evidence it reads from cargo's own
## depfiles, and that is what the test is about.
import repro_project_dsl

package cargo_target_dir_fixture:
  defaultToolProvisioning "path"

  uses:
    "cargo"
    "rustc"
    "gcc"

  build:
    let binary = cargo.build(
      actionId = "cargo-target-dir.build",
      manifestPath = "rust/Cargo.toml",
      extraInputs = @["rust/Cargo.toml"],
      extraOutputs = @["rust/target/debug/cargo-target-dir-fixture"])
    discard collect("default", @[binary])

## Fixture for t_cargo_target_dir_ownership_rebuild: a crate one directory
## below the recipe root, whose `cargo test --no-run` edge declares neither
## outputs nor source inputs. cargo links no test executable into the profile
## directory, so the only evidence that can notice a source edit is rustc's
## per-crate `deps/*.d`, whose sources are relative to the crate's directory.
import repro_project_dsl

package cargo_test_crate_dir_fixture:
  defaultToolProvisioning "path"

  uses:
    "cargo"
    "rustc"
    "gcc"

  build:
    let tests = cargo.test(
      actionId = "cargo-test-crate-dir.test",
      manifestPath = "rust/Cargo.toml",
      noRun = true,
      extraInputs = @["rust/Cargo.toml"])
    discard collect("default", @[tests.action])

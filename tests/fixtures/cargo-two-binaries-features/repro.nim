## Fixture for `t_cargo_two_binaries_different_features_are_not_shared_wrongly`
## and `t_cargo_and_cmake_cross_checkout_sharing_is_declared_as_measured`.
##
## A cargo workspace of three tiny path crates, built offline (`--offline
## --locked`, no registry crate, `Cargo.lock` committed): `featlib` declares
## two features, `alpha` and `beta`, and the two top-level binaries enable one
## each (`app-alpha` depends on `featlib` with `alpha`, `app-beta` with
## `beta`). Each feature adds a function (`alpha_marker`, `beta_marker`), so
## the compiled feature set of a `featlib` rlib can be read off its symbols.
##
## The build file uses the typed `cargo` tool in each granularity it offers:
##
## * `workspace`: one edge for the whole invocation (`cargo build`, every
##   member). cargo unifies features over what it builds, so both binaries
##   it links carry `featlib` with `alpha` AND `beta`.
## * `featlib`: the library alone (`--package featlib`) with the feature of
##   the selected top-level binary (`--features`), its rlib the declared
##   output.
## * `app`: the selected top-level binary alone (`--package app-<feature>`).
##
## `selected-app.txt` names the top-level binary this build is for (`alpha`
## or `beta`). The feature test rewrites it to switch from one binary to the
## other in the same checkout, so the `featlib` edge keeps its id, its target
## directory and its declared output and differs ONLY in the feature it
## enables: the case in which a key that ignored the feature set would serve
## one binary's library to the other. The selection is read from a data file
## rather than written into this file because an edit to the build file
## itself re-keys every action it declares, which would hide that case. The
## read is reported as an input of the graph's evaluation
## (`providerFileInput`), so a new selection re-derives the graph.
##
## Each edge has a target directory of its own: a cargo target directory is
## a position-keyed tool cache, and two edges sharing one would overwrite
## each other's artefacts (the uplifted `debug/libfeatlib.rlib` among them).
import std/[os, strutils]
import repro_project_dsl

package cargo_two_binaries_features:
  defaultToolProvisioning "path"

  uses:
    "cargo"
    "rustc"
    "gcc"

  build:
    let root = activeProviderProjectRoot()
    providerFileInput(root / "selected-app.txt")
    let selectedApp = readFile(root / "selected-app.txt").strip()
    let sources = @["Cargo.toml", "Cargo.lock", "featlib/Cargo.toml",
      "featlib/src/lib.rs", "app-alpha/Cargo.toml", "app-alpha/src/main.rs",
      "app-beta/Cargo.toml", "app-beta/src/main.rs"]
    let workspace = cargo.build(actionId = "workspace", locked = true,
      offline = true, targetDir = "target/workspace", extraInputs = sources,
      extraOutputs = @["target/workspace/debug/app-alpha",
        "target/workspace/debug/app-beta"])
    let library = cargo.build(actionId = "featlib", locked = true,
      offline = true, package = "featlib", features = selectedApp,
      targetDir = "target/featlib", extraInputs = sources,
      extraOutputs = @["target/featlib/debug/libfeatlib.rlib"])
    let app = cargo.build(actionId = "app", locked = true, offline = true,
      package = "app-" & selectedApp, targetDir = "target/app",
      extraInputs = sources, after = [library],
      extraOutputs = @["target/app/debug/app-" & selectedApp])
    discard collect("default", @[workspace, library, app])

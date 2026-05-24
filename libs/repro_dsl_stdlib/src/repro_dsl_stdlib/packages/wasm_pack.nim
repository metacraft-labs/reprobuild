import repro_project_dsl

package `wasm-pack`:
  provisioning:
    nixPackage "nixpkgs#wasm-pack", executablePath = "bin/wasm-pack"

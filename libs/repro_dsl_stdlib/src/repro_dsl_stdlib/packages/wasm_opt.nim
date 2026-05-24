import repro_project_dsl

package `wasm-opt`:
  provisioning:
    nixPackage "nixpkgs#binaryen", executablePath = "bin/wasm-opt"

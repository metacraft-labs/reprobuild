import repro_project_dsl

package emcc:
  provisioning:
    nixPackage "nixpkgs#emscripten", executablePath = "bin/emcc"

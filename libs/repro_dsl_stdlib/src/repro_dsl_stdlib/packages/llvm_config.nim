import repro_project_dsl

package `llvm-config`:
  provisioning:
    nixPackage "nixpkgs#llvm.dev", executablePath = "bin/llvm-config"

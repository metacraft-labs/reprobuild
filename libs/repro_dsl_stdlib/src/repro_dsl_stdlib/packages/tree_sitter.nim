import repro_project_dsl

package `tree-sitter`:
  provisioning:
    nixPackage "nixpkgs#tree-sitter", executablePath = "bin/tree-sitter"

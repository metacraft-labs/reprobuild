import repro_project_dsl

package mdbook:
  provisioning:
    nixPackage "nixpkgs#mdbook", executablePath = "bin/mdbook"

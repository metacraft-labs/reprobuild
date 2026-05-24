import repro_project_dsl

package curl:
  provisioning:
    nixPackage "nixpkgs#curl", executablePath = "bin/curl"

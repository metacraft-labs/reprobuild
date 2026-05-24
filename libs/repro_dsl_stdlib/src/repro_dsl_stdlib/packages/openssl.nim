import repro_project_dsl

package openssl:
  provisioning:
    nixPackage "nixpkgs#openssl", executablePath = "bin/openssl"

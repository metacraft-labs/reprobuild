import repro_project_dsl

package zstd:
  provisioning:
    nixPackage "nixpkgs#zstd", executablePath = "bin/zstd"

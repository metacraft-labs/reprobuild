import repro_project_dsl

package sqlite3:
  provisioning:
    nixPackage "nixpkgs#sqlite", executablePath = "bin/sqlite3"

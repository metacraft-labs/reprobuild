import repro_project_dsl

package `pcre-config`:
  provisioning:
    nixPackage "nixpkgs#pcre", executablePath = "bin/pcre-config"

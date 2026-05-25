import repro_project_dsl

package `pcre-config`:
  provisioning:
    nixPackage "nixpkgs#pcre.dev", executablePath = "bin/pcre-config",
      packageId = "pcre"

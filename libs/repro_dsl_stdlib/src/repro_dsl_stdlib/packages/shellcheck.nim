import repro_project_dsl

package shellcheck:
  provisioning:
    nixPackage "nixpkgs#shellcheck", executablePath = "bin/shellcheck"

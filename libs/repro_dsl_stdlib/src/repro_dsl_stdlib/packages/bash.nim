import repro_project_dsl

package bash:
  provisioning:
    nixPackage "nixpkgs#bash", executablePath = "bin/bash"

import repro_project_dsl

package `xvfb-run`:
  provisioning:
    nixPackage "nixpkgs#xvfb-run", executablePath = "bin/xvfb-run"

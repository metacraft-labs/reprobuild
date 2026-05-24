import repro_project_dsl

package tmux:
  provisioning:
    nixPackage "nixpkgs#tmux", executablePath = "bin/tmux"

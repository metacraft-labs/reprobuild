import repro_project_dsl

package ruby:
  provisioning:
    nixPackage "nixpkgs#ruby", executablePath = "bin/ruby"

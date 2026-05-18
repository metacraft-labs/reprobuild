import repro_project_dsl

package stylus:
  provisioning:
    nixPackage "reprobuild-stdlib-stylus-0.64.0",
      executablePath = "bin/stylus",
      expressionFile = "nix/stylus-0.64.0/default.nix",
      lockIdentity = "npm:stylus@0.64.0"

  executable stylus:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        pos source is string,
          role = input,
          position = 0

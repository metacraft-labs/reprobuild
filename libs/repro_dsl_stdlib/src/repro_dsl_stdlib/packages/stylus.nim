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

        # Named-Targets M0: ``-o`` is the primary output. The DSL
        # records the flag name; the engine derives the implicit
        # target name from the value the call supplies at M1.
        outputs output

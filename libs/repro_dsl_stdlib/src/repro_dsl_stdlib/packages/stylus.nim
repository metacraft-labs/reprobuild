import repro_project_dsl

package stylus:
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

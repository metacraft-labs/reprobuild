import repro_project_dsl

package sh:
  executable sh:
    cli:
      call:
        flag command is string,
          alias = "-c",
          required = true
        pos args is seq[string],
          position = 0,
          required = false

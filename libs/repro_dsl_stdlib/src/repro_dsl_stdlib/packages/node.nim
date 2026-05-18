import repro_project_dsl

package node:
  executable node:
    cli:
      call:
        pos args is seq[string],
          position = 0,
          required = false

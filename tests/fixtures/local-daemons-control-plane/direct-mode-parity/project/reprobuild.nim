import repro_project_dsl

package localDaemonParity:
  build:
    let generated = fs.writeText(
      actionId = "write-generated",
      output = "build/generated.txt",
      text = "direct-mode fixture\n")
    let copied = fs.copyFile(
      actionId = "copy-generated",
      source = "build/generated.txt",
      output = "dist/copied.txt",
      after = @[generated])
    let stamp = fs.stamp(
      actionId = "stamp-result",
      output = "dist/stamp.txt",
      title = "local-daemons-direct-mode-parity",
      entries = @["dist/copied.txt"],
      inputs = @["dist/copied.txt"],
      after = @[copied])
    defaultBuildAction(stamp)

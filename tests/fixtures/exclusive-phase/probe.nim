import std/os

for argument in commandLineParams():
  if argument == "--list-json":
    quit(3)

# The test copies this graph artifact under exclusive and parallel stems.
let observation = getAppDir().parentDir / "observed.txt"
let output = open(observation, fmAppend)
output.writeLine(splitFile(getAppFilename()).name & "=" &
  getEnv("REPROBUILD_MAX_PARALLELISM", "unset"))
output.close()

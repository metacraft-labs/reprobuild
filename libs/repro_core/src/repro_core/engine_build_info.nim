## The engine names itself to the build it runs.
##
## A build record that says which engine produced an artifact -- an
## installed prefix's `cross-build-info` `engine=` line (reprobuild-pm
## Distribution-And-Packaging.md §5.3) -- cannot ask the environment: an
## edge's environment is not its identity, and a value read from it would
## let a cached edge record a different engine than the one now running. So
## every `repro build` writes the engine's revision and version to
## `<project>/.repro/build/engine-build-info`, and an edge that records the
## engine declares that file as an input. Another engine then has another
## key. The file is rewritten only when its text changes, so an unchanged
## engine leaves such an edge a cache hit.

import std/os

import ../repro_core

const EngineBuildInfoSubpath* = ".repro/build/engine-build-info"
  ## Relative to the project root of the build target.

proc engineBuildInfoText*(): string =
  ## `engine=<revision>` (`unknown` when the image was built without one)
  ## and `engine_version=<version>`, one per line.
  "engine=" &
    (if ReprobuildSourceRevision.len > 0: ReprobuildSourceRevision
     else: "unknown") & "\n" &
    "engine_version=" & versionString() & "\n"

proc writeEngineBuildInfo*(projectRoot: string) =
  ## Write `<projectRoot>/.repro/build/engine-build-info` when its text
  ## differs from `engineBuildInfoText()`. An I/O failure is not the
  ## build's failure: an edge that needs the file is refused for its
  ## missing input, by name, which is where the failure belongs.
  let path = projectRoot / EngineBuildInfoSubpath
  let text = engineBuildInfoText()
  try:
    if fileExists(path) and readFile(path) == text:
      return
    createDir(path.parentDir)
    let tmp = path & ".tmp"
    writeFile(tmp, text)
    moveFile(tmp, path)
  except CatchableError:
    discard

## The engine names itself to the build it runs.
##
## A build record that says which engine produced an artifact -- an
## installed prefix's `cross-build-info` `engine=` line (reprobuild-pm
## Distribution-And-Packaging.md §5.3) -- cannot ask the environment: an
## edge's environment is not its identity, and a value read from it would
## let a cached edge record a different engine than the one now running. So
## an edge that records the engine declares
## `<project>/.repro/build/engine-build-info` as an input, and a `repro build`
## whose graph has such an edge writes the engine's revision and version
## there before it runs the graph. Another engine then has another key. The
## file is rewritten only when its text changes, so an unchanged engine
## leaves such an edge a cache hit.
##
## Only a graph that DECLARES the file gets it. `--work-root` (or
## `$REPROBUILD_WORK_ROOT`) moves the engine's own per-project metadata out
## of the project, and a build under it must leave no `<project>/.repro/build`
## behind (`t_e2e_local_reprobuild_project_build`, "work root override
## isolates metadata by worktree"). Writing the file on every build broke
## that for every project, though no recipe but one reads it. The file is not
## engine bookkeeping that could follow the work root: it is an input the
## recipe names by a project-relative path, so it is written where the
## recipe looks, and only for a recipe that looks.

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

proc isEngineBuildInfoInput*(projectRoot, cwd, input: string): bool =
  ## Whether the declared action input `input` names
  ## `<projectRoot>/.repro/build/engine-build-info`. A relative input is
  ## resolved against the action's `cwd` (the project root when empty), as
  ## the engine resolves it when it hashes the input.
  if input.len == 0 or projectRoot.len == 0:
    return false
  let base =
    if cwd.len == 0: projectRoot
    elif cwd.isAbsolute: cwd
    else: projectRoot / cwd
  let resolved = if input.isAbsolute: input else: base / input
  os.normalizedPath(resolved) ==
    os.normalizedPath(projectRoot / EngineBuildInfoSubpath)

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

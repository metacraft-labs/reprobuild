## `useEnvrc` — activate a project's existing `.envrc` from `repro.nim`.
##
##     devEnv:
##       useEnvrc()
##
## The sibling of `useFlakeDevShell`, over the SAME capture mechanism
## (`env_capture`) and the same lowering (`apply`). It exists because a
## transitioning project's `.envrc` is frequently more than `use flake`: it
## sources `.env`, adds tool directories, exports project variables. Absorbing
## the `.envrc` carries all of that across, where absorbing only the flake
## would silently drop it.
##
## ## Why `direnv export bash` and not `direnv exec`
##
## `direnv export bash` prints a bash script that applies the `.envrc`'s
## contribution to the current environment — structurally the same artifact
## `nix print-dev-env` prints, which is what lets both helpers share one
## capture. `direnv exec` would instead run a command with the environment
## already applied, so the contribution could only be recovered by dumping the
## child's environment and diffing it against a parent that direnv had already
## modified.
##
## `direnv export` refuses an unauthorized `.envrc`, which is a property worth
## keeping rather than working around: an `.envrc` is arbitrary code, and
## Reprobuild running it because a config flag was set would be a strictly
## worse trust boundary than direnv's. The refusal names `direnv allow`.

import std/[os, strutils]

import repro_core/ambient_execution
import repro_core/paths
import repro_project_dsl

import ./apply
import ./env_capture

const
  EnvrcFileName* = ".envrc"

  DirenvBookkeepingPrefix* = "DIRENV_"
    ## `direnv export` also emits its own state — `DIRENV_DIFF`,
    ## `DIRENV_WATCHES`, `DIRENV_DIR`, `DIRENV_FILE`. Those describe direnv's
    ## view of the directory it just loaded, not the project's environment, and
    ## `DIRENV_DIFF` in particular is a base64 blob of the whole before/after
    ## environment — recording it would put the capturing shell's `HOME` and
    ## `PATH` into a cached artifact that gets applied in a different shell.
    ## They are dropped, by prefix, here rather than by name, because direnv
    ## has added members to this family across versions.

proc direnvExportArgv*(direnvExe: string): seq[string] =
  ## The command shape. `bash` is the shell dialect, matching the dialect
  ## `env_capture` sources with.
  @[direnvExe, "export", "bash"]

proc resolveDirenvExe*(explicit = ""): string =
  ## Absolute path of the `direnv` to run. `REPRO_FOREIGN_ENV_DIRENV` is the
  ## interposition point, matching `REPRO_FOREIGN_ENV_NIX` in `flake.nim`.
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv("REPRO_FOREIGN_ENV_DIRENV")
  if fromEnv.len > 0:
    return fromEnv
  let found = uncontrolledFindExe("direnv")
  if found.len == 0:
    raise newException(ForeignEnvCaptureError,
      "useEnvrc needs direnv on PATH (or REPRO_FOREIGN_ENV_DIRENV); " &
      "install direnv, or drop the useEnvrc() call from devEnv:")
  found

proc withoutDirenvBookkeeping*(ops: openArray[ForeignEnvOp]):
    seq[ForeignEnvOp] =
  ## Drop direnv's own state variables from a captured contribution.
  for op in ops:
    if op.name.startsWith(DirenvBookkeepingPrefix):
      continue
    result.add(op)

proc baselineWithoutDirenvState*(pairs: openArray[(string, string)]):
    seq[(string, string)] =
  ## Remove direnv's own state from the environment the capture runs in.
  ##
  ## This is load-bearing, not tidiness. `direnv export` emits a TRANSITION:
  ## given `DIRENV_DIFF` describing an already-applied `.envrc`, it emits the
  ## `unset`s that undo that one plus the exports that apply this one. Run from
  ## a shell that is already inside some other direnv context, it would hand us
  ## a script whose first act is to unset variables that context contributed —
  ## and those `unset`s would be captured as `unsetEnv` contributions of an
  ## `.envrc` that never mentioned them. Scrubbing the state first makes the
  ## capture describe LOADING this `.envrc`, which is the only thing a dev-env
  ## contribution can mean.
  for pair in pairs:
    if pair[0].startsWith(DirenvBookkeepingPrefix):
      continue
    result.add(pair)

proc envrcForeignEnvWorkDir*(projectRoot: string): string =
  ## Shared with `flake.nim`'s work dir so a project has ONE place holding
  ## whatever a foreign environment produced, whichever helper produced it.
  projectRoot / ".repro" / "foreign-env"

proc envrcOps*(projectRoot: string; direnvExe = ""): seq[ForeignEnvOp] =
  ## Load `projectRoot/.envrc` through direnv and return its contribution.
  let envrcPath = projectRoot / EnvrcFileName
  if not fileExists(extendedPath(envrcPath)):
    raise newException(ForeignEnvCaptureError,
      "useEnvrc found no " & EnvrcFileName & " in " & projectRoot)
  withoutDirenvBookkeeping(
    captureForeignEnvOps(direnvExportArgv(resolveDirenvExe(direnvExe)),
      projectRoot, envrcForeignEnvWorkDir(projectRoot) / "direnv-export.bash",
      separator = $PathSep,
      baseline = baselineWithoutDirenvState(currentEnvironmentPairs())))

proc useEnvrc*(direnvExe = "";
               activities: openArray[string] = []) {.dynOrStatic.} =
  ## The one-liner for path 1's projects: keep the `.envrc`, activate it
  ## through Reprobuild, and get the observed manifest instead of the declared
  ## watch set.
  var projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    projectRoot = getCurrentDir()
  applyForeignEnvOps(envrcOps(projectRoot, direnvExe), activities)

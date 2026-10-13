## Locating the reprobuild source tree whose `libs/` a post-install compile
## builds against.
##
## Several edges compile Nim code against reprobuild's own libraries AFTER the
## `repro` binary was installed: the provider compile, the recipe interface
## extract and the home/system profile compile. All of them need the same
## answer to "where are reprobuild's sources?", and they used to get different
## ones. The provider compile asked `reprobuildLibraryWorkDir` in
## `repro_cli_support`, which honours the installed package's
## `$REPROBUILD_SOURCE_ROOT`; the profile compile read only
## `$REPROBUILD_REPO_ROOT` and otherwise fell back to the path its own source
## file had at COMPILE time. Under Nix that path is the build sandbox
## (`/nix/var/nix/builds/…-source`), which does not exist after the build, so
## every `repro home apply` from the Nix package died in `setCurrentDir`.
##
## This module is that one resolver. It lives in `repro_core` because both
## consumers need it and `repro_profile_compile` sits below `repro_cli_support`
## in the dependency graph, so the profile compile could not import the
## original.

import std/os
from ./paths import extendedPath

const
  ReprobuildLibsDirEnvVar* = "REPROBUILD_LIBS_DIR"
    ## Operator override naming the `libs/` directory itself.
  ReprobuildRepoRootEnvVar* = "REPROBUILD_REPO_ROOT"
    ## Operator override naming the source tree root.
  ReprobuildSourceRootEnvVar* = "REPROBUILD_SOURCE_ROOT"
    ## The source tree an installed package ships. The Nix package's wrapper
    ## sets it (`--set-default`) to the exact sources the binary was built
    ## from (`nix/pkgs/by-name/re/reprobuild/package.nix`), and a source
    ## checkout's engine sets it to its own checkout while resolving the
    ## monitor shim.

  CompiledSourceRoot* = currentSourcePath().parentDir.parentDir.parentDir.
    parentDir.parentDir
    ## The tree this file was compiled from:
    ## `libs/repro_core/src/repro_core/source_root.nim` is five levels below
    ## it. Right for a binary built in, and run from, a source checkout; a
    ## dead path for any packaged build, which is why it is the LAST arm.

proc hasReprobuildLibs*(root: string): bool =
  ## True when `root` holds reprobuild's library tree. `repro_project_dsl` is
  ## the marker because every post-install compile imports it.
  root.len > 0 and
    dirExists(extendedPath(root / "libs" / "repro_project_dsl" / "src"))

proc resolveReprobuildSourceRoot*(): string =
  ## The reprobuild source tree to compile against, or "" when no candidate
  ## holds reprobuild's libs. Precedence:
  ##
  ## 1. `$REPROBUILD_LIBS_DIR` (its parent), then `$REPROBUILD_REPO_ROOT` —
  ##    the operator's explicit overrides.
  ## 2. `$REPROBUILD_SOURCE_ROOT` — the installed package's sources.
  ## 3. The current directory, when it is itself a reprobuild tree.
  ## 4. `CompiledSourceRoot` — the checkout the binary was built in.
  ##
  ## Each arm is taken only when it really holds the libs, so an override
  ## naming a stale or empty directory falls through instead of producing a
  ## compile that fails far from the cause.
  let libsDir = getEnv(ReprobuildLibsDirEnvVar)
  if libsDir.len > 0 and hasReprobuildLibs(libsDir.parentDir):
    return libsDir.parentDir
  let repoRoot = getEnv(ReprobuildRepoRootEnvVar)
  if hasReprobuildLibs(repoRoot):
    return repoRoot
  let sourceRoot = getEnv(ReprobuildSourceRootEnvVar)
  if hasReprobuildLibs(sourceRoot):
    return sourceRoot
  let cwd = getCurrentDir()
  if hasReprobuildLibs(cwd):
    return cwd
  if hasReprobuildLibs(CompiledSourceRoot):
    return CompiledSourceRoot
  ""

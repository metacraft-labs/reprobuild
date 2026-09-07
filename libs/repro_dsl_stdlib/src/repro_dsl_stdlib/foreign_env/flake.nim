## `useFlakeDevShell` — §2b's degenerate end, as one line of `repro.nim`.
##
##     devEnv:
##       useFlakeDevShell()
##
## The flake keeps defining everything in the shell; Reprobuild only activates
## it. What the project gains is the activation mechanism: the `devEnv:` block
## runs inside the dev-env introspection edge, which the build engine executes
## UNDER THE MONITOR with `dgAutomaticMonitor` / `decComplete`
## (`repro_dev_env_engine.devEnvIntrospectionAction`). So every file the nix
## evaluation touched — read, probed-and-absent, enumerated — lands in that
## edge's observed input set and is fingerprinted into the action cache. Shell
## re-entry is then a fingerprint comparison against an OBSERVED manifest
## instead of `direnv`'s DECLARED `watch_file` set.
##
## ## The command shape is `direnv`'s, deliberately
##
## `nix print-dev-env --profile <profile> '.?submodules=1' --override-input
## <name> path:<sibling> …` is exactly what `nix-direnv`'s `use_flake` runs in
## this workspace today. Wrapping that command rather than re-deriving it means
## a project's shell does not change when activation moves to Reprobuild —
## which is the entire promise of the degenerate end. `--profile` is part of the
## shape and not decoration: it is the gcroot that stops the shell's store paths
## being garbage-collected out from under a cached artifact.
##
## ## The override arguments
##
## `overrideInputs` is a list of `(input name, sibling path)` pairs, lowered to
## `--override-input <name> path:<path>`. NF-1's `repro flake override-args`
## already computes that list from the workspace's develop set; this helper
## takes it as data so the recipe can pass NF-1's answer, a hand-written list,
## or nothing at all.

import std/os

import repro_core/ambient_execution
import repro_core/paths
import repro_project_dsl

import ./apply
import ./env_capture

const
  DefaultFlakeRef* = ".?submodules=1"
    ## The workspace's own expression. The query string is why `nix-direnv`
    ## never watched `flake.nix` / `flake.lock` (its `use_flake` registers them
    ## only when the flake expression names a DIRECTORY, and `.?submodules=1`
    ## is not one) — the first of the three failure modes §2b records, and the
    ## reason the default here is the one that broke rather than a tidier one.

  ForeignEnvWorkDirName* = "foreign-env"

proc flakeForeignEnvWorkDir*(projectRoot: string): string =
  ## Where the profile gcroot and the transient `print-dev-env` script live.
  ## Under the project's own `.repro/`, so it is Reprobuild scratch rather than
  ## anything a user is expected to look at or a VCS is expected to carry.
  projectRoot / ".repro" / ForeignEnvWorkDirName

proc flakePrintDevEnvArgv*(nixExe, flakeRef, profilePath: string;
                           overrideInputs: openArray[(string, string)] = [];
                           extraArgs: openArray[string] = []): seq[string] =
  ## Build the argv. Pure, so the command shape is asserted by a test rather
  ## than by reading it: an override arm that silently emits nothing is the
  ## exact defect §5 records the content-pinned direnv plugin shipping.
  result = @[nixExe, "print-dev-env"]
  if profilePath.len > 0:
    result.add("--profile")
    result.add(profilePath)
  result.add(flakeRef)
  for pair in overrideInputs:
    if pair[0].len == 0 or pair[1].len == 0:
      continue
    result.add("--override-input")
    result.add(pair[0])
    result.add("path:" & pair[1])
  for extra in extraArgs:
    result.add(extra)

proc resolveNixExe*(explicit = ""): string =
  ## Absolute path of the `nix` to run. `REPRO_FOREIGN_ENV_NIX` exists so a
  ## test can interpose a counting wrapper and PROVE that a warm re-entry
  ## spawned no evaluation, rather than inferring it from elapsed time.
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv("REPRO_FOREIGN_ENV_NIX")
  if fromEnv.len > 0:
    return fromEnv
  let found = uncontrolledFindExe("nix")
  if found.len == 0:
    raise newException(ForeignEnvCaptureError,
      "useFlakeDevShell needs nix on PATH (or REPRO_FOREIGN_ENV_NIX); " &
      "install nix, or drop the useFlakeDevShell() call from devEnv:")
  found

proc flakeDevShellOps*(projectRoot: string; flakeRef = DefaultFlakeRef;
                       overrideInputs: openArray[(string, string)] = [];
                       nixExe = ""; profile = "";
                       extraArgs: openArray[string] = []): seq[ForeignEnvOp] =
  ## Materialise the flake's dev shell and return its environment contribution.
  ## Separated from `useFlakeDevShell` so the capture can be exercised without
  ## a provider binary and without a live dev-env registry.
  let workDir = flakeForeignEnvWorkDir(projectRoot)
  createDir(extendedPath(workDir))
  let profilePath =
    if profile.len > 0: profile
    else: workDir / "flake-profile"
  let argv = flakePrintDevEnvArgv(resolveNixExe(nixExe), flakeRef, profilePath,
    overrideInputs, extraArgs)
  captureForeignEnvOps(argv, projectRoot, workDir / "print-dev-env.bash",
    separator = $PathSep)

proc useFlakeDevShell*(flakeRef = DefaultFlakeRef;
                       overrideInputs: openArray[(string, string)] = [];
                       nixExe = ""; profile = "";
                       extraArgs: openArray[string] = [];
                       activities: openArray[string] = []) {.dynOrStatic.} =
  ## The one-liner. Activates the project's flake dev shell and contributes
  ## everything it exports to the Reprobuild dev environment.
  var projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    # Outside a provider dispatch there is no request-supplied root; the
    # process cwd is the recipe's own directory in every path that reaches
    # here, and a wrong value would be silent, so it is named rather than
    # left implicit.
    projectRoot = getCurrentDir()
  applyForeignEnvOps(
    flakeDevShellOps(projectRoot, flakeRef, overrideInputs, nixExe, profile,
      extraArgs),
    activities)

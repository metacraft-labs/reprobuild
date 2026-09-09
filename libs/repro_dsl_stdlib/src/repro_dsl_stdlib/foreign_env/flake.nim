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
## <name> <sibling-ref> …` is exactly what `nix-direnv`'s `use_flake` runs in
## this workspace today. Wrapping that command rather than re-deriving it means
## a project's shell does not change when activation moves to Reprobuild —
## which is the entire promise of the degenerate end. `--profile` is part of the
## shape and not decoration: it is the gcroot that stops the shell's store paths
## being garbage-collected out from under a cached artifact.
##
## ## The override arguments
##
## `overrideInputs` is a list of `(input name, sibling path)` pairs, lowered to
## `--override-input <name> <ref>` where `<ref>` is chosen by
## `flakeSiblingOverrideRef` below — a git tree for a checkout, so `.gitignore`
## keeps build output out of the store, and a directory copy otherwise. NF-1's
## `repro flake override-args` already computes that list from the workspace's
## develop set; this helper takes it as data so the recipe can pass NF-1's
## answer, a hand-written list, or nothing at all.

import std/[os, osproc, strutils]

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

proc flakeSiblingIsGitCheckout*(dir: string): bool =
  ## Is ``dir`` a git checkout? BOTH shapes count, and that is the whole point
  ## of spelling this out once: in an ordinary clone ``.git`` is a DIRECTORY,
  ## but in a linked worktree (`git worktree add`, which is how
  ## ``repro branch ../<name>`` forks a workspace) it is a regular FILE holding
  ## a ``gitdir:`` pointer.
  ##
  ## Testing only for the directory silently misclassifies every linked
  ## worktree as "not a repo", and every caller fails OPEN in the dangerous
  ## direction when that happens: the binder would drop the input and report
  ## "nothing can have moved", the dirty-sibling scope would drop the repo and
  ## stop it blocking, and the override below would fall back to `path:` and
  ## copy that worktree's build output. All are §3.1 reintroduced quietly,
  ## which is the one outcome this campaign exists to prevent.
  dirExists(extendedPath(dir / ".git")) or
    fileExists(extendedPath(dir / ".git"))

type
  FlakeSiblingKind* = enum
    ## How a sibling checkout can be named to nix. The distinction is not
    ## cosmetic: each arm was chosen against a measured failure of the others.
    fskNotGit
      ## No `.git`. Nothing to enumerate, so the directory is copied whole.
    fskGit
      ## A git checkout with no submodules.
    fskGitWithSubmodules
      ## A git checkout whose submodules are ALL initialised.
    fskGitSubmodulesUninitialised
      ## A git checkout declaring submodules of which at least one is not
      ## initialised — `?submodules=1` cannot be used, see below.

proc flakeSiblingKind*(dir: string; gitExe = ""): FlakeSiblingKind =
  ## Classify a sibling checkout. ``gitExe`` is injectable so the CLI can pass
  ## the git its own tool-provisioning policy resolved, rather than this
  ## reaching for `PATH` behind that policy's back; empty means `PATH`, which
  ## is what the `useFlakeDevShell` path (already resolving `nix` the same way)
  ## uses.
  if not flakeSiblingIsGitCheckout(dir):
    return fskNotGit
  if not fileExists(extendedPath(dir / ".gitmodules")):
    return fskGit
  let git = if gitExe.len > 0: gitExe else: uncontrolledFindExe("git")
  if git.len == 0:
    # No git to ask, so "are the submodules present" cannot be answered. The
    # safe answer is the one that cannot fail: `?submodules=1` on an
    # uninitialised submodule aborts the fetch outright.
    return fskGitSubmodulesUninitialised
  # Uncontrolled deliberately, and for the same reason `resolveNixExe` resolves
  # `nix` that way: this asks the developer's own git about the developer's own
  # checkout, before any execution profile exists to run it under.
  let probe = uncontrolledExecCmdEx(quoteShell(git) & " -C " &
    quoteShell(dir) & " submodule status --recursive")
  if probe.exitCode != 0:
    return fskGitSubmodulesUninitialised
  # `git submodule status` marks an uninitialised entry with a leading `-`.
  for line in probe.output.splitLines():
    if line.startsWith("-"):
      return fskGitSubmodulesUninitialised
  fskGitWithSubmodules

proc flakeSiblingOverrideRef*(dir: string; kind: FlakeSiblingKind): string =
  ## How a sibling checkout is NAMED to nix — ONE spelling, shared by every
  ## emission site, so the arguments `.envrc` splices and the argv
  ## `useFlakeDevShell` runs cannot describe different trees.
  ##
  ## ## Why not `path:`
  ##
  ## `path:` is a plain directory copy: nix walks the tree, serialises it to a
  ## NAR and hashes it WITHOUT consulting git, so `.gitignore` does not apply.
  ## Measured on `codetracer` in this workspace: a 19 GB tree of which 17 GB is
  ## `src/db-backend/target`, a Rust build directory git already excludes,
  ## against 3,719 tracked files — 19 GB and ~50 minutes, against 75 MB and
  ## 13 s for the same checkout named as a git tree.
  ##
  ## It is a CORRECTNESS fix before a speed one. A `path:` store path is
  ## content-addressed over the build output too, so any write under `target/`
  ## changes the input hash and invalidates the dev shell for every consumer of
  ## the override: a Rust rebuild inside the sibling silently invalidates
  ## everyone's shell.
  ##
  ## ## Why this is safe for develop mode
  ##
  ## `git+file:` on a DIRTY tree contributes WORKING-TREE content — git is used
  ## to ENUMERATE, not to select a revision — so uncommitted edits to tracked
  ## files still reach the shell. That is the property the whole substitution
  ## exists for, and it is what makes this a fetcher change rather than a
  ## behaviour change. Files git has never been told about are the one
  ## exception; the binder NAMES them rather than letting them vanish quietly,
  ## because nix warns only that the tree is dirty and says nothing about
  ## having dropped them.
  ##
  ## ## Why `?submodules=1` is conditional
  ##
  ## Plain `git+file:` omits submodules entirely, and `codetracer` has ten of
  ## them, so a repo that HAS submodules needs the flag. But measured: with a
  ## submodule declared and NOT initialised, `?submodules=1` makes the fetch
  ## fail outright — nix tries to fetch the submodule and aborts. A broken
  ## shell is strictly worse than a slow one, so that case keeps `path:`, which
  ## copies exactly what is on disk and therefore cannot fail. Emitting plain
  ## `git+file:` there instead would be the worst of the three: fast, and
  ## silently missing the submodules that ARE checked out.
  case kind
  of fskNotGit, fskGitSubmodulesUninitialised: "path:" & dir
  of fskGit: "git+file://" & dir
  of fskGitWithSubmodules: "git+file://" & dir & "?submodules=1"

proc flakeSiblingOverrideRef*(dir: string; gitExe = ""): string =
  ## The same answer, classifying ``dir`` first.
  flakeSiblingOverrideRef(dir, flakeSiblingKind(dir, gitExe))

proc flakePrintDevEnvArgv*(nixExe, flakeRef, profilePath: string;
                           overrideInputs: openArray[(string, string)] = [];
                           extraArgs: openArray[string] = []): seq[string] =
  ## Build the argv. Pure apart from the sibling classification, so the command
  ## shape is asserted by a test rather than by reading it: an override arm
  ## that silently emits nothing is the exact defect §5 records the
  ## content-pinned direnv plugin shipping.
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
    result.add(flakeSiblingOverrideRef(pair[1]))
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

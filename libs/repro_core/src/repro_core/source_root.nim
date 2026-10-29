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
##
## It is also the one definition of the INSTALLED LAYOUT -- where a release
## archive, a `.deb`/`.rpm` or an MSI puts the sources beside `bin/`
## (Distribution-And-Packaging §5; the packaging side is
## `repro_dsl_stdlib/packaging/reprobuild_dist` and
## `scripts/release/stage_release_sources.sh`). Two consumers read it: the
## resolver below, and `repro_interface_artifacts`'
## `ensureInstalledSourcePackageEnvironment`, which seeds the same roots into
## the process environment for nested compilers and re-exports these names.
## The layout used to be defined there alone, which the profile compile could
## not import (Gradual-Nix-To-Reprobuild-Migration GM1w).

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
    ## checkout's engine seeds it with its own checkout while resolving the
    ## monitor shim. That seed fills only an unset variable, is recorded in
    ## `REPRO_BOOTSTRAP_SOURCE_ENV`, and is withdrawn before `repro exec` /
    ## `shell` / `run` / `develop` start the user's command
    ## (Distribution-And-Packaging §5), so it is never mistaken for a value
    ## the caller set.
  PublicCliPathEnvVar* = "REPRO_PUBLIC_CLI_PATH"
    ## The path of the ENGINE image (`bin/reprobuild`), when a launcher names
    ## it: the portable Linux archive's wrapper script and the version
    ## trampoline (`apps/repro-trampoline`) export it; the thin client only
    ## reads it. Same spelling as `repro_selfhost/handover.PublicCliEnvVar`.

  CompiledSourceRoot* = currentSourcePath().parentDir.parentDir.parentDir.
    parentDir.parentDir
    ## The tree this file was compiled from:
    ## `libs/repro_core/src/repro_core/source_root.nim` is five levels below
    ## it. Right for a binary built in, and run from, a source checkout; a
    ## dead path for any packaged build, which is why it is the LAST arm --
    ## and why that arm is taken only by an image that really runs from it
    ## (`runningImageIsUnder`).

# ---------------------------------------------------------------------------
# The installed layout.
# ---------------------------------------------------------------------------

const
  InstalledSourceRootSubdir* = "share/repro/source"
    ## Prefix-relative home of reprobuild's OWN ``libs/`` tree in an installed
    ## layout (release archive, .deb/.rpm, MSI). The same spelling as
    ## ``repro_dsl_stdlib/packaging/reprobuild_dist.ReprobuildSourceRootSubdir``;
    ## ``t_packaging_reprobuild_dist`` pins the two together.
  InstalledSourceTreesSubdir* = "share/repro/src"
    ## Prefix-relative parent of the per-input source-only trees
    ## (``reprobuild_dist.ReprobuildSourceSubdir``).
  InstalledSourcePackageTrees* = [
    ## ``(envName, path under InstalledSourceTreesSubdir)`` for every
    ## source-only input an installed layout may carry. The names and paths
    ## are the ``share/repro/src`` entries of the native-package wrapper
    ## contract (``reprobuild_dist.reprobuildToolWrapperValues``), so an
    ## archive and a package that ship the same tree seed the same variable.
    ## ``scripts/release/stage_release_sources.sh`` stages the archive's
    ## copies under the same destination names.
    ("NIMCRYPTO_SRC", "nimcrypto"),
    ("BEARSSL_SRC", "bearssl"),
    ("STACKABLE_HOOKS_SRC", "nim-stackable-hooks/src"),
    ("CODETRACER_TRACE_FORMAT_NIM_SRC", "codetracer-trace-format-nim"),
    ("IO_MON_SRC", "io-mon/src"),
    ("SHM_GSET_SRC", "nim-shm-gset/src"),
    ("SHM_QUEUE_SRC", "nim-shm-queue/src"),
    ("CODETRACER_PINNED_SRC", "codetracer/src"),
    ("REPRO_CT_TEST_RUNNER_SRC", "reprobuild-ct-test-runner"),
    ("REPRO_TEST_ADAPTERS_SRC", "reprobuild-test-adapters/src"),
    ("TEST_CERTIFICATES_TOOLS_SRC", "test-certificates-tools/src"),
    ("RUNQUOTA_SRC", "runquota"),
  ]

proc installedLayoutSourceRoot*(prefix: string): string =
  ## ``<prefix>/share/repro/source`` when it holds reprobuild's libs, else "".
  ## The marker is the one ``resolveReprobuildSourceRoot`` requires of any
  ## candidate root, narrowed to the package's entry module.
  if prefix.len == 0:
    return ""
  let root = prefix / InstalledSourceRootSubdir
  if fileExists(extendedPath(root / "libs" / "repro_project_dsl" / "src" /
      "repro_project_dsl.nim")):
    return root
  ""

proc installedLayoutPackageTrees*(prefix: string): seq[(string, string)] =
  ## The source-only input trees ``<prefix>/share/repro/src`` actually
  ## carries, as ``(envName, absolute dir)`` in ``InstalledSourcePackageTrees``
  ## order. Empty unless the prefix also holds reprobuild's own libs: the
  ## per-input trees are only meaningful beside them.
  if installedLayoutSourceRoot(prefix).len == 0:
    return
  for (envName, rel) in InstalledSourcePackageTrees:
    let dir = prefix / InstalledSourceTreesSubdir / rel
    if dirExists(extendedPath(dir)):
      result.add((envName, dir))

proc installedLayoutSourceRoots*(prefix: string): seq[(string, string)] =
  ## Every source root an installed layout rooted at ``prefix`` carries, as
  ## ``(envName, absolute dir)``: ``REPROBUILD_SOURCE_ROOT`` first, then the
  ## input trees. Empty unless the prefix holds reprobuild's own libs. Pure
  ## apart from existence checks, so it is testable on a fixture.
  let sourceRoot = installedLayoutSourceRoot(prefix)
  if sourceRoot.len == 0:
    return
  result.add((ReprobuildSourceRootEnvVar, sourceRoot))
  result.add(installedLayoutPackageTrees(prefix))

proc installedLayoutPrefixOfSourceRoot*(sourceRoot: string): string =
  ## The install prefix whose ``share/repro/source`` IS ``sourceRoot``, or ""
  ## when ``sourceRoot`` is not an installed layout's source root (a source
  ## checkout, a Nix store copy of the tree). Lets a compile that was handed
  ## a source root find the input trees shipped beside it, whichever arm of
  ## the resolver produced that root.
  if sourceRoot.len == 0:
    return ""
  # Strip `share/repro/source` one component at a time (`lastPathPart` and
  # `parentDir` accept either separator on Windows and ignore a trailing
  # one), so the root is recognised however it was spelled.
  var prefix = sourceRoot
  for component in ["source", "repro", "share"]:
    if prefix.lastPathPart != component:
      return ""
    prefix = prefix.parentDir
  if prefix.len == 0 or installedLayoutSourceRoot(prefix).len == 0:
    return ""
  prefix

proc installedLayoutPrefixCandidates*(appFilename, publicCliPath: string):
    seq[string] =
  ## Install prefixes to probe, derived from where the running image lives.
  ## ``<prefix>/bin/<exe>`` gives ``<prefix>``. The public CLI path is a
  ## second anchor because the portable Linux archive runs its images through
  ## the bundled loader, where ``getAppFilename()`` names
  ## ``<prefix>/lib/ld-linux-*.so.2`` rather than the executable (the loader's
  ## grandparent is the same prefix, but the launcher-set path says so
  ## explicitly). On Windows the variable is normally unset and the engine's
  ## own image, ``<prefix>\bin\reprobuild.exe``, is the anchor.
  for anchor in [appFilename, publicCliPath]:
    if anchor.len == 0:
      continue
    let prefix = anchor.parentDir.parentDir
    if prefix.len > 0 and prefix notin result:
      result.add(prefix)

var declaredImageSource: string
  ## The image this process stands in for, when it runs from a staged COPY of
  ## another image (`declareRunningImageSource`); "" otherwise. Written once,
  ## at start-up, before the process serves any request or starts a thread.

proc declareRunningImageSource*(path: string) =
  ## Declare that this process runs a staged copy of the image at `path`, so
  ## source-root resolution anchors on `path` rather than on the copy.
  ##
  ## The dev-mode user daemon is the caller: `repro build` stages the engine
  ## it was started from into `<daemon state>/dev-bin/<generation>/` and runs
  ## the copy, so the original can be rebuilt while the daemon runs. Anchored
  ## on the copy, a daemon started from a source checkout's `build/bin` would
  ## not count as running from that checkout, and one started from an
  ## installed layout would not find `<prefix>/share/repro/source`: every
  ## daemon-hosted compile of a project outside the checkout then lost
  ## reprobuild's libs and `config.nims`.
  ##
  ## Call it before any thread that resolves a source root is started.
  {.cast(gcsafe).}:
    declaredImageSource = path

proc runningImagePath(): string =
  ## The declared image source when there is one, else ``getAppFilename()``,
  ## or "" where the platform cannot answer.
  {.cast(gcsafe).}:
    # Read-only after start-up (see `declareRunningImageSource`).
    result = declaredImageSource
  if result.len > 0:
    return
  try:
    result = getAppFilename()
  except CatchableError:
    result = ""

proc runningImagePrefixCandidates*(): seq[string] =
  ## ``installedLayoutPrefixCandidates`` for THIS process: its own image and
  ## ``$REPRO_PUBLIC_CLI_PATH``.
  installedLayoutPrefixCandidates(runningImagePath(),
    getEnv(PublicCliPathEnvVar))

# ---------------------------------------------------------------------------
# The path that re-enters this engine.
# ---------------------------------------------------------------------------

proc absoluteNormalizedCliPath(path: string): string =
  ## `path` made absolute against the current directory and normalized.
  if path.isAbsolute:
    os.normalizedPath(path)
  else:
    os.normalizedPath(getCurrentDir() / path)

proc configuredPublicCliPath*(): string =
  ## ``$REPRO_PUBLIC_CLI_PATH`` made absolute, or "" when it is unset or does
  ## not name an existing file.
  ##
  ## A value naming nothing is ignored rather than trusted: a stale variable
  ## inherited from a launcher that has since moved or been deleted would
  ## otherwise turn every self-spawn into "no such file", far from the cause.
  ## Ignoring it falls back to ``getAppFilename()``, which is right for every
  ## image not run through a loader.
  let configured = getEnv(PublicCliPathEnvVar)
  if configured.len == 0:
    return ""
  let path = absoluteNormalizedCliPath(configured)
  if not fileExists(extendedPath(path)):
    return ""
  path

proc publicCliImagePath*(): string =
  ## The path to exec to run THIS engine again: what every self-spawn of the
  ## running engine (an internal verb, a nested ``build``, a detached cache
  ## push) and every hand-off of "the repro that is running" to something
  ## that will exec it must use, instead of a raw ``getAppFilename()``.
  ##
  ## WHY NOT ``getAppFilename()``. The portable Linux archive runs the engine
  ## through its bundled glibc loader
  ## (``exec <prefix>/lib/ld-linux-*.so.2 --library-path <prefix>/lib
  ## <prefix>/bin/.reprobuild.real "$@"``, written by
  ## ``scripts/relocate_release_posix.sh``). Under it ``/proc/self/exe`` -- and
  ## so ``getAppFilename()`` -- is the LOADER, and ``<loader> <verb> …`` makes
  ## rtld try to map ``<verb>`` as a program:
  ## ``<verb>: error while loading shared libraries: <verb>: cannot open
  ## shared object file``. The launcher exports ``$REPRO_PUBLIC_CLI_PATH``
  ## naming itself (``<prefix>/bin/reprobuild``), which is the only path that
  ## re-enters the engine with its library path intact; spawning
  ## ``.reprobuild.real`` directly would lose ``--library-path``.
  ##
  ## Precedence: ``configuredPublicCliPath()``, else ``getAppFilename()``
  ## made absolute. No ``PATH`` search: ``getAppFilename()`` asks the OS for
  ## the image (``/proc/self/exe``, ``_NSGetExecutablePath``,
  ## ``GetModuleFileName``) and its own fallback already searches ``PATH``, so
  ## a second, ambient lookup here could only name a DIFFERENT binary.
  ##
  ## This answers "which path", not "may it be spawned with an internal
  ## verb": the embedded-test-binary refusal is ``repro_cli_support``'s
  ## ``spawnableWithInternalVerb``, and a caller passing an internal selector
  ## must still go through it.
  let configured = configuredPublicCliPath()
  if configured.len > 0:
    return configured
  absoluteNormalizedCliPath(getAppFilename())

# ---------------------------------------------------------------------------
# The resolver.
# ---------------------------------------------------------------------------

proc hasReprobuildLibs*(root: string): bool =
  ## True when `root` holds reprobuild's library tree. `repro_project_dsl` is
  ## the marker because every post-install compile imports it.
  root.len > 0 and
    dirExists(extendedPath(root / "libs" / "repro_project_dsl" / "src"))

proc isAtOrBelow(path, root: string): bool =
  ## True when `root` is `path` or one of its ancestors. Compared by file
  ## identity (`sameFile`), not by spelling, so a drive alias (`subst`), a
  ## junction or a symlink between the two spellings does not break it.
  if path.len == 0 or root.len == 0 or not dirExists(extendedPath(root)):
    return false
  var cur = path
  while cur.len > 0:
    try:
      if dirExists(extendedPath(cur)) and sameFile(cur, root):
        return true
    except OSError:
      discard
    let parent = cur.parentDir
    if parent == cur or parent.len == 0:
      break
    cur = parent
  false

proc runningImageIsUnder*(root: string): bool =
  ## True when this process's image (the declared image source, for a staged
  ## copy) or the engine named by `$REPRO_PUBLIC_CLI_PATH` lives inside
  ## `root`.
  isAtOrBelow(runningImagePath(), root) or
    isAtOrBelow(getEnv(PublicCliPathEnvVar), root)

type
  SourceRootCandidate* = object
    ## One place the resolver looks, in precedence order. `origin` names it
    ## the way an operator would (a variable, a location); `path` is the
    ## directory it proposes ("" when the origin proposes none, e.g. an unset
    ## variable); `skipReason` is non-empty for a candidate that exists but is
    ## not eligible, and says why.
    origin*: string
    path*: string
    skipReason*: string

proc reprobuildSourceRootCandidates*(): seq[SourceRootCandidate] =
  ## Every candidate source root, in the order `resolveReprobuildSourceRoot`
  ## tries them. One list serves both the resolution and the diagnostic for
  ## its failure (`describeReprobuildSourceRootSearch`), so the two cannot
  ## disagree about where reprobuild looked.
  ##
  ## 1. `$REPROBUILD_LIBS_DIR` (its parent), then `$REPROBUILD_REPO_ROOT` —
  ##    the operator's explicit overrides.
  ## 2. `$REPROBUILD_SOURCE_ROOT` — the installed package's sources, as a
  ##    wrapper (the Nix package) names them.
  ## 3. `<prefix>/share/repro/source` beside the running image
  ##    (`<prefix>/bin/reprobuild[.exe]`, or the engine a launcher names in
  ##    `$REPRO_PUBLIC_CLI_PATH`) — the sources an installed layout with NO
  ##    wrapper ships: the Windows release zip, whose `repro.exe` is run
  ##    directly, and the POSIX tarballs. This is the same thing arm 2 says
  ##    for a wrapped package, which is why it sits directly after it: the
  ##    sources the image was released with. It must come BEFORE the current
  ##    directory, because an installed `repro` run from inside some other
  ##    reprobuild checkout would otherwise compile against libs of a
  ##    different revision than the binary — and it is what the image's own
  ##    start-up seeding of `$REPROBUILD_SOURCE_ROOT`
  ##    (`ensureInstalledSourcePackageEnvironment`) already made the effective
  ##    order, so placing it here changes no answer that seeding gave.
  ##    Explicit variables still win: they are the caller's stated choice.
  ## 4. The current directory, when it is itself a reprobuild tree.
  ## 5. `CompiledSourceRoot` — the checkout the binary was built in, and only
  ##    while this image runs from inside it. A binary copied out of its
  ##    checkout (a release bundle assembled on a developer's machine, an
  ##    install from a local build) is a different artifact whose sources
  ##    ship beside it; letting it reach back into the checkout would compile
  ##    against whatever revision that checkout holds NOW, silently, and on
  ##    any other machine the same binary would fail. Without this rule the
  ##    archive smoke test had to work around the build host's checkout
  ##    (`scripts/release/smoke_release_dev_exec.sh`).
  let libsDir = getEnv(ReprobuildLibsDirEnvVar)
  result.add SourceRootCandidate(origin: "$" & ReprobuildLibsDirEnvVar,
    path: (if libsDir.len > 0: libsDir.parentDir else: ""))
  result.add SourceRootCandidate(origin: "$" & ReprobuildRepoRootEnvVar,
    path: getEnv(ReprobuildRepoRootEnvVar))
  result.add SourceRootCandidate(origin: "$" & ReprobuildSourceRootEnvVar,
    path: getEnv(ReprobuildSourceRootEnvVar))
  for prefix in runningImagePrefixCandidates():
    result.add SourceRootCandidate(
      origin: "the installed layout beside this repro (" &
        prefix / "bin" & ")",
      path: prefix / InstalledSourceRootSubdir)
  var cwd = ""
  try:
    cwd = getCurrentDir()
  except OSError:
    discard
  result.add SourceRootCandidate(origin: "the current directory", path: cwd)
  result.add SourceRootCandidate(
    origin: "the checkout this repro was built in",
    path: CompiledSourceRoot,
    skipReason:
      (if runningImageIsUnder(CompiledSourceRoot): ""
       else: "not used: this repro does not run from that checkout"))

proc resolveReprobuildSourceRootCandidate*(): SourceRootCandidate =
  ## The candidate `resolveReprobuildSourceRoot` selects, with its `origin`,
  ## or an empty candidate when none holds reprobuild's libs. For a
  ## diagnostic that has to say not only which tree a compile used but why
  ## that one was chosen -- the half an operator needs to change it.
  for candidate in reprobuildSourceRootCandidates():
    if candidate.skipReason.len == 0 and hasReprobuildLibs(candidate.path):
      return candidate

proc resolveReprobuildSourceRoot*(): string =
  ## The reprobuild source tree to compile against, or "" when no candidate
  ## holds reprobuild's libs. Precedence: `reprobuildSourceRootCandidates`.
  ##
  ## Each candidate is taken only when it really holds the libs, so an
  ## override naming a stale or empty directory falls through instead of
  ## producing a compile that fails far from the cause.
  resolveReprobuildSourceRootCandidate().path

proc describeReprobuildSourceRootSearch*(): string =
  ## A multi-line account of every candidate `resolveReprobuildSourceRoot`
  ## tried and why each was not used, for the diagnostic of a compile that
  ## found no sources. Names the variables that would select a tree, so the
  ## operator learns the remedy from the message rather than from a
  ## `cannot open file` deep inside the compile.
  for candidate in reprobuildSourceRootCandidates():
    result.add "  " & candidate.origin & ": "
    if candidate.path.len == 0:
      result.add "unset\n"
    elif candidate.skipReason.len > 0:
      result.add candidate.path & " -- " & candidate.skipReason & "\n"
    elif hasReprobuildLibs(candidate.path):
      result.add candidate.path & " -- holds reprobuild's libs\n"
    elif dirExists(extendedPath(candidate.path)):
      result.add candidate.path & " -- exists, but has no " &
        "libs/repro_project_dsl/src\n"
    else:
      result.add candidate.path & " -- does not exist\n"

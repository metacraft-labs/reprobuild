## Cache-Scope P3.4 — the CLI's side of portable (cross-host) caching.
##
## Opt-in with ``REPRO_PORTABLE_CACHE=1``. When on, a build:
##
## * computes a portable fingerprint for every recorded action against the
##   logical roots below, and stores its memo record locally;
## * publishes each record (and, where the binary-cache scope publishes
##   bytes, its outputs) to the configured binary cache, when this host
##   holds a publisher keypair;
## * before scheduling, resolves the graph against the local and remote memo
##   planes and serves what it can without executing
##   (``BuildEngineConfig.portableLookup``).
##
## The logical roots are what make an identity portable: every observed path
## is named relative to one of them, so a checkout at another absolute path
## computes the same fingerprints.
##
## * ``project`` — the project being built;
## * ``work`` — its build output directory;
## * ``store`` — the reprobuild store, whose entry names are content
##   identities.
##
## Host operating-system directories are UNTRACKED: reads there (the system
## DLLs every Windows process loads, ``/proc``) are left out of the
## fingerprint, per Filesystem-Policy-And-Observed-Inputs.md. Anything else
## outside these roots makes the action non-portable: it still builds and
## caches locally, and the trace says which path kept it from being shared.

import std/[options, os, strutils]

import repro_build_engine
import repro_local_store
import repro_binary_cache_client/portable_memo_cache

proc portableCacheEnabled*(): bool =
  getEnv("REPRO_PORTABLE_CACHE", "").toLowerAscii() in ["1", "true", "yes"]

proc repositoryRootOf*(projectRoot: string): string =
  ## The nearest ancestor-or-self of `projectRoot` holding `.git` (a
  ## directory, or a file in a worktree), or "".
  if projectRoot.len == 0:
    return ""
  var dir = absolutePath(projectRoot)
  while true:
    if dirExists(dir / ".git") or fileExists(dir / ".git"):
      return dir
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      return ""
    dir = parent

proc portableCacheRoots*(projectRoot, workRoot: string;
                         storeRoot = resolveStoreRoot()): seq[LogicalRoot] =
  ## The declared root classification for this invocation.
  ##
  ## THE DERIVATION MOVED to `repro_build_engine.declaredFilesystemRoots`,
  ## and this is now the thin wrapper that supplies the one root the engine
  ## layer has no business discovering: the REPOSITORY the project lives in.
  ## A recipe's dependencies are provisioned into its SIBLING recipes
  ## (`<repo>/packages/source/<dep>/.repro/output/install`), and every action
  ## names them in its environment; without that root those paths stay
  ## absolute, so the same recipe in two checkouts never agreed on a single
  ## weak fingerprint. Finding it is a `.git` walk (`repositoryRootOf`),
  ## which must not sit on the dev-env activation path.
  ##
  ## There is now a SECOND consumer of this same classification — the
  ## membership exemption of `Incremental-Invalidation.md` §"Validation
  ## Criteria", via `BuildEngineConfig.filesystemRoots` — and it is why the
  ## derivation is shared instead of copied: two lists of the roots a
  ## workspace declares is one list to forget to update.
  declaredFilesystemRoots(projectRoot, workRoot, storeRoot,
                          repositoryRootOf(projectRoot))

proc wireFilesystemRoots*(config: var BuildEngineConfig;
                          projectRoot, workRoot: string; outRoot = "") =
  ## Declare this invocation's root classification to the engine.
  ##
  ## UNCONDITIONAL, unlike `wirePortableCache`. The portable identity is
  ## opt-in because it costs a BLAKE3 pass per input; the membership
  ## exemption this feeds is REQUIRED ("A second exemption is mandatory…"),
  ## costs a path-prefix test, and its absence is what made the dev-env
  ## provider-compile edge key on the immediate membership of `/` and of the
  ## user's home directory. Leaving it behind `REPRO_PORTABLE_CACHE` would
  ## also put the exemption behind an environment variable, which
  ## §"Validation Criteria" forbids outright.
  ##
  ## EVERY EXPLICITLY CONSTRUCTED engine configuration in the CLI calls this
  ## — all seven `var … = BuildEngineConfig(` sites — and not only the two
  ## build paths. The edges that walk furthest UP the filesystem are the
  ## internal helper ones — interface extraction and the provider compile,
  ## both of which run `nim c` — and they are the ones the measurement was
  ## taken on. An engine config that skipped this would simply keep every
  ## ancestor's membership in its key, silently, which is the shape
  ## `t_s7_build_paths_reach_the_restore_config.nim` was written about, and
  ## `t_every_engine_config_declares_its_filesystem_roots.nim` asserts over
  ## that population so a newly added site cannot opt out by not being
  ## looked at.
  ##
  ## WHAT IS NOT WIRED, said here rather than left as an overclaim. The
  ## roughly twenty `defaultBuildEngineConfig(...)` sites in the CLI do not
  ## call this, and neither does `repro_profile_compile`'s
  ## `profileCompileEngineConfig`, `repro_lock_gen` or
  ## `repro_tool_profiles`. Those keep the pre-exemption behaviour exactly,
  ## which is the fail-closed direction, and they are the workspace and VCS
  ## plumbing paths — `cloneForDevelop`, `executeWorkspaceSync`,
  ## `executeBranchCreate`, `executeWorkspaceSwitch` — whose edges run git
  ## rather than a compiler that searches upward. The profile compile has
  ## answered the same question by a different mechanism: it stages a
  ## `.nimble` so Nim's upward search STOPS at the profile directory and
  ## there are no ancestor enumerations to exempt
  ## (`issues/2026-10-14-macos-profile-compile-is-keyed-on-the-membership-of-
  ## every-ancestor-directory.md`). Wiring the rest is separable work; what
  ## must not happen is this comment claiming it is already done.
  config.filesystemRoots = declaredFilesystemRoots(projectRoot, workRoot,
    resolvedStoreRootOrEmpty(), repositoryRootOf(projectRoot), outRoot)

proc wirePortableCache*(config: var BuildEngineConfig;
                        projectRoot, workRoot: string) =
  ## Attach portable caching to an engine configuration, when enabled.
  ##
  ## The root classification is declared either way: see
  ## `wireFilesystemRoots`.
  wireFilesystemRoots(config, projectRoot, workRoot)
  if not portableCacheEnabled():
    return
  config.portableRoots = config.filesystemRoots
  config.portableLookup = true
  # A portable key is only shareable if the action cannot see the invoking
  # shell's own variables, so portable caching launches actions with an
  # allowlisted environment. `REPRO_HERMETIC_ENV=0` turns that off, for
  # diagnosing an action that turns out to need something undeclared.
  config.hermeticEnv = getEnv("REPRO_HERMETIC_ENV") != "0"
  let remote = memoRemoteFromEnv(workRoot / "portable-memo-remote")
  if remote.isNone:
    return
  let target = remote.get()
  config.portableMemoLookup = proc (roots: seq[LogicalRoot]; weakHex: string;
      resolve: IdentityResolver): Option[PortableMemoRecord] =
    {.cast(gcsafe).}:
      result = lookupRemoteMemo(target, roots, weakHex, resolve).hit
  config.portableMemoRestorer = proc (roots: seq[LogicalRoot];
      record: PortableMemoRecord): string =
    {.cast(gcsafe).}:
      result = restoreMemoOutputs(target, record, roots)
  if target.canPublish:
    config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
        record: PortableMemoRecord; withOutputs: bool): string =
      {.cast(gcsafe).}:
        let attempt = publishMemo(target, roots, record, withOutputs)
        result = if attempt.ok: "" else: attempt.reason

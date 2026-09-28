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

proc portableCacheRoots*(projectRoot, workRoot: string;
                         storeRoot = resolveStoreRoot()): seq[LogicalRoot] =
  if projectRoot.len > 0:
    result.add(LogicalRoot(label: "project", path: absolutePath(projectRoot),
                           kind: lrkTracked))
  if workRoot.len > 0:
    result.add(LogicalRoot(label: "work", path: absolutePath(workRoot),
                           kind: lrkTracked))
  if storeRoot.len > 0:
    result.add(LogicalRoot(label: "store", path: absolutePath(storeRoot),
                           kind: lrkTracked))
  when defined(windows):
    let systemRoot = getEnv("SystemRoot", "C:\\Windows")
    result.add(LogicalRoot(label: "system", path: systemRoot,
                           kind: lrkUntracked))
  else:
    for dir in ["/proc", "/sys", "/dev"]:
      result.add(LogicalRoot(label: "system" & dir.replace('/', '-'),
                             path: dir, kind: lrkUntracked))

proc wirePortableCache*(config: var BuildEngineConfig;
                        projectRoot, workRoot: string) =
  ## Attach portable caching to an engine configuration, when enabled.
  if not portableCacheEnabled():
    return
  config.portableRoots = portableCacheRoots(projectRoot, workRoot)
  config.portableLookup = true
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

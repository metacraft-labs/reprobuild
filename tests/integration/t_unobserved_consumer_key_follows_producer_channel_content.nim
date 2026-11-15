## An action whose reads nothing observes is keyed on the CONTENT of the
## producer directories it is handed.
##
## Issue: ``reprobuild-pm/issues/2026-11-12-develop-mode-rule-2-invalidation-uses-a-directory-mtime-so-report-keyed-consumers-get.md``.
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.3 (source invalidation, rule
## 2) and ``Failure-Semantics.md`` §"General Rules" (ambiguous correctness
## failures fail closed).
##
## Rule 2 of §4.3 covers a consumer action whose reads are NOT keyed
## (``readsAreKeyed`` false: a recognised-format / depfile policy). Its report
## names what the tool chose to report, not what it read; ``-MMD`` omits the
## headers found through ``-isystem``, which is how a producer's include
## directory is usually passed. So the producer's source has to reach the
## action's weak fingerprint some other way. Before the fix the only thing
## folded was the develop override's ``contentIdentity``, which named the
## producer ROOT directory's mtime: an edit deep in ``include/`` or ``src/``
## left the root mtime alone and the consumer got a stale cache hit. The
## lock-pinned arm had the same hole for a placed sibling checkout carrying
## uncommitted edits (only the pin's revision + integrity was folded).
##
## What this test asserts, for a rule-2 (``dgRecognizedFormat``) action naming
## the producer, against the shipped seam ``foldProducerSourceIdentities`` and
## a binding resolved by the shipped ``resolveProducerBinding``:
##   * an in-place edit of ``include/prod.h`` moves the key, with the producer
##     root's mtime pinned so the result does not depend on timing;
##   * so does an edit in a nested subdirectory of a channel directory;
##   * so does a ``cp -p``-style edit (same length, the file's own mtime
##     restored): nothing but the bytes changed;
##   * so does a new file under a channel directory;
##   * so does an edit reached through a symlink in a channel directory (a
##     symlinked file and a symlinked directory, both pointing outside every
##     channel directory), and a self-referencing directory link is walked
##     without looping;
##   * reverting the content restores the original key, and an unchanged
##     tree refolds to the identical key (determinism);
##   * VCS metadata under a channel directory (``.git``) does not move it;
##   * in the lock-pinned arm, an edit of a placed sibling's channel file
##     moves the key;
##   * an unreadable channel entry makes the action uncacheable instead of
##     keying it on a partial digest (skipped when running as root, which can
##     read a mode-000 file);
##   * a MONITORED (``dgAutomaticMonitor``) action naming the same producer
##     keeps its key across every one of these edits: rule 1 keys it on its
##     observed reads, which the store revalidates on lookup;
##   * a control action naming no producer stays byte-identical throughout.
##
## No mocks: the producer is a real sibling directory in a fresh tempdir, the
## develop override is written with ``writeDevelopOverridesFile`` and the lock
## with ``serializeLockedDependencies``, and the binding comes from the
## resolver the build uses. The splice sinks (``producerSourceBindings`` /
## ``producerMaterializedAuxPaths``) are filled the way the real splice fills
## them (``repro_cli_support`` ``spliceProducer…``, recording
## ``<root>/include`` and ``<root>/src``) rather than by running a full
## producer build, which ``t_sc_*`` end-to-end tests already cover and which
## would add nothing to the key arithmetic under test. Nothing touches
## ``$HOME``; no network, git or ``repro`` binary is needed.

import std/[os, posix, strutils, tables, times, unittest]

import repro_cli_support
import repro_core
import repro_hash
import repro_lock
import repro_workspace_manifests
import repro_build_engine

const
  producerName = "prod"
  siblingUrl = "https://vcs.invalid/prod.git"
  siblingRev = "0123456789abcdef0123456789abcdef01234567"
  siblingIntegrity = "git-sha1:0123456789abcdef0123456789abcdef01234567"

proc mkAction(id: string; refs: seq[string];
              policy = dgRecognizedFormat): BuildAction =
  BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakProcess,
    id: id,
    cacheable: true,
    dependencyPolicy: DependencyGatheringPolicy(kind: policy),
    toolIdentityRefs: refs,
    weakFingerprint: weakFingerprintFromText("channel-content-fixture-" & id))

proc writeLock(workspaceRoot: string) =
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(),
    optimal: true,
    inputsDigest: inputsDigestOf("channel-content-fixture"))
  ld.deps.add(LockedDep(
    name: producerName,
    path: "../prod",
    coordinates: Coordinates(kind: ckVcs, url: siblingUrl,
      revision: siblingRev),
    integrity: siblingIntegrity,
    visibility: "public"))
  writeFile(committedLockPath(workspaceRoot), serializeLockedDependencies(ld))

proc writeOverride(workspaceRoot, siblingCheckout: string) =
  let file = newDevelopOverrides().addOverride(DevelopOverrideEntry(
    package: producerName,
    local_path: siblingCheckout,
    state: "editable",
    created_at: "2026-11-15T00:00:00Z"))
  writeDevelopOverridesFile(workspaceRoot, file)

type Keys = object
  unobserved: ContentDigest
  unobservedCacheable: bool
  monitored: ContentDigest
  monitoredCacheable: bool
  control: ContentDigest

suite "unobserved consumer key follows producer channel content":

  test "t_unobserved_consumer_key_follows_producer_channel_content":
    let scratch = getTempDir() / "chancontent-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer:
      # A mode-000 file left by a failed check would stop removeDir.
      discard chmod(cstring(scratch / "prod" / "include" / "locked.h"), 0o644)
      removeDir(scratch)

    let workspace = absolutePath(scratch / "consumer")
    createDir(workspace)
    let prod = absolutePath(scratch / "prod")
    createDir(prod / "include" / "sub")
    createDir(prod / "src")
    createDir(prod / "vendor")
    createDir(prod / "vendor-dir")
    createDir(prod / "include" / ".git")
    writeFile(prod / "repro.nim", "package prod:\n  discard\n")
    writeFile(prod / "include" / "prod.h", "#define PROD_VALUE 1\n")
    writeFile(prod / "include" / "sub" / "deep.h", "#define PROD_DEEP 1\n")
    writeFile(prod / "include" / ".git" / "HEAD", "ref: refs/heads/dev\n")
    writeFile(prod / "src" / "prod.nim", "proc prodValue*(): int = 1\n")
    writeFile(prod / "vendor" / "real.h", "#define PROD_REAL 1\n")
    writeFile(prod / "vendor-dir" / "linked.h", "#define PROD_LINKED 1\n")
    createSymlink("../vendor/real.h", prod / "include" / "alias.h")
    createSymlink("../vendor-dir", prod / "include" / "vendored")
    # A directory link back to its own parent: the walk must terminate.
    createSymlink(".", prod / "include" / "loop")

    let includeDir = prod / "include"
    let srcDir = prod / "src"
    let rootMtime = getLastModificationTime(prod)

    let unobservedOrig = mkAction("consumer.cc", @["sh", producerName])
    let monitoredOrig = mkAction("consumer.monitored", @["sh", producerName],
      policy = dgAutomaticMonitor)
    let controlOrig = mkAction("consumer.control", @["sh"])
    check not unobservedOrig.readsAreKeyed
    check monitoredOrig.readsAreKeyed

    proc fold(binding: ResolvedPackageBinding): Keys =
      producerSourceBindings.clear()
      producerSourceBindings[producerName] = binding
      producerMaterializedAuxPaths.clear()
      producerMaterializedAuxPaths[producerName] = ProducerAuxPaths(
        includeDirs: @[includeDir], nimPathDirs: @[srcDir])
      var acts = @[unobservedOrig, monitoredOrig, controlOrig]
      foldProducerSourceIdentities(acts)
      Keys(unobserved: acts[0].weakFingerprint,
        unobservedCacheable: acts[0].cacheable,
        monitored: acts[1].weakFingerprint,
        monitoredCacheable: acts[1].cacheable,
        control: acts[2].weakFingerprint)

    writeLock(workspace)
    writeOverride(workspace, prod)

    proc foldDevelop(): Keys =
      # Re-resolve as the next ``repro build`` invocation would, with the
      # producer root's mtime put back first: before the fix that mtime was
      # the whole of the develop identity, so pinning it isolates the
      # property under test from the clock.
      setLastModificationTime(prod, rootMtime)
      let binding = resolveProducerBinding(producerName, workspace)
      check binding.kind == pbkDevelopOverride
      fold(binding.overrideBinding)

    proc editKeepingMtime(path, content: string) =
      let mtime = getLastModificationTime(path)
      writeFile(path, content)
      setLastModificationTime(path, mtime)

    let k1 = foldDevelop()
    check k1.unobserved != unobservedOrig.weakFingerprint
    check k1.unobservedCacheable
    check k1.control == controlOrig.weakFingerprint
    let monitoredKey = k1.monitored
    check monitoredKey != monitoredOrig.weakFingerprint

    proc expectMoved(label: string; keys: Keys) =
      checkpoint(label)
      check keys.unobserved != k1.unobserved
      check keys.unobservedCacheable
      check keys.monitored == monitoredKey
      check keys.monitoredCacheable
      check keys.control == controlOrig.weakFingerprint

    proc expectBaseline(label: string; keys: Keys) =
      checkpoint(label)
      check keys.unobserved == k1.unobserved
      check keys.unobservedCacheable
      check keys.monitored == monitoredKey
      check keys.control == controlOrig.weakFingerprint

    # Unchanged tree -> identical key.
    expectBaseline("unchanged tree refolds", foldDevelop())

    # (a) In-place edit of a header in the include channel.
    writeFile(includeDir / "prod.h", "#define PROD_VALUE 22\n")
    expectMoved("include/prod.h edited", foldDevelop())
    writeFile(includeDir / "prod.h", "#define PROD_VALUE 1\n")
    expectBaseline("include/prod.h reverted", foldDevelop())

    # (b) Edit in a nested subdirectory of a channel dir.
    writeFile(includeDir / "sub" / "deep.h", "#define PROD_DEEP 2\n")
    expectMoved("include/sub/deep.h edited", foldDevelop())
    writeFile(includeDir / "sub" / "deep.h", "#define PROD_DEEP 1\n")
    expectBaseline("include/sub/deep.h reverted", foldDevelop())

    # (c) ``cp -p``-style: same length, own mtime restored.
    let nimSrc = srcDir / "prod.nim"
    let nimSize = getFileSize(nimSrc)
    editKeepingMtime(nimSrc, "proc prodValue*(): int = 7\n")
    check getFileSize(nimSrc) == nimSize
    expectMoved("src/prod.nim same-size edit, mtime kept", foldDevelop())
    editKeepingMtime(nimSrc, "proc prodValue*(): int = 1\n")
    expectBaseline("src/prod.nim reverted", foldDevelop())

    # (d) A new file under a channel dir.
    writeFile(includeDir / "added.h", "#define PROD_ADDED 1\n")
    expectMoved("include/added.h added", foldDevelop())
    removeFile(includeDir / "added.h")
    expectBaseline("include/added.h removed", foldDevelop())

    # (e) Edits reached through symlinks whose targets lie outside every
    # channel dir: a symlinked file and a symlinked directory.
    editKeepingMtime(prod / "vendor" / "real.h", "#define PROD_REAL 2\n")
    expectMoved("vendor/real.h edited through include/alias.h", foldDevelop())
    editKeepingMtime(prod / "vendor" / "real.h", "#define PROD_REAL 1\n")
    expectBaseline("vendor/real.h reverted", foldDevelop())
    editKeepingMtime(prod / "vendor-dir" / "linked.h",
      "#define PROD_LINKED 2\n")
    expectMoved("vendor-dir/linked.h edited through include/vendored",
      foldDevelop())
    editKeepingMtime(prod / "vendor-dir" / "linked.h",
      "#define PROD_LINKED 1\n")
    expectBaseline("vendor-dir/linked.h reverted", foldDevelop())

    # (f) VCS metadata under a channel dir is not part of the identity.
    writeFile(includeDir / ".git" / "HEAD", "ref: refs/heads/other\n")
    expectBaseline(".git under a channel dir edited", foldDevelop())

    # (g) Fail closed: an unreadable channel entry makes the rule-2 action
    # uncacheable rather than keyed on a partial digest. Root reads a
    # mode-000 file, so the case cannot be staged there.
    if geteuid() == 0:
      echo "[skip] unreadable-entry case: running as root"
    else:
      let locked = includeDir / "locked.h"
      writeFile(locked, "#define PROD_LOCKED 1\n")
      check chmod(cstring(locked), 0) == 0
      let unreadable = foldDevelop()
      checkpoint("unreadable include/locked.h")
      check not unreadable.unobservedCacheable
      check unreadable.monitored == monitoredKey
      check unreadable.monitoredCacheable
      check unreadable.control == controlOrig.weakFingerprint
      check chmod(cstring(locked), 0o644) == 0
      removeFile(locked)
      expectBaseline("include/locked.h removed", foldDevelop())

    # (h) Lock-pinned arm: the producer is a placed sibling checkout at the
    # pin; uncommitted edits in its channel dirs must move the key too.
    removeFile(developOverridesPath(workspace))
    let lockBinding = resolveProducerBinding(producerName, workspace)
    check lockBinding.kind == pbkLockPinned
    let pinned = lockPinnedSourceBinding(producerName, lockBinding.lockedDep)
    let l1 = fold(pinned)
    check l1.unobserved != unobservedOrig.weakFingerprint
    check fold(pinned).unobserved == l1.unobserved
    writeFile(includeDir / "prod.h", "#define PROD_VALUE 33\n")
    let l2 = fold(pinned)
    check l2.unobserved != l1.unobserved
    check l2.unobservedCacheable
    check l2.monitored == l1.monitored
    check l2.control == controlOrig.weakFingerprint
    writeFile(includeDir / "prod.h", "#define PROD_VALUE 1\n")
    check fold(pinned).unobserved == l1.unobserved

    producerSourceBindings.clear()
    producerMaterializedAuxPaths.clear()
    producerMaterializedBinDirs.clear()

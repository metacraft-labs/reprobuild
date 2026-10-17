## WHICH PATHS THE PROMPT WATCH MANIFEST LISTS, AND WHEN IT MAY BE TRUSTED.
##
## `repro_dev_env_engine.devEnvPromptWatchEntries` decides what the shell
## hook's prompt-time key watches for an activation (`reprobuild-pm`
## `issues/2026-09-28-dev-env-prompt-key-ignores-flake-inputs.md`). Its
## end-to-end gate, `t_e2e_shell_hook_prompt_key_sees_flake_inputs.nim`,
## drives a real flake through a real activation; this file pins the rules
## that gate cannot isolate, on the CACHE-HIT shape -- the one a warm prompt
## re-activation actually takes:
##
##   * a hit's evidence is the record replayed (`evidenceFromRecord`), and a
##     directory whose membership the record fingerprinted must come back as
##     ENUMERATED, so the manifest a hit writes keys that directory on its
##     membership exactly as the execution that wrote the record did;
##   * a directory the record kept for existence only stays existence-only;
##   * `/nix/store/`, the edge's own output directory and its ignored-input
##     prefixes are left out, and `flake.nix` / `flake.lock` are always in;
##   * a hit whose evidence paths were elided, or never rebuilt at all
##     (`skipCacheHitEvidence`), reports the set incomplete, so the caller
##     emits a marker no prompt matches instead of keying on the flake floor
##     alone.
##
## MOCK POLICY: the record is constructed in the test rather than published
## by a build. The function under test starts from an `ActionResult` whose
## evidence `evidenceFromRecord` has rebuilt from a record, so a record is
## the input boundary; producing one through a monitored build would add a
## provider compile, a `nix` evaluation and a runquotad, none of which is on
## the path under test, and the e2e gate above covers that path for real.
## The record's directory metadata uses the production encoding
## (`membershipTrackedDirectory`: a non-zero `mtimeNs` on a directory), and
## every path it names exists on the real filesystem.

import std/[os, tempfiles, unittest]

import repro_build_engine
import repro_dev_env_engine
import repro_local_store
import repro_lock/identity

proc entryFor(entries: openArray[PromptWatchEntry];
              path: string): tuple[found, enumerated: bool] =
  for entry in entries:
    if entry.path == path:
      return (true, entry.enumerated)

suite "dev-env prompt watch entries":

  # The kernel's spelling, as the monitor records it (`/private/var/...` on
  # macOS rather than `/var/...`).
  let root = expandFilename(createTempDir("t_dev_env_prompt_watch_entries",
    ""))
  let project = root / "proj"
  let outDir = project / ".repro" / "dev-env" / "default"
  let sibling = root / "sib"
  let tree = sibling / "tree"
  createDir(outDir)
  createDir(project / ".repro" / "foreign-env")
  createDir(tree)
  writeFile(project / "repro.nim", "# project file\n")
  writeFile(sibling / "marker.txt", "sibA\n")
  writeFile(outDir / "provider", "binary\n")
  writeFile(project / ".repro" / "foreign-env" / "flake-profile", "gcroot\n")

  let act = action("__repro_dev_env_introspection", ["provider"],
    cwd = project, cacheable = true,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

  proc recorded(): ActionResultRecord =
    result.inputs.add(FileFingerprint(path: sibling / "marker.txt",
      metadata: FileMetadata(kind: ffkRegular, sizeBytes: 5,
        mtimeNs: 1_000_000_000'u64)))
    # Membership fingerprinted: the execution ENUMERATED it.
    result.inputs.add(FileFingerprint(path: tree,
      metadata: FileMetadata(kind: ffkDirectory, mtimeNs: 42'u64)))
    # Existence only: the execution merely probed it.
    result.inputs.add(FileFingerprint(path: sibling,
      metadata: FileMetadata(kind: ffkDirectory)))
    for excluded in [
        "/nix/store/00000000000000000000000000000000-x/bin/x",
        outDir / "provider",
        project / ".repro" / "foreign-env" / "flake-profile"]:
      result.inputs.add(FileFingerprint(path: excluded,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 1,
          mtimeNs: 1'u64)))

  proc hit(evidence: PathSetEvidence): ActionResult =
    ActionResult(id: act.id, status: asUpToDate, cacheDecision: cdHit,
      evidence: evidence)

  test "a replayed record yields the execution's watch set":
    var complete = false
    let entries = devEnvPromptWatchEntries(act,
      hit(evidenceFromRecord(act, recorded())), project, outDir, [], complete)
    check complete
    check entries.entryFor(sibling / "marker.txt") == (true, false)
    # Without the replay of membership-tracked directories as enumerations
    # this was (true, false): the hit's manifest keyed the directory on its
    # existence while the execution's keyed it on its membership.
    check entries.entryFor(tree) == (true, true)
    check entries.entryFor(sibling) == (true, false)
    # The floor, whether or not the files exist.
    check entries.entryFor(project / "flake.nix").found
    check entries.entryFor(project / "flake.lock").found
    # Immutable, derived, or rewritten by the edge itself.
    check not entries.entryFor(
      "/nix/store/00000000000000000000000000000000-x/bin/x").found
    check not entries.entryFor(outDir / "provider").found
    check not entries.entryFor(
      project / ".repro" / "foreign-env" / "flake-profile").found

  test "a hit whose evidence was never rebuilt is incomplete":
    # `skipCacheHitEvidence` leaves a zero `PathSetEvidence`. Read as
    # complete, it would shrink the set to the flake floor.
    var complete = true
    let entries = devEnvPromptWatchEntries(act, hit(PathSetEvidence()),
      project, outDir, [], complete)
    check not complete
    check entries.entryFor(project / "flake.nix").found

  test "a hit whose evidence paths were elided is incomplete":
    var elided = hit(PathSetEvidence())
    elided.evidencePathCounts = EvidencePathCounts(elided: true,
      monitorReads: 3)
    var complete = true
    discard devEnvPromptWatchEntries(act, elided, project, outDir, [],
      complete)
    check not complete

  removeDir(root)

import std/[algorithm, os, strutils, tables, times]

import blake3

const CacheKeySchema* = "reprobuild.dev-env.cache-key.v2"
  ## v2: the key folds in the prompt watch manifest (``promptWatch=``, the
  ## last part). See ``promptWatchState``.

const
  CanonicalProjectFileName = "repro.nim"
  LegacyProjectFileName = "reprobuild.nim"
  FrameMagic = "reprobuild.hash.v1\0"
  ActionFingerprintDomainTag = "action-fingerprint"

proc fastPathFsPath(path: string): string =
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      var canonical = absolutePath(path).replace('/', '\\')
      while "\\\\" in canonical:
        canonical = canonical.replace("\\\\", "\\")
      "\\\\?\\" & canonical
  else:
    path

proc fastFileExists(path: string): bool =
  fileExists(fastPathFsPath(path))

proc fileFingerprintPart(path: string): string =
  if path.len == 0:
    return ""
  if not fastFileExists(path):
    return path & "\n<missing>"
  path & "\n" & readFile(fastPathFsPath(path))

proc canonicalProjectFilePath(projectRoot: string): string =
  ## Mirror ``resolveProjectFile`` without surfacing ambiguity diagnostics on
  ## the prompt-time fast path. The full CLI remains authoritative whenever
  ## the fast path cannot prove a no-op.
  let canonical = projectRoot / CanonicalProjectFileName
  let legacy = projectRoot / LegacyProjectFileName
  let hasCanonical = fastFileExists(canonical)
  let hasLegacy = fastFileExists(legacy)
  if hasCanonical and hasLegacy:
    return ""
  if hasCanonical:
    canonical
  elif hasLegacy:
    legacy
  else:
    # NF-4 — a project with no project file of its own may still be running a
    # SYNTHESISED one (`repro_dsl_stdlib/foreign_env/auto_load`), whose body
    # names which foreign environment is activated. It has to be in the key:
    # without it, flipping an auto-load flag from `.envrc` to `flake.nix`
    # would be answered as a prompt-time no-op, and the shell would keep the
    # environment the operator just turned off. (When this key still gated
    # interface reuse in `computeDevEnvEdge`, it also left the previous
    # decision's cached interface artifact in place.) Spelled literally
    # rather than imported for the same reason the two project-file names
    # above are: this module is the prompt-time fast path and takes no
    # dependency it does not have to.
    let synthesized = projectRoot / ".repro" / "foreign-env" /
      CanonicalProjectFileName
    if fastFileExists(synthesized): synthesized else: ""

proc lockSliceFilePart(projectRoot: string): string =
  let lockPath = projectRoot / ".repro" / "dev-env.lock"
  fileFingerprintPart(lockPath)

proc envVarPart(name: string): string =
  if existsEnv(name):
    name & "=" & getEnv(name)
  else:
    name & "=<unset>"

proc textBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc gitDirForProjectRoot(projectRoot: string): string =
  let dotGit = projectRoot / ".git"
  if dirExists(dotGit):
    return dotGit
  if fileExists(dotGit):
    try:
      let content = readFile(dotGit).strip()
      const prefix = "gitdir:"
      if content.normalize().startsWith(prefix):
        let raw = content[prefix.len .. ^1].strip()
        if raw.isAbsolute:
          return os.normalizedPath(raw)
        return os.normalizedPath(projectRoot / raw)
    except CatchableError:
      discard
  ""

proc developOverridesMetadataPath*(projectRoot: string): string =
  let gitDir = gitDirForProjectRoot(projectRoot)
  if gitDir.len > 0:
    return gitDir / "reprobuild" / "develop-overrides.json"
  projectRoot / ".repro" / "local" / "develop-overrides.json"

proc updateU16Le(hasher: blake3.Blake3Hasher; value: uint16) =
  var bytes: array[2, byte]
  bytes[0] = byte(value and 0xff'u16)
  bytes[1] = byte((value shr 8) and 0xff'u16)
  hasher.update(bytes)

proc updateU64Le(hasher: blake3.Blake3Hasher; value: uint64) =
  var bytes: array[8, byte]
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    bytes[shift div 8] = byte((value shr shift) and 0xff'u64)
  hasher.update(bytes)

proc actionFingerprintDigest(payload: openArray[byte]): blake3.Blake3Digest =
  ## THE FRAME HERE IS NOT A PRIVATE ONE. Magic, tag length, tag, payload
  ## length, payload is the same layout `repro_hash/policy` frames, and
  ## `ActionFingerprintDomainTag` is the same string its `hdActionFingerprint`
  ## emits -- so this proc is byte-for-byte `casDigest(payload,
  ## hdActionFingerprint)`. It is spelled out again rather than imported for
  ## the reason the project-file names above are: this module is the
  ## prompt-time fast path and `repro_hash` would pull `gxhash` and `xxh3`
  ## into the front controller's link for a digest it never takes.
  ##
  ## `tests/unit/t_dev_env_cache_key_frame.nim` holds the duplication to that
  ## claim: it recomputes this key through `repro_hash` and fails if the two
  ## frames ever diverge. Without it the copy is free to drift, and drift
  ## here does not fail loudly -- it silently invalidates every cached
  ## dev-env edge.
  ##
  ## Streams the frame instead of concatenating it. The buffer this replaces
  ## existed only to be handed to the one-shot `blake3.digest`, and its
  ## payload half was a full copy of bytes the caller already owned. The same
  ## defect in `repro_hash/policy.framedPayload` was the hottest leaf frame in
  ## a warm-no-op profile; this copy was not on that path, but it is the same
  ## defect and there is no reason to keep it.
  var hasher = blake3.initHasher()
  defer:
    hasher.close()
  hasher.update(FrameMagic)
  hasher.updateU16Le(uint16(ActionFingerprintDomainTag.len))
  hasher.update(ActionFingerprintDomainTag)
  hasher.updateU64Le(uint64(payload.len))
  hasher.update(payload)
  hasher.finalize()

# ---------------------------------------------------------------------
# The prompt watch manifest.
#
# WHY IT EXISTS. Every input above is something the CLI can name without
# running the recipe: the project file, the lock slice, the develop-overrides
# file, a few variables. A recipe whose environment comes from somewhere else
# has inputs none of them describe. `useFlakeDevShell()` is the case that was
# measured: its environment is whatever `nix print-dev-env` makes of
# `flake.nix`, `flake.lock` and the working trees of the `--override-input`
# siblings, and with only the parts above in the key an edit to any of those
# was answered "no-op (cache key unchanged)" on every prompt after it -- the
# shell kept the previous environment indefinitely
# (`reprobuild-pm` `issues/2026-09-28-dev-env-prompt-key-ignores-flake-inputs.md`).
# `Nix-Flake-Coexistence.md` §2b is explicit that re-entry is decided against
# the OBSERVED manifest, not against a list somebody declared, and
# `Shell-Direnv-Hook.md` §"Fast-Path Cache-Key Check" is the check that was
# not doing so.
#
# WHAT IT IS. At the end of a full `repro dev-env export`, the activation
# writes the paths its introspection edge was observed to depend on -- reads,
# probes (present and absent), enumerated directories, depfile and declared
# inputs, filtered by `devEnvPromptWatchEntries` in `repro_dev_env_engine` --
# into a sidecar next to its rollback manifest. Every prompt's key then folds
# in the CURRENT `lstat` metadata of each listed path. The activation emits
# the key computed against the manifest it just wrote; the prompt locates the
# same file through `$__REPRO_ACTIVE_MANIFEST` (which the activation script
# sets) and recomputes it.
#
# WHY METADATA AND NOT CONTENT. This runs on every prompt, under the < 5 ms
# budget `t_e2e_shell_hook_noop_latency.nim` holds it to, and a flake's
# observed set is a few hundred paths. One `lstat` each is affordable; reading
# and hashing each is not, and neither is spawning `git` or `nix`. The cost of
# the choice is in the safe direction: a `touch` that changes nothing makes
# one prompt re-activate, and the engine, which IS content-addressed, decides
# from there.
#
# WHAT IS COMPARED, PER ENTRY. Two kinds, fixed by the writer:
#
#   * `p <path>` -- a path the edge read or probed. A file or symbolic link is
#     compared on kind, size, mtime and ctime (with nanoseconds where the
#     filesystem has them), device and inode; any edit, replacement or
#     appearance moves at least one. A link also records whether it
#     resolves, as the action cache's fingerprint does; the link's own
#     metadata does not move when a dangling link's target appears. Like the
#     action cache, a link's TARGET content is not followed: a target the
#     edge read is an entry of its own when the monitor recorded it. A
#     DIRECTORY is compared on kind ONLY:
#     a directory that was merely stat'ed -- `$HOME`, `$TMPDIR`, the project's
#     parent, every ancestor a path walk passes through -- changes membership
#     constantly for reasons unrelated to the environment, and keying on its
#     mtime would make every prompt a re-activation, which is the failure
#     this fast path exists to prevent.
#   * `d <path>` -- a directory the edge ENUMERATED. Its membership is an
#     input (`Incremental-Invalidation.md` §"Validation Criteria": adding or
#     removing a file in an enumerated directory invalidates), so it is
#     compared on the full metadata above; its mtime and ctime move when an
#     entry is added, removed or renamed.

const
  PromptWatchSchema* = "reprobuild.dev-env.prompt-watch.v1"
    ## First line of every prompt watch manifest. A file whose first line is
    ## anything else is malformed and keys as ``<malformed>``.
  PromptWatchFileName* = "dev-env.prompt-watch"
    ## The sidecar's name inside the per-activation directory. Deliberately
    ## not a ``dev-env.rbde*`` name: `t_e2e_shell_hook_noop_io_bounded.nim`
    ## forbids the no-op path from touching build artifacts by that
    ## substring, and this file is not one.
  PromptWatchNoneToken = "<none>"
    ## No manifest path at all: a caller that has no activation to compare
    ## against (or a pre-v2 caller).
  PromptWatchUnreadableToken = "<unreadable>"
    ## A manifest path that names nothing readable -- the activation
    ## directory was removed, or the environment names a manifest from
    ## another machine. Distinct from ``<none>`` and from every real state,
    ## so it can only match a marker computed against the same absence.
  PromptWatchMalformedToken = "<malformed>"
  CoarseTimestampMarginSeconds = 2.0
    ## The race guard's margin for a timestamp with no sub-second part: a
    ## filesystem with whole-second (HFS+, many network mounts) or
    ## two-second (FAT) resolution truncates a write made just after the
    ## edge started to a time up to two seconds BEFORE it.
  FineTimestampMarginSeconds = 0.02
    ## The margin for a nanosecond-resolution timestamp. Linux stamps inodes
    ## from the coarse kernel clock, which lags `CLOCK_REALTIME` by up to one
    ## jiffy (10 ms at HZ=100); this is twice that. Not more, because the
    ## margin has a cost too: a file written within it BEFORE the activation
    ## started is treated as unsettled and costs one extra activation, and
    ## "write a file, then activate" is exactly what a script (or a test
    ## fixture) does. At 100 ms that was measured to make the first
    ## activation of a freshly written project unmatchable.

type
  PromptWatchEntry* = object
    ## One path of the prompt watch manifest. ``enumerated`` selects the
    ## ``d`` comparison for a directory (membership); see the section note.
    path*: string
    enumerated*: bool

proc promptWatchManifestPathFor*(rollbackManifestPath: string): string =
  ## THE one derivation of the sidecar's location, used by the writer (the
  ## full `dev-env export`) and by both readers (the thin client's
  ## `tryDevEnvExportFastPath` and the engine's own fast-path check). Both
  ## readers start from `$__REPRO_ACTIVE_MANIFEST`, the rollback manifest's
  ## path, which the activation script exports. ``""`` in, ``""`` out.
  if rollbackManifestPath.len == 0:
    return ""
  parentDir(rollbackManifestPath) / PromptWatchFileName

proc writePromptWatchManifest*(path: string;
                               entries: openArray[PromptWatchEntry]) =
  ## Write the manifest atomically (``<path>.tmp`` then rename), sorted and
  ## de-duplicated by path so the same observed set always produces the same
  ## bytes. A path listed both ways keeps the stronger ``d`` reading.
  ##
  ## Raises ``ValueError`` for a path the line format cannot carry (empty,
  ## or containing a line break) rather than dropping it: a dropped path is
  ## an input the prompt key silently stops watching. The caller treats the
  ## raise as "this activation cannot be keyed" and emits a marker no prompt
  ## matches.
  var merged = initTable[string, bool]()
  for entry in entries:
    if entry.path.len == 0 or '\n' in entry.path or '\r' in entry.path:
      raise newException(ValueError,
        "prompt watch path cannot be recorded: " & entry.path.escape())
    merged[entry.path] = merged.getOrDefault(entry.path) or entry.enumerated
  var paths: seq[string]
  for p in merged.keys:
    paths.add(p)
  paths.sort(system.cmp[string])
  var body = PromptWatchSchema & "\n"
  for p in paths:
    body.add(if merged[p]: "d " else: "p ")
    body.add(p)
    body.add('\n')
  createDir(parentDir(path))
  let tmpPath = path & ".tmp"
  writeFile(tmpPath, body)
  moveFile(tmpPath, path)

proc readPromptWatchManifest(path: string;
    entries: var seq[PromptWatchEntry]): string =
  ## Parse ``path`` into ``entries``. Returns ``""`` on success, or the token
  ## that stands for the failure.
  var text: string
  try:
    text = readFile(fastPathFsPath(path))
  except CatchableError:
    return PromptWatchUnreadableToken
  var first = true
  for line in text.splitLines():
    if first:
      if line != PromptWatchSchema:
        return PromptWatchMalformedToken
      first = false
      continue
    if line.len == 0:
      continue
    if line.len < 3 or line[1] != ' ' or line[0] notin {'p', 'd'}:
      return PromptWatchMalformedToken
    entries.add(PromptWatchEntry(path: line[2 .. ^1],
      enumerated: line[0] == 'd'))
  if first:
    return PromptWatchMalformedToken
  ""

proc timeNs(t: Time): string =
  $t.toUnix() & "." & align($t.nanosecond, 9, '0')

proc timeSeconds(t: Time): float =
  float(t.toUnix()) + float(t.nanosecond) / 1e9

proc entryState(entry: PromptWatchEntry): string =
  ## The comparable state of one entry. See the section note for what each
  ## kind compares and why a probed directory compares on kind alone.
  var info: FileInfo
  try:
    info = getFileInfo(fastPathFsPath(entry.path), followSymlink = false)
  except OSError as err:
    # Absent (ENOENT), or not reachable (EACCES / ENOTDIR). The errno is
    # kept so that a path moving from one failure to the other is a change
    # too; a later appearance moves it to a real state.
    return "missing " & $err.errorCode
  case info.kind
  of pcDir:
    if not entry.enumerated:
      return "dir"
    result = "dir " & $info.size & " " & timeNs(info.lastWriteTime) & " " &
      timeNs(info.creationTime) & " " & $info.id.device & ":" & $info.id.file
  of pcFile, pcLinkToFile, pcLinkToDir:
    let kind =
      case info.kind
      of pcFile: "file"
      of pcLinkToFile: "link"
      else: "dirlink"
    # `creationTime` is the POSIX ctime (status change) on Unix: std/os fills
    # it from `st_ctim`. On Windows it is the creation time; there the mtime,
    # size and file index carry the change.
    result = kind & " " & $info.size & " " & timeNs(info.lastWriteTime) &
      " " & timeNs(info.creationTime) & " " & $info.id.device & ":" &
      $info.id.file
    if info.kind != pcFile:
      # Whether the link RESOLVES, as the action cache's own fingerprint
      # records it (`repro_local_store.fingerprintMetadata` classifies a
      # link by its target and keeps a dangling one as
      # `ffkUnresolvedSymlink`). The link's own metadata above does not
      # move when a dangling link's target appears, and std/os reports a
      # dangling link and a link to a file alike as `pcLinkToFile`.
      try:
        let target = getFileInfo(fastPathFsPath(entry.path),
          followSymlink = true)
        result.add(if target.kind == pcDir: " -> dir" else: " -> file")
      except OSError as err:
        result.add(" -> unresolved " & $err.errorCode)

proc promptWatchState*(manifestPath: string): string =
  ## The ``promptWatch=`` part of the prompt key: the manifest's own schema
  ## line, then ``<path>\t<state>`` per entry in manifest order -- or one of
  ## the fixed tokens when there is no manifest to read. Every token begins
  ## with ``<`` and every real state with the schema line, so none collides.
  if manifestPath.len == 0:
    return PromptWatchNoneToken
  var entries: seq[PromptWatchEntry]
  let failure = readPromptWatchManifest(manifestPath, entries)
  if failure.len > 0:
    return failure
  result = PromptWatchSchema
  for entry in entries:
    result.add('\n')
    result.add(if entry.enumerated: "d " else: "p ")
    result.add(entry.path)
    result.add('\t')
    result.add(entryState(entry))

proc comparablePromptWatchPath*(path: string): string =
  ## One spelling per location, for COMPARING a manifest path with a path the
  ## monitor recorded elsewhere (a write, a removal). On macOS `/var`, `/tmp`
  ## and `/etc` are symbolic links into `/private`, and one capture can
  ## record both forms of the same location. Used only to compare; the
  ## manifest keeps every path as recorded.
  result = path.replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)
  when defined(macosx):
    for prefix in ["/var", "/tmp", "/etc"]:
      if result == prefix or result.startsWith(prefix & "/"):
        return "/private" & result

proc changedSince(info: FileInfo; startedAt: float): bool =
  ## Whether ``info``'s mtime or ctime is not safely earlier than
  ## ``startedAt``, allowing for the filesystem's timestamp resolution: it is
  ## the timestamp the filesystem RECORDED that is compared, and a coarse one
  ## can sit before the moment the write actually happened.
  let coarse = info.lastWriteTime.nanosecond == 0 and
    info.creationTime.nanosecond == 0
  let margin =
    if coarse: CoarseTimestampMarginSeconds
    else: FineTimestampMarginSeconds
  max(timeSeconds(info.lastWriteTime), timeSeconds(info.creationTime)) >=
    startedAt - margin

type
  PromptWatchBaseline* = object
    ## The entry NAMES of each membership-tracked directory (``d`` entry) of
    ## a prompt watch manifest, listed BEFORE an activation's edge runs (see
    ## ``snapshotPromptWatchBaseline``). Keyed by
    ## ``comparablePromptWatchPath``.
    listings*: Table[string, seq[string]]

proc directoryNames(dir: string; names: var seq[string]): bool =
  ## The sorted entry names of ``dir``; false when it cannot be listed.
  names.setLen(0)
  try:
    for child in walkDir(fastPathFsPath(dir), relative = true):
      names.add(child.path)
  except OSError:
    return false
  names.sort(system.cmp[string])
  true

proc snapshotPromptWatchBaseline*(manifestPath: string): PromptWatchBaseline =
  ## List, NOW, every ``d`` entry of the manifest at ``manifestPath`` -- the
  ## previous activation's, read before this activation's edge runs. The
  ## race guard compares these listings with the directories after the edge
  ## ran, which is the only way to tell a foreign removal from the edge's
  ## own when both moved the same directory: timestamps say only THAT a
  ## directory changed, and the edge's evidence says what IT did, not what
  ## else happened. A manifest that cannot be read yields no listings, and
  ## the guard is conservative for every directory it has no listing for.
  result.listings = initTable[string, seq[string]]()
  var entries: seq[PromptWatchEntry]
  if manifestPath.len == 0 or
      readPromptWatchManifest(manifestPath, entries).len > 0:
    return
  for entry in entries:
    if not entry.enumerated:
      continue
    var names: seq[string]
    if directoryNames(entry.path, names):
      result.listings[comparablePromptWatchPath(entry.path)] = names

proc unsettledPromptWatchPaths*(manifestPath: string; startedAt: float;
                                ownWrites: openArray[string] = [];
                                ownRemovals: openArray[string] = [];
                                baseline = PromptWatchBaseline()):
    seq[string] =
  ## The race guard. The paths of the manifest that may have changed after
  ## the edge observed them. ``startedAt`` is seconds since the epoch, taken
  ## immediately BEFORE the build that ran (or cache-checked) the edge.
  ##
  ## WHY. The activation computes the key it emits from metadata it stats
  ## AFTER the edge has run, because only then does it know the observed set.
  ## A change that lands between the edge observing a path and that stat
  ## would therefore be keyed as current, while the environment in the script
  ## was built from the state before it -- and every later prompt would agree
  ## with it. Whatever cannot be told apart from that makes the caller emit a
  ## marker no prompt can match: the next prompt then falls through and
  ## activates again against settled files.
  ##
  ## THREE KINDS OF CHANGE, and each has its own test:
  ##
  ##   * an EDIT, to any file or link in the manifest: its mtime or ctime is
  ##     not safely earlier than ``startedAt``;
  ##   * a MEMBERSHIP change of a directory whose membership is keyed (a
  ##     ``d`` entry): an entry added to it, removed from it or renamed in it.
  ##     Each of those moves the directory's own mtime and ctime, on POSIX
  ##     filesystems and on NTFS alike, so a directory whose timestamps are
  ##     safely earlier than ``startedAt`` has the membership the edge listed
  ##     and is not even listed here. One that moved is listed, and its move
  ##     must be explained by the edge: one of its CURRENT entries changed
  ##     after the start and is an own change (see below), or the edge
  ##     created or removed an entry directly in it. Anything else is
  ##     reported -- a current entry changed after the start that the edge did
  ##     not make (an addition), and a move no current entry accounts for (a
  ##     removal, or an entry renamed away). The edge's own moves are why the
  ##     directory's timestamps alone cannot be the verdict: the first
  ##     activation of a project creates `<projectRoot>/.repro` while a
  ##     `useFlakeDevShell()` edge enumerates `<projectRoot>`, and
  ##     `nix print-dev-env` makes and removes a scratch directory beside
  ##     what it reads -- either made every first activation unmatchable when
  ##     the directory's timestamps were the test;
  ##   * a REMOVAL of a listed path: an entry that is missing now while the
  ##     nearest directory above it that still exists has an mtime or ctime
  ##     not safely earlier than ``startedAt``. Removing an entry moves the
  ##     timestamps of the directory that held it, and removing a whole
  ##     subtree moves those of the directory that held its top, so a path
  ##     removed after the edge observed it is caught; a path that was absent
  ##     all along (an absent probe, which the manifest lists too and which is
  ##     meant to be missing) sits below a directory nothing touched. That
  ##     directory is stat'ed THROUGH a symbolic link (`/tmp` and `/etc` are
  ##     links on macOS), because a link's own timestamps never move with its
  ##     target's membership.
  ##
  ##     Not "a path the edge READ that is now missing": the evidence does not
  ##     say whether a read found its file. Measured on a `useFlakeDevShell()`
  ##     edge on macOS, the read channel carried `PATH` lookups that found
  ##     nothing (`/opt/homebrew/bin/arch`, `./print-dev-env`) and a relative
  ##     scratch name resolved against the wrong directory, so that test made
  ##     every activation unmatchable.
  ##
  ## ``ownWrites`` and ``ownRemovals`` are the paths the edge itself wrote
  ## (or created) and removed, kept APART. They come from the edge's
  ## evidence; an edge that did not run (a cache hit) changed nothing, so the
  ## caller passes none, and every change after ``startedAt`` is then foreign
  ## by construction. Each side explains only its own kind of state. A
  ## PRESENT entry that changed is explained by being an own write, or a
  ## directory above any own change (an entry the edge created, or a
  ## directory it wrote into or removed from) -- never by being an own
  ## removal itself, so an entry the edge deleted and somebody else then
  ## created again is reported. Either kind explains the move of the
  ## directory directly holding it. An ABSENCE --
  ## a listed path missing now, or a name gone from an enumerated directory
  ## since the pre-edge listing -- is explained only by that exact path being
  ## an own REMOVAL: never by the edge having written elsewhere in the same
  ## directory (so a foreign removal beside the edge's own scratch is still
  ## reported), and never by the edge having WRITTEN that path (so an entry
  ## the edge relocked and somebody else then deleted is reported too).
  ##
  ## WHAT THE REMOVAL CHANNEL HOLDS, and why the absence rule converges. It
  ## is `PathSetEvidence.monitorRemovals`: io-mon's `unlink`, `unlinkat`,
  ## `rmdir` and `remove` records (`isRemovalMutation`), on Linux and macOS
  ## alike, so an edge's ordinary deletion of a watched entry is explained.
  ## A RENAME is not a removal there: io-mon records its destination as a
  ## write and its source as a read (Linux) or not at all (macOS), so an edge
  ## renaming a pre-existing watched entry away -- or deleting one through a
  ## call io-mon does not classify, which includes every deletion on Windows,
  ## where io-mon records `DeleteFileW` and a `MoveFileExW` source as writes
  ## -- leaves an absence nothing explains, and it is reported. That costs
  ## one extra activation, never a loop: the entry is gone by then, so the
  ## next activation either hits the cache
  ## (no own changes, and nothing moves after its start) or runs an edge
  ## that cannot remove the entry again, and the next pre-edge listing no
  ## longer holds its name. Either way its guard sees no absence. Reading a
  ## write as a removal instead would close that extra activation by
  ## missing a change, which no rule here may do.
  ##
  ## WHEN THE EDGE'S OWN CHANGES EXPLAIN A MOVE. Timestamps say THAT a
  ## directory's membership moved, not how often, so the edge having created
  ## or removed something in an enumerated directory cannot by itself rule
  ## out a foreign removal from the same directory. ``baseline`` decides
  ## that case: the directory's entry names listed BEFORE the edge ran
  ## (``snapshotPromptWatchBaseline``). Every name gone since must itself be
  ## an own removal, and every new one an own write or a directory above an
  ## own change; otherwise it is reported. A directory with no baseline
  ## listing is reported in that case, since nothing can verify it: one extra
  ## activation the first time, after which the listing exists.
  ##
  ## Every rule errs the same way -- an absent probe below a directory that
  ## changed for an unrelated reason, a foreign file created and removed
  ## again inside an enumerated directory, or an own rename-away as above,
  ## costs one extra activation, never a missed change.
  ##
  ## A probed directory (a ``p`` entry that is a directory) is keyed on its
  ## kind only, and nothing about it is tested here: its appearance or
  ## disappearance is a kind change, which no edit to its contents is.
  ##
  ## A manifest that cannot be read is reported as unsettled itself.
  var entries: seq[PromptWatchEntry]
  if manifestPath.len == 0 or
      readPromptWatchManifest(manifestPath, entries).len > 0:
    return @[manifestPath]
  # ``ownRemoved``: the own removals themselves, the only explanation of an
  # absence. ``own``: the only explanation of a PRESENT entry -- every own
  # write, and every directory above any own change (an entry the edge
  # created, or a directory it wrote into or removed from). An own removal
  # is not in it itself: the entry the edge removed being there now is
  # somebody else's re-creation. ``ownHolders``: the directories directly
  # holding an own change, whose membership moves the edge explains.
  # Invariant the early break below relies on: an entry in ``own`` has every
  # directory above it in ``own`` too.
  var own = initTable[string, bool]()
  var ownRemoved = initTable[string, bool]()
  var ownHolders = initTable[string, bool]()
  proc addOwnChange(path: string; written: bool) =
    var cursor = comparablePromptWatchPath(path)
    if written:
      own[cursor] = true
    else:
      ownRemoved[cursor] = true
    let holder = parentDir(cursor)
    if holder.len > 0 and holder != cursor:
      ownHolders[holder] = true
    while true:
      let parent = parentDir(cursor)
      if parent.len == 0 or parent == cursor or own.hasKey(parent):
        break
      own[parent] = true
      cursor = parent
  for path in ownWrites:
    addOwnChange(path, written = true)
  for path in ownRemovals:
    addOwnChange(path, written = false)

  proc nearestExistingAncestorChanged(path: string): bool =
    ## The REMOVAL test's directory: the closest one above ``path`` that
    ## exists now, stat'ed through a link. Reaching the top with nothing
    ## found is reported too: there is nothing left to say it was quiet.
    var cursor = path
    while true:
      let parent = parentDir(cursor)
      if parent.len == 0 or parent == cursor:
        return true
      try:
        let info = getFileInfo(fastPathFsPath(parent), followSymlink = true)
        return info.changedSince(startedAt)
      except OSError:
        cursor = parent

  for entry in entries:
    let comparable = comparablePromptWatchPath(entry.path)
    var info: FileInfo
    try:
      info = getFileInfo(fastPathFsPath(entry.path), followSymlink = false)
    except OSError:
      # Missing now. A REMOVAL when the directory that held it changed after
      # the start and the edge did not remove the entry itself -- writing it
      # is no explanation of its absence.
      if not ownRemoved.hasKey(comparable) and
          nearestExistingAncestorChanged(entry.path):
        result.add(entry.path)
      continue
    if info.kind != pcDir:
      if info.changedSince(startedAt):
        result.add(entry.path)
      continue
    if not entry.enumerated or not info.changedSince(startedAt):
      continue  # a probed directory, or a membership nothing has moved
    # The membership moved. Explained when the edge created or removed an
    # entry directly in it, or when a current entry that changed is its own
    # write (or a directory above an own change).
    var explained = ownHolders.hasKey(comparable)
    var foreign = false
    try:
      for child in walkDir(fastPathFsPath(entry.path), relative = true):
        let childPath = entry.path / child.path
        var childInfo: FileInfo
        try:
          childInfo = getFileInfo(fastPathFsPath(childPath),
            followSymlink = false)
        except OSError:
          continue  # gone again since the listing; the move still counts
        if not childInfo.changedSince(startedAt):
          continue
        if own.hasKey(comparablePromptWatchPath(childPath)):
          explained = true
        else:
          foreign = true  # an ADDITION the edge did not make
          break
    except OSError:
      foreign = true  # cannot be listed now: its membership is unknown
    if foreign or not explained:
      result.add(entry.path)
      continue
    # Explained by the edge's own changes, which says nothing about whether
    # SOMEBODY ELSE also removed an entry from the same directory meanwhile.
    # The pre-edge listing decides: every name that disappeared must itself
    # be an own removal (``ownRemoved``), and every name that appeared an own
    # write or a directory above an own change (``own``). Without a
    # listing (the first activation in this output directory, or a
    # directory the previous manifest did not track) that cannot be
    # verified, so the directory is reported: one extra activation, which
    # then has the listing.
    let comparableDir = comparable
    if not baseline.listings.hasKey(comparableDir):
      result.add(entry.path)
      continue
    var current: seq[string]
    if not directoryNames(entry.path, current):
      result.add(entry.path)
      continue
    let before = baseline.listings[comparableDir]
    var unexplained = false
    for name in before:
      if current.binarySearch(name) < 0 and
          not ownRemoved.hasKey(comparablePromptWatchPath(entry.path / name)):
        unexplained = true  # a REMOVAL the edge did not make
        break
    if not unexplained:
      for name in current:
        if before.binarySearch(name) < 0 and
            not own.hasKey(comparablePromptWatchPath(entry.path / name)):
          unexplained = true  # an addition that kept an old timestamp
          break
    if unexplained:
      result.add(entry.path)

proc computeDevEnvEdgeCacheKey*(projectRoot, activity, lockSliceId,
    developOverridesPath: string; watchManifestPath = ""): string =
  ## Deterministic prompt-time key for ``repro dev-env export`` no-op checks.
  ## This module intentionally avoids importing the build engine so the POSIX
  ## ``repro`` front controller can answer confirmed no-op prompts cheaply.
  ##
  ## ``watchManifestPath`` is the prompt watch manifest of the activation the
  ## key is compared against (``promptWatchManifestPathFor`` of
  ## `$__REPRO_ACTIVE_MANIFEST`), or ``""`` when there is none. The activation
  ## that EMITS a key passes the manifest it just wrote; every prompt passes
  ## the one its environment names. Both fast paths and the emitter call this
  ## one proc, so they cannot disagree about how the manifest is folded in.
  let projectFile = canonicalProjectFilePath(projectRoot)
  let projectFilePart =
    if projectFile.len == 0:
      projectRoot & "\n<no project file>"
    else:
      fileFingerprintPart(projectFile)
  let effectiveActivity =
    if activity.len > 0: activity else: "default"
  let resolvedOverridesPath =
    if developOverridesPath.len > 0:
      os.normalizedPath(absolutePath(developOverridesPath))
    else:
      developOverridesMetadataPath(projectRoot)
  let parts = @[
    CacheKeySchema,
    "projectRoot=" & projectRoot,
    "projectFile=" & projectFilePart,
    "activity=" & effectiveActivity,
    "lockSliceId=" & lockSliceId,
    "lockSliceFile=" & lockSliceFilePart(projectRoot),
    "developOverrides=" & fileFingerprintPart(resolvedOverridesPath),
    envVarPart("REPRO_DEVELOP_OVERRIDES_FILE"),
    envVarPart("REPRO_TOOL_PROVISIONING"),
    # WHERE the realized prefixes live, alongside WHICH provisioning mode
    # produced them. Both change the PATH an activation emits, so both have
    # to key it.
    #
    # Its absence was not theoretical. Pointing `REPRO_STORE_ROOT` at an
    # empty directory — the obvious way to rehearse a clean install without
    # a clean machine — appeared to do nothing at all: `resolveStoreRoot`
    # honoured the variable, but the activation never re-ran, so the
    # previous run's PATH entries were replayed and every tool still
    # resolved out of the default store. Nothing reported a conflict,
    # because from the key's point of view nothing had changed.
    envVarPart("REPRO_STORE_ROOT"),
    # WHICH reprobuild libs the recipe is compiled against. The interface
    # extraction and the provider compile both read these
    # (`reprobuildLibsRootFromEnv`), so an activation under one value is not
    # current under another, and a prompt that answered "no-op" across the
    # change would keep an environment built from the OTHER libs. (When this
    # key still gated interface reuse in `computeDevEnvEdge`, setting the
    # override replayed an interface naming stdlib modules the requested
    # checkout no longer has.)
    # Spelled out rather than imported: this module stays free of the
    # interface-artifact library so the prompt-time path stays cheap.
    envVarPart("REPROBUILD_LIBS_DIR"),
    envVarPart("REPROBUILD_REPO_ROOT"),
    # LAST, and the only part that is not a function of what the CLI can name
    # up front: the observed inputs of the activation being compared against.
    # See the prompt watch manifest section above.
    "promptWatch=" & promptWatchState(watchManifestPath)
  ]
  let digest = actionFingerprintDigest(parts.join("\n").textBytes())
  result = newStringOfCap(32)
  for i in 0 ..< 16:
    result.add(toHex(int(digest[i]), 2).toLowerAscii())

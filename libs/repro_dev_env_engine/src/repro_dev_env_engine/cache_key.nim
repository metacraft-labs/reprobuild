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

proc unsettledPromptWatchPaths*(manifestPath: string;
                                startedAt: float): seq[string] =
  ## The race guard. Paths in the manifest whose mtime or ctime is not
  ## safely earlier than ``startedAt`` (seconds since the epoch, taken
  ## BEFORE the activation's edge ran).
  ##
  ## WHY. The activation computes the key it emits from metadata it stats
  ## AFTER the edge has run, because only then does it know the observed set.
  ## An edit that lands between the edge reading a file and that stat would
  ## therefore be keyed as current, while the environment in the script was
  ## built from the content before it -- and every later prompt would agree
  ## with it. A path changed at or after the edge started is indistinguishable
  ## from that, so the caller must emit a marker no prompt can match: the next
  ## prompt then falls through and activates again against settled files.
  ##
  ## The comparison allows for the filesystem's timestamp resolution (see
  ## ``CoarseTimestampMarginSeconds`` / ``FineTimestampMarginSeconds``): it is
  ## the timestamp the filesystem RECORDED that is compared, and a coarse one
  ## can sit before the moment the write actually happened.
  ##
  ## DIRECTORIES ARE NOT CHECKED, and that is a measured trade, not an
  ## oversight. A probed directory is keyed on its kind only, so there is
  ## nothing to race. An enumerated one is keyed on its mtime, and the
  ## activation itself moves that: the first activation of a project creates
  ## `<projectRoot>/.repro` while the edge runs, and a `useFlakeDevShell()`
  ## edge enumerates `<projectRoot>`. Checked, that made every project's
  ## first activation unmatchable (one wasted re-activation, measured on the
  ## `t_e2e_shell_hook_prompt_key_sees_flake_inputs` fixture). Unchecked,
  ## the window left open is a file ADDED to an enumerated directory between
  ## the edge listing it and this stat; an edit to any file the edge read is
  ## still caught, because every such file is an entry of its own.
  ##
  ## A manifest that cannot be read is reported as unsettled itself.
  var entries: seq[PromptWatchEntry]
  if manifestPath.len == 0 or
      readPromptWatchManifest(manifestPath, entries).len > 0:
    return @[manifestPath]
  for entry in entries:
    var info: FileInfo
    try:
      info = getFileInfo(fastPathFsPath(entry.path), followSymlink = false)
    except OSError:
      continue
    if info.kind == pcDir:
      continue
    let coarse = info.lastWriteTime.nanosecond == 0 and
      info.creationTime.nanosecond == 0
    let margin =
      if coarse: CoarseTimestampMarginSeconds
      else: FineTimestampMarginSeconds
    let latest = max(timeSeconds(info.lastWriteTime),
      timeSeconds(info.creationTime))
    if latest >= startedAt - margin:
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

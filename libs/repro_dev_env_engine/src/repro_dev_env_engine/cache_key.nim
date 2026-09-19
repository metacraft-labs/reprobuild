import std/[os, strutils]

import blake3

const CacheKeySchema* = "reprobuild.dev-env.cache-key.v1"

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
    # would leave the previous decision's cached interface artifact in place,
    # and the shell would keep activating the environment the operator just
    # turned off. Spelled literally rather than imported for the same reason
    # the two project-file names above are: this module is the prompt-time
    # fast path and takes no dependency it does not have to.
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

proc computeDevEnvEdgeCacheKey*(projectRoot, activity, lockSliceId,
    developOverridesPath: string): string =
  ## Deterministic prompt-time key for ``repro dev-env export`` no-op checks.
  ## This module intentionally avoids importing the build engine so the POSIX
  ## ``repro`` front controller can answer confirmed no-op prompts cheaply.
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
    envVarPart("REPRO_STORE_ROOT")
  ]
  let digest = actionFingerprintDigest(parts.join("\n").textBytes())
  result = newStringOfCap(32)
  for i in 0 ..< 16:
    result.add(toHex(int(digest[i]), 2).toLowerAscii())

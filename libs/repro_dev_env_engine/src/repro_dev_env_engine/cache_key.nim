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
    ""

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

proc addU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc addU64Le(outp: var seq[byte]; value: uint64) =
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    outp.add(byte((value shr shift) and 0xff'u64))

proc addString(outp: var seq[byte]; value: string) =
  for ch in value:
    outp.add(byte(ord(ch)))

proc actionFingerprintDigest(payload: openArray[byte]): blake3.Blake3Digest =
  var framed = newSeqOfCap[byte](
    FrameMagic.len + 2 + ActionFingerprintDomainTag.len + 8 + payload.len)
  framed.addString(FrameMagic)
  framed.addU16Le(uint16(ActionFingerprintDomainTag.len))
  framed.addString(ActionFingerprintDomainTag)
  framed.addU64Le(uint64(payload.len))
  framed.add(payload)
  blake3.digest(framed)

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
    envVarPart("REPRO_TOOL_PROVISIONING")
  ]
  let digest = actionFingerprintDigest(parts.join("\n").textBytes())
  result = newStringOfCap(32)
  for i in 0 ..< 16:
    result.add(toHex(int(digest[i]), 2).toLowerAscii())

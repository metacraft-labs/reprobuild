import std/[os, strutils]

import repro_hash

const CacheKeySchema* = "reprobuild.dev-env.cache-key.v1"

const
  CanonicalProjectFileName = "repro.nim"
  LegacyProjectFileName = "reprobuild.nim"

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
  let parts = @[
    CacheKeySchema,
    "projectRoot=" & projectRoot,
    "projectFile=" & projectFilePart,
    "activity=" & effectiveActivity,
    "lockSliceId=" & lockSliceId,
    "lockSliceFile=" & lockSliceFilePart(projectRoot),
    "developOverrides=" & fileFingerprintPart(developOverridesPath),
    envVarPart("REPRO_DEVELOP_OVERRIDES_FILE")
  ]
  let digest = blake3DomainDigest(parts.join("\n").textBytes(),
    hdActionFingerprint)
  result = newStringOfCap(32)
  for i in 0 ..< 16:
    result.add(toHex(int(digest.bytes[i]), 2).toLowerAscii())

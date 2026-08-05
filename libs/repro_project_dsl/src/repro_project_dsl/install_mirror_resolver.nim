## Install-mirror path resolver shared by project DSL runtime and stdlib shims.
##
## The resolver lives in repro_project_dsl because BuildAction emission needs
## it while repro_dsl_stdlib already depends on the project DSL layer.

import std/[algorithm, os, strutils]

import blake3
# Only the pure path-arithmetic half of the local store. This module is in
# the import closure of every profile compile (via ``repro_project_dsl``),
# and a profile compile's ``--path`` set deliberately excludes the store
# runtime's SQLite binding and shm-index/shm-queue dependencies.
import repro_local_store/prefix_paths

const InstallMirrorModeEnvVar* = "REPRO_INSTALL_MIRROR_MODE"

const StoreRootEnvVar* = "REPRO_STORE_ROOT"
  ## Environment variable overriding the default CAS/Layer-2 store root.

const RealizationInfoFileName* = ".realization-info"
  ## Per-recipe sidecar written under
  ## ``<recipesRoot>/<depName>/.repro/output/.realization-info``.

type
  InstallMirrorMode* = enum
    immLegacy = "legacy"
    immHashed = "hashed"
    immHashedWithLegacyFallback = "hashed-with-legacy-fallback"

const LegacyInstallSubpath = ".repro/output/install"
const InstallMirrorPublishToolName* = "repro-install-mirror-publish"

proc currentInstallMirrorMode*(): InstallMirrorMode =
  case getEnv(InstallMirrorModeEnvVar).toLowerAscii()
  of "hashed":
    immHashed
  of "hashed-with-legacy-fallback":
    immHashedWithLegacyFallback
  else:
    immLegacy

proc legacyDepMirrorRoot(recipesRoot, depName: string): string =
  (recipesRoot / depName / LegacyInstallSubpath).replace("\\", "/")

proc resolveCasStoreRoot*(): string =
  let fromEnv = getEnv(StoreRootEnvVar)
  if fromEnv.len > 0:
    return fromEnv
  when defined(windows):
    let localAppData = getEnv("LOCALAPPDATA")
    if localAppData.len > 0:
      return localAppData & "/repro/store"
    return getHomeDir() & "AppData/Local/repro/store"
  elif defined(macosx):
    return getHomeDir() & "Library/Caches/repro/store"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    if xdg.len > 0:
      return xdg & "/repro/store"
    return getHomeDir() & ".cache/repro/store"

proc realizationInfoPath*(recipesRoot, depName: string): string =
  (recipesRoot / depName / ".repro" / "output" / RealizationInfoFileName)
    .replace("\\", "/")

proc toForwardSlash(value: string): string =
  result = value
  for i in 0 ..< result.len:
    if result[i] == '\\':
      result[i] = '/'

proc hexValue(ch: char): int =
  case ch
  of '0' .. '9': ord(ch) - ord('0')
  of 'a' .. 'f': ord(ch) - ord('a') + 10
  else: -1

proc parseRealizationHashHex*(value: string): PrefixIdBytes =
  if value.len != 64:
    raise newException(ValueError,
      "realization hash must be 64 lowercase hex chars")
  for i in 0 ..< 32:
    let hi = hexValue(value[i * 2])
    let lo = hexValue(value[i * 2 + 1])
    if hi < 0 or lo < 0:
      raise newException(ValueError,
        "realization hash must be 64 lowercase hex chars")
    result[i] = byte((hi shl 4) or lo)

proc isValidRealizationHashHex(value: string): bool =
  try:
    discard parseRealizationHashHex(value)
    true
  except ValueError:
    false

proc installMirrorStoreRelativePath*(depName, version,
                                     realizationHashHex: string): string =
  if depName.len == 0 or version.len == 0:
    return ""
  try:
    let prefixId = parseRealizationHashHex(realizationHashHex)
    prefixRelativePath(depName, version, prefixId).replace("\\", "/")
  except ValueError:
    ""

proc writeRealizationInfoFile*(recipesRoot, depName, version,
                               realizationHashHex: string;
                               storeRelativePath = "") =
  if recipesRoot.len == 0 or depName.len == 0:
    return
  if version.len == 0 or not isValidRealizationHashHex(realizationHashHex):
    return
  let canonicalRel = installMirrorStoreRelativePath(depName, version,
    realizationHashHex)
  let rel =
    if storeRelativePath.len > 0:
      storeRelativePath.replace("\\", "/")
    else:
      canonicalRel
  if rel.len == 0 or rel != canonicalRel:
    return
  let path = realizationInfoPath(recipesRoot, depName)
  let payload = "version=" & version & "\n" &
                "realization-hash=" & realizationHashHex & "\n" &
                "store-relative-path=" & rel & "\n"
  if fileExists(path):
    let existing = try:
      readFile(path)
    except CatchableError:
      ""
    if existing == payload:
      return
  createDir(parentDir(path))
  writeFile(path, payload)

type
  RealizationInfo* = object
    version*: string
    realizationHashHex*: string
    storeRelativePath*: string

proc readRealizationInfoFile*(recipesRoot, depName: string): RealizationInfo =
  if recipesRoot.len == 0 or depName.len == 0:
    return
  let path = realizationInfoPath(recipesRoot, depName)
  if not fileExists(path):
    return
  let raw = try:
    readFile(path)
  except CatchableError:
    ""
  if raw.len == 0:
    return
  for rawLine in raw.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    let eqIdx = line.find('=')
    if eqIdx < 1:
      continue
    let key = line[0 ..< eqIdx].strip()
    let value = line[eqIdx + 1 .. ^1].strip()
    if key == "version":
      result.version = value
    elif key == "realization-hash" and isValidRealizationHashHex(value):
      result.realizationHashHex = value
    elif key == "store-relative-path":
      result.storeRelativePath = value.replace("\\", "/")
  if result.version.len > 0 and result.realizationHashHex.len > 0:
    let canonicalRel = installMirrorStoreRelativePath(depName,
      result.version, result.realizationHashHex)
    if result.storeRelativePath.len == 0:
      result.storeRelativePath = canonicalRel
    elif result.storeRelativePath != canonicalRel:
      result.storeRelativePath = ""

proc hashedDepMirrorRoot*(recipesRoot, depName: string): string =
  if recipesRoot.len == 0 or depName.len == 0:
    return ""
  let info = readRealizationInfoFile(recipesRoot, depName)
  if info.version.len == 0 or info.realizationHashHex.len == 0 or
      info.storeRelativePath.len == 0:
    return ""
  let storeRoot = resolveCasStoreRoot().replace("\\", "/")
  storeRoot & "/" & info.storeRelativePath

proc packageInstallMirrorRoot*(recipesRoot, depName: string): string =
  if depName.len == 0 or recipesRoot.len == 0:
    return ""
  case currentInstallMirrorMode()
  of immLegacy:
    legacyDepMirrorRoot(recipesRoot, depName)
  of immHashed:
    let hashed = hashedDepMirrorRoot(recipesRoot, depName)
    if hashed.len > 0:
      hashed
    else:
      legacyDepMirrorRoot(recipesRoot, depName)
  of immHashedWithLegacyFallback:
    let hashed = hashedDepMirrorRoot(recipesRoot, depName)
    let legacy = legacyDepMirrorRoot(recipesRoot, depName)
    if hashed.len > 0 and dirExists(hashed):
      hashed
    else:
      legacy

proc packageInstallMirrorStagingRoot*(recipesRoot, depName: string): string =
  ## Mutable producer staging root for a package's own install mirror.
  ## Unlike ``packageInstallMirrorRoot`` this intentionally ignores the
  ## hashed resolver mode and any realization sidecar, so producer
  ## actions never write into immutable store prefixes.
  if depName.len == 0 or recipesRoot.len == 0:
    return ""
  legacyDepMirrorRoot(recipesRoot, depName)

proc packageInstallMirrorLibDirs*(recipesRoot, depName: string): seq[string] =
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0:
    return
  result.add(root & "/usr/lib")
  result.add(root & "/usr/lib64")

proc packageInstallMirrorPkgConfigDirs*(recipesRoot, depName: string):
    seq[string] =
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0:
    return
  result.add(root & "/usr/lib/pkgconfig")
  result.add(root & "/usr/lib64/pkgconfig")
  result.add(root & "/usr/share/pkgconfig")

proc packageInstallMirrorCmakeRoot*(recipesRoot, depName: string): string =
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0:
    return ""
  root & "/usr/lib/cmake"

proc packageInstallMirrorIncludeDir*(recipesRoot, depName: string): string =
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0:
    return ""
  root & "/usr/include"

proc packageInstallMirrorPropagatedManifestPath*(recipesRoot, depName,
    manifestFile: string): string =
  let root = packageInstallMirrorRoot(recipesRoot, depName)
  if root.len == 0:
    return ""
  root & "/" & manifestFile

proc packageInstallMirrorHumanFriendlyPath*(recipesRoot, depName: string):
    string =
  if depName.len == 0 or recipesRoot.len == 0:
    return ""
  legacyDepMirrorRoot(recipesRoot, depName)

proc shellDoubleQuote(value: string): string =
  "\"" & value.replace("\\", "/").replace("\"", "\\\"") & "\""

proc emitInstallMirrorStorePublish*(recipesRoot, depName, version,
                                    sourceDir: string): string =
  if recipesRoot.len == 0 or depName.len == 0 or version.len == 0 or
      sourceDir.len == 0:
    return ""
  let sidecarPath = realizationInfoPath(recipesRoot, depName)
  let sidecarParent = parentDir(sidecarPath)
  result.add("case \"${")
  result.add(InstallMirrorModeEnvVar)
  result.add(":-legacy}\" in hashed|hashed-with-legacy-fallback) ")
  result.add(InstallMirrorPublishToolName)
  result.add(" --recipes-root ")
  result.add(shellDoubleQuote(recipesRoot))
  result.add(" --package ")
  result.add(shellDoubleQuote(depName))
  result.add(" --version ")
  result.add(shellDoubleQuote(version))
  result.add(" --source ")
  result.add(shellDoubleQuote(sourceDir))
  result.add(" >/dev/null; ;; *) mkdir -p ")
  result.add(shellDoubleQuote(sidecarParent))
  result.add("; : > ")
  result.add(shellDoubleQuote(sidecarPath))
  result.add("; ;; esac; ")

proc emitInstallMirrorReadOnlyEnforcement*(mirrorRoot: string;
                                            mode = currentInstallMirrorMode()):
    string =
  if mode == immLegacy:
    return ""
  if mirrorRoot.len == 0:
    return ""
  let escapedRoot = mirrorRoot.replace("\"", "\\\"")
  result.add("if [ -d \"" & escapedRoot & "\" ]; then ")
  result.add("chmod -R a-w \"" & escapedRoot & "\"; ")
  result.add("fi; ")

proc installMirrorEnforcesReadOnly*(mode = currentInstallMirrorMode()): bool =
  mode != immLegacy

## Install-mirror path resolver shared by project DSL runtime and stdlib shims.
##
## The resolver lives in repro_project_dsl because BuildAction emission needs
## it while repro_dsl_stdlib already depends on the project DSL layer.

import std/[os, strutils]

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

proc writeRealizationInfoFile*(recipesRoot, depName, version,
                               realizationHashHex: string) =
  if recipesRoot.len == 0 or depName.len == 0:
    return
  if version.len == 0 or realizationHashHex.len != 64:
    return
  let path = realizationInfoPath(recipesRoot, depName)
  let payload = "version=" & version & "\n" &
                "realization-hash=" & realizationHashHex & "\n"
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
    elif key == "realization-hash" and value.len == 64:
      result.realizationHashHex = value

proc hashedDepMirrorRoot*(recipesRoot, depName: string): string =
  if recipesRoot.len == 0 or depName.len == 0:
    return ""
  let info = readRealizationInfoFile(recipesRoot, depName)
  if info.version.len == 0 or info.realizationHashHex.len == 0:
    return ""
  let storeRoot = resolveCasStoreRoot().replace("\\", "/")
  storeRoot & "/prefixes/" & depName & "/" &
    info.version & "-" & info.realizationHashHex

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

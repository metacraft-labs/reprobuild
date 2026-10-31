## Install-mirror path resolver shared by project DSL runtime and stdlib shims.
##
## The resolver lives in repro_project_dsl because BuildAction emission needs
## it while repro_dsl_stdlib already depends on the project DSL layer.

import std/[algorithm, os, strutils]

import blake3
import repro_platform
# Only the pure path-arithmetic half of the local store. This module is in
# the import closure of every profile compile (via ``repro_project_dsl``),
# and a profile compile's ``--path`` set deliberately excludes the store
# runtime's SQLite binding and shm-index/shm-queue dependencies.
import repro_local_store/prefix_paths
import repro_core/target_object_check

const TargetObjectExemptionSidecarKey* = "target-object-exemption"
  ## Sidecar key under which each declared object-check exemption is
  ## recorded, as ``<path>\t<reason>``. Readers that do not know it skip it.

proc exemptionSidecarLines*(raw: string): string =
  ## The sidecar lines recording the exemptions in ``raw`` (the
  ## ``TargetObjectExemptionsEnvVar`` value), each ``<key>=<path>\t<reason>``.
  for line in raw.split('\n'):
    if line.len > 0:
      result.add(TargetObjectExemptionSidecarKey & "=" & line & "\n")


const InstallMirrorModeEnvVar* = "REPRO_INSTALL_MIRROR_MODE"

const StoreRootEnvVar* = "REPRO_STORE_ROOT"
  ## Environment variable overriding the default CAS/Layer-2 store root.

const RealizationInfoFileName* = ".realization-info"
  ## Per-recipe sidecar written under
  ## ``<recipesRoot>/<depName>/.repro/output/.realization-info`` (with
  ## ``@<triple>`` appended under ``--target``; ``targetKeyedOutputName``).

type
  InstallMirrorMode* = enum
    immLegacy = "legacy"
    immHashed = "hashed"
    immHashedWithLegacyFallback = "hashed-with-legacy-fallback"

const LegacyInstallSubpath = ".repro/output/install"
  ## The producer staging root and legacy consumer root of a NATIVE build.
  ## A cross build's is this plus ``@<triple>`` (``installMirrorSubpath``).

const InstallMirrorTargetSeparator* = "@"

proc activeTargetTripleTag*(): string =
  ## The triple the build compiles FOR, or "" for a native build: the
  ## ``targetTriple`` assignment of ``REPRO_VARIANTS``, the env
  ## ``repro build --target=<triple>`` (and ``--variant``) writes for the
  ## provider hop. ``native`` is "" too.
  ##
  ## ReproOS-Add-On-Mode A15. This module sits below the stdlib, so it reads
  ## the assignment itself rather than ask ``toolchain_policy``; the two read
  ## one env entry with one spelling, and the stdlib's solver-assigned value
  ## can only ever agree with it (the solver consumed the same contribution
  ## at ``prSet``). Read here and in ``toolchain_policy`` only.
  for assignment in getEnv("REPRO_VARIANTS").split(','):
    let kv = assignment.split('=', 1)
    if kv.len == 2 and kv[0].strip() == "targetTriple":
      let value = kv[1].strip()
      # A triple naming the build host itself is a native build
      # (CLI/build.md §"Cross Targets: `--target`").
      if value.len > 0 and value.toLowerAscii() != "native" and
          not isHostTriple(value):
        return value
      return ""
  ""

var installMirrorTargetOverride {.threadvar.}: tuple[active: bool,
                                                        triple: string]
  ## ``withInstallMirrorTarget``'s state: while active, the mirror is keyed
  ## by ``triple`` ("" = native) instead of the build's target.

proc installMirrorSubpathFor*(triple: string): string =
  ## The install mirror subpath of a build for ``triple``; "" is native.
  if triple.len == 0: LegacyInstallSubpath
  else: LegacyInstallSubpath & InstallMirrorTargetSeparator & triple

proc effectiveInstallMirrorTarget*(): string =
  ## The triple the mirror is keyed by right now: an override in effect,
  ## else the build's target.
  if installMirrorTargetOverride.active: installMirrorTargetOverride.triple
  else: activeTargetTripleTag()

proc targetKeyedOutputName*(name: string): string =
  ## ``name`` for a native build, ``name@<triple>`` under ``--target``: the
  ## spelling of every entry of a recipe's ``.repro/output/`` that one build
  ## writes (the install mirror, the per-artifact staging directories, the
  ## realization sidecar), so a native and a target build of one recipe
  ## never read or overwrite each other's.
  let triple = effectiveInstallMirrorTarget()
  if triple.len == 0: name
  else: name & InstallMirrorTargetSeparator & triple

proc outputEntryTarget*(entryName: string): tuple[name, triple: string] =
  ## Split a ``.repro/output/`` entry name into the base name and the
  ## triple it was written for ("" = native); the inverse of
  ## ``targetKeyedOutputName``.
  let at = entryName.find(InstallMirrorTargetSeparator)
  if at < 0: (entryName, "")
  else: (entryName[0 ..< at],
         entryName[at + InstallMirrorTargetSeparator.len .. ^1])

template withInstallMirrorTarget*(targetTriple: string; body: untyped) =
  ## Run ``body`` with the install mirror keyed by ``targetTriple``
  ## ("" = native) whatever the build's target. The host/target split at
  ## the mirror: a ``nativeBuildDeps:`` entry runs on the build host, so a
  ## consumer resolving one under ``--target`` reads the sibling's NATIVE
  ## mirror, while its ``buildDeps:`` / ``runtimeDeps:`` read the target's.
  let saved = installMirrorTargetOverride
  installMirrorTargetOverride.active = true
  installMirrorTargetOverride.triple = targetTriple
  try:
    body
  finally:
    installMirrorTargetOverride = saved

proc installMirrorSubpath*(): string =
  ## Where a recipe's install mirror lives under the recipe directory:
  ## ``.repro/output/install`` for a native build and
  ## ``.repro/output/install@<triple>`` under ``repro build --target``
  ## (From-Source-Build-Recipes.md §"Package-level dependency
  ## declarations", "The install mirror is keyed by the target"). One rule
  ## for the producer's staging root, the consumer's resolver and the
  ## tool-profile side's sibling probes, so a host build and a target build
  ## of one recipe coexist and a ``buildDeps:`` of a cross build resolves to
  ## the target build of the same recipe -- the thing a target-suffixed
  ## package name used to stand in for.
  installMirrorSubpathFor(effectiveInstallMirrorTarget())
const InstallMirrorPublishToolName* = "repro-install-mirror-publish"
const InstallMirrorCoreToolNames* = ["sh", "rm", "mkdir", "cp", "touch"]
  ## External commands emitted by every install-mirror shell action. Keep
  ## these explicit so sealed action profiles never depend on ambient PATH or
  ## on an unrelated dependency happening to provide a core utility.

proc typedInstallMirrorShellTools*(packageName: string): seq[string] =
  ## Keep interface requirements and generated action refs in agreement.
  result = @InstallMirrorCoreToolNames & @["sed", "chmod"]
  when defined(linux):
    result.add(["find", "head", "od", "tr", "sort", "grep",
      "dirname", "basename", "wc", "patchelf", "readlink", "mktemp", "mv", "readelf"])
    if packageName == "glibcSource":
      result.add("ln")

proc currentInstallMirrorMode*(): InstallMirrorMode =
  case getEnv(InstallMirrorModeEnvVar).toLowerAscii()
  of "hashed":
    immHashed
  of "hashed-with-legacy-fallback":
    immHashedWithLegacyFallback
  else:
    immLegacy

proc legacyDepMirrorRoot(recipesRoot, depName: string): string =
  (recipesRoot / depName / installMirrorSubpath()).replace("\\", "/")

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
  (recipesRoot / depName / ".repro" / "output" /
    targetKeyedOutputName(RealizationInfoFileName)).replace("\\", "/")

proc currentRealizationPlatformTag*(): string =
  ## Stable producer identity for mutable source-package mirrors. This is the
  ## machine that produced the realization, not a package-manager namespace.
  let host = currentHost()
  result = host.os.toLowerAscii() & "-" & host.cpu.toLowerAscii()
  # A target build's realization is not the host's: the sidecar of a cross
  # build names the target, so a hashed-store lookup made for the host
  # never follows a cross build's sidecar and vice versa.
  let triple = effectiveInstallMirrorTarget()
  if triple.len > 0:
    result.add(InstallMirrorTargetSeparator & triple)

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
  let payload = "platform=" & currentRealizationPlatformTag() & "\n" &
                "version=" & version & "\n" &
                "realization-hash=" & realizationHashHex & "\n" &
                "store-relative-path=" & rel & "\n" &
                exemptionSidecarLines(getEnv(TargetObjectExemptionsEnvVar))
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
    platformTag*: string
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
    if key == "platform":
      result.platformTag = value.toLowerAscii()
    elif key == "version":
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
  if info.platformTag != currentRealizationPlatformTag() or
      info.version.len == 0 or info.realizationHashHex.len == 0 or
      info.storeRelativePath.len == 0:
    return ""
  let storeRoot = resolveCasStoreRoot().replace("\\", "/")
  storeRoot & "/" & info.storeRelativePath

proc realizationInfoMatchesCurrentPlatform*(recipeDir: string): bool =
  ## A missing sidecar is the pre-install compatibility case used by staged
  ## artifacts of a NATIVE build. Once a producer writes the sidecar, it must
  ## identify this process's OS and CPU; empty legacy sidecars are
  ## deliberately stale. Under ``--target`` a missing keyed sidecar is never
  ## a match: the sidecar is written only after the staged tree passed the
  ## object check, so a target mirror without one -- left by a build before
  ## that check existed, or by a refused one -- is a sibling that needs a
  ## build (CLI/build.md §"Cross Targets: `--target`").
  let path = recipeDir / ".repro" / "output" /
    targetKeyedOutputName(RealizationInfoFileName)
  if not fileExists(path):
    return effectiveInstallMirrorTarget().len == 0
  let info = readRealizationInfoFile(parentDir(recipeDir),
    extractFilename(recipeDir))
  info.platformTag == currentRealizationPlatformTag()

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

proc emitInstallMirrorTargetCheck*(sourceDir: string): string =
  ## Under ``--target``: the shell fragment that runs the object check over
  ## the staged mirror ``sourceDir`` and, on a mismatch, removes the mirror
  ## and fails the action, so nothing is mirrored and no sidecar is written
  ## (CLI/build.md §"Cross Targets: `--target`", the object check). Empty
  ## for a native build.
  let triple = effectiveInstallMirrorTarget()
  if triple.len == 0 or sourceDir.len == 0:
    return ""
  let dir = shellDoubleQuote(sourceDir)
  result.add(InstallMirrorPublishToolName)
  result.add(" --check-target ")
  result.add(shellDoubleQuote(triple))
  result.add(" --source ")
  result.add(dir)
  result.add(" || { rm -rf ")
  result.add(dir)
  result.add("; exit 1; }; ")

proc emitInstallMirrorStorePublish*(recipesRoot, depName, version,
                                    sourceDir: string): string =
  result = emitInstallMirrorTargetCheck(sourceDir)
  if recipesRoot.len == 0 or depName.len == 0 or version.len == 0 or
      sourceDir.len == 0:
    return
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
  result.add("; printf '%s\\n' 'platform=")
  result.add(currentRealizationPlatformTag())
  result.add("' > ")
  result.add(shellDoubleQuote(sidecarPath))
  # The declared object-check exemptions, one line each, from the action's
  # environment (CLI/build.md: they are recorded beside the mirror).
  result.add("; printf '%s\\n' \"${")
  result.add(TargetObjectExemptionsEnvVar)
  # `if`, not `[ … ] &&`: the loop's status is its last command's, and a
  # failed test on the final (empty) line would fail the whole action.
  result.add(":-}\" | while IFS= read -r l; do if [ -n \"$l\" ]; then ")
  result.add("printf '")
  result.add(TargetObjectExemptionSidecarKey)
  result.add("=%s\\n' \"$l\"; fi; done >> ")
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

proc emitInstallMirrorClearPrevious*(mirrorRoot: string;
                                     mode = currentInstallMirrorMode()):
    string =
  ## The shell snippet that removes the mirror a previous hashed-mode build
  ## left read-only (`emitInstallMirrorReadOnlyEnforcement`), so a rebuild of
  ## the same recipe can lay out a new one.
  ##
  ## The whole previous mirror goes, not just its `usr/`: the mirror action
  ## also rewrites files at its root (the stamp, the propagated-libdirs
  ## manifest), and a read-only file cannot be rewritten. Removing a
  ## directory entry needs write permission on the DIRECTORY, not on the
  ## file, so this restores `u+w` on the mirror's directories only, never on
  ## its files: the store may realize the published prefix by hardlinking
  ## the mirror's files, and a file's mode belongs to the shared inode, so
  ## making a mirror file writable would make the store prefix's file
  ## writable too. Symlinked directories are not followed.
  ##
  ## Only `chmod`, `rm` and shell builtins, which the mirror action already
  ## declares; empty in legacy mode, where the mirror is never made
  ## read-only and the legacy action stays byte-for-byte as it was.
  if mode == immLegacy or mirrorRoot.len == 0:
    return ""
  let escapedRoot = mirrorRoot.replace("\\", "/").replace("\"", "\\\"")
  result.add("_repro_unlock_dirs() { chmod u+w \"$1\"; ")
  result.add("for _e in \"$1\"/* \"$1\"/.[!.]* \"$1\"/..?*; do ")
  result.add("if [ -d \"$_e\" ] && [ ! -L \"$_e\" ]; then ")
  result.add("_repro_unlock_dirs \"$_e\"; fi; done; }; ")
  result.add("if [ -d \"" & escapedRoot & "\" ]; then ")
  result.add("_repro_unlock_dirs \"" & escapedRoot & "\"; ")
  result.add("rm -rf \"" & escapedRoot & "\"; fi; ")

proc installMirrorEnforcesReadOnly*(mode = currentInstallMirrorMode()): bool =
  mode != immLegacy

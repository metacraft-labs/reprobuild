## Phase B: stow-style dotfile materialization (see
## [Home-Profile-Intent-Layer.md] "Stow-Style Dotfile Support").
##
## Two responsibilities:
##
##   1. **Discovery**: walk `<profile-dir>/stow/` following the GNU
##      `stow` *package* convention and synthesize one
##      `PlannedGeneratedFile` per regular file, with
##      `sourceKind = pgfsStowFile` and `stowSourcePath` set. The
##      planner appends these to its `generatedFiles` list before
##      handing the plan to the suppression layer.
##   2. **Materialization**: per file, try the link decision tree
##      (symlink → junction → copy). The chosen mode is recorded as
##      `stow-symlink`, `stow-junction`, or `stow-copy` on the
##      manifest record.
##
## M73 — GNU `stow` package layout:
##   Each immediate SUBDIRECTORY of `<profile-dir>/stow/` is a GNU
##   `stow` *package*. A file at `stow/<package>/<rel>` materializes
##   at `$HOME/<rel>` — the `<package>` segment is STRIPPED and the
##   within-package relative path (`<rel>`, including any nested
##   directories and dotfile names) is preserved verbatim. For
##   example `stow/git/.gitconfig` -> `$HOME/.gitconfig` and
##   `stow/vim/.config/nvim/init.lua` -> `$HOME/.config/nvim/init.lua`.
##   A file located DIRECTLY under `stow/` (not inside any package
##   directory) is not valid GNU `stow` layout: it is reported as a
##   loose file via the `IStowLooseFile` informational diagnostic and
##   NOT materialized. There is no flat-mapping fallback — the
##   immediate subdirectories of `stow/` are packages, period.
##
## The decision tree is observable through two test hooks:
##
##   * `REPRO_TEST_STOW_DISABLE_SYMLINK=1` — every symlink attempt
##     fails as if `SeCreateSymbolicLinkPrivilege` were missing.
##   * `REPRO_TEST_STOW_DISABLE_JUNCTION=1` — every junction attempt
##     fails. Combined with the symlink env var this forces the
##     copy fallback.
##
## These hooks exist so the gates can drive each branch without
## requiring administrator privileges (or the lack thereof) on the
## CI host.
##
## M72 Deliverable 3 — non-destructive materialization:
##   The materializer NEVER blindly `removeFile`s a pre-existing
##   target. Cases:
##     * target absent              → create the link.
##     * target is ALREADY the correct symlink/junction to the stow
##       source → no-op CACHE-HIT (the link is not deleted+recreated).
##     * target is a regular file, OR a link to a DIFFERENT source,
##       whose content is BYTE-IDENTICAL to the stow source → no-op
##       CACHE-HIT (M76): the target is left exactly as is — not
##       deleted, not recreated. This was never a real conflict.
##     * target is a regular file, OR a link to a DIFFERENT source,
##       whose content GENUINELY DIFFERS from the stow source →
##       CONFLICT: the target is left byte-identical and
##       `EStowConflict` is raised, unless the caller passes a
##       reconcile-drift policy (then the prior content is recorded
##       and the target is replaced).
##   The copy fallback obeys the same rule: a pre-existing differing
##   file is never overwritten without the drift gate.
##
## M76 — plan/apply consistency:
##   `stowTargetMatchesSource` is the SINGLE byte-identical predicate.
##   `tryCreateSymlink`, the copy fallback, AND the apply planner's
##   `previewStowItem` all consult it, so a plan that previews a
##   cache-hit never fails at apply with `EStowConflict`. The
##   comparison is raw bytes via `readFile` (which follows links, so a
##   wrong-link target's *resolved* content is what is compared).

import std/[algorithm, os, sets, strutils, tables]
from repro_core/paths import extendedPath
import repro_core/link_target

import blake3
import repro_home_generations

import repro_home_resources/test_home_fence
import ./errors
import ./plan
import repro_home_intent

const
  DisableSymlinkEnvVar* = "REPRO_TEST_STOW_DISABLE_SYMLINK"
  DisableJunctionEnvVar* = "REPRO_TEST_STOW_DISABLE_JUNCTION"
  StowSubdirName* = "stow"

type
  StowMaterializationMode* = enum
    smSymlink
    smJunction
    smCopy

  StowReconcilePolicy* = enum
    ## M72 Deliverable 3: how the materializer treats a pre-existing
    ## target that conflicts with the desired stow link.
    srpFailClosed                     ## conflict → raise EStowConflict
    srpReconcileDrift                  ## conflict → record prior, replace

  StowEntry* = object
    ## One stow file the discovery pass surfaced.
    sourceAbsolutePath*: string
    homeRelativePath*: string
    targetAbsolutePath*: string       ## $HOME/<rel>
    package*: string
      ## GM11: the `stow/` package the file belongs to (the immediate
      ## subdirectory of `stow/` it sits in); `selectStowEntries` keeps or
      ## drops it by this name.

  AppliedStowRecord* = object
    sourceAbsolutePath*: string
    homeRelativePath*: string
    targetAbsolutePath*: string
    mode*: StowMaterializationMode
    postWriteDigest*: Digest256       ## blake3 of the source content
    hasPreWriteDigest*: bool
    preWriteDigest*: Digest256
    wasCacheHit*: bool
      ## M72: true when the target already existed as the correct
      ## symlink/junction to the stow source — materialized as a
      ## no-op (the existing link was NOT deleted and recreated).
    wasReconciled*: bool
      ## M72: true when a conflicting target was replaced under a
      ## reconcile-drift policy. `preWriteDigest` then carries the
      ## prior content digest so rollback can restore it.

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

type
  StowDiscovery* = object
    ## Result of a GNU `stow` package-layout discovery walk.
    entries*: seq[StowEntry]
      ## One per regular file inside a package directory. The
      ## `homeRelativePath` / `targetAbsolutePath` have the package
      ## level stripped.
    looseFiles*: seq[string]
      ## Files found DIRECTLY under `stow/` (not inside any package
      ## directory). These are NOT valid GNU `stow` layout — the
      ## caller emits an `IStowLooseFile` diagnostic per entry and
      ## materializes none of them. Paths are relative to `stow/`.
    packages*: seq[string]
      ## GM11: every package directory found (immediate subdirectories of
      ## `stow/`), sorted, empty ones included -- what an activity's
      ## `stow:` claim may name.

proc discoverStowEntries*(profileDir, homeDir: string): StowDiscovery =
  ## Walk `<profile-dir>/stow/` following the GNU `stow` package
  ## convention. Each immediate subdirectory of `stow/` is a package;
  ## a file at `stow/<package>/<rel>` produces a `StowEntry` whose
  ## target is `$HOME/<rel>` — the `<package>` level stripped. A file
  ## directly under `stow/` is not valid GNU `stow` layout and is
  ## returned in `looseFiles` for the caller to diagnose; it is never
  ## materialized. An empty package directory contributes nothing.
  ##
  ## The result depends only on the tree's contents, never on the order
  ## the filesystem enumerates it (reprobuild-pm issue
  ## 2026-10-13-stow-discovery-order-follows-directory-enumeration):
  ## `looseFiles` and `packages` are sorted, and `entries` are ordered by
  ## package name, then by within-package path (`/`-separated), both
  ## compared bytewise. Everything downstream -- the `[stow]` section of
  ## `repro home apply --plan`, the host facts, the order files are
  ## materialized in -- inherits that order.
  let stowRoot = profileDir / StowSubdirName
  if not dirExists(extendedPath(stowRoot)):
    return StowDiscovery()
  # Loose files: regular files sitting directly under `stow/`.
  for kind, path in walkDir(extendedPath(stowRoot), relative = true):
    if kind in {pcFile, pcLinkToFile}:
      result.looseFiles.add path.replace('\\', '/')
  result.looseFiles.sort(system.cmp[string])
  # Packages: each immediate subdirectory of `stow/`. The package
  # name is the directory name; it is STRIPPED on materialization.
  var packageDirs: seq[tuple[name, native: string]]
  for kind, pkgPath in walkDir(extendedPath(stowRoot), relative = true):
    if kind in {pcDir, pcLinkToDir}:
      packageDirs.add((name: pkgPath.replace('\\', '/'), native: pkgPath))
  packageDirs.sort(proc (a, b: tuple[name, native: string]): int =
    system.cmp(a.name, b.name))
  for (pkgName, pkgPath) in packageDirs:
    let packageDir = stowRoot / pkgPath
    result.packages.add pkgName
    # `filePath` is the within-package relative path — the path that maps
    # verbatim under `$HOME` with the package stripped. Kept native for the
    # joins, sorted by its `/` spelling so every platform orders alike.
    var files: seq[tuple[rel, native: string]]
    for filePath in walkDirRec(extendedPath(packageDir),
        yieldFilter = {pcFile, pcLinkToFile}, relative = true):
      files.add((rel: filePath.replace('\\', '/'), native: filePath))
    files.sort(proc (a, b: tuple[rel, native: string]): int =
      system.cmp(a.rel, b.rel))
    for (withinPackage, filePath) in files:
      var entry: StowEntry
      entry.sourceAbsolutePath = packageDir / filePath
      entry.homeRelativePath = withinPackage
      entry.targetAbsolutePath = homeDir / filePath
      entry.package = pkgName
      result.entries.add entry

proc refuseStowPackagesOnOnePath*(entries: seq[StowEntry]) =
  ## Two stow packages that map a file to one `$HOME` path cannot both be
  ## materialized there: a link names one source, so even identical files
  ## would leave the path to whichever package was linked last. Raises
  ## `EApplyPlanFailed` naming every such path and its packages, before
  ## anything is written (reprobuild-pm issue
  ## 2026-10-18-two-stow-packages-on-one-home-path-are-not-refused;
  ## Home-Profile-Intent-Layer.md §Stow-Style Dotfile Support, Discovery).
  ## `entries` is what the host gets (`selectStowEntries`), so packages no
  ## host gets together are not a pair. Paths compare exactly.
  var byPath = initOrderedTable[string, seq[string]]()
  for e in entries:
    byPath.mgetOrPut(e.homeRelativePath, @[]).add e.package
  var clashes: seq[string]
  for rel, packages in byPath:
    if packages.len > 1:
      clashes.add "`~/" & rel & "` (packages " & packages.join(", ") & ")"
  if clashes.len > 0:
    raisePlanFailed("two stow packages map a file to the same $HOME " &
      "path, and a path has one writer; keep the file in one package " &
      "only: " & clashes.join("; "))

proc selectStowEntries*(discovery: StowDiscovery; profile: Profile;
                        ctx: HostContext): StowDiscovery =
  ## GM11: the stow entries the host `ctx` gets (Home-Profile-Intent-Layer.md
  ## §Stow-Style Dotfile Support, "Packages that belong to an activity";
  ## `repro_profile/stow_scopes`). A package no activity claims is kept on
  ## every host. A claimed package is kept only when one of its claims
  ## holds: the host's selection -- `enabledActivitiesFor`, the one rule
  ## packages and resources use -- enables the claim's activity, and the
  ## claim's guard holds for `ctx`.
  ##
  ## A claim naming a package the tree does not have is refused
  ## (`EApplyIntentLoad`, naming the package and the packages that exist):
  ## a typo would otherwise leave the package it meant on every host.
  ##
  ## A profile without claims keeps everything and never computes the
  ## selection, so it plans exactly as before (an undeclared host included).
  result = discovery
  if profile.isNil or profile.stowScopes.len == 0:
    return
  var present = initHashSet[string]()
  for p in discovery.packages:
    present.incl p
  var claimed = initHashSet[string]()
  for s in profile.stowScopes:
    if s.package notin present:
      raiseIntentLoad(profile.path, "activity `" & s.activity &
        "` claims stow package `" & s.package & "`, but the profile's " &
        "stow/ tree has no such package directory (packages: " &
        (if discovery.packages.len == 0: "none"
         else: discovery.packages.join(", ")) & ")")
    claimed.incl s.package
  let activities = enabledActivitiesFor(profile, ctx.host)
  var enabled = initHashSet[string]()
  for s in profile.stowScopes:
    if s.activity in activities and evaluateHostPredicate(s.guardAst, ctx):
      enabled.incl s.package
  result.entries = @[]
  for e in discovery.entries:
    if e.package notin claimed or e.package in enabled:
      result.entries.add e

proc stowEntriesToPlanned*(entries: seq[StowEntry]): seq[PlannedGeneratedFile] =
  for e in entries:
    var content: seq[byte]
    if fileExists(extendedPath(e.sourceAbsolutePath)):
      let raw = readFile(extendedPath(e.sourceAbsolutePath))
      content = newSeq[byte](raw.len)
      for i, ch in raw:
        content[i] = byte(ord(ch))
    result.add(PlannedGeneratedFile(
      absoluteOutputPath: e.targetAbsolutePath,
      relativeHomePath: e.homeRelativePath,
      sourceKind: pgfsStowFile,
      contributingPackage: "",
      stowSourcePath: e.sourceAbsolutePath,
      contentBytes: content))

# ---------------------------------------------------------------------------
# Materialization
# ---------------------------------------------------------------------------

proc digestBytes(content: openArray[byte]): Digest256 =
  let raw = blake3.digest(content)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc readPreWriteDigest(dst: string): tuple[has: bool; digest: Digest256] =
  if not fileExists(extendedPath(dst)):
    return (false, default(Digest256))
  let raw = readFile(extendedPath(dst))
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  (true, digestBytes(buf))

# ---------------------------------------------------------------------------
# M72 Deliverable 3: non-destructive target inspection
# ---------------------------------------------------------------------------

type
  TargetState = enum
    tsAbsent                          ## nothing at the target path
    tsCorrectLink                     ## already the right symlink/junction
    tsWrongLink                       ## a link, but to a different source
    tsRegularFile                     ## a plain file (or dir) — conflict

  TargetInspection = object
    state: TargetState
    existingKind: string              ## human label for the diagnostic
    existingTarget: string            ## resolved link target, if a link

proc readLinkTargetBestEffort*(linkPath: string): string =
  ## Where the link at `linkPath` points, absolute (a relative target is
  ## joined to the link's directory), or "" when it cannot be read. Read
  ## from the link itself and never followed (`repro_core/link_target`),
  ## so a dangling link and an untraversable one still answer. Never the
  ## link's own path: `os.expandSymlink` returns its argument on Windows,
  ## which printed every drift row's link as its own "different source"
  ## (reprobuild-pm issue
  ## 2026-10-26-windows-stow-drift-names-the-link-itself-as-its-different-source).
  try:
    result = resolvedSymlinkTarget(linkPath)
  except OSError, IOError:
    result = ""

proc linkTextNames(linkPath, path: string): bool =
  ## Whether the link at `linkPath`, read without following it, names
  ## `path`.
  ##
  ## On Windows the text is resolved against the link's directory and
  ## compared as a path (`cmpPaths`: case-insensitive) after
  ## `normalizedPath` folds separators, `.` and `..`: Win32 path
  ## normalization is lexical, which is how a relative reparse target is
  ## resolved there.
  ##
  ## On POSIX the raw `readlink` text must equal `path` exactly. The kernel
  ## resolves `..` PHYSICALLY — after following the link's parent if that
  ## is itself a symlink — so a lexical join could name `path` while the
  ## link really leads elsewhere, and this predicate decides ownership.
  if path.len == 0:
    return false
  when defined(windows):
    let text = readLinkTargetBestEffort(linkPath)
    text.len > 0 and cmpPaths(normalizedPath(text), normalizedPath(path)) == 0
  else:
    var text = ""
    try: text = readSymlinkTarget(linkPath)
    except OSError, IOError: return false
    text == path

proc linkPointsAtSource*(linkPath, desiredSource: string): bool =
  ## Decide whether the link at `linkPath` resolves to the SAME file
  ## as `desiredSource`. Uses `os.sameFile` (file-identity comparison
  ## by volume serial + file index on Windows, inode on POSIX) — a
  ## symlink resolves to its target's identity, so this is true iff
  ## the link points at the stow source, however the link spells it (a
  ## relative target, a parent junction, a case variant).
  ##
  ## On Windows only, when `sameFile` cannot follow the link at all —
  ## Windows refuses to traverse some links over an SSH logon ("untrusted
  ## mount point") — the link's own text is the evidence left: a link
  ## whose target names `desiredSource` (an existing file) is a link to it
  ## (`linkTextNames`). Only a positive answer is taken from the text; a
  ## text that names something else stays "not the same". On POSIX a link
  ## the kernel cannot follow is not a correct link, whatever it says.
  try:
    if not fileExists(extendedPath(desiredSource)):
      return false
  except OSError, IOError:
    return false
  try:
    # `sameFile` follows the link on both arguments. If `linkPath`'s
    # target was deleted it will raise; fall through to the link text.
    return sameFile(linkPath, desiredSource)
  except OSError, IOError:
    discard
  when defined(windows):
    linkTextNames(linkPath, desiredSource)
  else:
    false

proc isRecordedStowTarget*(target, desiredSource: string;
                           rec: GeneratedFile): bool =
  ## True when `target` still holds exactly the stow file the CURRENT
  ## generation recorded materializing there (`rec`, its `generatedFiles`
  ## record for the path) from a source other than `desiredSource`: a link
  ## to the recorded `stowSource` (`stow-symlink`; by file identity, or by
  ## the link text when the recorded source has moved away and the link
  ## dangles), or a regular file whose bytes are the recorded post-write
  ## digest (`stow-copy`). Such a target is Reprobuild's own, unchanged
  ## since it was written -- not drift -- so the apply replaces it with the
  ## new link without `--reconcile-drift` (a stow file moved to another
  ## package, or a path a host's activity selection hands from one package
  ## to another; reprobuild-pm issue
  ## 2026-10-19-home-apply-refuses-a-stow-file-moved-to-another-package).
  ## Anything else at the path stays drift. Read-only; junctions are not
  ## considered (their identity is the directory, not the file).
  if rec.stowSource.len == 0 or rec.stowSource == desiredSource:
    return false
  try:
    case rec.ownershipPolicy
    of gfoStowSymlink:
      if not symlinkExists(extendedPath(target)):
        return false
      return linkPointsAtSource(target, rec.stowSource) or
        linkTextNames(target, rec.stowSource)
    of gfoStowCopy:
      if symlinkExists(extendedPath(target)) or
          not fileExists(extendedPath(target)):
        return false
      let raw = readFile(extendedPath(target))
      var buf = newSeq[byte](raw.len)
      for i, ch in raw:
        buf[i] = byte(ord(ch))
      return digestBytes(buf) == rec.postWriteDigest
    else:
      return false
  except OSError, IOError:
    return false

proc releaseRecordedStowTarget*(target, desiredSource: string;
                                rec: GeneratedFile): bool =
  ## Remove `target` when `isRecordedStowTarget` holds, so the materializer
  ## links the new source there; returns whether it did.
  if not isRecordedStowTarget(target, desiredSource, rec):
    return false
  enforceTestHomeFence(target, "home.stow release")
  try:
    removeFile(extendedPath(target))
    true
  except OSError:
    false

proc stowTargetMatchesSource*(target, desiredSource: string): bool =
  ## M76: the ONE byte-identical predicate shared by the apply path.
  ##
  ## Decide whether whatever currently lives at `target` (a regular
  ## file, OR a symlink/junction to some — possibly different — source)
  ## has content byte-identical to the desired stow source. When true,
  ## a target that `inspectTarget` classifies as `tsRegularFile` or
  ## `tsWrongLink` is NOT a real conflict: it is a no-op cache-hit.
  ##
  ## The comparison is RAW BYTES via `readFile`, exactly the mechanism
  ## `previewStowItem` (the plan path) uses — so the plan's cache-hit
  ## verdict and the apply's cache-hit verdict are always identical.
  ## `readFile` follows symlinks/junctions, so a wrong-link target's
  ## *resolved* content is what gets compared (a wrong link whose
  ## resolved bytes equal the source's is still a cache-hit, per the
  ## M76 deliverable). NEVER mutates the filesystem.
  try:
    if not fileExists(extendedPath(desiredSource)):
      return false
    if not fileExists(extendedPath(target)):
      # `fileExists` follows links; false here means there is no
      # readable file content at the target (absent, dangling link,
      # or a directory) — nothing byte-identical to compare against.
      return false
    readFile(extendedPath(target)) == readFile(extendedPath(desiredSource))
  except OSError, IOError:
    false

proc inspectTarget(target, desiredSource: string): TargetInspection =
  ## Classify what currently lives at `target` relative to the desired
  ## stow link. NEVER mutates the filesystem — this is the read the
  ## non-destructive decision tree branches on.
  if not fileExists(extendedPath(target)) and not symlinkExists(extendedPath(target)) and
     not dirExists(extendedPath(target)):
    return TargetInspection(state: tsAbsent)
  if symlinkExists(extendedPath(target)):
    # A symlink (file or dir). Compare by file identity — robust
    # across Windows reparse-point resolution quirks.
    if linkPointsAtSource(target, desiredSource):
      return TargetInspection(state: tsCorrectLink,
        existingKind: "symlink",
        existingTarget: readLinkTargetBestEffort(target))
    return TargetInspection(state: tsWrongLink,
      existingKind: "symlink",
      existingTarget: readLinkTargetBestEffort(target))
  # A regular file (or a real directory). On Windows a junction to a
  # directory reports via `dirExists` but not `symlinkExists`; the
  # stow files this module materializes are always FILES, so a
  # directory at a file's target path is itself a conflict.
  if dirExists(extendedPath(target)):
    return TargetInspection(state: tsRegularFile,
      existingKind: "directory")
  return TargetInspection(state: tsRegularFile,
    existingKind: "regular-file")

proc tryCreateSymlink(target, source: string;
                      reconcile: StowReconcilePolicy;
                      outCacheHit, outReconciled: var bool): bool =
  ## M72 Deliverable 3: non-destructive symlink materialization.
  ##
  ##   * target absent                       → create the link.
  ##   * target already the correct symlink  → no-op CACHE-HIT
  ##     (the link is NOT deleted and recreated).
  ##   * target is a regular file / wrong link whose content is
  ##     BYTE-IDENTICAL to the stow source → no-op CACHE-HIT (M76).
  ##     The file/link was never a real conflict — the plan path
  ##     (`previewStowItem`) already classifies it as a cache-hit, so
  ##     apply must agree. The target is left exactly as is: not
  ##     deleted, not recreated.
  ##   * target is a regular file / wrong link whose content GENUINELY
  ##     DIFFERS from the source → CONFLICT: raise `EStowConflict`
  ##     (fail-closed) unless `reconcile` is `srpReconcileDrift`, in
  ##     which case the prior content is recorded by the caller and
  ##     the target is replaced.
  ##
  ## Early-returns when the test hook disables symlinks WITHOUT
  ## mutating the filesystem — pre-creating the target's parent dir
  ## would defeat the junction fallback, which keys off "ancestor
  ## does not yet exist on disk."
  outCacheHit = false
  outReconciled = false
  if getEnv(DisableSymlinkEnvVar) == "1":
    return false
  let inspection = inspectTarget(target, source)
  case inspection.state
  of tsCorrectLink:
    # Already correct — no-op cache-hit. Do NOT delete-and-recreate.
    outCacheHit = true
    return true
  of tsRegularFile, tsWrongLink:
    # M76: a regular file or a wrong-source link whose (resolved)
    # content is byte-identical to the stow source is NOT a conflict —
    # it is a no-op cache-hit, exactly as `previewStowItem` previews
    # it. Leave the target untouched: do not delete, do not recreate.
    if stowTargetMatchesSource(target, source):
      outCacheHit = true
      return true
    if reconcile != srpReconcileDrift:
      raiseStowConflict(target, inspection.existingKind, source,
        inspection.existingTarget)
    # Reconcile: the caller already captured the prior content
    # digest via `readPreWriteDigest`. Remove the conflicting target
    # so the link can be created in its place.
    outReconciled = true
    try:
      removeFile(extendedPath(target))
    except OSError, IOError:
      # A directory cannot be removed with removeFile.
      try: removeDir(extendedPath(target)) except OSError: discard
  of tsAbsent:
    discard
  try:
    let parent = parentDir(target)
    if parent.len > 0:
      createDir(extendedPath(parent))
    createSymlink(extendedPath(source), extendedPath(target))
    true
  except OSError, IOError:
    false

proc tryCreateJunctionAtAncestor(homeDir, homeRel: string;
                                 sourceFile: string;
                                 actualTarget: var string): bool =
  ## Windows-only junction fallback. The spec mandates "deepest
  ## stow-exclusive ancestor". For Phase B's first cut we pick the
  ## immediate parent directory of the target file (if that directory
  ## does not yet exist on disk). A file whose package-stripped
  ## `$HOME` path has no parent directory (e.g. `stow/<pkg>/.gitconfig`
  ## materializing at `$HOME/.gitconfig`) cannot be junctioned because
  ## `$HOME` itself can never be replaced.
  ##
  ## M73: `homeRel` is the PACKAGE-STRIPPED relative path; the junction
  ## links `$HOME/<relParent>` to the stow source's parent directory,
  ## which is taken directly from `sourceFile`'s absolute path — NOT
  ## reconstructed from `homeRel` (the package level is absent there).
  when defined(windows):
    if getEnv(DisableJunctionEnvVar) == "1":
      return false
    let relPath = homeRel
    let slash = relPath.rfind('/')
    if slash <= 0:
      return false  # at $HOME root; not junctionable
    let relParent = relPath[0 ..< slash]
    let homeParent = homeDir / relParent.replace('/', DirSep)
    if dirExists(extendedPath(homeParent)):
      return false  # ancestor already populated; would clobber
    # The stow-side junction target is the real source file's parent
    # directory inside `stow/<package>/...`.
    let stowParent = parentDir(sourceFile)
    if not dirExists(extendedPath(stowParent)):
      return false
    try:
      let parentOfParent = parentDir(homeParent)
      if parentOfParent.len > 0:
        createDir(extendedPath(parentOfParent))
      # `mklink /J <link> <target>` creates an NTFS junction.
      let cmd = "cmd /c mklink /J " & quoteShell(homeParent) & " " &
        quoteShell(stowParent)
      let rc = execShellCmd(cmd)
      if rc != 0:
        return false
    except OSError, IOError:
      return false
    actualTarget = homeParent / extractFilename(sourceFile)
    return fileExists(extendedPath(actualTarget))
  else:
    discard
    return false

proc materializeStowEntry*(profileDir, homeDir: string;
                           entry: StowEntry;
                           reconcile: StowReconcilePolicy = srpFailClosed):
    AppliedStowRecord =
  ## Apply one stow entry through the symlink → junction → copy
  ## decision tree. The selected mode is returned so the pipeline
  ## emits `IStowFellBack` on the first fallback within a generation.
  ##
  ## M72 Deliverable 3: the materializer is non-destructive. A target
  ## that already exists as the correct link is a no-op cache-hit
  ## (`result.wasCacheHit = true`). A target that pre-exists as a
  ## regular file or a link to a different source is a CONFLICT —
  ## `EStowConflict` is raised under `srpFailClosed`, leaving the
  ## target byte-identical; under `srpReconcileDrift` the prior
  ## content is recorded (`preWriteDigest`) and the target replaced.
  enforceTestHomeFence(entry.targetAbsolutePath, "home.stow link")
  result.sourceAbsolutePath = entry.sourceAbsolutePath
  result.homeRelativePath = entry.homeRelativePath
  result.targetAbsolutePath = entry.targetAbsolutePath
  # Capture the prior content BEFORE any mutation. For a correct
  # symlink this reads the (identical) source bytes; for a conflicting
  # regular file / wrong link it captures the bytes rollback restores.
  let preDigest = readPreWriteDigest(entry.targetAbsolutePath)
  result.hasPreWriteDigest = preDigest.has
  if preDigest.has:
    result.preWriteDigest = preDigest.digest
  if not fileExists(extendedPath(entry.sourceAbsolutePath)):
    raiseMaterializeFailed(entry.targetAbsolutePath,
      "stow source missing: " & entry.sourceAbsolutePath)
  let raw = readFile(extendedPath(entry.sourceAbsolutePath))
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  result.postWriteDigest = digestBytes(buf)
  # NOTE: we do NOT eagerly `createDir(parentDir(target))` here.
  # The junction fallback below requires the deepest stow-exclusive
  # ancestor to NOT yet exist on disk; eager parent creation would
  # foreclose the junction option. Each branch creates the parent
  # itself when (and only when) it needs it.
  var cacheHit = false
  var reconciled = false
  if tryCreateSymlink(entry.targetAbsolutePath, entry.sourceAbsolutePath,
      reconcile, cacheHit, reconciled):
    result.mode = smSymlink
    result.wasCacheHit = cacheHit
    result.wasReconciled = reconciled
    return
  when defined(windows):
    var junctioned: string
    if tryCreateJunctionAtAncestor(homeDir, entry.homeRelativePath,
        entry.sourceAbsolutePath, junctioned):
      result.mode = smJunction
      return
  # Copy fallback — same non-destructive rule. A target that already
  # exists is inspected before any write:
  #   * byte-identical regular file / wrong link → no-op cache-hit
  #     (M76: one shared `stowTargetMatchesSource` predicate).
  #   * differing regular file / wrong link → conflict (fail-closed)
  #     unless reconcile-drift is in effect.
  let parent = parentDir(entry.targetAbsolutePath)
  let inspection = inspectTarget(entry.targetAbsolutePath,
    entry.sourceAbsolutePath)
  case inspection.state
  of tsCorrectLink:
    # A surviving correct link reached the copy fallback (symlink was
    # disabled by the test hook but the link was already present).
    # Leave it — it already resolves to the source.
    result.mode = smCopy
    result.wasCacheHit = true
    return
  of tsRegularFile, tsWrongLink:
    # M76: byte-identical (resolved) content already in place — no-op
    # cache-hit. Leave the target untouched. This is the SAME
    # `stowTargetMatchesSource` predicate `tryCreateSymlink` and
    # `previewStowItem` use, so plan and apply always agree.
    if stowTargetMatchesSource(entry.targetAbsolutePath,
        entry.sourceAbsolutePath):
      result.mode = smCopy
      result.wasCacheHit = true
      return
    if reconcile != srpReconcileDrift:
      raiseStowConflict(entry.targetAbsolutePath, inspection.existingKind,
        entry.sourceAbsolutePath, inspection.existingTarget)
    result.wasReconciled = true
    try: removeFile(extendedPath(entry.targetAbsolutePath))
    except OSError:
      try: removeDir(extendedPath(entry.targetAbsolutePath)) except OSError: discard
  of tsAbsent:
    discard
  if parent.len > 0:
    createDir(extendedPath(parent))
  copyFile(extendedPath(entry.sourceAbsolutePath), extendedPath(entry.targetAbsolutePath))
  result.mode = smCopy

proc modeToOwnershipPolicy*(mode: StowMaterializationMode):
    GeneratedFileOwnership =
  case mode
  of smSymlink: gfoStowSymlink
  of smJunction: gfoStowJunction
  of smCopy: gfoStowCopy

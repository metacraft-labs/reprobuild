## Scoop removal policy: which Scoop installs a home-generation transition
## may delete, and the install ledger that makes the answer knowable.
##
## Governing text: reprobuild-pm `spec/Scoop-Catalog-Adapter.md`
## §"Removal, Store Roots, and Two-Stage Migration" (the subsections
## "Install Provenance" and "Opt-In Cleanup Governed by Store GC Roots").
##
## Three rules, each closing one way the earlier per-app eager cleanup lost
## data:
##
## 1. **Opt-in.** Nothing is uninstalled unless the transition was asked to
##    with `--uninstall-from-scoop`. Without it a dropped Scoop package is
##    only unlinked from the generation; the Scoop install stays for the
##    user's other shells and tools.
## 2. **Provenance.** Only a version directory Reprobuild itself created
##    with `scoop install` is eligible. A version Reprobuild found already
##    installed (adopted as a cache-hit, e.g. by a `home-switch.ps1` or a
##    manual `scoop install`) is never deleted. The provenance lives in an
##    install ledger in the store index (`index.db`), keyed by Scoop root,
##    app and version, and bound to the identity (device + file index) of the
##    version directory it created, so a later uninstall-and-reinstall by
##    the user is not mistaken for Reprobuild's install.
## 3. **App-wide hold.** `scoop uninstall <app>` deletes every version of
##    the app, so the hold check spans every store prefix of the app, not
##    only the version the generation recorded: a workspace lock or dev
##    shell holding `app@14.0` keeps the whole app when the profile drops
##    `app@14.1`. A `profile` root counts too, unless it is the calling
##    state directory's own (`OwnProfileRoots`): several state directories
##    can use one store, and another one's generation may still use the
##    app.
##
## When some versions are Reprobuild's and others are not, only
## Reprobuild's versions are removed, one directory at a time, and never the
## version Scoop's `current` link points at (Scoop's shims for the user's
## other installs resolve through it). The whole-app `scoop uninstall`
## runs only when every installed version is Reprobuild's.
##
## This module is platform-neutral (it is exercised on Linux against a
## sandboxed Scoop root); the `scoop` CLI invocation for the whole-app case
## stays with `uninstallScoopApp` in `repro_tool_profiles`.

import std/[algorithm, os, sets, strutils, tables]

from repro_core/paths import extendedPath
import repro_local_store
import repro_tool_profiles/junction_aware_remove

const
  ScoopAdapterName = "scoop"
    ## The `adapter` key of this module's install-ledger records, and the
    ## `adapter` column of Scoop store prefixes.
  ScoopPrefixPackagePrefix = "scoop."
    ## Store prefixes of Scoop realizations are named
    ## `scoop.<bucket>.<app>` (`realizeScoopTool`).

type
  ScoopRemovalAction* = enum
    sraRetainNotRequested = "retain-not-requested"
      ## `--uninstall-from-scoop` was not passed: the Scoop install is
      ## left for its other consumers.
    sraRetainHeld = "retain-held"
      ## A `workspace`, `session` or `pin` root, or a `profile` root of
      ## another state directory, holds a prefix of the app.
    sraRetainAdopted = "retain-adopted"
      ## No installed version of the app is one Reprobuild installed, or
      ## the only ones it installed are the version `current` points at
      ## while other installs remain.
    sraAbsent = "absent"
      ## The app has no installed version under the Scoop root.
    sraUninstallApp = "uninstall-app"
      ## Every installed version is Reprobuild's: `scoop uninstall <app>`.
    sraRemoveVersions = "remove-versions"
      ## Remove only `removeVersions`; `retainedVersions` stay.

  OwnProfileRoots* = object
    ## The `profile` roots of the state directory running the transition,
    ## which the hold check does not count: the generation being left holds
    ## its own prefix until retention drops it, and the transition is what
    ## releases that hold. Every other `profile` root on the store belongs
    ## to another state directory and is a holder. The caller describes its
    ## roots, because their naming belongs to the home-generation registry
    ## (reprobuild-pm `spec/Home-Profile-Generations-And-State.md`
    ## §"Store GC Interaction"). An empty value owns nothing, so every
    ## `profile` root holds: the safe direction for a deletion guard.
    keyPrefix*: string
      ## `home/<state-dir-key>/`: every root under it is the caller's.
      ## Empty when the state directory has no readable key.
    bareIds*: HashSet[string]
      ## The ids of the generations the state directory holds. A root an
      ## earlier build registered under one of these bare ids is the
      ## caller's; a bare id it does not hold is another state directory's.

  ScoopRemovalPlan* = object
    ## The decision for one Scoop app dropped by a generation transition.
    ## Computed without mutating anything, so `--plan` previews exactly
    ## what the apply executes.
    bucket*: string
    app*: string
    recordedVersion*: string       ## the version the dropped record named
    scoopRoot*: string
    action*: ScoopRemovalAction
    holders*: seq[string]          ## `<root-id> (<kind>)` for sraRetainHeld
    removeVersions*: seq[string]   ## version dirs that will be deleted
    retainedVersions*: seq[string] ## installed versions that stay

# ---------------------------------------------------------------------------
# Version directories
# ---------------------------------------------------------------------------

proc scoopAppDir*(scoopRoot, app: string): string =
  scoopRoot / "apps" / app

proc installedScoopVersions*(scoopRoot, app: string): seq[string] =
  ## The exact-version directories under `<scoopRoot>/apps/<app>`, sorted.
  ## `current` is Scoop's link to the active version, not a version.
  let appDir = scoopAppDir(scoopRoot, app)
  if not dirExists(extendedPath(appDir)):
    return @[]
  for kind, path in walkDir(extendedPath(appDir), relative = true):
    if kind in {pcDir, pcLinkToDir}:
      let leaf = path.extractFilename
      if leaf.len > 0 and leaf != "current":
        result.add(leaf)
  result.sort()

proc dirIdentity(path: string): string =
  ## Device + file index of the directory at `path` (following links), or
  ## "" when it cannot be read. On Windows this is the volume serial and
  ## NTFS file index; on POSIX the device and inode. A directory deleted
  ## and recreated gets a different identity, which is what makes a ledger
  ## record specific to the install that created it.
  try:
    let info = getFileInfo(extendedPath(path), followSymlink = true)
    if info.kind notin {pcDir, pcLinkToDir}:
      return ""
    result = $info.id.device & ":" & $info.id.file
  except OSError:
    result = ""

proc currentScoopVersion*(scoopRoot, app: string): string =
  ## The version Scoop's `<appDir>/current` link resolves to, or "" when
  ## there is no `current`. Compared by directory identity so a Windows
  ## junction and a POSIX symlink are handled alike.
  let appDir = scoopAppDir(scoopRoot, app)
  let currentId = dirIdentity(appDir / "current")
  if currentId.len == 0:
    return ""
  for v in installedScoopVersions(scoopRoot, app):
    if dirIdentity(appDir / v) == currentId:
      return v

# ---------------------------------------------------------------------------
# Install ledger
# ---------------------------------------------------------------------------
#
# The records live in the store index (`adapter_installs`, see
# `repro_local_store.recordAdapterInstall`), keyed by the normalized Scoop
# root, the app and the version.

proc normalizedScoopRoot(scoopRoot: string): string =
  result = absolutePath(scoopRoot).normalizedPath
  when defined(windows):
    result = result.toLowerAscii

proc recordScoopInstall*(store: Store; scoopRoot, bucket, app,
                         version: string) =
  ## Record that Reprobuild ran `scoop install` and thereby created
  ## `<scoopRoot>/apps/<app>/<version>`. Call it only after a successful
  ## install that Reprobuild itself performed, never for a cache-hit.
  let versionDir = scoopAppDir(scoopRoot, app) / version
  let identity = dirIdentity(versionDir)
  if identity.len == 0:
    raise newException(IOError,
      "cannot record the Scoop install of " & app & "@" & version &
      ": " & versionDir & " is not a readable directory")
  store.recordAdapterInstall(ScoopAdapterName,
    normalizedScoopRoot(scoopRoot), app, version, identity, bucket)

proc recordScoopInstall*(storeRoot, scoopRoot, bucket, app, version: string) =
  ## `recordScoopInstall` for a caller that holds no open store.
  var store = openStore(storeRoot)
  defer: store.close()
  recordScoopInstall(store, scoopRoot, bucket, app, version)

proc scoopVersionInstalledByReprobuild*(store: Store; scoopRoot, app,
                                        version: string): bool =
  ## True only when the ledger records that Reprobuild installed exactly
  ## the directory now at `<scoopRoot>/apps/<app>/<version>`. A missing,
  ## unreadable or mismatching record answers false: the safe default is
  ## to treat the install as someone else's.
  try:
    let recorded = store.adapterInstallIdentity(ScoopAdapterName,
      normalizedScoopRoot(scoopRoot), app, version)
    let actual = dirIdentity(scoopAppDir(scoopRoot, app) / version)
    result = recorded.len > 0 and recorded == actual
  except CatchableError:
    result = false

proc recordedScoopInstalls*(store: Store; scoopRoot, app: string):
    seq[string] =
  ## The versions of `app` under `scoopRoot` the ledger records, whether or
  ## not their directories are still there.
  store.adapterInstallVersions(ScoopAdapterName,
    normalizedScoopRoot(scoopRoot), app)

proc forgetScoopInstall*(store: Store; scoopRoot, app, version: string) =
  ## Drop the ledger record once the version directory is gone.
  store.forgetAdapterInstall(ScoopAdapterName,
    normalizedScoopRoot(scoopRoot), app, version)

# ---------------------------------------------------------------------------
# Holders
# ---------------------------------------------------------------------------

proc isScoopPrefixOfApp(row: PrefixRow; app: string): bool =
  ## A store prefix realized through Scoop for `app`, in any bucket. The
  ## package name is `scoop.<bucket>.<app>` with unsafe characters
  ## replaced by `_` (`safeStoreSegment`). The match ignores case, because
  ## Scoop's app directories live on a case-insensitive file system, so
  ## `Ripgrep` and `ripgrep` name the same install; and a suffix match may
  ## also catch an app whose name ends in `.<app>`. Both over-match, which
  ## only retains more: the safe direction for a deletion guard.
  let name = row.packageName.toLowerAscii
  if row.adapter != ScoopAdapterName or
      not name.startsWith(ScoopPrefixPackagePrefix):
    return false
  var safeApp = ""
  for ch in app:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      safeApp.add(ch)
    else:
      safeApp.add('_')
  name.endsWith("." & safeApp.toLowerAscii)

proc ownsProfileRoot*(own: OwnProfileRoots; rootId: string): bool =
  ## True when `rootId` names a `profile` root of the caller's state
  ## directory (`OwnProfileRoots`).
  (own.keyPrefix.len > 0 and rootId.startsWith(own.keyPrefix)) or
    rootId in own.bareIds

proc scoopAppHolders*(store: Store; app: string;
                      own: OwnProfileRoots): seq[string] =
  ## Every root that holds ANY store prefix of `app`, rendered
  ## `<root-id> (<kind>)`, except the caller's own `profile` roots
  ## (`own`). A `profile` root of another state directory that uses the
  ## same store is a holder like a `workspace`, `session` or `pin` root.
  var rootKind = initTable[string, string]()
  for r in store.listRoots():
    rootKind[r.rootId] = r.kind
  var seen = initHashSet[string]()
  for row in store.listPrefixes():
    if not isScoopPrefixOfApp(row, app):
      continue
    for holder in store.rootsHolding(row.prefixId):
      # A holder whose root row is missing is counted, not skipped: an
      # index this guard cannot read fully must not license a deletion.
      let kind = rootKind.getOrDefault(holder, $rkUnknown)
      if kind == $rkProfile and own.ownsProfileRoot(holder):
        continue
      let rendered = holder & " (" & kind & ")"
      if rendered notin seen:
        seen.incl(rendered)
        result.add(rendered)
  result.sort()

# ---------------------------------------------------------------------------
# Planning and per-version removal
# ---------------------------------------------------------------------------

proc planScoopAppRemoval*(store: Store; scoopRoot, bucket, app,
                          recordedVersion: string;
                          uninstallFromScoop: bool;
                          own: OwnProfileRoots): ScoopRemovalPlan =
  ## Decide what a transition that drops `app` from the generation may
  ## delete. `own` names the `profile` roots of the state directory
  ## running the transition (`scoopAppHolders`). Reads only;
  ## `executeScoopVersionRemoval` and `uninstallScoopApp` carry the
  ## decision out.
  result = ScoopRemovalPlan(bucket: bucket, app: app,
    recordedVersion: recordedVersion, scoopRoot: scoopRoot)
  let installed =
    if scoopRoot.len > 0: installedScoopVersions(scoopRoot, app)
    else: @[]
  if not uninstallFromScoop:
    result.action = sraRetainNotRequested
    result.retainedVersions = installed
    return
  if installed.len == 0:
    result.action = sraAbsent
    return
  result.holders = scoopAppHolders(store, app, own)
  if result.holders.len > 0:
    result.action = sraRetainHeld
    result.retainedVersions = installed
    return
  var ours: seq[string]
  var theirs: seq[string]
  for v in installed:
    if scoopVersionInstalledByReprobuild(store, scoopRoot, app, v):
      ours.add(v)
    else:
      theirs.add(v)
  if ours.len == 0:
    result.action = sraRetainAdopted
    result.retainedVersions = installed
    return
  if theirs.len == 0:
    result.action = sraUninstallApp
    result.removeVersions = ours
    return
  # Mixed: some installs are someone else's. Remove only ours, and keep the
  # version `current` points at, through which Scoop's shims (and so the
  # other installs' users) reach the app.
  let current = currentScoopVersion(scoopRoot, app)
  for v in ours:
    if v == current:
      result.retainedVersions.add(v)
    else:
      result.removeVersions.add(v)
  result.retainedVersions.add(theirs)
  result.retainedVersions.sort()
  result.action =
    if result.removeVersions.len > 0: sraRemoveVersions
    else: sraRetainAdopted

proc executeScoopVersionRemoval*(store: Store; plan: ScoopRemovalPlan) =
  ## Delete the version directories of an `sraRemoveVersions` plan. Uses the
  ## junction-aware remover: a Scoop version directory links its persisted
  ## data (`<scoopRoot>/persist/<app>`) by junction, and `os.removeDir`
  ## would follow it and delete the user's data.
  if plan.action != sraRemoveVersions:
    return
  let appDir = scoopAppDir(plan.scoopRoot, plan.app)
  for v in plan.removeVersions:
    let dir = appDir / v
    if dirExists(extendedPath(dir)):
      removeJunctionAware(dir)
    if not dirExists(extendedPath(dir)):
      forgetScoopInstall(store, plan.scoopRoot, plan.app, v)

proc forgetScoopAppInstalls*(store: Store; plan: ScoopRemovalPlan) =
  ## After a whole-app uninstall: drop the ledger records of every version
  ## that is now gone.
  let appDir = scoopAppDir(plan.scoopRoot, plan.app)
  for v in plan.removeVersions:
    if not dirExists(extendedPath(appDir / v)):
      forgetScoopInstall(store, plan.scoopRoot, plan.app, v)

proc describeScoopRemoval*(plan: ScoopRemovalPlan): string =
  ## The `--plan` detail and apply log line for `plan`.
  let was = plan.bucket & "/" & plan.app &
    (if plan.recordedVersion.len > 0: "@" & plan.recordedVersion else: "")
  case plan.action
  of sraRetainNotRequested:
    "scoop app " & plan.app & " retained in Scoop (was " & was &
      "; pass --uninstall-from-scoop to remove the versions Reprobuild " &
      "installed)"
  of sraRetainHeld:
    "scoop app " & plan.app & " retained in Scoop (still held by store " &
      "root(s): " & plan.holders.join(", ") & ")"
  of sraRetainAdopted:
    "scoop app " & plan.app & " retained in Scoop (was " & was &
      "; not installed by Reprobuild, or in use as Scoop's current " &
      "version: " & plan.retainedVersions.join(", ") & ")"
  of sraAbsent:
    "scoop app " & plan.app & " is not installed (was " & was & ")"
  of sraUninstallApp:
    "scoop uninstall " & plan.app & " (was " & was & ")"
  of sraRemoveVersions:
    "remove Scoop " & plan.app & " version(s) " &
      plan.removeVersions.join(", ") & " installed by Reprobuild (was " &
      was & "; retained: " & plan.retainedVersions.join(", ") & ")"

proc scoopRemovalDestroys*(plan: ScoopRemovalPlan): bool =
  plan.action in {sraUninstallApp, sraRemoveVersions}

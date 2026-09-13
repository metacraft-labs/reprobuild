## ``repro self`` — the CLI surface of M5 SELF-HOST.
##
## "reprobuild installs reprobuild" needs exactly four verbs, and each one is
## a thin shell over `repro_selfhost` / `repro_selfhost/install`:
##
##   install    realize a built reprobuild image tree into the store as a
##              named version, so a pin can address it.
##   provision  put the version a pin names into the store, fetching it from
##              a binary cache when one is configured and refusing loudly
##              when it cannot. This is what the resolving launcher calls
##              when a pin resolves to a prefix that is not resident.
##   hold       attach the calling project's pin root to the prefix its lock
##              pins, so `repro store gc` keeps it.
##   which      report what the launcher WOULD exec here, and why.
##   list       the reprobuild images resident in the store.
##   prune-roots
##              re-derive every pin root from the lock it names. Run
##              automatically by `repro store gc`; exposed separately so the
##              re-derivation can be observed on its own.
##
## Deliberately NOT here: any notion of a "current" or "default" reprobuild
## version that lives outside a project's lock. There is no `repro self use`
## and no `repro self default`, because either one would be the
## `.reprobuild-version` file this milestone exists to avoid, wearing a
## command instead of a filename.

import std/[json, os, strutils]

import repro_lock
import repro_selfhost
import repro_selfhost/install as selfinstall
export PinRootOutcome, PinRootAction
import repro_local_store

const SelfUsage = """usage: repro self <subcommand> [options]

  install --from=DIR --version=V [--platform=P] [--store-root=PATH]
  provision --version=V [--platform=P] [--store-root=PATH] [--from=DIR]
  hold [--project=DIR] [--store-root=PATH]
  which [--project=DIR] [--store-root=PATH] [--json]
  list [--store-root=PATH] [--json]
  prune-roots [--store-root=PATH] [--json]"""

type
  SelfArgs = object
    sub: string
    fromDir: string
    version: string
    platform: string
    project: string
    storeRoot: string
    emitJson: bool

proc parseSelfArgs(args: openArray[string]): (SelfArgs, string) =
  var parsed = SelfArgs()
  for raw in args:
    if raw.startsWith("--from="):
      parsed.fromDir = raw["--from=".len .. ^1]
    elif raw.startsWith("--version="):
      parsed.version = raw["--version=".len .. ^1]
    elif raw.startsWith("--platform="):
      parsed.platform = raw["--platform=".len .. ^1]
    elif raw.startsWith("--project="):
      parsed.project = raw["--project=".len .. ^1]
    elif raw.startsWith("--store-root="):
      parsed.storeRoot = raw["--store-root=".len .. ^1]
    elif raw == "--json":
      parsed.emitJson = true
    elif raw.startsWith("--"):
      return (parsed, "unknown flag: " & raw)
    elif parsed.sub.len == 0:
      parsed.sub = raw
    else:
      return (parsed, "unexpected argument: " & raw)
  (parsed, "")

proc effectivePlatform(explicit: string): string =
  if explicit.len > 0: explicit else: currentPlatformId()

proc effectiveProject(explicit: string): string =
  ## The project whose pin a verb acts on: an explicit `--project`, else the
  ## nearest enclosing project of the working directory. Resolved through
  ## `findProjectRoot` in BOTH cases so an explicit `--project` pointing at a
  ## subdirectory names the same project the launcher would.
  let start = if explicit.len > 0: explicit else: getCurrentDir()
  findProjectRoot(start)

proc pinStateWord(state: SelfPinState): string =
  case state
  of spsNoProject: "no-project"
  of spsNoPin: "not-pinned"
  of spsNotAddressable: "not-addressable"
  of spsTampered: "tampered"
  of spsPinned: "pinned"

proc runSelfInstall(a: SelfArgs): int =
  if a.fromDir.len == 0 or a.version.len == 0:
    stderr.writeLine("repro self install: --from=DIR and --version=V are " &
      "both required")
    return 2
  let root = resolveStoreRoot(a.storeRoot)
  let platform = effectivePlatform(a.platform)
  let res = selfinstall.installSelfImage(root, a.version, platform, a.fromDir)
  if a.emitJson:
    echo $(%*{
      "storeRoot": root, "version": res.version, "platform": res.platform,
      "storeAddress": res.storeAddress,
      "prefixId": prefixIdHex(res.prefixId),
      "relativePath": res.relativePath,
      "executable": res.executablePath,
      "alreadyPresent": res.alreadyPresent})
  else:
    echo "repro self install: store-root=" & root
    echo "version: " & res.version & " (" & res.platform & ")"
    echo "store address: " & res.storeAddress
    echo "prefix id: " & prefixIdHex(res.prefixId)
    echo "realized: " & res.relativePath &
      (if res.alreadyPresent: " (already present)" else: "")
    echo "executable: " & res.executablePath
  0

proc runSelfProvision(a: SelfArgs): int =
  ## Put the named version in the store.
  ##
  ## THE M3 BOUNDARY IS HERE AND IS NAMED RATHER THAN PAPERED OVER. The
  ## spec's "a bootstrap repro builds/fetches other versions from the binary
  ## cache" has two arms. The LOCAL arm — `--from=DIR`, an image tree this
  ## host already has — is complete and is what the gate exercises. The
  ## REMOTE arm needs a reachable binary cache; `repro cache substitute`
  ## speaks only `http(s)://` (there is no `file://` substituter) and writes
  ## into `$REPRO_LOCAL_STORE`, a DIFFERENT tree from the `$REPRO_STORE_ROOT`
  ## the prefixes live in — so even against a localhost daemon it is a fetch
  ## followed by an install, not one step. Rather than pretend, this verb
  ## refuses with the two things a caller can act on: which version it could
  ## not find, and the command that would put it there.
  if a.version.len == 0:
    stderr.writeLine("repro self provision: --version=V is required")
    return 2
  let root = resolveStoreRoot(a.storeRoot)
  let platform = effectivePlatform(a.platform)
  let address = storeAddressFor(a.version, platform)
  let relative = prefixRelativePathFor(a.version, address)
  let absolute = root / relative
  if fileExists(selfExecutableIn(absolute)):
    echo "repro self provision: " & SelfPackageName & " " & a.version &
      " is already resident at " & relative
    return 0
  if a.fromDir.len > 0:
    var local = a
    local.platform = platform
    return runSelfInstall(local)
  stderr.writeLine("repro self provision: " & SelfPackageName & " " &
    a.version & " (" & platform & ", store address " & address &
    ") is not resident in " & root & " and no local image was offered.")
  stderr.writeLine("  install it from a built tree:")
  stderr.writeLine("    repro self install --from=<dir> --version=" &
    a.version & " --platform=" & platform & " --store-root=" & root)
  stderr.writeLine("  or fetch it from a binary cache first " &
    "(REPRO_BINARY_CACHE_URL / caches.conf), then install the " &
    "substituted tree with the command above.")
  1

proc runSelfHold(a: SelfArgs): int =
  let root = resolveStoreRoot(a.storeRoot)
  let project = effectiveProject(a.project)
  let pin = selfPinForProject(project)
  if pin.state != spsPinned:
    stderr.writeLine("repro self hold: " & pin.detail)
    return 1
  let prefixId = selfPrefixId(pin)
  if not selfinstall.attachPinRoot(root, project, prefixId):
    stderr.writeLine("repro self hold: " & SelfPackageName & " " &
      pin.version & " is not installed in " & root &
      " (prefix " & prefixIdHex(prefixId) & "); nothing to hold")
    return 1
  if a.emitJson:
    echo $(%*{"rootId": pinRootIdFor(project), "project": project,
      "prefixId": prefixIdHex(prefixId), "version": pin.version})
  else:
    echo "repro self hold: " & pinRootIdFor(project) & " -> " &
      prefixIdHex(prefixId) & " (" & SelfPackageName & " " & pin.version & ")"
  0

proc runSelfWhich(a: SelfArgs): int =
  ## What the launcher would exec here, and why. Exit 0 when a pin resolves
  ## to a resident image, 1 otherwise — so a script can gate on it.
  let root = resolveStoreRoot(a.storeRoot)
  let project = effectiveProject(a.project)
  let pin = selfPinForProject(project)
  var executable = ""
  var relative = ""
  var resident = false
  if pin.state == spsPinned:
    relative = selfPrefixRelativePath(pin)
    executable = selfExecutableIn(root / relative)
    resident = fileExists(executable)
  if a.emitJson:
    echo $(%*{
      "state": pinStateWord(pin.state),
      "projectRoot": pin.projectRoot,
      "lockPath": pin.lockPath,
      "version": pin.version,
      "platform": pin.platform,
      "storeAddress": pin.storeHash,
      "integrity": pin.integrity,
      "storeRoot": root,
      "relativePath": relative,
      "executable": executable,
      "resident": resident,
      "detail": pin.detail})
  else:
    echo "state: " & pinStateWord(pin.state)
    echo "project: " & pin.projectRoot
    echo "lock: " & pin.lockPath
    if pin.state == spsPinned:
      echo "version: " & pin.version & " (" & pin.platform & ")"
      echo "store address: " & pin.storeHash
      echo "integrity: " & pin.integrity
      echo "store root: " & root
      echo "prefix: " & relative
      echo "executable: " & executable
      echo "resident: " & (if resident: "yes" else: "no")
    else:
      echo "detail: " & pin.detail
  if pin.state == spsPinned and resident: 0 else: 1

proc runSelfList(a: SelfArgs): int =
  let root = resolveStoreRoot(a.storeRoot)
  let rows = selfinstall.listSelfPrefixes(root)
  if a.emitJson:
    var arr = newJArray()
    for row in rows:
      arr.add(%*{"version": row.version,
        "prefixId": prefixIdHex(row.prefixId),
        "relativePath": row.realizedPath,
        "adapter": row.adapter})
    echo $(%*{"storeRoot": root, "count": rows.len, "versions": arr})
  else:
    echo "repro self list: store-root=" & root
    echo "resident " & SelfPackageName & " versions: " & $rows.len
    for row in rows:
      echo "  - " & row.version & "  " & prefixIdHex(row.prefixId) & "  " &
        row.realizedPath
  0

proc runSelfPruneRoots(a: SelfArgs): int =
  let root = resolveStoreRoot(a.storeRoot)
  let outcomes = selfinstall.prunePinRoots(root)
  if a.emitJson:
    var arr = newJArray()
    for o in outcomes:
      arr.add(%*{"rootId": o.rootId, "projectRoot": o.projectRoot,
        "action": $o.action, "prefixId": o.prefixIdHex, "reason": o.reason})
    echo $(%*{"storeRoot": root, "count": outcomes.len, "roots": arr})
  else:
    echo "repro self prune-roots: store-root=" & root
    echo "pin roots re-derived: " & $outcomes.len
    for o in outcomes:
      echo "  - " & o.rootId & " " & $o.action &
        (if o.prefixIdHex.len > 0: " -> " & o.prefixIdHex else: "") &
        " (" & o.reason & ")"
  0

proc prunePinRootsForGc*(storeRoot: string): seq[PinRootOutcome] =
  ## `repro store gc`'s entry into the pin-root re-derivation. Named
  ## separately from `prunePinRoots` so the gc arm reads as one call and so
  ## the CLI keeps exactly one import of the install half.
  selfinstall.prunePinRoots(storeRoot)

proc runSelfCommand*(args: seq[string]): int =
  ## ``repro self <subcommand>``.
  if args.len == 0:
    echo SelfUsage
    return 2
  let (parsed, err) = parseSelfArgs(args)
  if err.len > 0:
    stderr.writeLine("repro self: " & err)
    return 2
  if parsed.sub.len == 0:
    stderr.writeLine("repro self: missing subcommand")
    return 2
  try:
    case parsed.sub
    of "install": return runSelfInstall(parsed)
    of "provision": return runSelfProvision(parsed)
    of "hold": return runSelfHold(parsed)
    of "which": return runSelfWhich(parsed)
    of "list": return runSelfList(parsed)
    of "prune-roots": return runSelfPruneRoots(parsed)
    else:
      stderr.writeLine("repro self: unknown subcommand: " & parsed.sub)
      stderr.writeLine(SelfUsage)
      return 2
  except CatchableError as e:
    stderr.writeLine("repro self " & parsed.sub & ": error: " & e.msg)
    return 1

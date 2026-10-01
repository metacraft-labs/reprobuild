## M5 SELF-HOST — the half of self-hosting that needs the store RUNTIME:
## realizing a reprobuild image into the content-addressed store, holding it
## with a pin root, and re-deriving those roots so a removed pin becomes
## collectable garbage.
##
## Kept OUT of ``repro_selfhost`` proper, and the split is the same one
## ``install_mirror_publish`` made for the same reason: the resolving
## launcher links the pin-resolution half and must not acquire a SQLite
## dependency to answer "where does my pinned reprobuild live". Resolution is
## arithmetic; installation is a database transaction. Only the second needs
## ``repro_local_store``.
##
## THE ROOT MODEL, AND WHY A PIN ROOT IS DERIVED RATHER THAN DECLARED.
## ``repro_local_store`` already had ``rkPin`` in ``RootKind`` and nothing
## used it. It is the right slot, but a pin root has a property the other
## kinds do not: it is not an assertion somebody made, it is a CONSEQUENCE of
## what a project's committed lock says right now. A profile root or a
## session root goes away when its owner deletes it; a pin root has to go
## away when the project stops pinning, and the project stops pinning by
## editing a file, not by calling an API.
##
## So the root id encodes the project path (``pin:reprobuild:<root>``) and
## ``prunePinRoots`` RE-DERIVES every pin root from the lock it names:
## forget it, read the lock again, and re-establish it only if the project
## still pins something the store still has. That is Nix's indirect-gcroot
## rule — a root that names something no longer there is not a root — and it
## is what makes "remove the pin, run gc" reclaim the version, with no
## bookkeeping step a user can forget.

import std/[os, strutils]

import repro_core/cli_images
import repro_local_store

import ../repro_selfhost

export repro_selfhost

type
  SelfInstallResult* = object
    prefixId*: PrefixIdBytes
    relativePath*: string
    absolutePath*: string
    executablePath*: string
    alreadyPresent*: bool
    version*: string
    platform*: string
    storeAddress*: string

  PinRootAction* = enum
    praKept        ## re-derived to the same prefix it already held
    praRepointed   ## the project now pins a different prefix
    praDropped     ## the project no longer pins an installable reprobuild

  PinRootOutcome* = object
    rootId*: string
    projectRoot*: string
    action*: PinRootAction
    prefixIdHex*: string
      ## The prefix the root holds AFTER the pass; "" when dropped.
    reason*: string

proc pinnedStoreReceiptHint(pkg: PinnedPackage;
                            version, storeAddress: string): StoreReceiptHint =
  ## The receipt an installed pinned image carries. ``lockIdentity`` is
  ## the lock's own self-describing store address, which is also what
  ## ``prefixIdFor`` folds into the realization hash — so the receipt on disk
  ## names the pin that may exec it.
  StoreReceiptHint(
    adapter: pkg.adapter,
    packageName: pkg.name,
    version: version,
    declaredExecutablePath: pinnedDeclaredExecutablePath(pkg),
    exportedExecutables: @[pinnedExecutableName(pkg)],
    lockIdentity: selfLockIdentity(storeAddress),
    provenanceUrl: "",
    provenanceChecksum: "",
    materializationMechanism: "")

proc validateProviderNimTree(sourceDir: string) =
  ## A pinned Nim is a Nim DISTRIBUTION, not a binary: ``bin/nim`` finds its
  ## standard library at ``../lib`` relative to itself, and a prefix holding
  ## the executable without it realizes cleanly and then fails every provider
  ## compile with "cannot open file: system". Refused here, where the person
  ## installing it can act, for the reason ``installSelfImage`` refuses a
  ## tree without its engine.
  let pkg = providerNimPin()
  if not fileExists(pinnedExecutableIn(pkg, sourceDir)):
    raise newException(ValueError,
      "repro self install --package=" & pkg.name & ": the source tree at " &
      sourceDir & " has no " & pinnedDeclaredExecutablePath(pkg) &
      "; a Nim image is the distribution directory that CONTAINS bin/" &
      pinnedExecutableName(pkg) & " and lib/, not the binary itself")
  if not fileExists(sourceDir / "lib" / "system.nim"):
    raise newException(ValueError,
      "repro self install --package=" & pkg.name & ": the source tree at " &
      sourceDir & " has " & pinnedDeclaredExecutablePath(pkg) &
      " but no lib/system.nim. The compiler resolves its standard library " &
      "relative to its own executable, so a prefix without lib/ cannot " &
      "compile a provider; install the whole Nim distribution directory")

proc realizePinnedTree(pkg: PinnedPackage;
                       storeRoot, version, platform, sourceDir: string):
    SelfInstallResult =
  result.version = version
  result.platform = platform
  result.storeAddress = storeAddressFor(pkg, version, platform)
  let hint = pinnedStoreReceiptHint(pkg, version, result.storeAddress)
  let prefixId = prefixIdFor(pkg, version, result.storeAddress)

  var store = openStore(storeRoot)
  defer: store.close()
  let realized = store.realizePrefix(prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      materializeViaHardlinkOrCopy(sourceDir, stagingDir, mechanism))
  result.prefixId = realized.prefixId
  result.relativePath = realized.relativePath.replace("\\", "/")
  result.absolutePath = realized.absolutePath
  result.executablePath = pinnedExecutableIn(pkg, realized.absolutePath)
  result.alreadyPresent = realized.outcome == roAlreadyPresent

proc installSelfImage*(storeRoot, version, platform, sourceDir: string):
    SelfInstallResult =
  ## Realize the reprobuild image tree at ``sourceDir`` into the store as
  ## version ``version`` for ``platform``.
  ##
  ## ``sourceDir`` must already be laid out the way a pin expects to find it
  ## — ``bin/repro`` AND ``bin/reprobuild``, plus whatever those images need
  ## beside them. Both, because they are two halves of one CLI: ``bin/repro``
  ## is the thin daemon client and cannot build on its own, and
  ## ``bin/reprobuild`` is the engine it hands every non-routable invocation
  ## to. A tree with only the first realizes cleanly and then cannot run a
  ## single command. The check is
  ## made HERE and refuses, rather than at exec time: a prefix that realizes
  ## cleanly and then cannot be executed is a store entry that satisfies
  ## every query and serves no invocation, and the pin that points at it
  ## fails on a machine and in a session far from the install that created
  ## it.
  if version.len == 0:
    raise newException(ValueError, "repro self install: version is required")
  if platform.len == 0:
    raise newException(ValueError, "repro self install: platform is required")
  if sourceDir.len == 0 or not dirExists(sourceDir):
    raise newException(ValueError,
      "repro self install: source tree does not exist: " & sourceDir)
  let sourceExe = selfExecutableIn(sourceDir)
  if not fileExists(sourceExe):
    raise newException(ValueError,
      "repro self install: the source tree at " & sourceDir &
      " has no " & selfDeclaredExecutablePath() &
      "; a reprobuild image is the directory that CONTAINS bin/" &
      selfExecutableName() & ", not the binary itself")

  # THE SECOND IMAGE, refused here for the reason stated above rather than at
  # exec time. `apps/repro-trampoline` hard-fails when a resolved prefix has no
  # engine beside its `bin/repro`; this is the check that makes reaching that
  # failure evidence of a modified or pre-check prefix rather than of a routine
  # configuration. Refusing in both places is deliberate: one of them is the
  # only one a person can act on before the prefix exists.
  let sourceEngine = sourceDir / "bin" / reprobuildEngineExeName()
  if not fileExists(sourceEngine):
    raise newException(ValueError,
      "repro self install: the source tree at " & sourceDir &
      " has bin/" & selfExecutableName() & " but no bin/" &
      reprobuildEngineExeName() &
      ". bin/" & selfExecutableName() & " is the thin daemon client; it " &
      "routes a quiet non-terminal `repro build` to the daemon and execs " &
      "bin/" & reprobuildEngineExeName() & " for everything else, so a " &
      "prefix without it answers every other invocation with \"no " &
      reprobuildEngineExeName() & " image to fall back to\". Build both " &
      "(`just build` / `scripts/build_apps.sh` produce both) before " &
      "installing this tree")

  realizePinnedTree(reprobuildPin(), storeRoot, version, platform, sourceDir)

proc installPinnedImage*(pkg: PinnedPackage;
                         storeRoot, version, platform, sourceDir: string):
    SelfInstallResult =
  ## Realize the image tree at ``sourceDir`` into the store as ``pkg``
  ## ``version`` for ``platform``, at the prefix a lock pinning exactly that
  ## identity resolves to. Each package's tree is validated first.
  if pkg.name == SelfPackageName:
    return installSelfImage(storeRoot, version, platform, sourceDir)
  if version.len == 0:
    raise newException(ValueError, "repro self install: version is required")
  if platform.len == 0:
    raise newException(ValueError, "repro self install: platform is required")
  if sourceDir.len == 0 or not dirExists(sourceDir):
    raise newException(ValueError,
      "repro self install: source tree does not exist: " & sourceDir)
  if pkg.name == ProviderNimPackageName:
    validateProviderNimTree(sourceDir)
  realizePinnedTree(pkg, storeRoot, version, platform, sourceDir)

proc attachPinRoot*(pkg: PinnedPackage; storeRoot, projectRoot: string;
                    prefixId: PrefixIdBytes): bool =
  ## Hold ``prefixId`` with ``projectRoot``'s pin root for ``pkg``.
  ## Returns false when the prefix is not indexed, which is the only way
  ## this can fail without the caller having done something wrong: a root
  ## may not hold a prefix the store does not have.
  var store = openStore(storeRoot)
  defer: store.close()
  if not store.lookupPrefix(prefixId).found:
    return false
  let rootId = pinRootIdFor(pkg, projectRoot)
  store.deleteRoot(rootId)
  store.registerRoot(rootId, rkPin)
  store.attachPrefixToRoot(rootId, prefixId)
  true

proc attachPinRoot*(storeRoot, projectRoot: string;
                    prefixId: PrefixIdBytes): bool =
  ## Hold ``prefixId`` with the reprobuild pin root belonging to
  ## ``projectRoot``.
  attachPinRoot(reprobuildPin(), storeRoot, projectRoot, prefixId)

proc dropPinRoot*(pkg: PinnedPackage; storeRoot, projectRoot: string) =
  var store = openStore(storeRoot)
  defer: store.close()
  store.deleteRoot(pinRootIdFor(pkg, projectRoot))

proc dropPinRoot*(storeRoot, projectRoot: string) =
  dropPinRoot(reprobuildPin(), storeRoot, projectRoot)

proc prunePinRoots*(storeRoot: string): seq[PinRootOutcome] =
  ## Re-derive every ``pin:reprobuild:*`` and ``pin:nim:*`` root from the
  ## lock it names.
  ##
  ## Runs before ``repro store gc``'s dead-set query, so a pin removed from a
  ## project's ``repro.lock`` makes that project's pinned version
  ## unreachable in the same command that collects it. Roots belonging to
  ## other kinds are untouched, and so are pin roots for packages nothing
  ## here knows how to re-derive.
  var store = openStore(storeRoot)
  defer: store.close()
  var pending: seq[tuple[rootId, projectRoot: string; pkg: PinnedPackage]] =
    @[]
  for row in store.listRoots():
    if row.kind != $rkPin:
      continue
    for pkg in [reprobuildPin(), providerNimPin()]:
      let projectRoot = projectRootFromPinRootId(pkg, row.rootId)
      if projectRoot.len > 0:
        pending.add((rootId: row.rootId, projectRoot: projectRoot, pkg: pkg))
        break

  for entry in pending:
    var outcome = PinRootOutcome(rootId: entry.rootId,
      projectRoot: entry.projectRoot)
    let held = store.prefixesHeldByRoot(entry.rootId)
    let pin = selfPinForProject(entry.projectRoot, entry.pkg)
    store.deleteRoot(entry.rootId)
    if pin.state != spsPinned:
      outcome.action = praDropped
      outcome.reason = pin.detail
      result.add(outcome)
      continue
    let prefixId = selfPrefixId(pin)
    if not store.lookupPrefix(prefixId).found:
      outcome.action = praDropped
      outcome.reason = "the project pins " & entry.pkg.name & " " &
        pin.version & " but no prefix for it is installed (" &
        prefixIdHex(prefixId) & ")"
      result.add(outcome)
      continue
    store.registerRoot(entry.rootId, rkPin)
    store.attachPrefixToRoot(entry.rootId, prefixId)
    outcome.prefixIdHex = prefixIdHex(prefixId)
    outcome.action =
      if held.len == 1 and held[0] == prefixId: praKept
      else: praRepointed
    outcome.reason = "pinned " & entry.pkg.name & " " & pin.version
    result.add(outcome)

proc listPinnedPrefixes*(pkg: PinnedPackage;
                         storeRoot: string): seq[PrefixRow] =
  ## Every ``pkg`` image a pin may resolve to, resident in the store.
  ## Filtered on the ADAPTER as well as the name so a package that merely
  ## happens to share the name and was put there by some other adapter is
  ## not offered to a pin.
  var store = openStore(storeRoot)
  defer: store.close()
  for row in store.listPrefixes():
    if row.packageName == pkg.name and row.adapter == pkg.adapter:
      result.add(row)

proc listSelfPrefixes*(storeRoot: string): seq[PrefixRow] =
  ## Every reprobuild image resident in the store.
  listPinnedPrefixes(reprobuildPin(), storeRoot)

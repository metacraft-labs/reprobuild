## M5 SELF-HOST — turning a project's COMMITTED reprobuild pin into a path in
## the content-addressed store.
##
## THE ONE IDEA. "reprobuild installs reprobuild" is not a new subsystem. A
## reprobuild release is a reprobuild package; a project that needs a
## particular one pins it the way it pins ``nim`` or ``gcc`` — a ``uses:``
## entry in the build graph, solved once, recorded in the committed
## ``repro.lock`` — and the launcher on ``PATH`` reads that pin and execs the
## matching image out of the store. There is no ``.reprobuild-version``, no
## ``.tool-versions``, and no field anywhere that only the launcher knows how
## to read. Everything this module does is arithmetic over ``repro.lock`` and
## ``repro_local_store``'s existing naming contract.
##
## THE CHAIN, END TO END, WITH THE OWNER OF EACH LINK.
##
## 1. The recipe declares the dependency and its provenance::
##
##      package myApp:
##        packageSource "reprobuild", "store"
##        uses:
##          "reprobuild >=0.1.4-m5a"
##
##    ``uses:`` is ``repro_project_dsl``'s ordinary dependency list;
##    ``packageSource`` is ``repro_dsl_stdlib/configurables/variants``.
##
## 2. ``repro lock refresh`` solves and writes ``repro.lock``. The solved
##    package lands in the ``packages`` sub-part, and because its source is
##    ``store``, ``repro_lock.lockedDepsFromPackages`` LIFTS it into ``deps``
##    as a first-class ``LockedDep`` with ``coord_kind = "store"``, a
##    ``store_hash`` from ``solvedPackageStoreHash(name, version, platform)``
##    and a ``blake3:<addr>`` integrity. Address and integrity are the same
##    value; that is what content-addressed means here.
##
## 3. This module reads that ``LockedDep`` (``selfPinForProject``) and
##    computes where the matching prefix lives (``selfPrefixId`` ->
##    ``selfPrefixRelativePath``), using the STORE's own
##    ``computeRealizationHash`` / ``prefixRelativePath``, not a private
##    scheme.
##
## 4. ``repro self install`` realizes an image there and attaches it to an
##    ``rkPin`` root named after the consuming project. ``repro store gc``
##    reclaims a prefix no root holds; ``prunePinRoots`` drops a pin root
##    whose project no longer pins what it holds, so deleting the pin is what
##    makes the version collectable.
##
## WHY THE PREFIX ID IS DERIVABLE FROM THE LOCK, AND WHY THAT IS NOT A CHEAT.
## ``computeRealizationHash`` is documented as an INPUT identity: "adapters
## compose the inputs that fully determine the bytes of the prefix". For this
## adapter the input that determines the bytes is the lock's own store
## address, which is itself the package's canonical solved identity
## (name + version + platform). So the launcher can name the prefix with no
## index lookup at all — the property that lets it stay thin — while the
## address it names is the one the lock committed to. A wrong version, a
## wrong platform or a tampered ``store_hash`` all produce a different
## directory, which is absent, which is a loud failure rather than a silently
## wrong exec.
##
## WHAT THIS MODULE DELIBERATELY DOES NOT IMPORT. Not ``repro_local_store``
## (SQLite), not the build engine, not the CLI. ``repro_lock`` plus the
## store's pure naming/hash pair is the whole dependency set, so the resolving
## launcher that links it starts without loading a database.

import std/[os, strutils]

import repro_lock
import repro_local_store/prefix_paths
import repro_local_store/realization_hash

export prefix_paths

const
  SelfPackageName* = "reprobuild"
    ## The package name a project pins. Deliberately the same string the
    ## repository's own root ``LockedDep`` already carries, and the same one
    ## ``uses:`` would name.

  SelfHostAdapter* = "reprobuild-self"
    ## The store adapter name recorded in the receipt of a realized
    ## reprobuild image. Distinct from ``nix`` / ``tarball`` / ``scoop`` /
    ## ``install-mirror`` so ``repro store list`` says what a prefix is, and
    ## so a reprobuild realized by some other adapter cannot be mistaken for
    ## one a pin may exec.

  PinRootPrefix* = "pin:reprobuild:"
    ## Prefix of the ``rkPin`` root id a consuming project gets. The
    ## remainder is the project root path, normalized and forward-slashed,
    ## which is what makes the root RE-CHECKABLE: ``prunePinRoots`` re-reads
    ## that project's lock and drops the root when the pin is gone. Same
    ## shape as Nix's indirect gc-roots, where the root is alive only while
    ## the thing it names still points somewhere.

  ResolvedEnvVar* = "REPRO_SELFHOST_RESOLVED"
    ## Set by the launcher to the prefix-id hex it exec'd, so a pinned image
    ## that re-enters the resolution path can see that resolution already
    ## happened and refuse to loop.

  CommittedLockFileName* = "repro.lock"

  ProviderNimPackageName* = "nim"
    ## The package name a project pins for the compiler that builds its
    ## PROVIDER (the binary compiled from ``repro.nim`` that reads the
    ## recipe). Reprobuild-specs Distribution-And-Packaging.milestones.org,
    ## M5 "pin the provider-compile toolchain", rule 1: "A project's lock may
    ## pin both the reprobuild version and the Nim compiler used to build its
    ## provider. Both are ordinary locked packages, realized into the store
    ## like any other." So it is the ordinary ``nim`` package, declared the
    ## same way the reprobuild pin is (``packageSource "nim", "store"`` beside
    ## a ``uses:`` entry), and only a STORE-sourced entry is a pin: the bare
    ## ``nim`` entry most locks already carry (this repository's own included)
    ## has no coordinate, pins nothing, and leaves the compile to the
    ## bootstrap's own Nim (rule 2).

  ProviderNimAdapter* = "reprobuild-provider-nim"
    ## Store adapter recorded in the receipt of a realized pinned Nim, for
    ## the same reason ``SelfHostAdapter`` exists: ``repro store list`` says
    ## what the prefix is, and a ``nim`` realized by an unrelated adapter (a
    ## package build's own tool, a scoop install) is never mistaken for the
    ## one a pin addresses.

type
  PinnedPackage* = object
    ## A package a project's committed lock may pin and a reprobuild resolves
    ## by ARITHMETIC over that lock: where its store prefix lives, which
    ## adapter realizes it, which executable a resolved prefix must hold.
    ##
    ## Two exist, and they are the two rule 1 names. Adding a field here
    ## rather than a second copy of the resolution code is the point: the
    ## tamper check, the prefix naming and the pin-root derivation are the
    ## same for both, and a second copy is how they would come to differ.
    name*: string
    adapter*: string
    executable*: string
      ## Base name, no extension: ``repro`` / ``nim``.

proc reprobuildPin*(): PinnedPackage =
  PinnedPackage(name: SelfPackageName, adapter: SelfHostAdapter,
    executable: "repro")

proc providerNimPin*(): PinnedPackage =
  PinnedPackage(name: ProviderNimPackageName, adapter: ProviderNimAdapter,
    executable: "nim")

proc pinnedPackageNamed*(name: string): PinnedPackage =
  ## The pinnable package called ``name``. Raises for any other name: a
  ## caller that asks for a package nothing here knows how to lay out would
  ## otherwise get a prefix computed under an empty adapter.
  case name
  of SelfPackageName: reprobuildPin()
  of ProviderNimPackageName: providerNimPin()
  else:
    raise newException(ValueError, "\"" & name & "\" is not a package a " &
      "project can pin for reprobuild itself; the pinnable packages are " &
      SelfPackageName & " and " & ProviderNimPackageName)

proc pinnedExecutableName*(pkg: PinnedPackage): string =
  addFileExt(pkg.executable, ExeExt)

proc pinnedDeclaredExecutablePath*(pkg: PinnedPackage): string =
  ## Prefix-relative image path, extension included. Folded into the
  ## realization hash, so it is spelled once.
  "bin/" & pinnedExecutableName(pkg)

proc pinnedExecutableIn*(pkg: PinnedPackage;
                         prefixAbsolutePath: string): string =
  prefixAbsolutePath / "bin" / pinnedExecutableName(pkg)

proc pinRootPrefixFor*(pkg: PinnedPackage): string =
  ## ``pin:<package>:``. For reprobuild this is ``PinRootPrefix``.
  "pin:" & pkg.name & ":"

proc constraintHint(pkg: PinnedPackage): string =
  ## How the remedy sentences spell the ``uses:`` entry. A reprobuild pin
  ## names a floor; a compiler pin names the exact version, because the
  ## version is what the provider compile's cache key moves with.
  if pkg.name == SelfPackageName: " >=<version>" else: " ==<version>"

type
  SelfPinState* = enum
    ## Why resolution answered the way it did. Every non-``spsPinned`` value
    ## is reported with its own sentence rather than collapsed into "no pin":
    ## "this project does not pin reprobuild" and "this project pins
    ## reprobuild but the pin carries no coordinate" are different situations
    ## with different remedies, and a launcher that says only the first when
    ## the second is true sends its user looking in the wrong place.
    spsNoProject        ## no `repro.lock` at or above the starting directory
    spsNoPin            ## the lock has no `reprobuild` package at all
    spsNotAddressable   ## pinned, but with a bare definition identity
    spsTampered         ## pinned with a coordinate that is not its content's
    spsPinned           ## pinned with a store coordinate

  SelfPin* = object
    ## A resolved (or unresolvable) reprobuild pin, plus where it was read.
    state*: SelfPinState
    projectRoot*: string
    lockPath*: string
    version*: string
    platform*: string
    storeHash*: string
      ## The lock's ``ckStore`` coordinate: the lowercase-hex BLAKE3 over the
      ## package's canonical solved identity.
    integrity*: string
      ## The lock's self-describing integrity, ``blake3:<storeHash>``.
    detail*: string
      ## A one-sentence explanation for the non-``spsPinned`` states, written
      ## for whoever has to act on it.
    package*: string
      ## Which pinnable package this pin is for (``SelfPackageName`` or
      ## ``ProviderNimPackageName``). Empty means reprobuild, so a value built
      ## by hand before this field existed keeps its meaning.
    archive*: LockedArchive
      ## The upstream archive the lock pins this version's bytes to, when
      ## ``repro lock refresh`` resolved one (today: a store-sourced ``nim``).
      ## Realization downloads it and verifies it against this digest; it is
      ## what lets a reprobuild realize a pinned compiler it does not already
      ## hold. Empty for a lock written before archive pins existed.

proc pinnedPackageOf*(pin: SelfPin): PinnedPackage =
  if pin.package.len == 0: reprobuildPin()
  else: pinnedPackageNamed(pin.package)

type
  StoreRootError* = object of CatchableError
    ## The per-user store root could not be resolved because the environment
    ## names no home. Raised rather than defaulted: a launcher that guesses a
    ## store root resolves a pin against the wrong store and execs the wrong
    ## image, and a wrong image is worse than a refusal.

const StoreRootEnvVar* = "REPRO_STORE_ROOT"

proc selfStoreRoot*(explicit = ""): string =
  ## The store root the launcher resolves against.
  ##
  ## A SECOND spelling of ``repro_local_store.resolveStoreRoot`` living here
  ## rather than an import of it, and the duplication is deliberate:
  ## ``repro_local_store`` carries the SQLite binding, and the whole claim of
  ## the resolving launcher is that it does not need a database to find the
  ## image a pin names. Four lines of environment lookup is a smaller cost
  ## than that dependency.
  ##
  ## The duplication is not left to trust. ``t_self_store_root_matches_the_
  ## store.nim`` drives both procs over the same set of environments —
  ## explicit override, env var, each platform default, and each
  ## nothing-is-set case — and asserts they agree, so the two cannot drift
  ## without a red test.
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv(StoreRootEnvVar)
  if fromEnv.len > 0:
    return fromEnv
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      return local / "repro" / "store"
    let home = getEnv("USERPROFILE")
    if home.len > 0:
      return home / "AppData" / "Local" / "repro" / "store"
    raise newException(StoreRootError,
      "neither LOCALAPPDATA nor USERPROFILE is set; cannot resolve a " &
      "per-user store root on Windows")
  elif defined(macosx):
    let home = getEnv("HOME")
    if home.len == 0:
      raise newException(StoreRootError,
        "HOME is not set; cannot resolve a per-user store root on macOS")
    return home / "Library" / "Caches" / "repro" / "store"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    let base =
      if xdg.len > 0: xdg
      else:
        let home = getEnv("HOME")
        if home.len == 0:
          raise newException(StoreRootError,
            "neither XDG_CACHE_HOME nor HOME is set; cannot resolve a " &
            "per-user store root")
        home / ".cache"
    return base / "repro" / "store"

proc selfExecutableName*(): string =
  ## ``repro`` with this platform's executable extension.
  addFileExt("repro", ExeExt)

proc selfDeclaredExecutablePath*(): string =
  ## The prefix-relative image path, extension included. Folded into the
  ## realization hash, so it is spelled once here.
  "bin/" & selfExecutableName()

proc selfLockIdentity*(storeHash: string): string =
  ## The ``lockIdentity`` this adapter folds into the realization hash: the
  ## lock's self-describing integrity spelling of the store address, so the
  ## value that decides the prefix says which algorithm produced it. Kept as
  ## a proc rather than inlined at the two call sites because the installer
  ## and the launcher MUST agree on it byte-for-byte or they name different
  ## directories.
  formatMultihash("blake3", storeHash)

proc findProjectRoot*(startDir: string): string =
  ## The nearest enclosing directory holding a committed ``repro.lock``, or
  ## "" when there is none.
  ##
  ## The lock is the marker rather than ``repro.nim`` on purpose: the lock is
  ## what carries the pin, and a recipe with no lock has nothing to resolve.
  ## A directory holding a recipe but no lock therefore answers "no project"
  ## with ``spsNoProject``, whose remedy sentence is ``repro lock refresh`` —
  ## the thing that would actually fix it.
  if startDir.len == 0:
    return ""
  var dir =
    try: absolutePath(startDir)
    except CatchableError: return ""
  while true:
    if fileExists(dir / CommittedLockFileName):
      return dir
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      return ""
    dir = parent

proc pinFromParsed*(ld: LockedDependencies; lockPath, projectRoot: string;
                    pkg: PinnedPackage): SelfPin =
  ## Read ``pkg``'s pin out of an already-parsed committed lock.
  ##
  ## The one resolution routine for every pinnable package: the lock is
  ## parsed once by the caller and each pin read from the same document, so
  ## the reprobuild pin and the compiler pin cannot be read from two
  ## different versions of a lock that changed between two reads.
  result = SelfPin(state: spsNoPin, projectRoot: projectRoot,
                   lockPath: lockPath, package: pkg.name)
  result.platform = ld.platform

  # The LIFTED entry is authoritative: it is the one that carries a
  # coordinate and an integrity. Prefer it over recomputing from `packages`,
  # because recomputing would make this module agree with itself rather than
  # with the lock.
  for dep in ld.deps:
    if dep.name != pkg.name:
      continue
    if dep.coordinates.kind != ckStore:
      continue
    result.version = dep.version
    result.storeHash = dep.coordinates.storeHash
    result.integrity = dep.integrity
    result.archive = dep.archive
    if result.version.len == 0 or result.storeHash.len == 0:
      result.state = spsNotAddressable
      result.detail = "the committed lock at " & lockPath & " records a " &
        "store-coordinate dependency on " & pkg.name &
        " whose version or store hash is empty; regenerate it with " &
        "`repro lock refresh`"
      return

    # THE COORDINATE IS CHECKED AGAINST ITS OWN CONTENT.
    #
    # `ckStore` is content-addressed: `store_hash` is not a label attached to
    # the entry, it is a BLAKE3 over the entry's canonical solved identity
    # (name + version + platform), and `integrity` is that same value tagged
    # with the algorithm that produced it. So the lock states its own
    # checksum, and a reader that takes it on trust is not reading a
    # content-addressed coordinate at all -- it is reading a path with a hash
    # painted on it.
    #
    # Without this, the only thing standing between a hand-edited lock and an
    # exec was that the address it names happens to be absent from the store.
    # That is a coincidence, not a check, and it fails in the direction that
    # matters: the diagnosis a user gets is "that version is not installed",
    # which sends them to `repro self install` -- to INSTALL the version the
    # edit invented -- when the truth is that the lock no longer says what
    # `repro lock refresh` wrote. Worse, on a host where something else had
    # already realized a prefix at the forged address, the same edit would
    # silently succeed.
    #
    # Recomputed from the LOCK's OWN fields (its version, its platform),
    # never from the running image or the host, so the check is a statement
    # about the document's internal consistency and answers the same way on
    # every machine. An empty `platform` therefore fails too, which is
    # correct: a lock that does not say which platform it solved for has not
    # committed to an address.
    let expectedHash = solvedPackageStoreHash(pkg.name,
      result.version, result.platform)
    let expectedIntegrity = formatMultihash("blake3", expectedHash)
    if result.storeHash != expectedHash or result.integrity != expectedIntegrity:
      result.state = spsTampered
      result.detail = "the committed lock at " & lockPath & " pins " &
        pkg.name & " " & result.version & " for platform \"" &
        result.platform & "\" with store address " & result.storeHash &
        " (integrity " & result.integrity & "), but that identity addresses " &
        expectedHash & " (integrity " & expectedIntegrity & "). A " &
        "content-addressed coordinate that disagrees with its own content " &
        "was not written by `repro lock refresh` -- editing a version in " &
        "repro.lock by hand does not move the pin. Restore the committed " &
        "lock, or change the recipe's uses: constraint and re-run " &
        "`repro lock refresh`."
      return

    result.state = spsPinned
    return

  for p in ld.packages:
    if p.name != pkg.name:
      continue
    result.version = p.version
    result.state = spsNotAddressable
    result.detail = "the committed lock at " & lockPath & " pins " &
      pkg.name & " " & p.version & " with the bare definition " &
      "identity source=\"" & p.source & "\", which carries no " &
      "coordinate, so there is nothing to resolve in the store. Declare " &
      "packageSource \"" & pkg.name & "\", \"store\" in the " &
      "recipe's package block and re-run `repro lock refresh`."
    return

  result.detail = "the committed lock at " & lockPath & " does not pin " &
    pkg.name & "; add a uses: \"" & pkg.name & constraintHint(pkg) &
    "\" entry (with packageSource \"" & pkg.name &
    "\", \"store\") to the recipe and run `repro lock refresh`"

proc unreadableLockPin(lockPath, projectRoot, why: string;
                       pkg: PinnedPackage): SelfPin =
  SelfPin(state: spsNoProject, projectRoot: projectRoot, lockPath: lockPath,
    package: pkg.name,
    detail: "the committed lock at " & lockPath & " could not be read (" &
      why & "); regenerate it with `repro lock refresh`")

proc pinFromLockText*(text, lockPath, projectRoot: string;
                      pkg: PinnedPackage): SelfPin =
  ## Read ``pkg``'s pin out of committed-lock BYTES.
  ##
  ## Split from ``selfPinForProject`` so the property "a lock with a
  ## store-sourced package resolves, and one with a bare definition identity
  ## does not" is testable on bytes, with no filesystem and no store.
  var ld: LockedDependencies
  try:
    ld = parseLockedDependencies(text)
  except CatchableError as err:
    return unreadableLockPin(lockPath, projectRoot, err.msg, pkg)
  pinFromParsed(ld, lockPath, projectRoot, pkg)

proc pinFromLockText*(text, lockPath, projectRoot: string): SelfPin =
  ## The reprobuild pin out of committed-lock bytes.
  pinFromLockText(text, lockPath, projectRoot, reprobuildPin())

proc noLockPin(projectRoot: string; pkg: PinnedPackage): (SelfPin, string) =
  ## ``(pin, "")`` when there is no lock to read, else ``(_, lockPath)``.
  if projectRoot.len == 0:
    return (SelfPin(state: spsNoProject, package: pkg.name,
      detail: "no enclosing project: no " & CommittedLockFileName &
        " was found at or above the working directory"), "")
  let lockPath = projectRoot / CommittedLockFileName
  if not fileExists(lockPath):
    return (SelfPin(state: spsNoProject, projectRoot: projectRoot,
      lockPath: lockPath, package: pkg.name,
      detail: "no committed lock at " & lockPath &
        "; run `repro lock refresh` in " & projectRoot), "")
  (SelfPin(), lockPath)

proc selfPinForProject*(projectRoot: string; pkg: PinnedPackage): SelfPin =
  ## ``pkg``'s pin committed by the project rooted at ``projectRoot``.
  let (absent, lockPath) = noLockPin(projectRoot, pkg)
  if lockPath.len == 0:
    return absent
  pinFromLockText(readFile(lockPath), lockPath, projectRoot, pkg)

proc selfPinForProject*(projectRoot: string): SelfPin =
  ## The reprobuild pin committed by the project rooted at ``projectRoot``.
  selfPinForProject(projectRoot, reprobuildPin())

proc selfPinFrom*(startDir: string): SelfPin =
  ## ``findProjectRoot`` + ``selfPinForProject``, the pair the launcher runs.
  selfPinForProject(findProjectRoot(startDir))

type
  ProjectPins* = object
    ## Every pin one committed lock makes, read from ONE parse of it.
    projectRoot*: string
    lockPath*: string
    reprobuild*: SelfPin
    providerNim*: SelfPin

proc projectPinsFor*(projectRoot: string): ProjectPins =
  ## Rule 1's two pins for the project rooted at ``projectRoot``.
  result.projectRoot = projectRoot
  let (absent, lockPath) = noLockPin(projectRoot, reprobuildPin())
  if lockPath.len == 0:
    result.reprobuild = absent
    result.providerNim = noLockPin(projectRoot, providerNimPin())[0]
    return
  result.lockPath = lockPath
  var ld: LockedDependencies
  try:
    ld = parseLockedDependencies(readFile(lockPath))
  except CatchableError as err:
    result.reprobuild = unreadableLockPin(lockPath, projectRoot, err.msg,
      reprobuildPin())
    result.providerNim = unreadableLockPin(lockPath, projectRoot, err.msg,
      providerNimPin())
    return
  result.reprobuild = pinFromParsed(ld, lockPath, projectRoot, reprobuildPin())
  result.providerNim = pinFromParsed(ld, lockPath, projectRoot,
    providerNimPin())

proc projectPinsFrom*(startDir: string): ProjectPins =
  projectPinsFor(findProjectRoot(startDir))

proc storeAddressFor*(pkg: PinnedPackage; version, platform: string): string =
  ## The store address the LOCK would record for ``pkg`` at this identity.
  solvedPackageStoreHash(pkg.name, version, platform)

proc storeAddressFor*(version, platform: string): string =
  ## The store address the LOCK would record for this identity. Exposed so an
  ## installer can address a version it is about to realize before any lock
  ## names it, and so a test can assert the two agree.
  storeAddressFor(reprobuildPin(), version, platform)

proc prefixIdFor*(pkg: PinnedPackage; version, storeHash: string):
    PrefixIdBytes =
  ## The store prefix id for a pinned ``pkg``. For reprobuild this is exactly
  ## the value it has always been (same name, adapter and executable path
  ## folded in), so no existing pin is re-addressed.
  computeRealizationHash(pkg.name, version, pkg.adapter,
    selfLockIdentity(storeHash), pinnedDeclaredExecutablePath(pkg))

proc prefixIdFor*(version, storeHash: string): PrefixIdBytes =
  ## The store prefix id for a pinned reprobuild image.
  prefixIdFor(reprobuildPin(), version, storeHash)

proc selfPrefixId*(pin: SelfPin): PrefixIdBytes =
  prefixIdFor(pinnedPackageOf(pin), pin.version, pin.storeHash)

proc prefixRelativePathFor*(pkg: PinnedPackage; version,
                            storeHash: string): string =
  prefixRelativePath(pkg.name, version, prefixIdFor(pkg, version, storeHash))

proc prefixRelativePathFor*(version, storeHash: string): string =
  prefixRelativePathFor(reprobuildPin(), version, storeHash)

proc selfPrefixRelativePath*(pin: SelfPin): string =
  ## ``prefixes/<package>/<version>-<hash16>``, from the store's own
  ## arithmetic.
  prefixRelativePathFor(pinnedPackageOf(pin), pin.version, pin.storeHash)

proc selfPrefixAbsolutePath*(storeRoot: string; pin: SelfPin): string =
  storeRoot / selfPrefixRelativePath(pin)

proc selfExecutableIn*(prefixAbsolutePath: string): string =
  prefixAbsolutePath / "bin" / selfExecutableName()

proc normalizedProjectKey(projectRoot: string): string =
  ## Forward-slashed, and lower-cased on Windows, so the same project reached
  ## through two spellings of its path is one root rather than two. A second
  ## root for the same project would keep a superseded version alive after
  ## the pin moved, which is precisely the leak ``repro store gc`` exists to
  ## stop.
  var p = projectRoot
  try:
    p = absolutePath(projectRoot)
  except CatchableError:
    discard
  p = p.replace('\\', '/')
  while p.len > 1 and p.endsWith("/"):
    p.setLen(p.len - 1)
  when defined(windows):
    p = p.toLowerAscii()
  p

proc pinRootIdFor*(pkg: PinnedPackage; projectRoot: string): string =
  ## The ``rkPin`` root id holding ``pkg`` for a consuming project:
  ## ``pin:<package>:<project>``.
  pinRootPrefixFor(pkg) & normalizedProjectKey(projectRoot)

proc pinRootIdFor*(projectRoot: string): string =
  ## The ``rkPin`` root id for a consuming project's reprobuild pin.
  pinRootIdFor(reprobuildPin(), projectRoot)

proc projectRootFromPinRootId*(pkg: PinnedPackage; rootId: string): string =
  ## The inverse of ``pinRootIdFor(pkg, _)``, or "" when ``rootId`` is not a
  ## pin root for ``pkg``.
  let prefix = pinRootPrefixFor(pkg)
  if not rootId.startsWith(prefix):
    return ""
  rootId[prefix.len .. ^1]

proc projectRootFromPinRootId*(rootId: string): string =
  ## The inverse of ``pinRootIdFor``, or "" when ``rootId`` is not a pin root.
  projectRootFromPinRootId(reprobuildPin(), rootId)

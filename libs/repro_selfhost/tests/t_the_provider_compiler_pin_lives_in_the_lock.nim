## M5 "pin the provider-compile toolchain", rule 1: a project's lock may pin
## the Nim compiler that builds its provider, and that pin is an ORDINARY
## locked package realized into the store like any other.
##
## THE PROPERTIES, EACH WITH THE DEFECT IT CATCHES:
##
##   * a store-sourced `nim` entry resolves to a pin, read from the same
##     document and by the same routine as the reprobuild pin. Catches a
##     second, private reader for the compiler that could disagree with the
##     first about the same bytes;
##   * the bare `nim` entry every existing lock carries (this repository's
##     own included) is NOT a pin. Catches the change of meaning that would
##     make every committed lock suddenly demand a compiler nobody pinned;
##   * a hand-edited compiler version is refused as tampered, like the
##     reprobuild pin;
##   * the compiler prefix and the reprobuild prefix at the same version are
##     different directories, and the reprobuild prefix is EXACTLY what it
##     was before compiler pins existed. Catches re-addressing every
##     installed reprobuild image as a side effect of the generalization;
##   * a Nim tree without its standard library is refused at install time;
##   * the compiler's pin root is re-derived by `prunePinRoots` like the
##     reprobuild one, so removing the pin makes the compiler collectable.
##
## Test-double policy: no mocks. Locks come from the real `repro_lock` writer
## and MO-11 lift (what `repro lock refresh` writes); the store is a real
## `repro_local_store` on a temp directory.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_lock
import repro_local_store
import repro_local_store/realization_hash
import repro_selfhost
import repro_selfhost/install

const Platform = "amd64-linux"

proc lockBytes(packages: openArray[(string, string, string)]): string =
  ## (name, version, source) -> committed lock bytes.
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version, _) in packages:
    sol.packages[name] = version
  var ld = lockedDepsFromSolved(solutionToLock(sol, Platform, ""))
  for i in 0 ..< ld.packages.len:
    for (name, _, source) in packages:
      if ld.packages[i].name == name:
        ld.packages[i].source = source
  ld.deps = lockedDepsFromPackages(ld.packages, Platform)
  serializeLockedDependencies(ld)

proc makeNimTree(dir, marker: string; withLib = true): string =
  createDir(dir / "bin")
  writeFile(dir / "bin" / addFileExt("nim", ExeExt), "nim " & marker & "\n")
  if withLib:
    createDir(dir / "lib")
    writeFile(dir / "lib" / "system.nim", "# system " & marker & "\n")
  dir

suite "the provider compiler pin is an ordinary locked package":

  test "a store-sourced nim entry is a pin, read from the same lock parse":
    let text = lockBytes([("nim", "2.2.10", "store"),
                          ("reprobuild", "0.2.9", "store")])
    check text.contains("name = \"nim\"")
    let dir = createTempDir("repro-m5-nimpin-", "")
    defer: removeDir(dir)
    writeFile(dir / "repro.lock", text)
    let pins = projectPinsFor(dir)
    check pins.providerNim.state == spsPinned
    check pins.providerNim.version == "2.2.10"
    check pins.providerNim.package == ProviderNimPackageName
    check pins.providerNim.storeHash ==
      solvedPackageStoreHash("nim", "2.2.10", Platform)
    check pins.reprobuild.state == spsPinned
    check pins.reprobuild.version == "0.2.9"
    # The single-package reader answers the same as the one-parse reader.
    let alone = selfPinForProject(dir, providerNimPin())
    check alone.state == pins.providerNim.state
    check alone.storeHash == pins.providerNim.storeHash

  test "the bare nim entry existing locks carry is not a pin":
    let text = lockBytes([("nim", "2.2.0", "nim")])
    let pin = pinFromLockText(text, "repro.lock", ".", providerNimPin())
    check pin.state == spsNotAddressable
    check pin.detail.contains("packageSource \"nim\", \"store\"")

  test "a lock with no nim at all says so, naming an exact-version uses entry":
    let text = lockBytes([("reprobuild", "0.2.9", "store")])
    let pin = pinFromLockText(text, "repro.lock", ".", providerNimPin())
    check pin.state == spsNoPin
    check pin.detail.contains("does not pin nim")
    check pin.detail.contains("nim ==<version>")

  test "a hand-edited compiler version is refused as tampered":
    let honest = lockBytes([("nim", "2.2.10", "store")])
    let edited = honest.replace("version = \"2.2.10\"",
      "version = \"2.2.12\"")
    check edited != honest
    let pin = pinFromLockText(edited, "repro.lock", ".", providerNimPin())
    check pin.state == spsTampered
    check pin.detail.contains("was not written by `repro lock refresh`")
    # ...and the reprobuild pin of the same document is untouched by it.
    check pinFromLockText(edited, "repro.lock", ".").state == spsNoPin

suite "the compiler prefix is store arithmetic, and reprobuild's did not move":

  test "the reprobuild prefix id is exactly its pre-generalization value":
    let h = storeAddressFor("0.2.9", Platform)
    let expected = computeRealizationHash("reprobuild", "0.2.9",
      "reprobuild-self", "blake3:" & h, "bin/" & addFileExt("repro", ExeExt))
    check prefixIdFor("0.2.9", h) == expected
    check prefixIdFor(reprobuildPin(), "0.2.9", h) == expected

  test "the compiler and reprobuild prefixes at one version differ":
    let nimH = storeAddressFor(providerNimPin(), "2.2.10", Platform)
    let rbH = storeAddressFor(reprobuildPin(), "2.2.10", Platform)
    check nimH != rbH
    let nimRel = prefixRelativePathFor(providerNimPin(), "2.2.10", nimH)
    check nimRel.replace('\\', '/').startsWith("prefixes/nim/2.2.10-")
    check nimRel != prefixRelativePathFor(reprobuildPin(), "2.2.10", rbH)

  test "pin root ids are per package and invert":
    let project = getTempDir() / "some-project"
    let nimRoot = pinRootIdFor(providerNimPin(), project)
    check nimRoot.startsWith("pin:nim:")
    check pinRootIdFor(project).startsWith(PinRootPrefix)
    check projectRootFromPinRootId(providerNimPin(), nimRoot).len > 0
    # A nim root is not mistaken for a reprobuild root, or vice versa.
    check projectRootFromPinRootId(nimRoot) == ""
    check projectRootFromPinRootId(providerNimPin(),
      pinRootIdFor(project)) == ""

suite "a pinned compiler is realized into the store and held like any pin":

  test "a Nim tree without lib/system.nim is refused at install time":
    let root = createTempDir("repro-m5-nimtree-", "")
    defer: removeDir(root)
    createDir(root / "store")
    let bare = makeNimTree(root / "bare", "2.2.10", withLib = false)
    expect ValueError:
      discard installPinnedImage(providerNimPin(), root / "store", "2.2.10",
        Platform, bare)
    check listPinnedPrefixes(providerNimPin(), root / "store").len == 0

  test "an installed compiler is where the lock's pin resolves":
    let root = createTempDir("repro-m5-nimtree-", "")
    defer: removeDir(root)
    let store = root / "store"
    createDir(store)
    let project = root / "proj"
    createDir(project)
    writeFile(project / "repro.lock", lockBytes([("nim", "2.2.10", "store")]))
    let res = installPinnedImage(providerNimPin(), store, "2.2.10", Platform,
      makeNimTree(root / "nim-2.2.10", "2.2.10"))
    let pin = selfPinForProject(project, providerNimPin())
    check pin.state == spsPinned
    check res.prefixId == selfPrefixId(pin)
    check res.executablePath ==
      pinnedExecutableIn(providerNimPin(), selfPrefixAbsolutePath(store, pin))
    check fileExists(res.executablePath)
    check fileExists(selfPrefixAbsolutePath(store, pin) / "lib" / "system.nim")
    # Listed under its own adapter, and not offered as a reprobuild image.
    check listPinnedPrefixes(providerNimPin(), store).len == 1
    check listSelfPrefixes(store).len == 0

  test "removing the compiler pin drops its root on the next re-derivation":
    let root = createTempDir("repro-m5-nimroot-", "")
    defer: removeDir(root)
    let store = root / "store"
    createDir(store)
    let project = root / "proj"
    createDir(project)
    writeFile(project / "repro.lock", lockBytes([("nim", "2.2.10", "store")]))
    discard installPinnedImage(providerNimPin(), store, "2.2.10", Platform,
      makeNimTree(root / "nim-2.2.10", "2.2.10"))
    let pin = selfPinForProject(project, providerNimPin())
    check attachPinRoot(providerNimPin(), store, project, selfPrefixId(pin))

    var outcomes = prunePinRoots(store)
    check outcomes.len == 1
    check outcomes[0].rootId == pinRootIdFor(providerNimPin(), project)
    check outcomes[0].action == praKept

    writeFile(project / "repro.lock", lockBytes([("nim", "2.2.10", "nim")]))
    outcomes = prunePinRoots(store)
    check outcomes.len == 1
    check outcomes[0].action == praDropped
    var store2 = openStore(store)
    defer: store2.close()
    for row in store2.listRoots():
      check row.rootId != pinRootIdFor(providerNimPin(), project)

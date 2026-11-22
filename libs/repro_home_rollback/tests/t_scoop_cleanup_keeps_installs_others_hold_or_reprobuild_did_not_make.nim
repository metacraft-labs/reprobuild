## A home-generation transition that drops a Scoop package must not delete
## Scoop installs that something else still uses: a version another store
## root holds, a version Reprobuild only adopted, or anything at all unless
## the operator asked for the cleanup (reprobuild-pm
## `spec/Scoop-Catalog-Adapter.md` §"Install Provenance" and §"Opt-In
## Cleanup Governed by Store GC Roots").
##
## Regression test for reprobuild-pm
## `issues/2026-11-12-scoop-eager-cleanup-deletes-every-version-including-installs-reprobuild-only-adopted-and.md`.
## Before the fix, `repro home apply` and `repro home rollback` ran
## `scoop uninstall <app>` (which removes EVERY version) whenever the dropped
## record's own prefix had no non-profile holder, by default, and with no
## notion of who installed the app. Each case below names the deletion that
## code made:
##
## * no `--uninstall-from-scoop`: rollback and apply leave Scoop untouched
##   (before: the app was uninstalled; `--plan` previewed `destroy`);
## * with the flag, a version Reprobuild did not install (adopted as a
##   cache-hit) is kept (before: uninstalled);
## * with the flag, a `workspace` root holding `ripgrep@14.0` keeps the whole
##   app while the generation drops `ripgrep@14.1` (before: the hold check
##   looked only at the 14.1 prefix, then uninstalled every version), and so
##   does a hold on the same app spelled in another case;
## * with the flag and a mix of installs, only Reprobuild's non-current
##   versions go; the adopted one and Scoop's `current` stay (before: all);
## * a ledger record does not survive the user reinstalling the version
##   themselves (the directory identity no longer matches);
## * positive control: with the flag, an app every version of which
##   Reprobuild installed and nothing holds IS removed, and its ledger
##   records are dropped.
##
## Regression test for reprobuild-pm
## `issues/2026-11-19-scoop-cleanup-does-not-count-a-generation-of-another-state-directory-as-a-holder.md`.
## Several state directories can use one store, each holding its
## generations through `profile` roots of its own
## (`home/<state-dir-key>/<generation-id>`). Before the fix the cleanup
## skipped EVERY `profile` root as a holder, so a transition with the flag
## in one state directory uninstalled an app another state directory's
## current generation still uses. The cases:
##
## * a rollback in state directory A keeps the install B's current
##   generation holds, both when the two generation ids differ and when
##   they are equal (generation ids are content-addressed, so the same
##   profile applied in both collides);
## * an apply in A: `--plan` previews `skip` naming B's root
##   (`home/<B-key>/<id> (profile)`), and the apply keeps the install;
## * a `profile` root an earlier build registered under a bare generation
##   id that A has no generation for is a holder;
## * positive control: a bare-id root for a generation A itself holds is
##   A's own, not a holder, and the app is removed.
##
## Production paths: `runRollback`, `runApplyPlan` and `runApply` run
## unmodified against a real store (`index.db`, CAS), a real state directory
## and a real sandboxed Scoop root on disk.
##
## Fixtures, and why they are not the real thing:
##
## * The previous generation is written with `writeGeneration` (the
##   production generation writer) rather than produced by a Scoop
##   realization, because `realizeScoopTool` is Windows-only and needs a
##   real `scoop.exe`. What a Scoop realization leaves behind for removal to
##   read is exactly what the fixture writes: a `RealizedPackage` with
##   `adapter = "scoop"` and `scoop:<bucket>/<app>@<version>` provenance, a
##   `scoop.<bucket>.<app>` prefix row, the generation's `profile` root, and
##   -- when Reprobuild ran the install -- a ledger row in `index.db`
##   written by the production `recordScoopInstall`.
## * The Scoop CLI is absent (`REPRO_TEST_SCOOP_OVERRIDE` names a file that
##   does not exist), so a whole-app uninstall takes `uninstallScoopApp`'s
##   no-CLI branch, which removes `<scoopRoot>/apps/<app>` itself. The
##   decision under test -- whether to remove, and what -- is made before
##   that branch and does not depend on the CLI.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import blake3

import repro_home_apply
import repro_home_generations
import repro_home_rollback
import repro_local_store
import repro_tool_profiles
from repro_test_support import testCaseScratchSlug

let FixtureRoot = absolutePath("build/test-tmp/t-scoop-cleanup" /
  testCaseScratchSlug())

type Fixture = object
  root, stateDir, storeRoot, scoopRoot, profileDir, homeDir: string

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc newFixture(name: string): Fixture =
  result.root = FixtureRoot / name
  resetDir(result.root)
  result.stateDir = result.root / "state"
  result.storeRoot = result.root / "store"
  result.scoopRoot = result.root / "scoop"
  result.profileDir = result.root / "profile"
  result.homeDir = result.root / "home"
  for d in [result.stateDir, result.storeRoot, result.scoopRoot,
            result.profileDir, result.homeDir]:
    createDir(extendedPath(d))
  # A profile with no packages: applying it drops every Scoop package the
  # previous generation recorded.
  writeFile(extendedPath(result.profileDir / "home.nim"),
    "import repro/profile\n\nprofile \"scoopDrop\":\n  activity default:\n")
  putEnv("SCOOP", result.scoopRoot)
  putEnv("REPRO_TEST_SCOOP_OVERRIDE", result.root / "no-such-scoop.exe")
  putEnv("REPRO_CACHE_DISABLE", "1")
  putEnv("REPRO_HOME_POSIX_PATH_RC", result.homeDir / ".profile-path-rc")

proc appDir(f: Fixture; app: string): string =
  f.scoopRoot / "apps" / app

proc installVersion(f: Fixture; app, version: string) =
  ## A Scoop version directory as `scoop install` leaves it.
  let dir = f.appDir(app) / version
  createDir(extendedPath(dir))
  writeFile(extendedPath(dir / (app & ".exe")), app & " " & version)
  writeFile(extendedPath(dir / "manifest.json"),
    "{\"version\": \"" & version & "\", \"bin\": \"" & app & ".exe\"}")

proc pointCurrentAt(f: Fixture; app, version: string) =
  ## Scoop's `current` link (a junction on Windows, a symlink here).
  let link = f.appDir(app) / "current"
  createSymlink(f.appDir(app) / version, link)

proc markInstalledByReprobuild(f: Fixture; app, version: string) =
  recordScoopInstall(f.storeRoot, f.scoopRoot, "main", app, version)

proc blake3Digest32(text: string): Digest256 =
  let d = blake3.digest(text)
  for i in 0 ..< 32:
    result[i] = d[i]

proc prefixIdFor(app, version: string): PrefixIdBytes =
  let d = blake3Digest32("scoop-prefix:" & app & "@" & version)
  for i in 0 ..< 32:
    result[i] = d[i]

proc toDigest(p: PrefixIdBytes): Digest256 =
  for i in 0 ..< 32:
    result[i] = p[i]

proc registerScoopPrefix(store: var Store; f: Fixture;
                         app, version: string): PrefixIdBytes =
  ## The store prefix a Scoop realization registers (`scoop.<bucket>.<app>`).
  result = prefixIdFor(app, version)
  let rel = "prefixes/scoop.main." & app & "/" & version & "-fixture"
  createDir(extendedPath(f.storeRoot / rel))
  discard store.insertPrefixOrIgnore(PrefixRow(prefixId: result,
    packageName: "scoop.main." & app, version: version, realizedPath: rel,
    adapter: "scoop", receiptDigest: result, createdAtUnix: 1000))

proc writeGenIn(f: Fixture; stateDir: string; store: var Store; tag: string;
                timestamp: int64;
                scoopRecords: openArray[(string, string)]): string =
  ## One generation of `stateDir` recording `scoopRecords`
  ## (`(app, version)`) as Scoop packages. Returns its hex id.
  var manifest = ActivationManifest(schemaVersion: 1'u16)
  var envelope = PointerEnvelope(schemaVersion: 1'u16,
    activationTimestamp: timestamp, hostIdentity: "fixture-host")
  for (app, version) in scoopRecords:
    let pid = registerScoopPrefix(store, f, app, version)
    var provenance: seq[byte]
    for ch in "scoop:main/" & app & "@" & version:
      provenance.add(byte(ch))
    manifest.realizedPackages.add(RealizedPackage(packageId: app,
      realizedPrefixId: toDigest(pid), adapter: "scoop",
      provenance: provenance))
    envelope.realizedPrefixIds.add(toDigest(pid))
  var snapshot: seq[byte]
  for ch in tag:
    snapshot.add(byte(ch))
  envelope.generationId = computeGenerationId(
    blake3Digest32(tag), "fixture-host", timestamp)
  writeGeneration(stateDir, envelope, encodeManifest(manifest), snapshot,
    snapshot, store)
  generationIdHex(envelope.generationId)

proc writeGen(f: Fixture; store: var Store; tag: string; timestamp: int64;
              scoopRecords: openArray[(string, string)]): string =
  ## `writeGenIn` for the fixture's own state directory.
  writeGenIn(f, f.stateDir, store, tag, timestamp, scoopRecords)

proc otherStateDir(f: Fixture): string =
  ## A second state directory using the same store (another container,
  ## another `REPRO_HOME_STATE_DIR`).
  result = f.root / "state-b"
  createDir(extendedPath(result))

type StoreSetup = proc (store: var Store; currentId: string)

proc rollbackDroppingRipgrep(f: Fixture; uninstallFromScoop: bool;
                             currentVersion = "14.1";
                             holdByWorkspace = "";
                             holdAppSpelling = "ripgrep";
                             extraSetup: StoreSetup = nil) =
  ## Current generation records ripgrep@`currentVersion`; the target (older)
  ## generation records nothing, so the rollback drops ripgrep. When
  ## `holdByWorkspace` names a version, a `workspace` root holds that
  ## version's prefix (a project lock still using it), registered under
  ## the app name `holdAppSpelling`. `extraSetup` runs on the open store
  ## after both generations are written, with the current one's id.
  var store = openStore(f.storeRoot)
  let target = writeGen(f, store, "target", 1000, [])
  let current = writeGen(f, store, "current", 2000,
    [("ripgrep", currentVersion)])
  if extraSetup != nil:
    extraSetup(store, current)
  if holdByWorkspace.len > 0:
    let held = registerScoopPrefix(store, f, holdAppSpelling,
      holdByWorkspace)
    store.registerRoot("ws-project-a", rkWorkspace)
    store.attachPrefixToRoot("ws-project-a", held)
  store.close()
  writeCurrentGenerationId(f.stateDir, current)
  discard runRollback(RollbackOptions(stateDir: f.stateDir,
    storeRoot: f.storeRoot, homeDir: f.homeDir, host: "fixture-host",
    targetGenerationId: target, uninstallFromScoop: uninstallFromScoop))

proc ledgerRecords(f: Fixture; app: string): int =
  ## The install-ledger rows (`index.db` `adapter_installs`) for `app`.
  var store = openStore(f.storeRoot)
  defer: store.close()
  store.recordedScoopInstalls(f.scoopRoot, app).len

proc installedByReprobuild(f: Fixture; app, version: string): bool =
  var store = openStore(f.storeRoot)
  defer: store.close()
  scoopVersionInstalledByReprobuild(store, f.scoopRoot, app, version)

suite "dropping a Scoop package keeps the installs others hold or " &
      "Reprobuild did not make":

  test "rollback without --uninstall-from-scoop leaves Scoop untouched":
    let f = newFixture("rollback-default")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    rollbackDroppingRipgrep(f, uninstallFromScoop = false)
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "with the flag, a version Reprobuild only adopted is kept":
    let f = newFixture("rollback-adopted")
    f.installVersion("ripgrep", "14.1")   # no ledger record: adopted
    rollbackDroppingRipgrep(f, uninstallFromScoop = true)
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "with the flag, a workspace holding 14.0 keeps the app while the " &
       "generation drops 14.1":
    let f = newFixture("rollback-held-other-version")
    f.installVersion("ripgrep", "14.0")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.0")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    rollbackDroppingRipgrep(f, uninstallFromScoop = true,
      holdByWorkspace = "14.0")
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.0"))
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "with the flag, a hold on the app spelled in another case still " &
       "keeps it":
    # Scoop's app directories are on a case-insensitive file system, so a
    # workspace that realized `Ripgrep` holds the same install.
    let f = newFixture("rollback-held-other-case")
    f.installVersion("ripgrep", "14.0")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.0")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    rollbackDroppingRipgrep(f, uninstallFromScoop = true,
      holdByWorkspace = "14.0", holdAppSpelling = "Ripgrep")
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.0"))
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "with the flag and mixed installs, only Reprobuild's non-current " &
       "versions are removed":
    let f = newFixture("rollback-mixed")
    f.installVersion("ripgrep", "13.0")   # the user's, and Scoop's current
    f.installVersion("ripgrep", "14.1")   # Reprobuild's
    f.installVersion("ripgrep", "14.2")   # Reprobuild's
    f.markInstalledByReprobuild("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.2")
    f.pointCurrentAt("ripgrep", "13.0")
    rollbackDroppingRipgrep(f, uninstallFromScoop = true)
    check dirExists(extendedPath(f.appDir("ripgrep") / "13.0"))
    check dirExists(extendedPath(f.appDir("ripgrep") / "current"))
    check not dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))
    check not dirExists(extendedPath(f.appDir("ripgrep") / "14.2"))
    check f.ledgerRecords("ripgrep") == 0

  test "with mixed installs, Reprobuild's version that is Scoop's current " &
       "stays":
    let f = newFixture("rollback-mixed-current")
    f.installVersion("ripgrep", "13.0")   # the user's
    f.installVersion("ripgrep", "14.1")   # Reprobuild's, and current
    f.markInstalledByReprobuild("ripgrep", "14.1")
    f.pointCurrentAt("ripgrep", "14.1")
    rollbackDroppingRipgrep(f, uninstallFromScoop = true)
    check dirExists(extendedPath(f.appDir("ripgrep") / "13.0"))
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "a version the user reinstalled is no longer Reprobuild's":
    let f = newFixture("rollback-reinstalled")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    check f.installedByReprobuild("ripgrep", "14.1")
    # `scoop uninstall ripgrep; scoop install ripgrep@14.1` by hand: the
    # directory is deleted and created again. Recreate it under another
    # name first so the file system cannot hand the old inode straight back.
    f.installVersion("ripgrep", "placeholder")
    removeDir(extendedPath(f.appDir("ripgrep") / "14.1"))
    f.installVersion("ripgrep", "14.1")
    removeDir(extendedPath(f.appDir("ripgrep") / "placeholder"))
    check not f.installedByReprobuild("ripgrep", "14.1")
    rollbackDroppingRipgrep(f, uninstallFromScoop = true)
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "positive control: with the flag, an unheld app Reprobuild installed " &
       "is removed":
    let f = newFixture("rollback-control")
    f.installVersion("ripgrep", "14.0")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.0")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    check f.ledgerRecords("ripgrep") == 2
    rollbackDroppingRipgrep(f, uninstallFromScoop = true)
    check not dirExists(extendedPath(f.appDir("ripgrep")))
    check f.ledgerRecords("ripgrep") == 0

  test "apply: --plan and the apply keep Scoop without the flag, and the " &
       "flag removes only what Reprobuild installed":
    let f = newFixture("apply")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    var store = openStore(f.storeRoot)
    let current = writeGen(f, store, "current", 2000, [("ripgrep", "14.1")])
    store.close()
    writeCurrentGenerationId(f.stateDir, current)
    let opts = ApplyOptions(profileDir: f.profileDir,
      profilePath: f.profileDir / "home.nim", host: "fixture-host",
      stateDir: f.stateDir, storeRoot: f.storeRoot, homeDir: f.homeDir)

    proc ripgrepItem(preview: PlanPreview): PlanItem =
      for item in preview.items:
        if item.category == "package" and item.name == "ripgrep":
          return item
      doAssert false, "the plan has no item for the dropped ripgrep:\n" &
        renderPlanPreview(preview)

    # Default: previewed as retained, and the apply keeps it.
    let kept = ripgrepItem(runApplyPlan(opts))
    checkpoint(kept.detail)
    check kept.action == piaSkip
    check "--uninstall-from-scoop" in kept.detail
    discard runApply(opts)
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

    # The flag, with a workspace holding the app: still retained, naming
    # the holder.
    let f2 = newFixture("apply-held")
    f2.installVersion("ripgrep", "14.1")
    f2.markInstalledByReprobuild("ripgrep", "14.1")
    var store2 = openStore(f2.storeRoot)
    let current2 = writeGen(f2, store2, "current", 2000,
      [("ripgrep", "14.1")])
    let held = registerScoopPrefix(store2, f2, "ripgrep", "14.0")
    store2.registerRoot("ws-project-b", rkWorkspace)
    store2.attachPrefixToRoot("ws-project-b", held)
    store2.close()
    writeCurrentGenerationId(f2.stateDir, current2)
    var opts2 = ApplyOptions(profileDir: f2.profileDir,
      profilePath: f2.profileDir / "home.nim", host: "fixture-host",
      stateDir: f2.stateDir, storeRoot: f2.storeRoot, homeDir: f2.homeDir,
      uninstallFromScoop: true)
    let heldItem = ripgrepItem(runApplyPlan(opts2))
    checkpoint(heldItem.detail)
    check heldItem.action == piaSkip
    check "ws-project-b (workspace)" in heldItem.detail
    discard runApply(opts2)
    check dirExists(extendedPath(f2.appDir("ripgrep") / "14.1"))

    # The flag, nothing holding it, Reprobuild installed it: destroyed.
    let f3 = newFixture("apply-control")
    f3.installVersion("ripgrep", "14.1")
    f3.markInstalledByReprobuild("ripgrep", "14.1")
    var store3 = openStore(f3.storeRoot)
    let current3 = writeGen(f3, store3, "current", 2000,
      [("ripgrep", "14.1")])
    store3.close()
    writeCurrentGenerationId(f3.stateDir, current3)
    let opts3 = ApplyOptions(profileDir: f3.profileDir,
      profilePath: f3.profileDir / "home.nim", host: "fixture-host",
      stateDir: f3.stateDir, storeRoot: f3.storeRoot, homeDir: f3.homeDir,
      uninstallFromScoop: true)
    let doomed = ripgrepItem(runApplyPlan(opts3))
    checkpoint(doomed.detail)
    check doomed.action == piaDestroy
    check "scoop uninstall ripgrep" in doomed.detail
    discard runApply(opts3)
    check not dirExists(extendedPath(f3.appDir("ripgrep")))

suite "dropping a Scoop package keeps the installs another state " &
      "directory's generations hold":

  proc otherDirHoldsRipgrep(f: Fixture; tag: string; timestamp: int64):
      tuple[stateDir, generationId: string] =
    ## State directory B, on the same store, whose current generation
    ## records ripgrep@14.1.
    result.stateDir = f.otherStateDir()
    var store = openStore(f.storeRoot)
    result.generationId = writeGenIn(f, result.stateDir, store, tag,
      timestamp, [("ripgrep", "14.1")])
    store.close()
    writeCurrentGenerationId(result.stateDir, result.generationId)

  test "rollback in A keeps the app B's current generation holds " &
       "(different generation ids)":
    let f = newFixture("other-dir-different-id")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    let b = f.otherDirHoldsRipgrep("b-current", 3000)
    rollbackDroppingRipgrep(f, uninstallFromScoop = true)
    check readCurrentGenerationId(b.stateDir) == b.generationId
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))
    check f.ledgerRecords("ripgrep") == 1

  test "rollback in A keeps the app B's current generation holds " &
       "(the same generation id in both)":
    # The same profile, host and timestamp: `computeGenerationId` gives
    # both state directories one id, and only their keys tell the roots
    # apart.
    let f = newFixture("other-dir-same-id")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    let b = f.otherDirHoldsRipgrep("current", 2000)
    rollbackDroppingRipgrep(f, uninstallFromScoop = true)
    check readCurrentGenerationId(f.stateDir) != b.generationId
    check profileRootId(b.stateDir, b.generationId) !=
      profileRootId(f.stateDir, b.generationId)
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))
    check f.ledgerRecords("ripgrep") == 1

  test "apply in A: --plan names B's root and the apply keeps the app":
    let f = newFixture("other-dir-apply")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    var store = openStore(f.storeRoot)
    let current = writeGen(f, store, "current", 2000, [("ripgrep", "14.1")])
    store.close()
    writeCurrentGenerationId(f.stateDir, current)
    let b = f.otherDirHoldsRipgrep("b-current", 3000)
    let opts = ApplyOptions(profileDir: f.profileDir,
      profilePath: f.profileDir / "home.nim", host: "fixture-host",
      stateDir: f.stateDir, storeRoot: f.storeRoot, homeDir: f.homeDir,
      uninstallFromScoop: true)
    var item: PlanItem
    var found = false
    let preview = runApplyPlan(opts)
    for it in preview.items:
      if it.category == "package" and it.name == "ripgrep":
        item = it
        found = true
    checkpoint(renderPlanPreview(preview))
    check found
    check item.action == piaSkip
    check (profileRootId(b.stateDir, b.generationId) & " (profile)") in
      item.detail
    discard runApply(opts)
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "a bare-id profile root of a generation A does not hold is a holder":
    # An earlier build registered `profile` roots under the bare generation
    # id. One whose generation is not A's is another state directory's.
    let f = newFixture("legacy-bare-foreign")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    let foreignId = generationIdHex(computeGenerationId(
      blake3Digest32("legacy-b"), "fixture-host", 5000))
    proc legacyHold(store: var Store; currentId: string) =
      store.registerRoot(foreignId, rkProfile)
      store.attachPrefixToRoot(foreignId, prefixIdFor("ripgrep", "14.1"))
    rollbackDroppingRipgrep(f, uninstallFromScoop = true,
      extraSetup = legacyHold)
    check not dirExists(extendedPath(generationDir(f.stateDir, foreignId)))
    check dirExists(extendedPath(f.appDir("ripgrep") / "14.1"))

  test "positive control: a bare-id profile root of A's own generation " &
       "is not a holder":
    let f = newFixture("legacy-bare-own")
    f.installVersion("ripgrep", "14.1")
    f.markInstalledByReprobuild("ripgrep", "14.1")
    proc ownLegacyHold(store: var Store; currentId: string) =
      store.registerRoot(currentId, rkProfile)
      store.attachPrefixToRoot(currentId, prefixIdFor("ripgrep", "14.1"))
    rollbackDroppingRipgrep(f, uninstallFromScoop = true,
      extraSetup = ownLegacyHold)
    check not dirExists(extendedPath(f.appDir("ripgrep")))
    check f.ledgerRecords("ripgrep") == 0

## The home-profile lock (`home.lock`): GM4b deliverable 4 —
## `adapterPreference:` is selection policy, serialised into the lock together
## with every selection made under it (Provisioning-Contributions.md §"The
## home-profile lock").
##
## Cases, each with the mutation that would make it fail:
##
## * the TOML subset round-trips byte for byte, canonically ordered, and a
##   malformed lock is refused (mutation: a reader that skips an unknown kind
##   instead of refusing it);
## * a recorded selection PINS the next resolution under the same policy —
##   proven with a package whose default policy would select a DIFFERENT kind
##   (mutation: ignoring `lockTarget` in `resolveInContext`);
## * an ambient selection is never pinned, a changed policy re-derives, and
##   `--relock` ignores the pins;
## * a pin whose realization is gone fails naming the lock and the relock
##   command instead of re-selecting silently;
## * the pin is the recorded REALIZATION, not just its kind: after a newer
##   realization is added to the definition (one the default policy would
##   now select) the locked one is still selected, planned and applied as a
##   no-op; once the locked one is withdrawn, plan and apply fail naming its
##   version, its lock identity and `--relock`, and `--relock` selects and
##   records the new one (mutation: dropping `lockIdentity` from the pin in
##   `resolveInContext` makes the newer realization win);
## * a record without a lock identity (pre-identity or hand-written) pins
##   kind and contributor only, and the next apply records the identity
##   without changing either; a record whose version differs from the
##   reference's version pin is re-derived;
## * a REAL apply writes the lock (policy, policy source, selections), a no-op
##   re-apply leaves it byte-identical, and `--plan` never writes it.
##
## Fixture: `gm4block`, a package registered in this test process (the
## process stands in for the engine, which links its package definitions the
## same way) with a nixPackage and a raw `file://` tarball the test builds, so
## the apply realizes for real through the `uses:` provisioning edge. Nothing
## is mocked; the shared binary cache is disabled so nothing is published.
## "A definition update" is made the way an engine upgrade makes it: the
## test re-registers `gm4block` in the same package registry the engine's
## linked definitions populate (`registerPackageDef`), with a realization
## added or withdrawn, and restores the original afterwards.

import std/[options, os, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_project_dsl
import repro_tool_profiles
import repro_home_apply
import repro_home_intent

const ExeSuffix = when defined(windows): ".exe" else: ""

proc writeExecutable(path, body: string) =
  createDir(parentDir(path))
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

let fixtureRoot = createTempDir("repro-gm4b-lock-fixture-", "")
let fixturePayload = fixtureRoot / ("gm4block" & ExeSuffix)
writeExecutable(fixturePayload, "#!/bin/sh\necho gm4block\n")
let fixtureSha = fileSha256Hex(fixturePayload)
# The "newer realization" a definition update adds: a different artifact
# (different bytes, so a different digest and lock identity) at 2.0.
let fixturePayloadV2 = fixtureRoot / "v2" / ("gm4block" & ExeSuffix)
writeExecutable(fixturePayloadV2, "#!/bin/sh\necho gm4block 2.0\n")
let fixtureShaV2 = fileSha256Hex(fixturePayloadV2)

package gm4block:
  provisioning:
    nixPackage "nixpkgs#hello", executablePath = "bin/hello",
      packageId = "gm4block-nix"
    tarball url = "file://" & fixturePayload,
      sha256 = fixtureSha,
      archiveType = "raw",
      executablePath = "gm4block" & ExeSuffix,
      packageId = "gm4block@1.0",
      version = "1.0"

proc profileText(policyLine = ""): string =
  result = "import repro/profile\n\nprofile \"gm4bLock\":\n"
  if policyLine.len > 0:
    result.add("  adapterPreference:\n    " & policyLine & "\n\n")
  result.add("  activity default:\n    gm4block\n")

proc hostKey(): string =
  case detectHostOs()
  of poWindows: "windows"
  of poMacos: "darwin"
  else: "linux"

proc options(root: string; host = currentHost()): ApplyOptions =
  result.profileDir = root / "profile"
  result.profilePath = root / "profile" / "home.nim"
  result.stateDir = root / "state"
  result.storeRoot = root / "store"
  result.homeDir = root / "home"
  result.host = host

proc setupProfile(root: string; policyLine = "") =
  for d in ["profile", "state", "store", "home"]:
    createDir(root / d)
  writeFile(root / "profile" / "home.nim", profileText(policyLine))

proc selectionOf(opts: ApplyOptions): PackagePreview =
  let s = resolveProfileSelections(opts)
  doAssert s.previews.len == 1
  s.previews[0]

proc gm4blockDefinition(): PackageDef =
  for p in registeredPackages():
    if p.packageName == "gm4block":
      return p
  doAssert false, "the gm4block fixture is not registered"

proc redefineGm4block(def: PackageDef) =
  ## Replace the registered ``gm4block`` definition, keeping every other.
  let all = registeredPackages()
  resetPackageRegistry()
  for p in all:
    registerPackageDef(if p.packageName == "gm4block": def else: p)

proc v2Record(): TarballProvisioningDef =
  ## The 1.0 record re-pointed at the 2.0 artifact.
  result = gm4blockDefinition().tarballProvisioning[0]
  result.url = "file://" & fixturePayloadV2
  result.sha256 = fixtureShaV2
  result.packageId = "gm4block@2.0"
  result.lockIdentity = ""
  result.detail.version = "2.0"

template withApplyEnv(root: string; body: untyped) =
  ## A real apply into ``root``: no shared binary cache, and the POSIX
  ## PATH rc file inside the scratch home.
  let savedCache = getEnv("REPRO_CACHE_DISABLE")
  let savedRc = getEnv("REPRO_HOME_POSIX_PATH_RC")
  putEnv("REPRO_CACHE_DISABLE", "1")
  putEnv("REPRO_HOME_POSIX_PATH_RC", root / "home" / ".profile-path-rc")
  try:
    body
  finally:
    if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
    else: delEnv("REPRO_CACHE_DISABLE")
    if savedRc.len > 0: putEnv("REPRO_HOME_POSIX_PATH_RC", savedRc)
    else: delEnv("REPRO_HOME_POSIX_PATH_RC")

proc lockedSelection(path: string): HomeLockSelection =
  let lock = parseHomeProfileLock(readFile(path))
  doAssert lock.targets.len == 1 and lock.targets[0].packages.len == 1
  lock.targets[0].packages[0]

suite "home-profile lock: format":

  test "serialisation round-trips and is canonical":
    let lock = HomeProfileLock(schema: HomeProfileLockSchemaV1, targets: @[
      HomeLockTarget(target: "x86_64-linux", policy: @[rkNix, rkPath],
        policySource: "adapterPreference.linux", packages: @[
          HomeLockSelection(package: "zeta", kind: rkPath,
            lockIdentity: "path:/usr/bin/zeta", ambient: true),
          HomeLockSelection(package: "alpha", kind: rkTarball,
            contributor: "github:x/y", version: "1.0",
            lockIdentity: "contributor:github:x/y\nsha256:abc")]),
      HomeLockTarget(target: "aarch64-macos", policy: DefaultSelectionPolicy,
        policySource: "default")])
    let text = serializeHomeProfileLock(lock)
    let parsed = parseHomeProfileLock(text)
    check serializeHomeProfileLock(parsed) == text
    # Canonical order: targets and packages by name.
    check text.find("aarch64-macos") < text.find("x86_64-linux")
    check text.find("\"alpha\"") < text.find("\"zeta\"")
    let linuxTarget = lockedTarget(parsed, "x86_64-linux").get
    check linuxTarget.policy == @[rkNix, rkPath]
    var alpha: HomeLockSelection
    for p in linuxTarget.packages:
      if p.package == "alpha": alpha = p
    check alpha.lockIdentity == "contributor:github:x/y\nsha256:abc"
    check alpha.contributor == "github:x/y"

  test "a lock this reader cannot interpret is refused":
    expect EHomeLockParse:
      discard parseHomeProfileLock("schema = \"something-else\"\n")
    expect EHomeLockParse:
      discard parseHomeProfileLock("schema = \"" & HomeProfileLockSchemaV1 &
        "\"\n\n[target]\nname = \"x86_64-linux\"\npolicy = \"tarball\"\n" &
        "packages = [{ name = \"a\", kind = \"homebrew\" }]\n")
    expect EHomeLockParse:
      discard parseHomeProfileLock("schema = \"" & HomeProfileLockSchemaV1 &
        "\"\n\n[target]\nname = \"x86_64-linux\"\n")

  test "pins: non-ambient under the recorded policy only":
    let t = some(HomeLockTarget(target: "x", policy: @[rkTarball, rkNix],
      packages: @[
        HomeLockSelection(package: "a", kind: rkNix,
          lockIdentity: "nixpkgs#a"),
        HomeLockSelection(package: "b", kind: rkPath, ambient: true),
        HomeLockSelection(package: "c", kind: rkTarball, version: "1.0",
          lockIdentity: "sha256:abc")]))
    check lockedPin(t, "a", @[rkTarball, rkNix]).get.kind == rkNix
    check lockedPin(t, "a", @[rkTarball, rkNix]).get.lockIdentity ==
      "nixpkgs#a"
    # The identity and version travel with the pin; a reference whose exact
    # version pin no longer matches the record is re-derived.
    let c = lockedPin(t, "c", @[rkTarball, rkNix], requestedVersion = "1.0")
    check c.get.lockIdentity == "sha256:abc"
    check c.get.version == "1.0"
    check lockedPin(t, "c", @[rkTarball, rkNix]).isSome
    check lockedPin(t, "c", @[rkTarball, rkNix],
      requestedVersion = "2.0").isNone
    check lockedPin(t, "b", @[rkTarball, rkNix]).isNone
    check lockedPin(t, "a", @[rkNix, rkTarball]).isNone
    check lockedPin(t, "missing", @[rkTarball, rkNix]).isNone

  test "withTarget replaces one target and carries the others":
    let base = HomeProfileLock(schema: HomeProfileLockSchemaV1, targets: @[
      HomeLockTarget(target: "a", policy: @[rkPath]),
      HomeLockTarget(target: "b", policy: @[rkPath])])
    let updated = base.withTarget(HomeLockTarget(target: "b",
      policy: @[rkNix]))
    check updated.targets.len == 2
    check lockedTarget(updated, "a").get.policy == @[rkPath]
    check lockedTarget(updated, "b").get.policy == @[rkNix]

suite "home-profile lock: resolution honours it":

  test "a recorded selection pins the kind the policy would not choose":
    let root = createTempDir("repro-gm4b-lock-pin-", "")
    defer: removeDir(root)
    setupProfile(root)
    var opts = options(root, host = "gm4b-lock-elsewhere")
    opts.targetContext = HostContext(platform: "linux", arch: "x86_64",
      host: opts.host)
    opts.hasTargetContext = true
    # Without a lock the default policy selects the tarball.
    check selectionOf(opts).resolution.selection.kind == rkTarball
    # A lock recorded under the same (default) policy pins nix.
    writeHomeProfileLock(homeProfileLockPath(opts.profileDir),
      HomeProfileLock(schema: HomeProfileLockSchemaV1, targets: @[
        HomeLockTarget(target: "x86_64-linux", policy: DefaultSelectionPolicy,
          policySource: "default", packages: @[HomeLockSelection(
            package: "gm4block", kind: rkNix)])]))
    let pinned = selectionOf(opts)
    check pinned.resolved
    check pinned.resolution.selection.kind == rkNix
    # --relock ignores the pin.
    var relock = opts
    relock.relock = true
    check selectionOf(relock).resolution.selection.kind == rkTarball

  test "a changed policy re-derives instead of honouring the old pin":
    let root = createTempDir("repro-gm4b-lock-policy-", "")
    defer: removeDir(root)
    setupProfile(root, "linux: [tarball, path]")
    var opts = options(root, host = "gm4b-lock-elsewhere")
    opts.targetContext = HostContext(platform: "linux", arch: "x86_64",
      host: opts.host)
    opts.hasTargetContext = true
    writeHomeProfileLock(homeProfileLockPath(opts.profileDir),
      HomeProfileLock(schema: HomeProfileLockSchemaV1, targets: @[
        HomeLockTarget(target: "x86_64-linux", policy: DefaultSelectionPolicy,
          policySource: "default", packages: @[HomeLockSelection(
            package: "gm4block", kind: rkNix)])]))
    let s = resolveProfileSelections(opts)
    check s.policy == @[rkTarball, rkPath]
    check s.policySource == "adapterPreference.linux"
    check s.previews[0].resolution.selection.kind == rkTarball

  test "a pin whose realization is gone names the lock and the relock " &
      "command":
    let root = createTempDir("repro-gm4b-lock-gone-", "")
    defer: removeDir(root)
    setupProfile(root)
    var opts = options(root, host = "gm4b-lock-elsewhere")
    opts.targetContext = HostContext(platform: "linux", arch: "x86_64",
      host: opts.host)
    opts.hasTargetContext = true
    writeHomeProfileLock(homeProfileLockPath(opts.profileDir),
      HomeProfileLock(schema: HomeProfileLockSchemaV1, targets: @[
        HomeLockTarget(target: "x86_64-linux", policy: DefaultSelectionPolicy,
          policySource: "default", packages: @[HomeLockSelection(
            package: "gm4block", kind: rkTarball,
            contributor: "github:example/withdrawn")])]))
    let pv = selectionOf(opts)
    check not pv.resolved
    check pv.kind == ppkMissing
    check "home-profile lock pins gm4block" in pv.detail
    check "github:example/withdrawn" in pv.detail
    check "--relock" in pv.detail

suite "home-profile lock: apply writes it":

  test "an apply records policy and selections; a no-op re-apply and " &
      "--plan leave it untouched":
    let root = createTempDir("repro-gm4b-lock-apply-", "")
    let savedCache = getEnv("REPRO_CACHE_DISABLE")
    let savedRc = getEnv("REPRO_HOME_POSIX_PATH_RC")
    putEnv("REPRO_CACHE_DISABLE", "1")
    putEnv("REPRO_HOME_POSIX_PATH_RC", root / "home" / ".profile-path-rc")
    defer:
      if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
      else: delEnv("REPRO_CACHE_DISABLE")
      if savedRc.len > 0: putEnv("REPRO_HOME_POSIX_PATH_RC", savedRc)
      else: delEnv("REPRO_HOME_POSIX_PATH_RC")
      removeDir(root)
    setupProfile(root)
    let opts = options(root)
    let lockPath = homeProfileLockPath(opts.profileDir)

    # --plan never writes the lock.
    discard runApplyPlan(opts)
    check not fileExists(lockPath)

    let applied = runApply(opts)
    check applied.kind == aokFreshApplied
    check fileExists(lockPath)
    let first = readFile(lockPath)
    checkpoint(first)
    let lock = parseHomeProfileLock(first)
    check lock.targets.len == 1
    let record = lock.targets[0]
    check record.policy == DefaultSelectionPolicy
    check record.policySource == "default"
    check record.packages.len == 1
    let selection = record.packages[0]
    check selection.package == "gm4block"
    check selection.kind == rkTarball
    check selection.version == "1.0"
    check selection.lockIdentity == "sha256:" & fixtureSha
    check not selection.ambient

    # A re-apply is a no-op and leaves the lock byte-identical.
    let again = runApply(opts)
    check again.kind == aokNoOpVerified
    check readFile(lockPath) == first

suite "home-profile lock: pins the selected realization":

  test "a newer realization does not displace the locked one; a withdrawn " &
      "one asks for --relock, which selects and records the new one":
    let root = createTempDir("repro-gm4b-lock-identity-", "")
    let original = gm4blockDefinition()
    defer:
      redefineGm4block(original)
      removeDir(root)
    withApplyEnv(root):
      setupProfile(root)
      let opts = options(root)
      let lockPath = homeProfileLockPath(opts.profileDir)
      var relock = opts
      relock.relock = true

      # (a) A real apply records the selected realization's identity.
      check runApply(opts).kind == aokFreshApplied
      let first = readFile(lockPath)
      checkpoint(first)
      let locked = lockedSelection(lockPath)
      check locked.kind == rkTarball
      check locked.version == "1.0"
      check locked.lockIdentity == "sha256:" & fixtureSha

      # (b) The definition gains a 2.0 realization declared FIRST, so it is
      # what an unlocked selection takes now ...
      var withNewer = original
      withNewer.tarballProvisioning.insert(v2Record(), 0)
      redefineGm4block(withNewer)
      let unlocked = selectionOf(relock).resolution.selection
      check unlocked.version == "2.0"
      check unlocked.lockIdentity == "sha256:" & fixtureShaV2
      # ... but the lock still selects 1.0, in the plan and in the apply,
      # and the apply is a no-op that leaves the lock byte-identical.
      let pinned = selectionOf(opts)
      check pinned.resolved
      check pinned.resolution.selection.version == "1.0"
      check pinned.resolution.selection.lockIdentity == "sha256:" & fixtureSha
      check "@1.0" in pinned.detail
      check runApply(opts).kind == aokNoOpVerified
      check readFile(lockPath) == first

      # (c) The locked 1.0 realization is withdrawn: no silent re-selection.
      var onlyNewer = original
      onlyNewer.tarballProvisioning = @[v2Record()]
      redefineGm4block(onlyNewer)
      let gone = selectionOf(opts)
      check not gone.resolved
      check gone.kind == ppkMissing
      checkpoint(gone.detail)
      check "home-profile lock pins gm4block" in gone.detail
      check "at version 1.0" in gone.detail
      check ("sha256:" & fixtureSha) in gone.detail
      check "no longer offered" in gone.detail
      check "--relock" in gone.detail
      let plan = runApplyPlan(opts)
      check plan.driftCount >= 1
      expect CatchableError:
        discard runApply(opts)
      check readFile(lockPath) == first
      # --relock re-selects and rewrites the record.
      check runApply(relock).kind == aokFreshApplied
      let relocked = lockedSelection(lockPath)
      check relocked.kind == rkTarball
      check relocked.version == "2.0"
      check relocked.lockIdentity == "sha256:" & fixtureShaV2
      # And the new record pins in turn.
      check runApply(opts).kind == aokNoOpVerified

  test "a record without an identity pins kind and contributor; the next " &
      "apply records the identity":
    let root = createTempDir("repro-gm4b-lock-legacy-", "")
    defer: removeDir(root)
    withApplyEnv(root):
      setupProfile(root)
      let opts = options(root)
      let lockPath = homeProfileLockPath(opts.profileDir)
      let target = describeTarget(hostProfileResolutionContext().target)
      writeHomeProfileLock(lockPath,
        HomeProfileLock(schema: HomeProfileLockSchemaV1, targets: @[
          HomeLockTarget(target: target, policy: DefaultSelectionPolicy,
            policySource: "default", packages: @[HomeLockSelection(
              package: "gm4block", kind: rkTarball)])]))
      # --plan honours the kind pin and does not write the identity.
      let before = readFile(lockPath)
      discard runApplyPlan(opts)
      check readFile(lockPath) == before
      check runApply(opts).kind == aokFreshApplied
      let upgraded = lockedSelection(lockPath)
      check upgraded.kind == rkTarball
      check upgraded.contributor == ""
      check upgraded.version == "1.0"
      check upgraded.lockIdentity == "sha256:" & fixtureSha

removeDir(fixtureRoot)

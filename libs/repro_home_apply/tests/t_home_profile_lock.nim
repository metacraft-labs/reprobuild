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
## * a REAL apply writes the lock (policy, policy source, selections), a no-op
##   re-apply leaves it byte-identical, and `--plan` never writes it.
##
## Fixture: `gm4block`, a package registered in this test process (the
## process stands in for the engine, which links its package definitions the
## same way) with a nixPackage and a raw `file://` tarball the test builds, so
## the apply realizes for real through the `uses:` provisioning edge. Nothing
## is mocked; the shared binary cache is disabled so nothing is published.

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
        HomeLockSelection(package: "a", kind: rkNix),
        HomeLockSelection(package: "b", kind: rkPath, ambient: true)]))
    check lockedPin(t, "a", @[rkTarball, rkNix]).get.kind == rkNix
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

removeDir(fixtureRoot)

## Smoke test for the M83 step 9 Homebrew adapter — `pkg.homebrewFormula`
## (Driver A) cross-platform pure-logic + lifecycle + platform-guard
## tests. The shell-out only runs on macOS; the binary-discovery helpers,
## the argv composers, the canonical-bytes derivation, the digest
## derivation, the realWorldIdentity derivation, and the off-macOS
## fail-closed gate are cross-platform.

import std/[os, strutils, unittest]

import repro_home_resources
import repro_homebrew_adapter

suite "M83 step 9 Driver A: pkg.homebrewFormula":

  # -------------------------------------------------------------------
  # Pure helpers — name validation.
  # -------------------------------------------------------------------

  test "isSafeHomebrewName: accepts conventional formulae":
    for ok in ["ripgrep", "tmux", "git", "node@18", "python@3.11",
               "openssl@3", "ffmpeg", "fd", "bat", "gnu-tar",
               "gettext", "p7zip", "icu4c"]:
      check isSafeHomebrewName(ok)

  test "isSafeHomebrewName: rejects empty / uppercase / metacharacters":
    check not isSafeHomebrewName("")
    check not isSafeHomebrewName("Ripgrep")    # uppercase
    check not isSafeHomebrewName("MyPkg")      # uppercase
    check not isSafeHomebrewName(".hidden")    # leading dot
    check not isSafeHomebrewName("-leading")   # leading dash
    for ch in [";", "&", "|", "$", "`", "\"", "'", "\\", " ", "\n", "/"]:
      check not isSafeHomebrewName("pkg" & ch & "evil")

  test "isSafeHomebrewArg: accepts brew flags":
    for ok in ["--build-from-source", "--HEAD", "--ignore-dependencies",
               "--no-quarantine", "--cask=foo", "-q", "-v"]:
      check isSafeHomebrewArg(ok)

  test "isSafeHomebrewArg: rejects empty / metacharacters / control":
    check not isSafeHomebrewArg("")
    for ch in [";", "&", "|", "$", "`", "\"", "'", " ", "\t", "\n"]:
      check not isSafeHomebrewArg("--flag" & ch & "evil")
    check not isSafeHomebrewArg("--flag\x01")  # control byte

  # -------------------------------------------------------------------
  # Pure helpers — `brew list --versions` output parsing.
  # -------------------------------------------------------------------

  test "parseBrewVersionsLine: empty input is absent":
    check parseBrewVersionsLine("") == HomebrewAbsentVersion
    check parseBrewVersionsLine("\n") == HomebrewAbsentVersion
    check parseBrewVersionsLine("   ") == HomebrewAbsentVersion

  test "parseBrewVersionsLine: name + single version returns the version":
    check parseBrewVersionsLine("ripgrep 14.1.0") == "14.1.0"
    check parseBrewVersionsLine("ripgrep 14.1.0\n") == "14.1.0"

  test "parseBrewVersionsLine: name + multiple versions returns the first":
    check parseBrewVersionsLine("node@18 18.20.4 18.19.1") == "18.20.4"

  test "parseBrewVersionsLine: ignores trailing diagnostic lines":
    let output = "tmux 3.5a\nWarning: tmux is outdated\n"
    check parseBrewVersionsLine(output) == "3.5a"

  test "parseBrewVersionsLine: lone bare version token is accepted":
    # Defensive fallback for any future homebrew output shape.
    check parseBrewVersionsLine("1.2.3") == "1.2.3"
    check parseBrewVersionsLine("0.99") == "0.99"

  test "parseBrewVersionsLine: lone name token is absent":
    # A formula name with no version printed = not installed.
    check parseBrewVersionsLine("ripgrep") == HomebrewAbsentVersion

  # -------------------------------------------------------------------
  # Pure helpers — argv composers.
  # -------------------------------------------------------------------

  test "composeListArgs: formula vs cask":
    check composeListArgs(isCask = false, name = "ripgrep") ==
      @["list", "--formula", "--versions", "ripgrep"]
    check composeListArgs(isCask = true, name = "iterm2") ==
      @["list", "--cask", "--versions", "iterm2"]

  test "composeInstallArgs: extra args precede the name":
    check composeInstallArgs(isCask = false, name = "ripgrep",
        extraArgs = []) ==
      @["install", "ripgrep"]
    check composeInstallArgs(isCask = false, name = "ripgrep",
        extraArgs = ["--build-from-source"]) ==
      @["install", "--build-from-source", "ripgrep"]
    check composeInstallArgs(isCask = true, name = "iterm2",
        extraArgs = ["--no-quarantine"]) ==
      @["install", "--cask", "--no-quarantine", "iterm2"]

  test "composeUninstallArgs: formula vs cask":
    check composeUninstallArgs(isCask = false, name = "ripgrep") ==
      @["uninstall", "ripgrep"]
    check composeUninstallArgs(isCask = true, name = "iterm2") ==
      @["uninstall", "--cask", "iterm2"]

  test "composeBrewCommand: quotes the brew exe + every arg":
    let cmd = composeBrewCommand("/opt/homebrew/bin/brew",
      ["install", "--formula", "ripgrep"])
    # The exact quoting form is platform-dependent (quoteShell uses
    # POSIX or Windows quoting); we just check that the brew exe and
    # every argv element appears in the composed line.
    check cmd.contains("brew")
    check cmd.contains("install")
    check cmd.contains("--formula")
    check cmd.contains("ripgrep")

  # -------------------------------------------------------------------
  # Brew binary discovery — env-var override.
  # -------------------------------------------------------------------

  test "brewBinary: REPRO_HOMEBREW_BREW_BINARY override wins when file exists":
    let tmpDir = getTempDir() / "repro-homebrew-test-binary"
    createDir(tmpDir)
    let stub = tmpDir / "brew-stub.exe"
    writeFile(stub, "stub")
    let oldValue = getEnv(BrewBinaryEnvVar)
    try:
      putEnv(BrewBinaryEnvVar, stub)
      check brewBinary() == stub
    finally:
      if oldValue.len > 0: putEnv(BrewBinaryEnvVar, oldValue)
      else: delEnv(BrewBinaryEnvVar)
      try: removeFile(stub) except OSError: discard
      try: removeDir(tmpDir) except OSError: discard

  test "brewBinary: override pointing at a non-existent file falls back to PATH":
    let oldValue = getEnv(BrewBinaryEnvVar)
    try:
      putEnv(BrewBinaryEnvVar, "/nonexistent/brew-binary-xyz")
      # No assertion about the PATH result — there's likely no `brew`
      # on the Windows host PATH. The important thing is that
      # `brewBinary()` doesn't crash and returns either "" or a
      # PATH-found brew. Used to live-test the fallback.
      let result = brewBinary()
      check result != "/nonexistent/brew-binary-xyz"
    finally:
      if oldValue.len > 0: putEnv(BrewBinaryEnvVar, oldValue)
      else: delEnv(BrewBinaryEnvVar)

  test "brewPrefix: REPRO_HOMEBREW_PREFIX override short-circuits the shell-out":
    let oldValue = getEnv(BrewPrefixEnvVar)
    try:
      putEnv(BrewPrefixEnvVar, "/opt/homebrew")
      check brewPrefix("/anything/brew") == "/opt/homebrew"
      check brewPrefix("") == "/opt/homebrew"  # no shell-out needed
    finally:
      if oldValue.len > 0: putEnv(BrewPrefixEnvVar, oldValue)
      else: delEnv(BrewPrefixEnvVar)

  # -------------------------------------------------------------------
  # Canonical-bytes derivation.
  # -------------------------------------------------------------------

  test "canonicalHomebrewFormulaBytes: name+0x1e+version layout":
    let bytes = canonicalHomebrewFormulaBytes("ripgrep", "14.1.0")
    var s = ""
    for b in bytes: s.add(char(b))
    check s == "ripgrep\x1e14.1.0"

  test "canonicalHomebrewFormulaBytes: empty version produces name+0x1e":
    let bytes = canonicalHomebrewFormulaBytes("ripgrep", "")
    var s = ""
    for b in bytes: s.add(char(b))
    check s == "ripgrep\x1e"

  # -------------------------------------------------------------------
  # Resource model integration.
  # -------------------------------------------------------------------

  test "resourceKindFromString covers pkg.homebrewFormula":
    check resourceKindFromString("pkg.homebrewFormula") ==
      rkHomebrewFormula

  test "digestOfResource: pkg.homebrewFormula digests (name, version)":
    let r = Resource(kind: rkHomebrewFormula,
      address: "hb:digest",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "14.1.0",
      formulaArgs: @[])
    let expected = digestOfBytes(
      canonicalHomebrewFormulaBytes("ripgrep", "14.1.0"))
    check digestOfResource(r) == expected

  test "digestOfResource: version change flips the digest":
    var r = Resource(kind: rkHomebrewFormula,
      address: "hb:flip",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "14.1.0",
      formulaArgs: @[])
    let before = digestOfResource(r)
    r.formulaVersion = "14.0.0"
    check before != digestOfResource(r)

  test "digestOfResource: empty version vs explicit version differ":
    var trackLatest = Resource(kind: rkHomebrewFormula,
      address: "hb:track",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "",
      formulaArgs: @[])
    var pinned = trackLatest
    pinned.formulaVersion = "14.1.0"
    check digestOfResource(trackLatest) != digestOfResource(pinned)

  test "digestOfResource: formulaArgs change does NOT affect the digest":
    # `args` controls HOW the install happens, not WHAT ends up
    # installed — by design the digest does not cover it.
    var r1 = Resource(kind: rkHomebrewFormula,
      address: "hb:args-1",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "14.1.0",
      formulaArgs: @[])
    var r2 = r1
    r2.formulaArgs = @["--build-from-source"]
    check digestOfResource(r1) == digestOfResource(r2)

  test "realWorldIdentity: homebrew:formula:<name>":
    let r = Resource(kind: rkHomebrewFormula,
      address: "hb:id",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "14.1.0",
      formulaArgs: @[])
    check realWorldIdentity(r) == "homebrew:formula:ripgrep"

  test "realWorldIdentity: version is NOT part of the identity":
    # Two resources differing only in formulaVersion address the SAME
    # Homebrew slot. A version-pin tweak is an update, not a new
    # resource.
    let r1 = Resource(kind: rkHomebrewFormula,
      address: "hb:id-1",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "14.0.0",
      formulaArgs: @[])
    var r2 = r1
    r2.formulaVersion = "14.1.0"
    check realWorldIdentity(r1) == realWorldIdentity(r2)

  test "realWorldIdentity: name change IS a new resource":
    let r1 = Resource(kind: rkHomebrewFormula,
      address: "hb:id-3",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "")
    var r2 = r1
    r2.formulaName = "fd"
    check realWorldIdentity(r1) != realWorldIdentity(r2)

  # -------------------------------------------------------------------
  # Lifecycle decisions.
  # -------------------------------------------------------------------

  test "lifecycle: no-op when desired matches observed":
    let desired = Resource(kind: rkHomebrewFormula,
      address: "hb:noop",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "14.1.0",
      formulaArgs: @[])
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    state.observed.digest = digestOfResource(desired)
    let action = decideAction(state)
    check action.kind == rakNoOp
    check action.resourceKind == rkHomebrewFormula

  test "lifecycle: create when absent":
    let desired = Resource(kind: rkHomebrewFormula,
      address: "hb:create",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = false
    let action = decideAction(state)
    check action.kind == rakCreate
    check action.resourceKind == rkHomebrewFormula

  test "lifecycle: version pin mismatch plans update on prior generation":
    var desired = Resource(kind: rkHomebrewFormula,
      address: "hb:update",
      lifecyclePolicy: lpDefault,
      formulaName: "ripgrep",
      formulaVersion: "14.1.0")
    var state: ResourceState
    state.address = desired.address
    state.desired = desired
    state.hasDesired = true
    state.observed.present = true
    let observedDigest = digestOfBytes(
      canonicalHomebrewFormulaBytes("ripgrep", "14.0.0"))
    state.observed.digest = observedDigest
    state.hasRecorded = true
    state.recorded.kind = rkHomebrewFormula
    state.recorded.postWriteDigest = observedDigest
    let action = decideAction(state)
    check action.kind == rakUpdate

  # -------------------------------------------------------------------
  # Platform guards — off-macOS fail-closed.
  # -------------------------------------------------------------------

  test "off-macOS: observeHomebrewFormula raises ENotImplementedPlatform":
    when not defined(macosx):
      expect ENotImplementedPlatform:
        discard observeHomebrewFormula("ripgrep", "")
      try:
        discard observeHomebrewFormula("ripgrep", "")
        check false  # unreachable
      except ENotImplementedPlatform as e:
        check e.resourceKind == "pkg.homebrewFormula"
        check e.requiredPlatform == "macosx"
        check e.currentPlatform != "macosx"
    else:
      skip()

  test "off-macOS: applyHomebrewFormula raises ENotImplementedPlatform":
    when not defined(macosx):
      expect ENotImplementedPlatform:
        discard applyHomebrewFormula("ripgrep", "", @[])
    else:
      skip()

  test "off-macOS: destroyHomebrewFormula raises ENotImplementedPlatform":
    when not defined(macosx):
      expect ENotImplementedPlatform:
        destroyHomebrewFormula("ripgrep")
    else:
      skip()

  test "off-macOS: applyHomebrewFormula raises off-mac even with version+args":
    # The platform guard must trip regardless of which fields are set.
    when not defined(macosx):
      expect ENotImplementedPlatform:
        discard applyHomebrewFormula("ripgrep", "14.1.0",
          @["--build-from-source"])
    else:
      skip()

  # -------------------------------------------------------------------
  # Validation — defence-in-depth layer 1.
  # -------------------------------------------------------------------

  test "resourceValidationError: clean formula passes":
    check resourceValidationError(Resource(kind: rkHomebrewFormula,
      address: "hb:ok",
      formulaName: "ripgrep",
      formulaVersion: "14.1.0",
      formulaArgs: @["--build-from-source"])) == ""

  test "resourceValidationError: rejects empty name":
    check resourceValidationError(Resource(kind: rkHomebrewFormula,
      address: "hb:empty",
      formulaName: "",
      formulaVersion: "")).len > 0

  test "resourceValidationError: rejects uppercase / metacharacter name":
    check resourceValidationError(Resource(kind: rkHomebrewFormula,
      address: "hb:uppercase",
      formulaName: "Ripgrep",
      formulaVersion: "")).len > 0
    for ch in [";", "&", "|", "$", "`", " ", "\n", "/"]:
      check resourceValidationError(Resource(kind: rkHomebrewFormula,
        address: "hb:evil",
        formulaName: "pkg" & ch & "evil",
        formulaVersion: "")).len > 0

  test "resourceValidationError: rejects metacharacter in version":
    for ch in [";", "&", "|", "$", "`", " "]:
      check resourceValidationError(Resource(kind: rkHomebrewFormula,
        address: "hb:evil-v",
        formulaName: "ripgrep",
        formulaVersion: "1.0" & ch & "0")).len > 0

  test "resourceValidationError: rejects unsafe arg":
    for ch in [";", "&", "|", "$", "`", " ", "\t"]:
      check resourceValidationError(Resource(kind: rkHomebrewFormula,
        address: "hb:evil-args",
        formulaName: "ripgrep",
        formulaVersion: "",
        formulaArgs: @["--flag" & ch & "evil"])).len > 0

  test "resourceValidationError: rejects empty arg":
    check resourceValidationError(Resource(kind: rkHomebrewFormula,
      address: "hb:empty-arg",
      formulaName: "ripgrep",
      formulaVersion: "",
      formulaArgs: @[""])).len > 0

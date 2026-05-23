## M69 Phase B Verification Gate: e2e_windows_vs_installer
##
## Per the M69 verification block: apply installs VS Build Tools with
## two workloads via `windows.vsInstaller`; `vswhere` confirms the
## installed product manifest matches. A user-added workload outside
## the resource's spec is reported as drift with policy `leave-alone`
## by default; setting `strict = true` removes it on next apply.
## Component version drift is silently ignored.
##
## ===========================================================================
## DESTRUCTIVE GATE — REQUIRES A VM. DO NOT RUN ON A REAL HOST.
## ===========================================================================
##
## Installing / modifying real VS Build Tools is HOST-ALTERING, heavy
## (gigabytes), and reboot-prone. This gate's REAL-INSTALL scenario
## runs ONLY when `REPRO_M69_VSINSTALLER_VM=1` is set — the milestone
## keeps this gate's `status:` at `pending` until a disposable-VM run
## sets it.
##
## On a normal host (the env var unset) the gate still runs its
## NON-DESTRUCTIVE half: the PURE `vswhere`-output parser, the
## installed-vs-desired workload/component diff, the drift
## classification, the `strict`-flag policy, the installer-argv
## construction, and the typed-operation wiring into the M81 closed
## set — so the `windows.vsInstaller` DRIVER logic is proven without
## touching the host.
##
## No `skip`, no `xfail` — the pure-logic half ALWAYS runs and always
## asserts; only the real-install half is VM-gated.

when not defined(windows):
  echo "[platform N/A] t_e2e_windows_vs_installer: the " &
    "windows.vsInstaller driver is Windows-only"
  quit(0)

import std/[os, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  ## Resolve the `repro.exe` to use for broker launches. Honors the
  ## `REPRO_TEST_BIN_DIR` override so the gate can be run inside the
  ## M69 system-scope Sandbox harness (`tools/sandbox-m69-system/`)
  ## where the built binaries are mapped into a fixed sandbox path,
  ## not at the host-side `ProjectRoot / build / bin /`.
  let override = getEnv("REPRO_TEST_BIN_DIR")
  if override.len > 0:
    let c = override / "repro.exe"
    doAssert fileExists(c), "repro binary not found at " & c &
      " (REPRO_TEST_BIN_DIR override)"
    return c
  let candidate = ProjectRoot / "build" / "bin" / "repro.exe"
  doAssert fileExists(candidate), "repro binary not found at " & candidate
  candidate

let vmMode = getEnv("REPRO_M69_VSINSTALLER_VM") == "1"

# A representative `vswhere -format json -include packages` document:
# one installed Build Tools product carrying two workloads and two
# components, plus a few non-workload/non-component packages (which the
# membership diff must ignore).
const SampleVsWhereJson = """
[
  {
    "instanceId": "a1b2c3d4",
    "installationPath": "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools",
    "installationVersion": "17.9.34728.123",
    "productId": "Microsoft.VisualStudio.Product.BuildTools",
    "channelId": "VisualStudio.17.Release",
    "packages": [
      { "id": "Microsoft.VisualStudio.Workload.VCTools", "type": "Workload", "version": "17.9.34728.123" },
      { "id": "Microsoft.VisualStudio.Workload.MSBuildTools", "type": "Workload", "version": "17.9.34728.123" },
      { "id": "Microsoft.VisualStudio.Component.Git", "type": "Component", "version": "2.44.0" },
      { "id": "Microsoft.VisualStudio.Component.VC.CoreIde", "type": "Component", "version": "17.9.34728.123" },
      { "id": "Microsoft.VisualStudio.Product.BuildTools", "type": "Product", "version": "17.9.34728.123" },
      { "id": "Microsoft.VisualCpp.CRT.x86.Store", "type": "Vsix", "version": "14.38.33135" }
    ]
  }
]
"""

# ===========================================================================
# NON-DESTRUCTIVE: pure vswhere-output parsing + membership diff +
# drift classification + strict policy. These always run.
# ===========================================================================

suite "windows.vsInstaller: pure vswhere-output parsing":

  test "parseVsWhereOutput reads the product + its packages":
    let products = parseVsWhereOutput(SampleVsWhereJson)
    check products.len == 1
    let p = products[0]
    check p.productId == "Microsoft.VisualStudio.Product.BuildTools"
    check p.channelId == "VisualStudio.17.Release"
    check p.installationPath.contains("BuildTools")
    check p.packages.len == 6

  test "an empty vswhere document means no VS product is installed":
    check parseVsWhereOutput("[]").len == 0
    check parseVsWhereOutput("   ").len == 0
    check parseVsWhereOutput("").len == 0

  test "a malformed vswhere document raises VsWhereParseError":
    expect VsWhereParseError:
      discard parseVsWhereOutput("{ not an array")
    expect VsWhereParseError:
      discard parseVsWhereOutput("[ {\"id\": } ]")

  test "workload / component package ids are extracted by type":
    let products = parseVsWhereOutput(SampleVsWhereJson)
    let workloads = installedWorkloadIds(products[0])
    let components = installedComponentIds(products[0])
    check workloads.len == 2
    check "Microsoft.VisualStudio.Workload.VCTools" in workloads
    check "Microsoft.VisualStudio.Workload.MSBuildTools" in workloads
    check components.len == 2
    # The Product / Vsix packages are NOT counted as components.
    check "Microsoft.VisualStudio.Component.Git" in components

suite "windows.vsInstaller: membership diff + drift classification":

  test "an in-sync installation classifies as in-sync":
    let products = parseVsWhereOutput(SampleVsWhereJson)
    let desired = VsInstallerDesiredState(
      edition: "BuildTools", channel: "VisualStudio.17.Release",
      installPath: r"C:\Program Files\Microsoft Visual Studio\2022\BuildTools",
      workloads: @["Microsoft.VisualStudio.Workload.VCTools",
                   "Microsoft.VisualStudio.Workload.MSBuildTools"],
      components: @["Microsoft.VisualStudio.Component.Git",
                    "Microsoft.VisualStudio.Component.VC.CoreIde"],
      strict: false)
    let diff = diffMembership(desired, products)
    check diff.productInstalled
    check diff.missingWorkloads.len == 0
    check diff.missingComponents.len == 0
    check diff.extraWorkloads.len == 0
    check classifyDrift(diff) == vsdInSync
    check not requiresMutation(diff, strict = false)

  test "a not-installed product classifies as needs-install":
    let desired = VsInstallerDesiredState(
      edition: "BuildTools", channel: "VisualStudio.17.Release",
      installPath: r"C:\Program Files\Microsoft Visual Studio\2022\BuildTools",
      workloads: @["Microsoft.VisualStudio.Workload.VCTools"],
      components: @[], strict: false)
    let diff = diffMembership(desired, @[])    # nothing installed
    check not diff.productInstalled
    check diff.missingWorkloads.len == 1
    check classifyDrift(diff) == vsdNeedsInstall
    check requiresMutation(diff, strict = false)

  test "a missing declared workload classifies as needs-modify":
    let products = parseVsWhereOutput(SampleVsWhereJson)
    let desired = VsInstallerDesiredState(
      edition: "BuildTools", channel: "VisualStudio.17.Release",
      installPath: r"C:\Program Files\Microsoft Visual Studio\2022\BuildTools",
      # The resource ALSO wants the ManagedDesktop workload, which the
      # sample install does NOT have.
      workloads: @["Microsoft.VisualStudio.Workload.VCTools",
                   "Microsoft.VisualStudio.Workload.MSBuildTools",
                   "Microsoft.VisualStudio.Workload.ManagedDesktop"],
      components: @[], strict: false)
    let diff = diffMembership(desired, products)
    check diff.missingWorkloads == @[
      "Microsoft.VisualStudio.Workload.ManagedDesktop"]
    check classifyDrift(diff) == vsdNeedsModify
    check requiresMutation(diff, strict = false)

  test "component VERSION drift is benign — the diff compares IDs only":
    # A vswhere document where the Git component reports a DIFFERENT
    # version than any baseline; the resource pins membership, not
    # versions, so this must NOT be reported as a difference.
    const updatedJson = """
[
  {
    "instanceId": "x",
    "installationPath": "C:\\VS\\BuildTools",
    "productId": "Microsoft.VisualStudio.Product.BuildTools",
    "channelId": "VisualStudio.17.Release",
    "packages": [
      { "id": "Microsoft.VisualStudio.Component.Git", "type": "Component", "version": "99.99.0" }
    ]
  }
]
"""
    let products = parseVsWhereOutput(updatedJson)
    let desired = VsInstallerDesiredState(
      edition: "BuildTools", channel: "VisualStudio.17.Release",
      installPath: r"C:\VS\BuildTools",
      workloads: @[],
      components: @["Microsoft.VisualStudio.Component.Git"],
      strict: false)
    let diff = diffMembership(desired, products)
    check diff.missingComponents.len == 0
    check diff.extraComponents.len == 0
    check classifyDrift(diff) == vsdInSync

  test "an out-of-spec workload is membership-drift; strict flips the policy":
    let products = parseVsWhereOutput(SampleVsWhereJson)
    # The resource declares ONLY VCTools — the install also has
    # MSBuildTools, a user-added out-of-spec workload.
    let desired = VsInstallerDesiredState(
      edition: "BuildTools", channel: "VisualStudio.17.Release",
      installPath: r"C:\Program Files\Microsoft Visual Studio\2022\BuildTools",
      workloads: @["Microsoft.VisualStudio.Workload.VCTools"],
      components: @["Microsoft.VisualStudio.Component.Git",
                    "Microsoft.VisualStudio.Component.VC.CoreIde"],
      strict: false)
    let diff = diffMembership(desired, products)
    check diff.extraWorkloads == @[
      "Microsoft.VisualStudio.Workload.MSBuildTools"]
    check diff.missingWorkloads.len == 0
    check classifyDrift(diff) == vsdMembershipDrift
    # DEFAULT policy (strict = false): leave-alone — no mutation.
    check not requiresMutation(diff, strict = false)
    check buildInstallerArgs(desired, diff).len == 0
    # STRICT policy: the out-of-spec workload is removed.
    var strictDesired = desired
    strictDesired.strict = true
    let strictDiff = diffMembership(strictDesired, products)
    check requiresMutation(strictDiff, strict = true)
    let strictArgs = buildInstallerArgs(strictDesired, strictDiff)
    check strictArgs.len > 0
    check strictArgs[0] == "modify"
    check "--remove" in strictArgs
    check "Microsoft.VisualStudio.Workload.MSBuildTools" in strictArgs
    check "--norestart" in strictArgs

  test "the canonical state makes a non-strict drift a cache-hit":
    # With strict = false an extra workload does not change the
    # canonical observed state, so the broker's drift gate treats a
    # re-apply over a user-added workload as a no-op (no endless
    # modify loop). With strict = true it is actionable.
    let products = parseVsWhereOutput(SampleVsWhereJson)
    let desired = VsInstallerDesiredState(
      edition: "BuildTools", channel: "VisualStudio.17.Release",
      installPath: r"C:\Program Files\Microsoft Visual Studio\2022\BuildTools",
      workloads: @["Microsoft.VisualStudio.Workload.VCTools"],
      components: @["Microsoft.VisualStudio.Component.Git",
                    "Microsoft.VisualStudio.Component.VC.CoreIde"],
      strict: false)
    let diff = diffMembership(desired, products)
    check canonicalVsInstallerState(diff, strict = false) ==
      canonicalVsInstallerDesired()
    check canonicalVsInstallerState(diff, strict = true) !=
      canonicalVsInstallerDesired()

  test "the installer exit codes map to success / reboot-needed":
    check vsInstallerSucceeded(0)
    check vsInstallerSucceeded(3010)
    check not vsInstallerSucceeded(1)
    check not vsInstallerRestartNeeded(0)
    check vsInstallerRestartNeeded(3010)

suite "windows.vsInstaller: typed-operation wiring into the M81 closed set":

  test "a system.nim vsInstaller stanza parses and types":
    let profile = parseSystemProfile("""
windows.vsInstaller {
  edition = "BuildTools"
  channel = "VisualStudio.17.Release"
  installPath = "C:\Program Files\Microsoft Visual Studio\2022\BuildTools"
  workloads = [
    "Microsoft.VisualStudio.Workload.VCTools",
    "Microsoft.VisualStudio.Workload.MSBuildTools"
  ]
  components = [
    "Microsoft.VisualStudio.Component.Git"
  ]
  strict = true
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkWindowsVsInstaller
    check r.vsEdition == "BuildTools"
    check r.vsWorkloads.len == 2
    check r.vsComponents.len == 1
    check r.vsStrict
    let op = toPrivilegedOperation(r)
    check op.kind == pokWindowsVsInstaller
    check op.vsWorkloads.len == 2
    check op.vsStrict
    check not op.vsDestroy
    # The destroy direction is the uninstall.
    let destroyOp = toPrivilegedOperation(r, destroy = true)
    check destroyOp.vsDestroy
    # It partitions as a privileged (broker-dispatched) operation.
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1
    check requiresElevation(pokWindowsVsInstaller)

  test "the closed-set validator + protocol codec round-trip the op":
    let op = PrivilegedOperation(kind: pokWindowsVsInstaller,
      address: "vsInstaller:BuildTools",
      vsEdition: "BuildTools", vsChannel: "VisualStudio.17.Release",
      vsInstallPath: r"C:\VS\BuildTools",
      vsWorkloads: @["Microsoft.VisualStudio.Workload.VCTools"],
      vsComponents: @["Microsoft.VisualStudio.Component.Git"],
      vsStrict: true, vsDestroy: false)
    check operationValidationError(op).len == 0
    # The RBEB protocol codec round-trips the operation faithfully.
    let wire = WireOperation(operation: op, baselineDigestHex: "")
    let encoded = encodeOperation(wire)
    let decoded = decodeOperation(decodeFrame(encoded).body)
    check decoded.operation.kind == pokWindowsVsInstaller
    check decoded.operation.vsEdition == "BuildTools"
    check decoded.operation.vsWorkloads == op.vsWorkloads
    check decoded.operation.vsComponents == op.vsComponents
    check decoded.operation.vsStrict
    # The kind tag is in the closed set.
    check isKnownPrivilegedOperationKind("windows.vsInstaller")

  test "an empty edition / channel is rejected by the validator":
    check operationValidationError(PrivilegedOperation(
      kind: pokWindowsVsInstaller, address: "x",
      vsEdition: "", vsChannel: "Release")).len > 0
    check operationValidationError(PrivilegedOperation(
      kind: pokWindowsVsInstaller, address: "x",
      vsEdition: "BuildTools", vsChannel: "")).len > 0

  test "the planner desired-digest helper covers the vsInstaller kind":
    # `desiredDigestForKind` must route the vsInstaller kind to the
    # vsInstaller digest, not raise (the Phase-A `systemDesiredDigestHex`
    # rejects a non-Phase-A kind).
    let op = PrivilegedOperation(kind: pokWindowsVsInstaller,
      address: "x", vsEdition: "BuildTools", vsChannel: "Release")
    check desiredDigestForKind(op).len == 64
    let destroyOp = PrivilegedOperation(kind: pokWindowsVsInstaller,
      address: "x", vsEdition: "BuildTools", vsChannel: "Release",
      vsDestroy: true)
    check desiredDigestForKind(destroyOp) != desiredDigestForKind(op)

# ===========================================================================
# DESTRUCTIVE: a real VS Build Tools install / modify. VM-ONLY —
# guarded by REPRO_M69_VSINSTALLER_VM=1.
# ===========================================================================

suite "windows.vsInstaller: REAL install (VM-only)":

  test "real VS Build Tools apply (only runs under REPRO_M69_VSINSTALLER_VM=1)":
    if not vmMode:
      echo "  [VM-gated] REPRO_M69_VSINSTALLER_VM not set — the real " &
        "VS Build Tools install / modify scenario is NOT EXERCISED on " &
        "this host (it is host-altering, multi-gigabyte, and " &
        "reboot-prone). Run this gate inside a disposable VM with " &
        "REPRO_M69_VSINSTALLER_VM=1 to exercise the real vs_installer / " &
        "vswhere mutation. The pure-logic suites above already proved " &
        "the vswhere parser, the membership diff, the drift " &
        "classification, the strict-flag policy, and the typed-" &
        "operation wiring without mutating the host."
    else:
      let stateDir = createTempDir("repro-m69-vs-vm-", "")
      defer: removeDir(stateDir)
      writeFile(stateDir / "system.nim", """
windows.vsInstaller {
  edition = "BuildTools"
  channel = "VisualStudio.17.Release"
  installPath = "C:\BuildTools"
  workloads = [
    "Microsoft.VisualStudio.Workload.VCTools",
    "Microsoft.VisualStudio.Workload.MSBuildTools"
  ]
}
""")
      let profileText = readFile(stateDir / "system.nim")
      var opts: ApplyOptions
      opts.stateDir = stateDir
      opts.hostIdentity = "vm-host"
      opts.reproExe = reproBinary()
      opts.elevationMode = emBroker
      opts.forceBroker = false          # the VM runs elevated
      let r = runInfraApply(profileText, opts)
      check r.errorCount == 0
      # vswhere confirms the installed product manifest matches.
      let products = observeVsInstallerState(PrivilegedOperation(
        kind: pokWindowsVsInstaller, address: "vm",
        vsEdition: "BuildTools", vsChannel: "VisualStudio.17.Release",
        vsInstallPath: r"C:\BuildTools",
        vsWorkloads: @["Microsoft.VisualStudio.Workload.VCTools",
                       "Microsoft.VisualStudio.Workload.MSBuildTools"]))
      check classifyDrift(products.diff) == vsdInSync

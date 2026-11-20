## A Windows ARM64 host realizes a native Rust toolchain, and the catalog
## carries the Windows ``gnullvm`` target standard libraries.
##
## THE GAP (reprobuild-pm issue 2026-11-14-a-windows-gnullvm-cross-target-
## cannot-be-declared-through-uses). ``rustc`` and ``cargo``'s Windows
## ``tarball`` arms were ``cpu = "x86_64"`` only, and arm selection has no
## emulation tier (``armPreferenceTier``: an x86_64 arm does not apply to an
## aarch64 host at all), so ``uses: "rustc"`` on Windows ARM64 resolved to
## nothing, although rust-lang publishes ``rust-<ver>-aarch64-pc-windows-msvc``
## for every release the catalog offers. And ``rust-std`` had no row for
## either Windows ``gnullvm`` target, so a cross build for one was refused by
## name at emission.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. The registered
## catalog definitions are turned into the tool use a ``uses:`` line gets
## (``toProjectInterface``, as the conformance sweep does) and planned by the
## production planner (``tarballAcquisitionPlan``) for an explicit target.
## Nothing is downloaded: the archives are 250-300 MB each, the digests are
## upstream's published ones (see the arms' comments), and that the declared
## executable exists in the archive is the conformance sweep's question
## (``tests/integration/t_stdlib_catalog_tarball_arms_realize.nim``), which
## only a Windows ARM64 host can answer for these arms.

import std/[strutils, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
# Imported for their ``package`` blocks, which register the records read
# below; no symbol of either is named.
{.push warning[UnusedImport]: off.}
import repro_dsl_stdlib/packages/rustc
import repro_dsl_stdlib/packages/cargo
{.pop.}
import repro_dsl_stdlib/packages/rust_std
import repro_dsl_stdlib/rust_toolchain_pins

const
  Aarch64WindowsMsvcSha256 = [
    # https://static.rust-lang.org/dist/rust-<ver>-aarch64-pc-windows-msvc.tar.xz.sha256,
    # read 2026-11-18, each equal to the ``xz_hash`` row of
    # https://static.rust-lang.org/dist/channel-rust-<ver>.toml.
    ("1.94.0", "5dced6c4150806b0f845be99146d6a7eb8f583efc3aecda2fb2164b8dfb5690e"),
    ("1.97.1", "839418454d75ac05ce0db02da2081a763d1f386274d279db68861d880d41695f"),
  ]

let
  windowsArm64 = realizationTargetFor(pcAArch64, poWindows)
  windowsX64 = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

proc toolUseFor(constraint: string): InterfaceToolUse =
  ## The tool use a consumer declaring ``uses: "<constraint>"`` gets, built
  ## from the registered stdlib definitions.
  let selector = constraint.splitWhitespace()[0]
  let iface = toProjectInterface(PackageDef(
    packageName: "rustArm64Consumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: constraint, packageSelector: selector,
      executableName: selector, depKind: "native")]), registeredPackages())
  doAssert iface.toolUses.len == 1, "expected one tool use for " & constraint
  iface.toolUses[0]

proc expectedSha(version: string): string =
  for (v, sha) in Aarch64WindowsMsvcSha256:
    if v == version: return sha
  raiseAssert "no pinned aarch64-pc-windows-msvc digest for " & version

suite "rustc / cargo: a Windows ARM64 host selects a native toolchain":

  test "every offered release has one aarch64 Windows arm, written like " &
      "the x86_64 one":
    for name in ["rustc", "cargo"]:
      for release in RustReleases:
        checkpoint name & " " & release.version
        let sha = expectedSha(release.version)
        var arms = 0
        for arm in toolUseFor(name).tarballProvisioning:
          if arm.os != "windows" or arm.cpu != "aarch64" or
              arm.detail.version != release.version:
            continue
          inc arms
          check arm.url == "https://static.rust-lang.org/dist/rust-" &
            release.version & "-aarch64-pc-windows-msvc.tar.xz"
          check arm.sha256 == sha
          check arm.archiveType == "tar.xz"
          check arm.stripComponents == 1
          check arm.executablePath == "bin/" & name & ".exe"
          check arm.packageId == "rust@" & release.version
          check arm.lockIdentity == "tarball:rust@" & release.version &
            ":windows-aarch64:sha256:" & sha
        check arms == 1

  test "uses: rustc / cargo on Windows ARM64 plans the native archive, " &
      "default release first":
    for name in ["rustc", "cargo"]:
      checkpoint name
      let plan = tarballAcquisitionPlan(toolUseFor(name),
        target = windowsArm64)
      check plan.url == "https://static.rust-lang.org/dist/rust-" &
        RustDefaultRelease.version & "-aarch64-pc-windows-msvc.tar.xz"
      check plan.sha256 == expectedSha(RustDefaultRelease.version)

  test "a range past the default release plans 1.97.1's ARM64 archive":
    for name in ["rustc", "cargo"]:
      checkpoint name
      let plan = tarballAcquisitionPlan(toolUseFor(name & " >=1.95"),
        target = windowsArm64)
      check plan.url == "https://static.rust-lang.org/dist/" &
        "rust-1.97.1-aarch64-pc-windows-msvc.tar.xz"
      check plan.sha256 == expectedSha("1.97.1")

  test "Windows x86_64 still plans the x86_64 msvc archive":
    let plan = tarballAcquisitionPlan(toolUseFor("rustc"), target = windowsX64)
    check plan.url == "https://static.rust-lang.org/dist/rust-" &
      RustDefaultRelease.version & "-x86_64-pc-windows-msvc.tar.xz"

  test "rustc and cargo realize one ARM64 prefix":
    # One archive, one lock identity: the two selectors realize the same
    # prefix, as on every other platform.
    let r = tarballAcquisitionPlan(toolUseFor("rustc"), target = windowsArm64)
    let c = tarballAcquisitionPlan(toolUseFor("cargo"), target = windowsArm64)
    check r.url == c.url
    check r.sha256 == c.sha256

suite "rust-std: the Windows gnullvm target components":

  test "each offered release catalogues both gnullvm targets":
    for release in RustReleases:
      for (triple, cpu) in [("x86_64-pc-windows-gnullvm", "x86_64"),
                            ("aarch64-pc-windows-gnullvm", "aarch64")]:
        checkpoint release.version & " " & triple
        let c = rustStdComponent(triple, release.version)
        check c.cpu == cpu
        check c.os == "windows"
        check c.sha256.len == 64
        check rustStdUrl(c) == "https://static.rust-lang.org/dist/rust-std-" &
          release.version & "-" & triple & ".tar.gz"

  test "the default release's digests are upstream's":
    # rust-std-1.94.0-<triple>.tar.gz.sha256, read 2026-11-18, equal to the
    # ``hash`` rows of channel-rust-1.94.0.toml and to the digests the issue
    # recorded on 2026-11-14.
    check rustStdComponent("x86_64-pc-windows-gnullvm").sha256 ==
      "881b1cd467ac69dd8b0cf3e3f099bcc5051c64f5e7841ea7a018f31fc8899a87"
    check rustStdComponent("aarch64-pc-windows-gnullvm").sha256 ==
      "8afeb73b427d9039f44cddee301245a043f60220c44ba98581d3afec1f6e4406"

  test "the gnullvm arms are keyed by the target and name a file the " &
      "component carries":
    var arms = 0
    for arm in toolUseFor("rust-std").tarballProvisioning:
      if arm.os != "windows": continue
      inc arms
      let triple = arm.cpu & "-pc-windows-gnullvm"
      checkpoint arm.url
      check ("-" & triple & ".tar.gz") in arm.url
      # The self-contained CRT start-up object: a gnullvm component has no
      # ``libc.a`` (listed 2026-11-18 from both 1.94.0 archives).
      check arm.executablePath == "lib/rustlib/" & triple &
        "/lib/self-contained/crt2.o"
      check (":windows-" & arm.cpu & ":sha256:" & arm.sha256) in
        arm.lockIdentity
    check arms == 2 * RustReleases.len

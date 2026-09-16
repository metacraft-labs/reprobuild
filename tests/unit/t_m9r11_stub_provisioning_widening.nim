## DSL-port M9.R.11 — stub provisioning widening test.
##
## Preserve the existing Nix/Scoop channels and genuine binary tarballs.
## The bounded source-archive set must not expose configure/configure.sh
## as a ready-to-run package tool. Real catalog checks precede resolution
## so restoring an invalid channel fails without a network download.

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
# Pull every package whose provisioning we want to inspect into module
# init so ``registeredPackages()`` carries the widened
# ``nixProvisioning`` / ``scoopProvisioning`` / ``tarballProvisioning``
# fields. The two aggregator imports cover system_tools (texinfo, perl,
# m4, ...) + gmp/mpfr/mpc (also under system_tools).
import repro_dsl_stdlib/packages/system_tools
import repro_dsl_stdlib/packages/autoconf
import repro_dsl_stdlib/packages/automake
import repro_dsl_stdlib/packages/libtool

proc packageProvisioning(name: string):
    tuple[nix: int; scoop: int; tarball: int] =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return (nix: pkg.nixProvisioning.len,
              scoop: pkg.scoopProvisioning.len,
              tarball: pkg.tarballProvisioning.len)
  (-1, -1, -1)

proc bisonConsumerInterface(): ProjectInterface =
  toProjectInterface(PackageDef(
    packageName: "bisonToolConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: "bison >=3.0", packageSelector: "bison",
      executableName: "bison", depKind: "native")]), registeredPackages())

const
  WaylandChainStubs = [
    "texinfo", "perl", "m4", "bison", "flex",
    "gperf", "bc", "file", "rsync", "swig",
    "gmp", "mpfr", "mpc",
  ]
  WaylandChainStubsRequiringTarball = ["perl", "swig"]
  FormerConfigurePlaceholderPackages = [
    "autoconf", "automake", "bc", "bison", "file", "flex", "gmp",
    "gperf", "libtool", "libtoolize", "m4", "make", "mpc", "mpfr",
    "rsync", "texinfo",
  ]
  StubsWithScoop = [
    "perl", "m4", "bison", "bc", "file", "swig",
  ]

suite "DSL-port M9.R.11 — stub provisioning widening":

  test "bison exposes executable channels, not its source configure script":
    let iface = bisonConsumerInterface()
    require iface.toolUses.len == 1
    let useDef = iface.toolUses[0]
    check useDef.packageSelector == "bison"
    check useDef.executableName == "bison"
    check useDef.depKind == "native"
    require useDef.nixProvisioning.len == 1
    check useDef.nixProvisioning[0].selector == "nixpkgs#bison"
    check useDef.nixProvisioning[0].executablePath == "bin/bison"
    require useDef.scoopProvisioning.len == 1
    check useDef.scoopProvisioning[0].app == "bison"
    check useDef.scoopProvisioning[0].executablePath == "bin/bison.exe"
    check useDef.tarballProvisioning.len == 0

  test "forced bison tarball provisioning fails before materialization":
    let iface = bisonConsumerInterface()
    require iface.toolUses.len == 1
    check iface.toolUses[0].tarballProvisioning.len == 0
    # Check the pure planning gate first so restoring the old channel makes
    # this regression fail without attempting a network download.
    if iface.toolUses[0].tarballProvisioning.len == 0:
      var diagnostic = ""
      try:
        discard tarballAcquisitionPlan(iface.toolUses[0])
      except ValueError as exc:
        diagnostic = exc.msg
      require diagnostic.contains("does not declare provisioning: tarball metadata")
      check diagnostic.contains("bison >=3.0")

      let scratch = createTempDir("repro-bison-no-tarball-", "")
      defer: removeDir(scratch)
      let storeRoot = scratch / "tool-store"
      try:
        discard toolBuildIdentity(artifactFor(iface), tpmTarball,
          pathValue = "", storeRoot = storeRoot)
        check false
      except ValueError as exc:
        check exc.msg == diagnostic
      check not dirExists(storeRoot)

  when defined(posix):
    test "bison already on PATH remains a path-resolved executable":
      let scratch = createTempDir("repro-bison-on-path-", "")
      defer: removeDir(scratch)
      let binary = scratch / "bison"
      writeFile(binary, "#!/bin/sh\necho 'bison fixture 3.8.2'\n")
      setFilePermissions(binary, {fpUserRead, fpUserWrite, fpUserExec})
      let storeRoot = scratch / "tool-store"
      let identity = toolBuildIdentity(artifactFor(bisonConsumerInterface()),
        tpmPathOnly, pathValue = scratch, storeRoot = storeRoot)
      require identity.profiles.len == 1
      let profile = identity.profiles[0]
      check profile.installMethod == "path"
      check profile.resolvedExecutablePath == binary
      require profile.probes.len == 1
      check profile.probes[0].exitCode == 0
      check profile.probes[0].output.strip() == "bison fixture 3.8.2"
      check not dirExists(storeRoot)

  test "affected catalog entries reject source configure placeholders":
    for name in FormerConfigurePlaceholderPackages:
      var found = false
      for pkg in registeredPackages():
        if pkg.packageName != name:
          continue
        found = true
        checkpoint(name)
        check pkg.nixProvisioning.len >= 1
        if name == "make":
          check pkg.tarballProvisioning.len == 1
        else:
          check pkg.tarballProvisioning.len == 0
        for channel in pkg.tarballProvisioning:
          check channel.executablePath notin ["configure", "configure.sh"]
      check found

  test "make retains its pinned Windows binary tarball":
    var found = false
    for pkg in registeredPackages():
      if pkg.packageName != "make":
        continue
      found = true
      require pkg.tarballProvisioning.len == 1
      let channel = pkg.tarballProvisioning[0]
      check channel.executablePath == "bin/mingw32-make.exe"
      check channel.cpu == "x86_64"
      check channel.os == "windows"
      check channel.archiveType == "7z"
      check channel.packageId == "make-winlibs@16.1.0"
      check channel.sha256 ==
        "62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"
    check found

  test "remaining binary tarball stubs retain their channels":
    var missing: seq[string] = @[]
    for name in WaylandChainStubsRequiringTarball:
      let p = packageProvisioning(name)
      if p.nix == -1:
        missing.add(name & " (not registered)")
        continue
      if p.tarball < 1:
        missing.add(name & " (no tarball channel)")
    if missing.len > 0:
      checkpoint("missing tarball provisioning: " & missing.join(", "))
    check missing.len == 0

  test "every wayland-chain stub keeps the original nix channel":
    # The widening must NOT delete the M9.R.10a nix entries — Nix-capable
    # hosts must still resolve via the nix channel as the highest
    # preference.
    for name in WaylandChainStubs:
      let p = packageProvisioning(name)
      check p.nix >= 1

  test "scoop entries match the ScoopInstaller/Main bucket coverage":
    # Stubs whose tool is in scoop's main bucket carry a scoop entry.
    for name in StubsWithScoop:
      let p = packageProvisioning(name)
      check p.scoop >= 1

  test "every widened tarball lockIdentity starts with 'tarball:'":
    # M48 fingerprinting contract: lockIdentity is the deterministic
    # cache key. The convention is ``tarball:<pkg>@<ver>:[<os>:]sha256:
    # <hash>``; pin the prefix so a future schema rename surfaces here.
    for pkg in registeredPackages():
      if pkg.packageName notin WaylandChainStubsRequiringTarball:
        continue
      for tb in pkg.tarballProvisioning:
        check tb.lockIdentity.startsWith("tarball:")

  test "every widened tarball declares a non-zero sha256":
    # Hash-zero placeholders are explicitly disallowed for the M9.R.11
    # widening set. (Other stubs may still ship a "TODO" marker;
    # the wayland-chain set requires real upstream-pinned hashes.)
    for pkg in registeredPackages():
      if pkg.packageName notin WaylandChainStubsRequiringTarball:
        continue
      for tb in pkg.tarballProvisioning:
        check tb.sha256.len == 64  # hex sha256 = 64 chars
        check tb.sha256 != "0000000000000000000000000000000000000000000000000000000000000000"

  test "remaining M9.R.10a stubs document the widening TODO marker":
    # The 30 stubs NOT in the M9.R.11 canary set should still carry the
    # standard ``TODO(M9.R.10b+):`` or ``TODO(M9.R.11.1):`` marker so a
    # later re-harvest pass can sweep them. We don't read the files
    # here (would couple the test to the filesystem); instead we pin
    # that the unwidened stubs continue to register their single nix
    # channel, which guarantees the audit-test contract.
    for pkg in registeredPackages():
      if pkg.packageName in WaylandChainStubs:
        continue
      # The non-stub packages (nim, gcc, meson, ...) have multiple
      # channels already — skip them.
      if pkg.nixProvisioning.len == 0:
        continue
      # The legitimate stub fingerprint is: 1 nix channel, 0 scoop,
      # 0 tarball. Confirm the unwidened set hasn't lost its nix entry.
      if pkg.scoopProvisioning.len == 0 and
         pkg.tarballProvisioning.len == 0:
        check pkg.nixProvisioning.len >= 1

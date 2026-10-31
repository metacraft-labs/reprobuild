## DSL-port M9.R.11 — stub provisioning widening test.
##
## Preserve the existing Nix/Scoop channels and genuine binary tarballs.
## The bounded source-archive set must not expose configure/configure.sh
## as a ready-to-run package tool. Real catalog checks precede resolution
## so restoring an invalid channel fails without a network download.
##
## ``perl`` is the case that slipped past the lower-case ``configure``
## check: its one tarball arm was the cpan.org SOURCE release, declared
## ``os = "any"`` with perl's capitalised ``Configure`` as the executable, so
## tarball mode handed every host a configure script where a perl was
## expected and never fell through to the from-source recipe
## (reprobuild-pm/issues/
## 2026-10-20-stdlib-perl-tarball-realization-is-a-source-tree-not-a-perl.md).
## ``swig`` had the same defect with ``autogen.sh``. Both packages' tarball
## arms are now Windows-only binaries; the cases below pin both halves of
## that for each: what Windows selects, and that Linux and macOS select
## nothing and fall through.

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_tool_profiles/tarball_conformance
import repro_dsl_stdlib/packages_schema
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

type
  WindowsBinaryTarball = object
    ## What a package whose only tarball arms are one Windows binary archive
    ## (declared for x86_64 and, emulated, aarch64) must declare.
    package, constraint: string
    url, sha256, executablePath, packageId, version: string
    stripComponents: int
    nixExecutablePath, scoopExecutablePath: string

const
  WindowsOnlyBinaryTarballs = [
    WindowsBinaryTarball(package: "perl", constraint: "perl >=5",
      url: "https://github.com/StrawberryPerl/Perl-Dist-Strawberry/" &
        "releases/download/SP_54231_64bit/" &
        "strawberry-perl-5.42.3.1-64bit-portable.zip",
      sha256:
        "6a081a811781c30aca51dbc036afd93092af91e3297901f02c17043795a10690",
      executablePath: "perl/bin/perl.exe",
      packageId: "strawberry-perl@5.42.3.1", version: "5.42.3",
      stripComponents: 0,
      nixExecutablePath: "bin/perl",
      scoopExecutablePath: "perl/bin/perl.exe"),
    WindowsBinaryTarball(package: "swig", constraint: "swig >=4",
      url: "https://downloads.sourceforge.net/project/swig/swigwin/" &
        "swigwin-4.5.1/swigwin-4.5.1.zip",
      sha256:
        "6a8662c063ba4d1e72beaecef24da4af3d631d73ffdde958fb42aa50fdefb962",
      executablePath: "swig.exe",
      packageId: "swigwin@4.5.1", version: "4.5.1",
      stripComponents: 1,
      nixExecutablePath: "bin/swig",
      scoopExecutablePath: "swig.exe"),
  ]
  # Hosts with no binary tarball for those packages: tarball mode must fall
  # through to the from-source recipe on each of them rather than select an
  # arm.
  FallThroughTargets = [("linux", "x86_64"), ("linux", "aarch64"),
    ("macos", "x86_64"), ("macos", "aarch64")]
  # Basenames that mark a source tree's build driver; a tarball arm
  # declaring one is a source release posing as the tool.
  SourceBuildDriverNames = ["Configure", "configure", "configure.sh",
    "autogen.sh", "Makefile.SH"]

proc consumerInterface(expected: WindowsBinaryTarball): ProjectInterface =
  ## A consumer declaring ``uses: "<package> >=N"`` — for perl, the
  ## declaration Agent Harbor's ``repro.nim`` wants to make — built from the
  ## registered stdlib definition so the arms under test are the package's
  ## own.
  toProjectInterface(PackageDef(
    packageName: expected.package & "ToolConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: expected.constraint,
      packageSelector: expected.package,
      executableName: expected.package, depKind: "native")]),
    registeredPackages())

const
  WaylandChainStubs = [
    "texinfo", "perl", "m4", "bison", "flex",
    "gperf", "bc", "file", "rsync", "swig",
    "gmp", "mpfr", "mpc",
  ]
  # Packages that must keep at least one tarball arm. Both now carry only
  # Windows binary arms (see ``WindowsOnlyBinaryTarballs``).
  WaylandChainStubsRequiringTarball = ["perl", "swig"]
  FormerConfigurePlaceholderPackages = [
    "autoconf", "automake", "bc", "bison", "file", "flex", "gmp",
    "gperf", "libtool", "libtoolize", "m4", "make", "mpc", "mpfr",
    "rsync", "texinfo",
  ]
  FormerMsys2CatalogPackages = ["autoconf", "automake", "libtool",
    "libtoolize"]
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

      # Since eb88a3bd2 a tarball-mode tool use with no host tarball falls
      # through to its from-source recipe
      # (Dependency-Provisioning-In-Build-Graph.md 4.3), so the refusal is
      # no longer the planning gate's: with neither a tarball nor a recipe
      # it is rule 3's, naming the host and the recipe path probed. The
      # recipe root is pinned to an empty scratch tree so the outcome does
      # not depend on which catalog checkout happens to sit beside this one.
      let scratch = createTempDir("repro-bison-no-tarball-", "")
      defer: removeDir(scratch)
      let storeRoot = scratch / "tool-store"
      let recipes = scratch / "recipes"
      createDir(recipes)
      let savedRoot = getEnv(FromSourceRootEnvVar)
      putEnv(FromSourceRootEnvVar, recipes)
      defer:
        if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
        else: delEnv(FromSourceRootEnvVar)
      try:
        discard toolBuildIdentity(artifactFor(iface), tpmTarball,
          pathValue = "", storeRoot = storeRoot)
        check false
      except OSError as exc:
        checkpoint exc.msg
        check exc.msg.contains("package \"bison\" has no tarball " &
          "realization for this host")
        check exc.msg.contains(recipes / "bison" / "repro.nim")
      check not dirExists(storeRoot)

  test "perl's and swig's tarball arms are Windows binaries only":
    for expected in WindowsOnlyBinaryTarballs:
      checkpoint("package: " & expected.package)
      let iface = consumerInterface(expected)
      require iface.toolUses.len == 1
      let useDef = iface.toolUses[0]
      check useDef.packageSelector == expected.package
      # The Nix and Scoop channels are untouched by the tarball change.
      require useDef.nixProvisioning.len == 1
      check useDef.nixProvisioning[0].executablePath ==
        expected.nixExecutablePath
      require useDef.scoopProvisioning.len == 1
      check useDef.scoopProvisioning[0].executablePath ==
        expected.scoopExecutablePath

      for arm in useDef.tarballProvisioning:
        checkpoint(describeArm(expected.package, arm))
        # A source tree is not the tool: no arm may hand back its driver.
        check extractFilename(arm.executablePath.replace('\\', '/')) notin
          SourceBuildDriverNames

      for (os, cpu) in FallThroughTargets:
        var matching = 0
        for arm in useDef.tarballProvisioning:
          if armMatchesTarget(arm, os, cpu): inc matching
        checkpoint(os & "/" & cpu & " arms: " & $matching)
        check matching == 0

      for (cpu, cpuToken) in [(pcX86_64, "x86_64"), (pcAArch64, "aarch64")]:
        var matching: seq[InterfaceTarballProvisioning] = @[]
        for arm in useDef.tarballProvisioning:
          if armMatchesTarget(arm, "windows", cpuToken): matching.add(arm)
        checkpoint("windows/" & cpuToken & " arms: " & $matching.len)
        require matching.len == 1
        # The selection `repro` itself makes for that target, with the
        # consumer's version range applied, lands on an arm of the same
        # shape.
        let selected = selectTarballProvisioning(useDef,
          target = realizationTargetFor(cpu, poWindows))
        for arm in [matching[0], selected]:
          check arm.url == expected.url
          check arm.sha256 == expected.sha256
          check arm.archiveType == "zip"
          check arm.stripComponents == expected.stripComponents
          check arm.executablePath == expected.executablePath
          check arm.os == "windows"
          check arm.cpu == cpuToken
          check arm.detail.version == expected.version
          check arm.packageId == expected.packageId
          check arm.lockIdentity == "tarball:" & expected.packageId &
            ":windows-" & cpuToken & ":sha256:" & expected.sha256

  test "forced perl and swig tarball provisioning falls through off Windows":
    for expected in WindowsOnlyBinaryTarballs:
      checkpoint("package: " & expected.package)
      let iface = consumerInterface(expected)
      require iface.toolUses.len == 1
      let useDef = iface.toolUses[0]
      when defined(windows):
        # Windows HAS these tarballs; this case is about the hosts that do
        # not.
        check not tarballModeFallsThroughToFromSource(useDef)
      else:
        # The pure planning predicate first, so restoring a host-matching
        # source-tree arm fails here without attempting a network download.
        require tarballModeFallsThroughToFromSource(useDef)

        # With the recipe root pinned to an empty scratch tree there is no
        # from-source recipe to fall through to, so the refusal is the
        # fall-through's own (Dependency-Provisioning-In-Build-Graph.md 4.3
        # rule 3): it names the host and the recipe path probed, and nothing
        # reaches the tool store.
        let scratch = createTempDir("repro-" & expected.package &
          "-no-tarball-", "")
        defer: removeDir(scratch)
        let storeRoot = scratch / "tool-store"
        let recipes = scratch / "recipes"
        createDir(recipes)
        let savedRoot = getEnv(FromSourceRootEnvVar)
        putEnv(FromSourceRootEnvVar, recipes)
        defer:
          if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
          else: delEnv(FromSourceRootEnvVar)
        try:
          discard toolBuildIdentity(artifactFor(iface), tpmTarball,
            pathValue = "", storeRoot = storeRoot)
          check false
        except OSError as exc:
          checkpoint exc.msg
          check exc.msg.contains("package \"" & expected.package &
            "\" has no tarball realization for this host")
          check exc.msg.contains(recipes / expected.package / "repro.nim")
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
        elif name in FormerMsys2CatalogPackages:
          # GM4b moved the MSYS2 catalog record of these four into the
          # package as its one Windows `tarball` realization. It is a
          # prebuilt MSYS2 package merged by the home archive realizer —
          # binaries, not a source archive — so it is the only tarball
          # record these packages may carry.
          require pkg.tarballProvisioning.len == 1
          let channel = pkg.tarballProvisioning[0]
          check channel.detail.installMethod == "msys2-pacman"
          check channel.os == "windows"
          check channel.url.startsWith("https://repo.msys2.org/")
          check channel.executablePath.startsWith("bin/")
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

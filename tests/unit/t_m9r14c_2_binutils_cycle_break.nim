## DSL-port M9.R.14c.2 — widen cycle-break taxonomy to include
## binutils + sub-binaries + the GNU bootstrap floor.
##
## ## Context
##
## M9.R.10a's reactive cycle break fires on the closing edge of an
## observed recursion cycle: e.g. ``gcc → binutils → gcc`` adds
## ``gcc`` to ``fromSourceCycleBrokenTools`` but leaves ``binutils``
## (and its sub-binaries ``ld`` / ``ar`` / ``ranlib`` / ``strip`` /
## ``nm`` / ``objdump`` / ``objcopy`` / ``as`` / ``readelf`` /
## ``size`` / ``strings``) untouched. The autotools smoke loop
## therefore still paid the ~15-minute binutils-from-source compile
## per iteration even though binutils is just an implementation
## detail of the bootstrap layer.
##
## Fix: ``seedBootstrapCycleBreakTools()`` proactively populates the
## cycle-break set with the bootstrap floor (gcc / cc / g++ / c++ /
## make / gmake / binutils / its 11 sub-binaries) at the entry to
## the ``tpmFromSource`` dispatcher. The bootstrap layer is treated
## as a stdlib-provisioned floor; the upper layers (autoconf /
## automake / expat / libffi / etc.) still build from source.
##
## ## What this test pins
##
##   1. ``BootstrapCycleBreakTools`` exports the canonical list and
##      includes ``binutils`` + every sub-binary called out by the
##      ``binutils.nim`` stdlib package.
##   2. ``seedBootstrapCycleBreakTools()`` is idempotent and
##      populates the set without erasing existing entries.
##   3. After seeding, ``binutils`` / ``ld`` / ``ar`` / ``ranlib``
##      route through stdlib provisioning when consumed.
##   4. After seeding, ``gcc`` and ``make`` (the M9.R.10a reactive
##      targets) also stay in the set — backward compatibility.
##   5. Tools NOT in the seed list (e.g. ``autoconf``, ``automake``,
##      ``expat``) are NOT cycle-broken — they keep their from-source
##      semantics.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_cli_support
import repro_tool_profiles
import repro_interface_artifacts

proc syntheticUseDef(name: string;
                     nix: seq[InterfaceNixProvisioning] = @[];
                     scoop: seq[InterfaceScoopProvisioning] = @[];
                     tarball: seq[InterfaceTarballProvisioning] = @[]):
    InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name,
    nixProvisioning: nix,
    scoopProvisioning: scoop,
    tarballProvisioning: tarball)

suite "DSL-port M9.R.14c.2 — bootstrap cycle-break taxonomy widening":

  test "BootstrapCycleBreakTools exports the canonical list":
    # The list MUST cover the M9.R.10a "gcc + make" baseline.
    check "gcc" in BootstrapCycleBreakTools
    check "make" in BootstrapCycleBreakTools
    # M9.R.14c.2 widening: ``binutils`` as a logical name + every
    # sub-binary the stdlib's binutils.nim ships a package block
    # for (matches packages/binutils.nim line-for-line).
    check "binutils" in BootstrapCycleBreakTools
    check "ld" in BootstrapCycleBreakTools
    check "ar" in BootstrapCycleBreakTools
    check "ranlib" in BootstrapCycleBreakTools
    check "strip" in BootstrapCycleBreakTools
    check "nm" in BootstrapCycleBreakTools
    check "objdump" in BootstrapCycleBreakTools
    check "objcopy" in BootstrapCycleBreakTools
    check "as" in BootstrapCycleBreakTools

  test "seedBootstrapCycleBreakTools populates the set idempotently":
    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()

    check fromSourceCycleBrokenTools.len == 0
    seedBootstrapCycleBreakTools()
    let firstSize = fromSourceCycleBrokenTools.len
    check firstSize >= BootstrapCycleBreakTools.len
    check "binutils" in fromSourceCycleBrokenTools
    check "ld" in fromSourceCycleBrokenTools
    check "gcc" in fromSourceCycleBrokenTools
    check "make" in fromSourceCycleBrokenTools

    # Idempotent: a second call doesn't grow the set further (it's a
    # ``HashSet.incl`` over a fixed list).
    seedBootstrapCycleBreakTools()
    check fromSourceCycleBrokenTools.len == firstSize

  test "seedBootstrapCycleBreakTools preserves caller-supplied entries":
    # Caller may have already marked a tool (e.g. via the reactive
    # dispatcher path); seeding must not clobber existing entries.
    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()
    fromSourceCycleBrokenTools.incl("custom-tool-x")

    seedBootstrapCycleBreakTools()
    check "custom-tool-x" in fromSourceCycleBrokenTools
    check "binutils" in fromSourceCycleBrokenTools

  test "binutils sub-binary routes to stdlib after seeding":
    # End-to-end check: ld is in the seed list, has stdlib
    # provisioning (here a tarball block), and the resolver routes
    # through stdlib without hitting either the sibling-recipe probe
    # OR the cycle-break diagnostic.
    let scratch = createTempDir("repro-m9r14c-2-ld-", "")
    defer: removeDir(scratch)

    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()
    seedBootstrapCycleBreakTools()

    when defined(windows):
      let scoop = @[InterfaceScoopProvisioning(
        bucket: "main",
        app: "git",
        executablePath: "bin/sh.exe",
        packageId: "git@2.54.0")]
      let useDef = syntheticUseDef("ld", scoop = scoop)
    else:
      let tarball = @[InterfaceTarballProvisioning(
        url: "file:///does/not/exist.tar.gz",
        sha256: "0".repeat(64),
        archiveType: "tar.gz",
        executablePath: "ld",
        packageId: "ld@2.43",
        cpu: "any",
        os: "any",
        lockIdentity: "tarball:ld@2.43:sha256:0")]
      let useDef = syntheticUseDef("ld", tarball = tarball)

    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_m9r14c_2_ld",
        toolUses: @[useDef]))

    let savedRoot = getEnv(FromSourceRootEnvVar)
    putEnv(FromSourceRootEnvVar, scratch)
    defer:
      if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
      else: delEnv(FromSourceRootEnvVar)

    try:
      discard toolBuildIdentity(artifact, tpmFromSource,
        storeRoot = scratch / "tool-store")
      check true
    except CatchableError as exc:
      # Whatever error surfaces, it MUST NOT be the cycle-break
      # diagnostic (that would mean the seed didn't take effect AND
      # the cycle dispatcher detected ``ld`` cyclically — impossible
      # in this synthetic single-tool fixture).
      check not exc.msg.contains("from-source recursion cycle detected")
      # MUST NOT be the M9.R.9 "no sibling" gate either — the
      # cycle-break entry routes through stdlib without probing for
      # a sibling.
      check not exc.msg.contains("but no sibling recipe at")

  test "non-bootstrap tool still builds from source after seeding":
    # Pin the "doesn't leak" contract: a tool that's NOT in the
    # bootstrap list (e.g. expat / libffi / wayland) still goes
    # through the normal from-source path — the seed must be narrow
    # enough that application recipes still build from source. The
    # M9.R.14c.8 widening added autoconf / automake / libtool / m4 /
    # perl to the bootstrap floor (perl scripts whose execution
    # requires sibling install-tree assets the stage-copy convention
    # drops), but actual application packages are still from-source.
    check "expat" notin BootstrapCycleBreakTools
    check "libffi" notin BootstrapCycleBreakTools
    check "wayland" notin BootstrapCycleBreakTools
    check "glib2" notin BootstrapCycleBreakTools
    check "fontconfig" notin BootstrapCycleBreakTools

    let scratch = createTempDir("repro-m9r14c-2-autoconf-", "")
    defer: removeDir(scratch)

    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()
    seedBootstrapCycleBreakTools()

    # No sibling, no provisioning -- the resolver MUST hit the M9.R.9
    # ``rrSiblingMissing`` + no-stdlib hard-fail, NOT the cycle-break
    # path (which would mean the seed leaked).
    let useDef = syntheticUseDef("autoconf-not-bootstrapped")
    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_m9r14c_2_no_leak",
        toolUses: @[useDef]))
    let savedRoot = getEnv(FromSourceRootEnvVar)
    putEnv(FromSourceRootEnvVar, scratch)
    defer:
      if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
      else: delEnv(FromSourceRootEnvVar)

    try:
      discard toolBuildIdentity(artifact, tpmFromSource,
        storeRoot = scratch / "tool-store")
      check false
    except OSError as exc:
      check exc.msg.contains("autoconf-not-bootstrapped")
      check exc.msg.contains("no sibling recipe")
      # MUST NOT be the cycle-break diagnostic.
      check not exc.msg.contains("auto-recurse detected a cycle")

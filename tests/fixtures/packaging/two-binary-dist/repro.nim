## M0 gate fixture — ONE ``Distribution`` definition, three formats.
##
## Distribution-And-Packaging.milestones.org M0's gate, as amended by
## user decision: "From a single ``Distribution`` definition for a
## trivial two-binary sample project, ``repro build`` produces a valid
## ``.deb`` AND a valid ``.msi``, each installing to the declared prefix
## with the wrapper/RPATH contract applied", with ``.tar.gz`` kept as
## the cheap control.
##
## The single definition is ``sampleDistribution`` below. Everything
## after it is producer selection — the producers read the same value
## and translate it, which is the property §6 calls "one source of truth
## for package metadata, components, service wiring, and the runtime
## contract".
##
## ## Why the target OS is chosen here and not in the layer
##
## ``hostTargetOs`` is the only ``defined(windows)`` in the whole
## exercise, and it is deliberately in the RECIPE. The packaging layer
## never asks what host it is running on: ``Distribution.targetOs`` is a
## property of the tree being staged, exactly as
## ``prefix_layout.PrefixLayout`` is a property of the prefix. Keeping
## the host question at the edge is what makes a cross-staged tree
## expressible at all, and it is why the layer has no host-conditional
## code to get wrong.
##
## ## Why the format set differs per host
##
## §6.1: "an unavailable format is just an unresolvable dependency,
## surfaced through the normal mechanism". There is no host ``dpkg-deb``
## on Windows and no host ``candle.exe`` on Linux, so each host builds
## the formats whose tool packages resolve for it. Nothing in the engine
## knows this; the recipe simply does not ask for a producer whose tool
## it cannot get.

import repro_project_dsl
import repro_dsl_stdlib/packaging

const SampleVersion = "0.2.0"

func hostTargetOs(): TargetOs =
  when defined(windows): toWindows
  elif defined(macosx): toDarwin
  else: toLinux

proc sampleDistribution(targetOs: TargetOs;
                        helloEdge, adderEdge: BuildActionDef): Distribution =
  ## THE single definition. Read by every producer below.
  let exeSuffix = (if targetOs == toWindows: ".exe" else: "")
  result = newDistribution("sampletool", SampleVersion, targetOs,
    prefix = (if targetOs == toWindows: "" else: "/usr"),
    layout = (if targetOs == toWindows: plWindowsTree else: plUnix),
    stagingRoot = "build/dist/sampletool-" & SampleVersion,
    outputDir = "build/dist")

  # --- the §5 contract, stated once ---------------------------------
  #
  # A real project's list is much longer — reprobuild's own is the
  # twenty names in ``runtime_contract.ReprobuildWrapperVariables``,
  # derived from flake.nix's wrapProgram loop. Two entries are enough
  # for the gate because what is under test is that the layer APPLIES
  # the contract identically to every format, not how long the list is.
  #
  # ``@PREFIX@`` is expanded by the wrapper at RUN time, not at
  # generation time, which is what lets the same staged tree serve the
  # fixed-prefix formats (deb, msi) and the relocatable tarball.
  result.runtime.envDefaults = @[
    ("SAMPLETOOL_DATA_DIR", "@PREFIX@/share/sampletool"),
    ("SAMPLETOOL_MODE", "packaged")
  ]
  result.runtime.privateLibSubdir = "lib/sampletool"
  # EMPTY, and examined rather than defaulted.
  #
  # ``dlopenLeafNames`` exists because ``DT_NEEDED`` cannot see a
  # ``dlopen``: the closure walk reads an ELF's declared dependencies,
  # and a library opened by name at run time appears in no ELF. The
  # field is the recipe's chance to say what the walk cannot discover,
  # and the layer treats it as a CHECKED POST-CONDITION -- every name in
  # it must resolve into the private libdir or the build fails.
  #
  # These two binaries open nothing. ``hello.nim`` and ``adder.nim``
  # import ``std/os`` and ``std/strutils`` and call neither
  # ``std/dynlib`` nor any FFI that would; their whole library closure
  # is what the linker recorded, which is what the walk finds by itself.
  # So an empty list here is a true statement about this sample, not an
  # unexamined default -- reprobuild's own distribution will have
  # entries (zstd and clingo, per Distribution-And-Packaging.md
  # section 5) and M1 is what supplies them.
  #
  # The cost of the honest answer is worth recording: with nothing
  # declared, the dlopen ARM of the walk is exercised by unit cases
  # rather than by this end-to-end fixture. Making it real would mean
  # giving the sample a shared library of its own to open by leaf name;
  # that is a bigger fixture than "a trivial two-binary sample project",
  # which is what the gate asks for.
  result.runtime.dlopenLeafNames = @[]
  result.runtime.wrapExecutables = true

  result.components = @[
    executableComponent("build/bin/hello" & exeSuffix, @[helloEdge]),
    executableComponent("build/bin/adder" & exeSuffix, @[adderEdge])
  ]

  # --- services -----------------------------------------------------
  #
  # Declared, and rendered by both the deb producer (a systemd unit plus
  # postinst/prerm) and the MSI producer (ServiceInstall/ServiceControl
  # rows plus the SCM's Environment registry value), so M0 discharges
  # its obligation that a service-installing package be EXPRESSIBLE.
  # The eventual consumer is runquota — a daemon plus a CLI, with a
  # Windows Service on Windows and systemd/launchd on Unix — and this
  # entry exists to prove ``ServiceDef`` is the right shape for it, not
  # to package anything.
  #
  # It is deliberately NOT started at boot. A fixture that enabled a
  # service on the machine running the test would be changing the state
  # of the host to test a build.
  result.services = @[
    ServiceDef(
      name: "sampletool-daemon",
      displayName: "Sample Tool Daemon",
      description: "M0 packaging fixture service (does not start at boot)",
      scope: ssSystem,
      execComponent: "hello" & exeSuffix,
      execArgs: @["--serve"],
      environment: @[("SAMPLETOOL_ROLE", "daemon")],
      startAtBoot: false,
      restartOnFailure: true,
      after: @["network.target"])
  ]

  result.metadata = DistMetadata(
    summary: "Reprobuild packaging-layer sample tool",
    description: "A trivial two-binary distribution used to verify " &
      "reprobuild's DSL packaging layer end to end.\n" &
      "It exists only as a test fixture.",
    maintainer: "Reprobuild Developers <dev@reprobuild.invalid>",
    vendor: "Reprobuild",
    license: "MIT",
    homepage: "https://github.com/metacraft-labs/reprobuild",
    section: "devel",
    priority: "optional",
    # A GUID generated once and pasted, per the MSI producer's refusal
    # to invent one: it is what makes two releases of this product an
    # upgrade rather than two side-by-side installs, so it must be
    # constant across versions and unique to the product.
    upgradeCode: "{6E2A9B84-3C1D-4F57-9A20-7D5E8C41B0F3}")

package sampletool:
  config:
    sourceRepository = "https://example.invalid/sampletool.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-fixture"

  uses:
    "nim >=2.2 <3.0"
    # nim shells out to a C compiler, and a build action's PATH is
    # composed only of the tools the graph resolved FOR THAT EDGE — so
    # an undeclared gcc is not "picked up from the shell", it is a
    # build failure. See the same three-line note in reprobuild's own
    # ``repro.nim``.
    "gcc >=12"
    # The producers declare these themselves at the EDGE level (see
    # ``runtime_contract.declareProducerTool``), which is what puts each
    # tool's bin directory on its own action's PATH. These literals are
    # the package-level half: reprobuild collects a package's tool
    # dependencies at macro-expansion time, before any ``build:`` body
    # has run, so a producer invoked from inside ``build:`` cannot be
    # the first thing to name them. Listing them here is not the recipe
    # author guessing — the selectors are public constants of the
    # producers (``DpkgDebSelector``, ``TarSelector``, ``CandleSelector``,
    # …) and a test asserts these entries against them.
    "tar"
    # gzip is not a typo for tar. ``tar -z`` forks a program CALLED
    # ``gzip``, and an action's PATH holds only what its edge named, so
    # the tarball producer declares it too, on the tar edge itself
    # (``producers/tarball.nim``'s ``GzipSelector``, which the same
    # pinning test below reads). Left out, the tar action exits 2 with
    # "gzip: command not found" -- which is exactly how the first real
    # Linux build of this fixture failed.
    "gzip"
    "dpkg-deb"
    "patchelf"
    "install-file"
    # The runtime-closure walk runs as a shell program: the DT_NEEDED
    # closure of a binary is not knowable until the binary exists, so it
    # cannot be computed while the graph is being built. ``sh`` is that
    # program's interpreter and, like every other tool here, a real
    # reprobuild package (``packaging/runtime_contract.ShSelector``).
    "sh"
    "wix-candle"
    "wix-light"

  build:
    let hello = nim.c(
      source = "src/hello.nim",
      binary = "build/bin/hello")
    let adder = nim.c(
      source = "src/adder.nim",
      binary = "build/bin/adder")

    let dist = sampleDistribution(hostTargetOs(), hello, adder)
    let site = packagingSite("sampletool")

    when defined(windows):
      # ``dist.msi`` in §6's table. The structurally different second
      # format the amended M0 gate exists to exercise.
      discard msiPackage(dist, site)
    else:
      # ``dist.deb`` and ``dist.tarball`` in §6's table.
      discard debPackage(dist, site)
      discard tarballPackage(dist, site)

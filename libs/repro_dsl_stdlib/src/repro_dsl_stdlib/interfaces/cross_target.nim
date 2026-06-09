## Spec-Implementation M3 — ``CrossTarget`` cross-cutting interface.
##
## Per Reprobuild-Standard-Library §"Cross-Cutting Interfaces" /
## §"`CrossTarget`", a ``CrossTarget`` describes a cross-compilation
## target with enough information for typed-tool wrappers to set the
## right ``--target=`` / ``--sysroot=`` / linker flags without recipes
## touching those details. The interface is vtable-shaped so adapter
## packages can supply target families without the stdlib knowing the
## specific triples.
##
## M3 ships the canonical methods called out in the milestone brief:
## ``targetTriple``, ``hostPrefix``, and ``splice``. The ``splice``
## form mirrors Nix's package-set splicing (``pkgsCross.<target>``
## composes a ``buildPackages`` / ``hostPackages`` / ``targetPackages``
## trio so a cross build can still address the host-runnable tools
## without manual triple juggling).
##
## Two default adapters ship with the stdlib:
##   * ``nativeCrossTarget`` — returns the detected host triple and
##     synthesises a degenerate splice where every facet of the
##     ``SplicedPackageSet`` is the same input set.
##   * ``crossTargetFromTriple(triple)`` — consults the ``targetTriple``
##     variant and produces a non-native ``CrossTarget`` whose
##     ``triple`` is the chosen value. ct-test's cross-aarch64 adapter
##     and similar will replace this with sysroot-aware
##     implementations as their packages land.

import ./toolchain
export toolchain

type
  BinaryFormat* = enum
    bfELF, bfMachO, bfPE, bfWASM

  SplicedPackageSet* = object
    ## Trio of facet package sets a ``CrossTarget`` exposes per
    ## Nix-style splicing. The three string-list fields represent the
    ## logical package sets; M3 stores their names only (the resolved
    ## package values come from the solver's solved set keyed by
    ## name). M5's cross-compilation worked example consumes this.
    buildPkgs*: seq[string]
      ## Packages that run on the build machine.
    hostPkgs*: seq[string]
      ## Packages that run on the machine that runs the produced
      ## binary (the "host" in autoconf terminology).
    targetPkgs*: seq[string]
      ## Packages the produced binary will itself target (e.g. a
      ## compiler that emits code for yet another platform).

  CrossTarget* = ref object of RootObj
    ## Vtable for a cross-target adapter. Stored on
    ## ``PackageBuildState.crossTargetSlot`` as a ``RootRef``.
    name*: string
      ## Adapter identity, e.g. ``"native"``,
      ## ``"cross-aarch64-linux-gnu"``.
    triple*: string
      ## Resolved target triple. For the native adapter this is the
      ## host triple; for cross adapters it's the configured target.
    sysroot*: string
      ## Path to the target sysroot. Empty for the native adapter.
    isNative*: bool
      ## Convenience flag; true iff ``triple`` matches the host.
    cFlags*: seq[string]
      ## Tool-agnostic flags this target requires. Typed-tool wrappers
      ## fold them into every compile invocation.
    linkFlags*: seq[string]
      ## Tool-agnostic flags this target requires at link time.
    binaryFormat*: BinaryFormat
      ## Object/executable format the target uses.
    pageSize*: int
      ## Target page size in bytes; layout computations consult it.
    targetTriple*: proc(): string
      ## Returns the configured triple. Recipes call this rather than
      ## reading ``triple`` directly when they want a stable accessor
      ## that adapter packages can override (e.g. a multi-arch adapter
      ## that picks the triple per build edge).
    hostPrefix*: proc(): string
      ## Returns the binary-name prefix the host toolchain expects on
      ## tool invocations (``""`` for native, ``"aarch64-linux-gnu-"``
      ## for a cross-aarch64 GNU toolchain).
    splice*: proc(buildPkgs, hostPkgs, targetPkgs: seq[string]):
        SplicedPackageSet
      ## Build a ``SplicedPackageSet`` from the three facet lists.
      ## For the native adapter this is a degenerate splice (the input
      ## sets pass through); for cross adapters it merges /
      ## transforms the lists so the recipe can address all three
      ## facets through a single typed handle.

proc newCrossTarget*(
    name: string;
    triple: string;
    sysroot: string;
    isNative: bool;
    cFlags: seq[string];
    linkFlags: seq[string];
    binaryFormat: BinaryFormat;
    pageSize: int;
    targetTriple: proc(): string;
    hostPrefix: proc(): string;
    splice: proc(buildPkgs, hostPkgs, targetPkgs: seq[string]):
        SplicedPackageSet
    ): CrossTarget =
  CrossTarget(
    name: name,
    triple: triple,
    sysroot: sysroot,
    isNative: isNative,
    cFlags: cFlags,
    linkFlags: linkFlags,
    binaryFormat: binaryFormat,
    pageSize: pageSize,
    targetTriple: targetTriple,
    hostPrefix: hostPrefix,
    splice: splice)

proc validate*(c: CrossTarget) =
  doAssert c != nil,
    "CrossTarget is nil — the active build context's crossTarget " &
    "slot was never populated"
  doAssert c.name.len > 0,
    "CrossTarget.name is empty — every adapter must set its identity"
  doAssert c.targetTriple != nil,
    "CrossTarget.targetTriple is nil — adapter '" & c.name &
      "' is incomplete"
  doAssert c.hostPrefix != nil,
    "CrossTarget.hostPrefix is nil — adapter '" & c.name &
      "' is incomplete"
  doAssert c.splice != nil,
    "CrossTarget.splice is nil — adapter '" & c.name &
      "' is incomplete"

proc tripleOrEmpty*(c: CrossTarget): string =
  ## Returns ``""`` when the target is native and ``triple`` otherwise.
  ## Mirrors the spec's documented helper so adapters and recipes have
  ## one accessor for "is this a cross build, and if so which triple".
  if c.isNative: "" else: c.triple

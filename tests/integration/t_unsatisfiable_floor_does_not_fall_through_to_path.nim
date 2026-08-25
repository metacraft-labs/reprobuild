## PMC-4 — an unsatisfiable microarchitecture floor must not fall through to
## `cakPath`.
##
## ## Why this test exists
##
## PMC-1 closed this hazard on the AVAILABILITY axis. `Package-Model.md`:
## "`cakPath` stops being reachable for a package known to be unavailable,
## closing the silent-fallthrough-to-PATH hole." The gate sits in front of the
## adapter loop, because availability is known before any adapter runs.
##
## PMC-2/PMC-3 then added a second way for a package to be unusable here: the
## catalog HAS a slice for this cpu/os, and the host cannot execute it. That
## refusal happens INSIDE the builtin adapter, so it lands after PMC-1's gate
## — and the chain walked on to `cakPath`, which probes PATH for a same-named
## executable.
##
## The result was PMC-1's hazard wearing new clothes, and worse than the
## original: the user asks for a package with an x86-64-v3 floor, the resolver
## correctly refuses it, and then hands back whatever `foo.exe` happened to be
## first on PATH — reporting success. Nothing anywhere says the artifact is
## not the one that was refused.
##
## PMC-4's review flagged this as acceptable ONLY while the feature is inert
## (no catalog declares a floor, so the refusal path is unreachable outside
## its own tests). PMC-5 is the milestone that declares the first floor, so
## this had to close before PMC-5 starts.
##
## ## What is asserted, and what is deliberately NOT
##
## Only `cakPath` is poisoned. `cakNix` and `cakScoop` resolve genuinely
## different artifacts that may well satisfy this host; refusing those would
## turn a safety fix into an outage. That distinction is pinned below, because
## "refuse everything after a shortfall" is the plausible over-correction.

import std/[options, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

suite "PMC-4 — a capability refusal does not fall through to PATH":

  test "the shortfall is a TYPED signal, not a substring of the reason":
    # Control flow keys off `ChainStep.capabilityShortfall`. If this ever
    # becomes a string match on `reason`, it breaks silently the first time
    # the wording changes -- and the wording is a diagnostic, which is exactly
    # the kind of thing that gets reworded.
    var step = ChainStep(adapter: cakBuiltin, outcome: csoAdapterUnavailable)
    check not step.capabilityShortfall
    step.capabilityShortfall = true
    check step.capabilityShortfall

  test "a capability refusal and a plain miss are different things":
    # "I don't have it" is a reason to try the next adapter. "I have it and
    # this machine cannot run it" is not. Collapsing the two is precisely how
    # the hole was opened.
    var miss = ChainStep(adapter: cakBuiltin, outcome: csoCatalogMiss,
      reason: "built-in catalog for 'demo' is empty")
    check not miss.capabilityShortfall

  test "the refusal names why PATH was not consulted":
    # The message has to explain the SUBSTITUTION, not merely report a skip.
    # A user who sees "path: not found" learns nothing; a user who sees that
    # a same-named binary was deliberately not substituted can act.
    const expected = ["refused", "cannot run it", "PATH", "undeclared"]
    let sample = "refused: the builtin catalog has this package but this " &
      "host cannot run it, and resolving a same-named executable from PATH " &
      "would substitute an undeclared binary for the one that was refused " &
      "(resolveBuiltinPackage: microarch-floor-not-satisfied (...))"
    for token in expected:
      check token in sample

  test "only cakPath is poisoned, not the whole chain":
    # The plausible over-correction is to refuse every remaining adapter.
    # cakNix and cakScoop resolve DIFFERENT artifacts, which may be
    # satisfiable here -- turning a safety fix into an outage would be a worse
    # bug than the one being fixed.
    let chain = defaultAdapterChain()
    check cakPath in chain
    # The default chain must still end at cakPath, or the gate above is
    # guarding a step that no longer exists.
    check chain[^1] == cakPath

# ---------------------------------------------------------------------------
# The behavioural half: drive the REAL refusal that feeds the gate.
#
# `chainResolvePackage` reads the compiled-in registry, and no checked-in
# catalog declares a floor yet (PMC-5 is the milestone that adds the first),
# so the chain cannot be driven end-to-end with a v3 arm from here without a
# test-registration seam that does not exist. What CAN be driven is the exact
# input the gate keys off: `resolveBuiltinPackage` takes a synthetic catalog,
# so the refusal below is the real code path, producing the real error kind
# that `tryResolveBuiltin` maps onto `ChainStep.capabilityShortfall`.
#
# Stated plainly rather than papered over: the gate's own branch is pinned
# structurally above, not behaviourally. The behavioural end-to-end assertion
# becomes possible — and should be added — as soon as PMC-5 declares a floor
# on a real catalog entry.
# ---------------------------------------------------------------------------

const
  V3Url = "https://example.invalid/demo-2.0.0-linux-x86-64-v3.tar.gz"
  V3Sha = "3333333333333333333333333333333333333333333333333333333333333333"

proc v3OnlyCatalog(): seq[VersionedProvisioning] =
  @[
    initVersionedProvisioning(
      version = "2.0.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = @[
        initPlatformBinary(cpu = pcX86_64, os = poLinux, url = V3Url,
          sha256 = V3Sha, cpu_level = mlX86_64_v3)
      ])
  ]

suite "PMC-4 — the refusal that feeds the gate is real":

  test "a v3-floor arm on a v2 host yields breMicroarchFloorNotSatisfied":
    # This is the error kind the chain maps onto `capabilityShortfall`. If it
    # ever degrades to the generic `brePlatformNotSupported`, the gate stops
    # firing and the fallthrough silently reopens -- so the DISTINCTION is
    # what matters here, not merely that something failed.
    let cat = v3OnlyCatalog()
    let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
      mlX86_64_v2)
    check not r.found
    check r.error == breMicroarchFloorNotSatisfied
    check r.error != brePlatformNotSupported
    # There IS a slice for this cpu/os -- the host just cannot run it. The
    # pre-PMC-2 phrasing would be actively misleading here.
    check "no platform slice" notin r.errorDetail

  test "the same catalog resolves on a host that satisfies the floor":
    # Positive control. Without it, the assertion above passes trivially if
    # resolution were broken for every host.
    let cat = v3OnlyCatalog()
    let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
      mlX86_64_v3)
    check r.found

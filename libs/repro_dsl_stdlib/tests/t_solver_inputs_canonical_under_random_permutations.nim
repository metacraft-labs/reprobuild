## Named-Lock-Files NLF-M1, the deliverable the milestone spells out and the
## suite did not have: "Property test: N packages, K random import
## permutations, one digest."
##
## WHY THIS EXISTS ALONGSIDE `t_solver_inputs_render_order_independent.nim`.
## That file asserts the same property over THREE hand-picked orders — the
## reversal, one rotation, one interleaving. Three fixed permutations cannot
## distinguish "the rendering is canonical for all orders" from "the rendering
## is canonical for the three orders someone thought of", and a reader has no
## way to tell which of the two the green tick means. This file replaces the
## picking with sampling.
##
## THE PICKING WAS NOT THE ONLY LIMIT, and the second one turned out to matter
## more. The hand-picked file registers its dependencies as bare range strings
## (`">=1.2.0"`), but `registerSolverDependency` takes the RAW `uses:`
## constraint — selector first, range after the space — and `rangePartOf`
## strips the leading token. A string with no space therefore has NO range
## part, so every dependency in that fixture collapses onto the single
## synthesized candidate `"1.0.0"` and every rendered `depends:` line onto
## `">=0.0.0"`. Two of the five collections NLF-M1 canonicalizes are
## consequently degenerate there: the per-dependency version list is always one
## element, and no parent declares two edges to the same dependency. A sort
## over a one-element list is unfalsifiable. This fixture uses the real
## `"<selector> <range>"` form, so the version lists have several members and
## the edge list has ties.
##
## N AND K, and why these numbers. N = 29 dependency records across 6 parent
## packages and 10 dependency packages, plus 4 variant declarations — 20
## rendered blocks in total. K = 64 permutations. The suite is already slow, so
## the budget was set at "single-digit milliseconds": one render is pure
## in-memory work over ~30 records with no solver call and no I/O, and 64 of
## them plus 64 digests measure well under a tenth of a second. K = 64 is
## chosen against the failure model rather than for a round number: every
## canonicalization defect in this path leaves SOME pair of records in arrival
## order, a uniformly random permutation flips any given pair with probability
## 1/2, and 64 independent samples therefore miss a live defect with
## probability at most 2^-64. Going higher buys nothing measurable; going to
## three buys a one-in-eight chance of a silent pass.
##
## THE SEED IS A CONSTANT, and is printed. A property test whose failing case
## cannot be re-run is worse than no property test: it converts a reproducible
## defect into a flake, and the usual response to a flake is a retry. The base
## seed is the compile-time constant `DefaultPropertySeed`, overridable through
## `REPRO_PROPERTY_SEED` for a widened local sweep; permutation `k` is drawn
## from `initRand(baseSeed + k)`, so a single (seed, k) pair names one exact
## permutation. Both are emitted through `checkpoint` on any mismatch, together
## with the full permuted order, and the seed line is echoed once per run so a
## CI log records which sample space was searched. Nothing here reads the clock.
##
## Test-double policy: no mocks, doubles or fakes. The test drives the real
## public registration surface (`registerSolverDependency`, `variantImpl`) and
## the real renderer through `currentSolverInputsFixture`, and takes the real
## `repro_lock.inputsDigestOf` over the result. It deliberately does not run
## the solver: the property under test is a property of the RENDERING, and
## involving clingo would make it depend on the solver being installed and the
## instance satisfiable — the same reasoning the hand-picked file records.

import std/[os, random, strutils, unittest]

import repro_dsl_stdlib/configurables/variants
# `captureSite` / `ckDefault` come from the configurables API and type modules;
# `variants` imports them without re-exporting, so the test names them itself.
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_lock

const DefaultPropertySeed = 20260821'i64
  ## A constant, not a clock reading. See the module doc.

const PropertySeedEnvVar = "REPRO_PROPERTY_SEED"
  ## Widens the sweep locally (`REPRO_PROPERTY_SEED=12345 ./t_...`) without
  ## making the default run non-reproducible. Unset is the constant above.

const PermutationCount = 64
  ## K. See the module doc for why 64 and not 3, and not 10_000.

type Edge = tuple[parent, dep, rng, gateVariant, gateValue: string]

const Parents = ["appAlpha", "appBeta", "appGamma", "appDelta", "appEpsilon",
                 "appZeta"]

const Libs = ["zlib", "openssl", "curl", "expat", "sqlite", "libpng",
              "libxml2", "ncurses", "readline", "bzip2"]

const VariantNames = ["useTls", "useLto", "buildProfile", "useSsl"]

proc buildEdges(): seq[Edge] =
  ## The declaration set, built once and deterministically. Only the ORDER is
  ## sampled; the content is fixed, so a failure is a statement about
  ## canonicalization and never about which records were generated.
  var idx = 0
  for pi in 0 ..< Parents.len:
    for j in 0 .. 3:
      let dep = Libs[(pi * 3 + j) mod Libs.len]
      # Selector first, then the range — the shape `rangePartOf` expects and
      # the shape a real `uses:` line has. Varying the lower bound per edge is
      # what gives a shared dependency a multi-element candidate list, which is
      # the only way `versions.sort()` can be falsified at all.
      let rng = dep & " >=" & $(1 + idx mod 3) & "." & $(idx mod 5) & ".0"
      result.add((Parents[pi], dep, rng, "", ""))
      inc idx

  # THE TIE PAIRS, added explicitly because the generator above never produces
  # one: each parent above draws four DISTINCT dependencies. `buildPackageDecls`
  # sorts a parent's edges "on the whole tuple", and its comment says why —
  # "two edges to the same dependency can differ only in their range or in
  # their conditional gate, so name alone is not a total order and would leave
  # those pairs in arrival order". A fixture with no such pair cannot tell a
  # whole-tuple sort from a sort by name, so the documented hazard would go
  # unasserted. Two edges to one dependency is not a contrived shape: it is
  # what a `case variant.value:` block with two arms emits.
  result.add(("appAlpha", "zlib", "zlib >=1.2.0", "", ""))
    # Differs from appAlpha's generated zlib edge only in the RANGE.
  result.add(("appBeta", "expat", "expat >=2.0.0", "useTls", "true"))
  result.add(("appBeta", "expat", "expat >=2.0.0", "useLto", "true"))
    # Differ from each other only in the GATE VARIANT.
  result.add(("appGamma", "libxml2", "libxml2 >=1.0.0", "useTls", "true"))
  result.add(("appGamma", "libxml2", "libxml2 >=1.0.0", "useTls", "false"))
    # Differ from each other only in the GATE VALUE.

let Edges = buildEdges()

proc renderWith(order: seq[Edge]; variantOrder: seq[string]): string =
  ## Register exactly `order` (and declare exactly `variantOrder`) into a clean
  ## registry and render. `variantImpl` is given an EXPLICIT name so the
  ## declaration order can be varied while the NAMES stay fixed: an anonymous
  ## `variant[T]` derives its name from its scope and disambiguates collisions
  ## with a registration-order `#N` suffix, so reordering anonymous
  ## declarations renames them and no sort could make two such renderings
  ## equal. Sorting canonicalizes the order of a fixed set of names; it cannot
  ## canonicalize the names themselves.
  resetVariantState()
  for name in variantOrder:
    discard variantImpl[bool](false, name, captureSite(ckDefault))
  for e in order:
    registerSolverDependency(e.parent, e.dep, e.rng, e.gateVariant,
                             e.gateValue)
  result = currentSolverInputsFixture()
  resetVariantState()

proc describe(order: seq[Edge]): string =
  ## The permuted order, in a form that can be pasted back into a scratch
  ## reproduction. Only rendered when a check has already failed.
  var parts: seq[string] = @[]
  for e in order:
    parts.add("(" & e.parent & ", " & e.rng & ", " & e.gateVariant & "=" &
      e.gateValue & ")")
  parts.join("\n  ")

proc baseSeed(): int64 =
  let raw = getEnv(PropertySeedEnvVar)
  if raw.len == 0:
    return DefaultPropertySeed
  try:
    parseBiggestInt(raw).int64
  except ValueError:
    raise newException(ValueError,
      PropertySeedEnvVar & "='" & raw & "' is not an integer. The seed is the " &
      "only thing that makes a failure here replayable, so an unreadable one " &
      "is refused rather than silently replaced by the default.")

suite "solver input rendering is canonical under random permutations":
  ## NLF-M1's fourth deliverable. One digest for K random permutations of N
  ## declarations.

  setup:
    let seed = baseSeed()

  test "the fixture actually exercises what NLF-M1 canonicalizes":
    # A property test over a degenerate fixture is a green tick with no content
    # behind it, and that is exactly how the hand-picked file's version-list
    # and edge-tie coverage was lost. Assert the teeth before using them.
    let baseline = renderWith(Edges, @VariantNames)
    checkpoint("REPRO_PROPERTY_SEED=" & $seed)

    # (1) At least one dependency has a MULTI-ELEMENT candidate list, so
    #     `versions.sort()` is falsifiable.
    var sawMultiVersion = false
    for line in baseline.splitLines():
      if line.startsWith("versions: ") and "," in line:
        sawMultiVersion = true
    check sawMultiVersion

    # (2) At least one parent declares TWO edges to the same dependency, so a
    #     sort keyed on the dependency name alone is falsifiable.
    var zlibEdges = 0
    var inAlpha = false
    for line in baseline.splitLines():
      if line.startsWith("package "):
        inAlpha = line.strip() == "package appAlpha"
        continue
      if inAlpha and line.startsWith("depends: zlib"):
        inc zlibEdges
    check zlibEdges == 2

    # (3) Gated edges are present, so the gate fields of the sort key are
    #     falsifiable too.
    check "when useTls=" in baseline

    # (4) The variants reached the rendering at all.
    for name in VariantNames:
      check ("variant " & name) in baseline

  test "K random permutations render one identical document":
    let baseline = renderWith(Edges, @VariantNames)
    echo "[property] ", PropertySeedEnvVar, "=", seed, " permutations=",
      PermutationCount, " records=", Edges.len
    check baseline.len > 0
    for k in 0 ..< PermutationCount:
      var rng = initRand(seed + k.int64)
      var order = Edges
      rng.shuffle(order)
      var variantOrder = @VariantNames
      rng.shuffle(variantOrder)
      let rendered = renderWith(order, variantOrder)
      if rendered != baseline:
        checkpoint("replay with " & PropertySeedEnvVar & "=" & $seed &
          ", permutation index " & $k & " (sub-seed " & $(seed + k.int64) &
          ")\n  variants: " & variantOrder.join(", ") &
          "\n  order:\n  " & describe(order))
      check rendered == baseline

  test "K random permutations yield one identical inputsDigest":
    # The digest is the consumer that makes an unstable rendering a live defect
    # rather than a cosmetic one: `repro_lock.inputsDigestOf` is taken over
    # exactly this text, and a digest that moves when nothing meaningful
    # changed cannot decide whether a lock is current.
    let baseline = inputsDigestOf(renderWith(Edges, @VariantNames))
    check baseline.len > 0
    for k in 0 ..< PermutationCount:
      var rng = initRand(seed + k.int64)
      var order = Edges
      rng.shuffle(order)
      var variantOrder = @VariantNames
      rng.shuffle(variantOrder)
      let digest = inputsDigestOf(renderWith(order, variantOrder))
      if digest != baseline:
        checkpoint("replay with " & PropertySeedEnvVar & "=" & $seed &
          ", permutation index " & $k & " (sub-seed " & $(seed + k.int64) &
          ")\n  expected digest " & baseline & ", got " & digest &
          "\n  variants: " & variantOrder.join(", ") &
          "\n  order:\n  " & describe(order))
      check digest == baseline

  test "the sampler really does sample":
    # A shuffle that silently returned its input would make every assertion
    # above vacuous, and it would look identical in the log. Two different
    # sub-seeds must produce two different orders, and neither may equal the
    # declaration order.
    var rngA = initRand(seed)
    var orderA = Edges
    rngA.shuffle(orderA)
    var rngB = initRand(seed + 1)
    var orderB = Edges
    rngB.shuffle(orderB)
    check orderA != Edges
    check orderA != orderB
    # And the same sub-seed must reproduce the same order, or the replay
    # instruction printed on failure would be a lie.
    var rngA2 = initRand(seed)
    var orderA2 = Edges
    rngA2.shuffle(orderA2)
    check orderA2 == orderA

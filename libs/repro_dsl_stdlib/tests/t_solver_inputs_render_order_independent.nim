## Solver-input rendering is canonical: the same declarations render the same
## text, and therefore the same ``inputsDigest``, whatever order they arrived in.
##
## Why this matters today, independent of any lock-file design: the rendered
## fixture is what ``inputsDigest`` is taken over (``repro_lock.inputsDigestOf``
## over ``renderSolverInputsFixture``'s output). If the rendering varies with
## registration order, then the one existing digest over solver inputs is not
## reproducible — two runs that declared exactly the same thing disagree about
## whether their inputs matched. A digest that moves when nothing meaningful
## changed cannot be used to decide a lock is current.
##
## Registration order is not exotic. The pending registry is process-wide and is
## appended to by each ``package`` macro at module initialization, so the order
## is the import order of the modules that happen to be linked into the running
## binary. Consolidating test binaries changes it; so does adding an import.
##
## ``repro_lock.solutionToLock`` already sorts for exactly this reason, and says
## so: "so the serialized lock is deterministic regardless of the (unordered)
## ``Table`` iteration order". The lock WRITER knew about the hazard. This test
## holds the same line one stage earlier, at the renderer that feeds it.
##
## Test-double policy: no mocks or doubles. The test drives the real public
## registration surface (``registerSolverDependency``, ``variant``) and the real
## renderer through ``currentSolverInputsFixture``, and compares whole rendered
## documents. It deliberately does not run the solver: the property under test
## is a property of the rendering, and involving clingo would make the test
## depend on the solver being installed and the instance satisfiable.

import std/[algorithm, sequtils, strutils, unittest]

import repro_dsl_stdlib/configurables/variants
# `captureSite` / `ckDefault` come from the configurables API and type modules;
# `variants` imports them without re-exporting, so the test names them itself.
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_lock

type Dep = tuple[parent, dep, rng: string]

const Deps: seq[Dep] = @[
  ("appAlpha", "zlib", ">=1.2.0"),
  ("appAlpha", "openssl", ">=3.0.0"),
  ("appAlpha", "curl", ">=8.0.0"),
  ("appBeta", "expat", ">=2.6.0"),
  ("appBeta", "zlib", ">=1.3.0"),
  ("appGamma", "sqlite", ">=3.40.0"),
  ("appGamma", "openssl", ">=3.1.0"),
  ("appDelta", "libpng", ">=1.6.0"),
]

proc renderWith(order: seq[Dep]): string =
  ## Register exactly `order` into a clean registry and render.
  resetVariantState()
  for d in order:
    registerSolverDependency(d.parent, d.dep, d.rng)
  result = currentSolverInputsFixture()
  resetVariantState()

proc renderWithVariants(order: seq[Dep];
                        variantNames: seq[string]): string =
  ## Same, plus variant declarations — the approved design makes feature
  ## selections key material, and they render from the same unsorted
  ## structure (`ctx.nodes`, in declaration order) the dependency records do.
  ##
  ## The names are passed in and declared through `variantImpl` with an
  ## EXPLICIT scope name so the caller can vary declaration order while
  ## holding the names fixed. That separation is necessary: an anonymous
  ## `variant[T]` derives its name from its scope and disambiguates a
  ## collision with a registration-order `#N` suffix, so reordering anonymous
  ## declarations renames them, and no amount of sorting could make two such
  ## renderings equal. Sorting canonicalises the ORDER of a fixed set of
  ## names; it cannot canonicalise the names themselves.
  resetVariantState()
  for name in variantNames:
    discard variantImpl[bool](false, name, captureSite(ckDefault))
  for d in order:
    registerSolverDependency(d.parent, d.dep, d.rng)
  result = currentSolverInputsFixture()
  resetVariantState()

suite "solver input rendering is order-independent":

  test "the same declarations render identically in reversed order":
    let forward = renderWith(Deps)
    let reversed = renderWith(Deps.reversed())
    check forward.len > 0
    check forward == reversed

  test "the same declarations render identically under a rotation":
    # A rotation keeps every parent's dependency run contiguous but changes
    # which parent is seen first, so it isolates the parent ordering from the
    # dependency-table ordering.
    let rotated = Deps[3 .. ^1] & Deps[0 .. 2]
    check renderWith(Deps) == renderWith(rotated)

  test "the same declarations render identically when interleaved":
    # Interleaving breaks the contiguous runs, so the parent list is built in a
    # different sequence AND the dependency table receives its keys in a
    # different sequence.
    var interleaved: seq[Dep] = @[]
    for i in 0 ..< Deps.len:
      if i mod 2 == 0: interleaved.add(Deps[i])
    for i in 0 ..< Deps.len:
      if i mod 2 == 1: interleaved.add(Deps[i])
    check renderWith(Deps) == renderWith(interleaved)

  test "inputsDigest is stable across every one of those orders":
    # The digest is the consumer that makes this a live defect rather than a
    # cosmetic one.
    let rotated = Deps[3 .. ^1] & Deps[0 .. 2]
    var interleaved: seq[Dep] = @[]
    for i in 0 ..< Deps.len:
      if i mod 2 == 0: interleaved.add(Deps[i])
    for i in 0 ..< Deps.len:
      if i mod 2 == 1: interleaved.add(Deps[i])
    let baseline = inputsDigestOf(renderWith(Deps))
    check baseline.len > 0
    check inputsDigestOf(renderWith(Deps.reversed())) == baseline
    check inputsDigestOf(renderWith(rotated)) == baseline
    check inputsDigestOf(renderWith(interleaved)) == baseline

  test "variant selections render identically when the deps are reordered":
    const Names = @["enableTls", "enableLto", "buildProfile"]
    check renderWithVariants(Deps, Names) ==
      renderWithVariants(Deps.reversed(), Names)

  test "variant selections render identically when the VARIANTS are reordered":
    # The arm that actually exercises the variant ordering. Same three names,
    # declared in three different sequences; the rendered document — and so
    # the digest — must not be able to tell which sequence was used.
    const A = @["enableTls", "enableLto", "buildProfile"]
    const B = @["buildProfile", "enableTls", "enableLto"]
    const C = @["enableLto", "buildProfile", "enableTls"]
    let baseline = renderWithVariants(Deps, A)
    check baseline.contains("variant ")
    check renderWithVariants(Deps, B) == baseline
    check renderWithVariants(Deps, C) == baseline
    check inputsDigestOf(renderWithVariants(Deps, B)) ==
      inputsDigestOf(baseline)
    check inputsDigestOf(renderWithVariants(Deps, C)) ==
      inputsDigestOf(baseline)

  test "the variant blocks are canonically ordered":
    const Names = @["enableTls", "enableLto", "buildProfile"]
    let text = renderWithVariants(Deps, Names)
    var variantNames: seq[string] = @[]
    for line in text.splitLines():
      if line.startsWith("variant "):
        variantNames.add(line["variant ".len .. ^1].strip())
    check variantNames.len == Names.len
    check variantNames == Names.sorted()

  test "the rendered document is itself canonically ordered":
    # Order-independence could in principle be met by a rendering that is
    # stably WRONG, so pin the actual shape too.
    #
    # The document is deliberately NOT one globally sorted list: dependency
    # packages are materialized before the parents that reference them, and
    # `buildPackageDecls` says so. The canonical form is therefore two
    # consecutive sorted runs — dependencies, then parents. Asserting a single
    # global sort here would be asserting a property the renderer does not have
    # and should not have.
    let text = renderWith(Deps)
    var packageNames: seq[string] = @[]
    for line in text.splitLines():
      if line.startsWith("package "):
        packageNames.add(line["package ".len .. ^1].strip())
    var parents: seq[string] = @[]
    var deps: seq[string] = @[]
    for d in Deps:
      if d.parent notin parents: parents.add(d.parent)
      if d.dep notin deps: deps.add(d.dep)
    check packageNames.len == parents.len + deps.len
    check packageNames[0 ..< deps.len] == deps.sorted()
    check packageNames[deps.len .. ^1] == parents.sorted()

  test "a package's dependency lines are canonically ordered":
    let text = renderWith(Deps)
    var inAlpha = false
    var depLines: seq[string] = @[]
    for line in text.splitLines():
      if line.startsWith("package "):
        inAlpha = line.strip() == "package appAlpha"
        continue
      if inAlpha and line.startsWith("depends: "):
        depLines.add(line["depends: ".len .. ^1].strip())
    check depLines.len == 3
    check depLines == depLines.sorted()

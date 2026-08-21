## NLF-M9 — a package reached only through an untaken variant-conditioned
## arm is IN the solved graph and RECORDED as unselected.
##
## Named-Lock-Files design §5.6 (owner decision, 2026-08-21) and §16
## ("seventh round"). §5.6's "the first wave fetches metadata for *all* arms
## of a variant-conditioned `uses:` and the solve selects among them" was
## ambiguous in a load-bearing way. The decision is neither "unselected
## packages vanish from the graph" nor "nothing is recorded":
##
## > **The solve MUST record, per package instance, whether anything selected
## > it** — whether any non-dormant edge required it. That fact belongs in the
## > solved graph. **What downstream does with it is separate policy.**
##
## ## Why this is a live hazard and not tidiness
##
## `version_encoder` gates the *range constraint*, not package presence, and
## the program carries **no `#minimize` directive at all** — the sibling case
## in `t_version_encoder_conditional_deps.nim` is literally named "variant off
## keeps the version free". So a package reached only through a dormant arm is
## not merely unconstrained: *nothing prefers any value*, and which version
## lands is decided by clingo's enumeration defaults (no seed, no
## `--opt-strategy`, last model kept). `solutionToLock` copies `sol.packages`
## unfiltered and `lockIdentityOf` hashes every instance, so a clingo upgrade
## can change the pinned version of a package nothing uses, change the lock
## identity, and invalidate every artifact.
##
## This case does not fix that. It records the fact that makes it fixable.
##
## ## What makes this discriminating rather than tautological
##
## Two arms, run over the SAME package set, differing only in the gating
## variant's value:
##
##   * **dormant** (`enableTLS = false`) — `openssl` must be PRESENT and
##     recorded UNSELECTED;
##   * **live** (`enableTLS = true`) — the same `openssl`, reached through the
##     same declaration, must be recorded SELECTED.
##
## An implementation that marks everything unselected fails the live arm; one
## that marks everything selected fails the dormant arm. Neither can be passed
## by accident, and neither can be passed by a field that is merely present.
##
## Transitivity is asserted too (`zlib`, reachable only *through* the dormant
## `openssl`): "whether any non-dormant edge required it" is not a one-hop
## property, and an implementation that only looks at the immediate incoming
## edge would report `zlib` selected because `openssl -> zlib` is
## unconditional.
##
## Test-double policy: NO mocks, doubles, or fakes. This drives the product's
## real `solve()` against real `libclingo`; the assertions read the real
## `UnifiedSolution` the build path consumes.

import std/[tables, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api

proc packageSet(): seq[PackageDecl] =
  ## `app` depends on `openssl` ONLY when `enableTLS` is true; `openssl`
  ## depends on `zlib` unconditionally. `zlib` is therefore reachable only
  ## through the conditional arm.
  @[
    newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "openssl", ">=3.0", "enableTLS", "true")]),
    newPackage("openssl",
      versions = ["1.1.0", "3.0.0"],
      depends = [newDependency("zlib", ">=1.0")]),
    newPackage("zlib", versions = ["1.3.1"]),
  ]

suite "NLF-M9: the solve records what it selected":

  test "a package reached only through a dormant arm is present and unselected":
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "false")])
    let sol = solve([enableTls], packageSet())

    # 1. The gate is off, so the arm is dormant.
    check sol.variants["enableTLS"] == "false"

    # 2. PRESENCE. The decision is explicit that an unselected package does
    #    NOT vanish from the solved graph — the encoder gates the range
    #    constraint, not presence, and that stays true.
    check "openssl" in sol.packages
    check "zlib" in sol.packages

    # 3. THE FACT. Nothing required either of them.
    check sol.selected["openssl"] == false
    check sol.selected["zlib"] == false

    # 4. The root of the request is selected: `app` is what the solve was
    #    asked for, and "nothing selected it" would be a false report.
    check sol.selected["app"] == true

  test "the same package under a live arm is recorded selected":
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "true")])
    let sol = solve([enableTls], packageSet())

    check sol.variants["enableTLS"] == "true"
    check sol.selected["app"] == true
    check sol.selected["openssl"] == true
    # Transitive: reached through a now-live parent.
    check sol.selected["zlib"] == true
    # And the range constraint fired, as it always did.
    check sol.packages["openssl"] in ["3.0.0"]

  test "every package instance in the graph carries a status":
    # A status recorded for only some instances is not a per-instance fact.
    # `repro why` must be able to answer for any package the graph holds.
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "false")])
    let sol = solve([enableTls], packageSet())
    check sol.packages.len == 3
    for name in sol.packages.keys:
      check name in sol.selected

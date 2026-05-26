## Standard-provider protocol constants (Tier 2b).
##
## ``repro-standard-provider`` is the pre-built binary the engine
## dispatches when a package omits its ``build:`` block entirely. The
## provider derives the build graph from the language's conventional
## source layout — see ``reprobuild-specs/Provider-Compile-Tiering.md``
## §"2b" and ``reprobuild-specs/Language-Conventions/README.md``.
##
## Engine and provider must agree on a small set of identifiers — the
## ``providerArtifactId`` baked into the engine's dispatch decision,
## the root entry-point id the engine asks for, and the package
## metadata the synthetic ``PackageDef`` advertises. Putting those
## constants in a shared library mirrors how
## ``repro_cmake_trycompile`` ships the trycompile equivalents, so the
## two sides cannot drift on a single side's edit.
##
## At milestone M0 the binary is a scaffold; it responds to manifest
## requests with a placeholder entry point and to graph-invocation
## requests with an empty fragment. The artifact id is suffixed
## ``v0-scaffold`` so any production engine wiring rejects it — a real
## ``v1`` value will land once M1 lands the convention dispatch
## framework.

const
  ## Stable identity of the standard-provider binary. The engine bakes
  ## this string into ``ProviderArtifactId`` whenever it routes a no-
  ## ``build:`` package through the Tier 2b path; every project on the
  ## same ``repro`` release that hits this provider shares an action-
  ## cache scope for the provider artifact itself. Bumping the suffix
  ## invalidates that share — keep it in lockstep with the binary's
  ## emitted graph schema.
  StandardProviderArtifactId* =
    "repro-standard-provider.v0-scaffold"
    ## v0-scaffold: M0 placeholder; one fake entry point, empty graph
    ##              fragments. Engine routing is not wired up yet, so
    ##              this value never reaches production cache keys.
    ## v1 (future): M1's convention-dispatch framework lands and the
    ##              binary emits real per-language fragments.
  StandardProviderRootEntryPointId* =
    "standardProvider.root"
  StandardProviderRootBodyHash* =
    "standardProvider.root.v0"
  StandardProviderPackageName* = "standardProvider"
  StandardProviderNamespace* = "project"

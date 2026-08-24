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
  ## Stable namespace for standard-provider artifacts. The engine appends
  ## the provider binary's content digest before dispatch, so byte-identical
  ## installations share graph snapshots while any implementation change
  ## invalidates previously emitted graphs.
  StandardProviderArtifactId* =
    "repro-standard-provider.v1"
  StandardProviderRootEntryPointId* =
    "standardProvider.root"
  StandardProviderRootBodyHash* =
    "standardProvider.root.v0"
  StandardProviderPackageName* = "standardProvider"
  StandardProviderNamespace* = "project"

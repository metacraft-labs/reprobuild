# repro_standard_provider_protocol

Standard-provider protocol constants (Tier 2b).

`repro-standard-provider` is the pre-built binary the engine dispatches
when a package omits its `build:` block entirely. The provider derives
the build graph from the language's conventional source layout — see
`reprobuild-specs/Provider-Compile-Tiering.md` §"2b" and
`reprobuild-specs/Language-Conventions/README.md`.

Engine and provider must agree on a small set of identifiers — the
`providerArtifactId` baked into the engine's dispatch decision, the
root entry-point id the engine asks for, and the package metadata the
synthetic `PackageDef` advertises. Keeping those constants in a shared
library mirrors how `repro_cmake_trycompile` ships the trycompile
equivalents, so the two sides cannot drift on a single side's edit.

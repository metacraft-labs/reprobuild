# Package Cache Identity Safety

Package substitution requires the identity of the complete resolved package,
not just the contents of its entry recipe. Imported recipes, implementation
sources, selected options, dependencies, SDK-generated build steps and the
actual target/toolchain can change the resulting package independently.

Automatic source-package identity construction currently lacks these complete
inputs. Its identity therefore carries the reserved `repro.identity.pending`
option. Presence of this option, including an empty value, prevents key
derivation. It is serialized with the identity so graph-cache restoration
cannot accidentally make an incomplete identity usable.

## Current Behavior

- Ordinary builds still run and use the local action cache. Their separate
  monitored-input validation is unchanged by this package-cache guard.
- Automatic package publication is skipped for incomplete identities. The
  build trace records `binary-cache-identity-incomplete` and the stats count
  incomplete identities. The build itself is not failed by this optional
  publication step, including warm publication and intermediate-cache scope.
- Explicit materialized publication fails for an incomplete identity.
- Materialized substitution reports a miss before network access or touching
  the existing prefix, allowing the source-build path to proceed.
- Graph inspection remains available. `binaryCacheKey` is empty and
  `binaryCacheIdentityError` explains the incomplete identity.
- Caller-supplied identities without the marker retain their existing key
  encoding. The caller remains responsible for supplying a complete identity;
  absence of the marker is not a proof of completeness.

Do not remove the marker, add a recipe comment to force a new key, or overwrite
an existing immutable cache entry to work around this guard. None of these
operations binds the missing inputs. Existing signed entries authenticate
their publisher and payload, not the completeness of their lookup identity.

## Re-enabling Automatic Source Substitution

The resolver must bind the complete source/provider inputs, solved options,
target and ABI, relevant dependency instances and actual toolchain before
lookup. Publication must use exactly that identity and verify that the
materialized output was built from it; the existence of an install prefix is
not sufficient evidence for backfill.

Regression coverage must distinguish imported recipe, SDK generator, local
non-Nim source, dependency implementation, option and toolchain changes. It
must also prove relocation stability and identical lookup/publication keys.
Reusing an import scanner, provider graph ID or entry-file digest alone does
not meet this requirement. This guard is containment, not that completed
identity-resolution work.

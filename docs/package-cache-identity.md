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

This also applies to hand-authored `nim.c` outputs. Automatic public-interface
tagging, `publish = true`, and `publishAs` select publication intent; none of
them supplies the missing source/dependency/toolchain inputs. They use the same
pending constructor as the source conventions. `publish = false` still opts
out, and ordinary builds and local action caching continue normally.

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

## Local Source Producer Validation

An existing install prefix is a location probe, not proof that its producer is
current. Source provisioning validates the producer through the normal build
engine even when the requested artifact is present. Unchanged producer actions
can use their local action-cache hits; recipe imports and action-input changes
must be observed, and a failed producer cannot be hidden by old output files.

A successful trusted substitution under the current package identity can
satisfy this validation without executing the source build or provisioning its
native build tools. Automatic incomplete identities cannot take that path.
The producer's build/runtime dependency closure is still prepared for consumers.

Deduplication lasts for one outer build invocation, including nested producer
builds. Later invocations in the same process revalidate. A producer already
active in a self-hosting cycle may use its existing artifact as a bootstrap
seed; that seed does not mark the active producer as successfully validated.

## Install Mirror Runtime Closure

Custom shell and typed source builds use the same install-mirror runtime
normalization. On Linux, this includes ELF subprograms under `usr/libexec`,
declared dependency library directories and propagated runtime manifests.
Generated mirror tools are declared during interface extraction, before the
build body runs. `REPRO_M9R30_NEEDED_CHECK=1` additionally refuses a mirror
whose ELF dependencies cannot be resolved.

These are local runtime-closure checks, not certification that an archive can
be restored on another machine. Dynamic interpreter paths still require
independent relocation validation; the incomplete-identity guard remains.

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

### What has landed so far

`solvedSourceCacheEntryIdentity` (libs/repro_project_dsl/.../source_cache_identity.nim)
is the canonical constructor. It binds the transitive local source closure of the
entry project file — `import` / `from ... import` / `include`, plus declared local
non-Nim inputs — together with the solved options, the resolved dependency
instances, the target triple and the actual toolchain. The closure digest is taken
over project-relative paths and content digests, so relocation alone does not move
it. Any unavailable input keeps the `repro.identity.pending` marker.

The import scan resolves a spec against the importing file's own directory, the
project root, the nimble `srcDir`, and every `--path` / `switch("path", "...")`
search root with a string-literal argument declared in `nim.cfg`, `config.nims`,
`<entry>.nim.cfg` or `<entry>.nims` that lies inside the project root. At each
root it tries the literal spec first (so `include "frag.inc"` and
`include "frag.nim"` resolve), then `.nim` / `.nims`, then the package-directory
form (`pkgdir` -> `pkgdir/pkgdir.nim`). `staticRead` / `slurp` with a
string-literal argument enter the closure; `gorge` / `gorgeEx` / `staticExec`, a
compile-time read with a non-literal path, and a read resolving outside the
project root are missing evidence. The visited-set key folds case only on
Windows, so two case-distinct files no longer merge on a case-sensitive
filesystem. Nothing outside the project root reaches the digest: a containment
check replaces `os.relativePath`, whose Windows cross-drive behaviour is to
return the absolute path rather than raise.

**External library vs unresolvable local module.** A spec that fails to resolve
is missing evidence — the identity refuses — when it is explicitly relative or
absolute, when it came from an `include`, when it carries a Nim source extension,
when the project declares a search path this scanner cannot evaluate (so the root
set itself is unknown), or when its first path segment matches an on-disk
directory or `.nim`/`.nims` file under one of the search roots. Otherwise it is an
external library and is ignored, as are `std/*`, `pkg/*`, `system`, and any spec
that resolves to a file outside the project root (that code is bound through the
dependency instances instead). Comments and triple-quoted literals are masked
before scanning, so a commented-out `import ./ghost` is neither bound nor refused:
Nim does not read those bytes, and refusing on them would leave a correct project
permanently unkeyable.

**Residual.** A bare spec with no on-disk evidence under any modelled search root
is still assumed external and dropped. The consequence splits in two, and the two
halves are not the same defect.

A `config.nims` that computes its `--path` in a loop or from an expression is
*seen*: the switch is present but its argument is not a string literal, so the
search-root set is marked unknown and every unresolved spec becomes missing
evidence. Such a project REFUSES — permanently pending, no digest — rather than
aliasing. Reprobuild's own tree is that shape, and taking it as a project root
refuses (four `staticExec` calls plus eleven unresolved imports). That is
fail-closed and useless for keying, not a cache hazard.

The hazard is the channel that leaves no trace in a scanned config file at all:
an `--path` supplied on the command line, a path contributed by a nimble
dependency. The scanner has nothing to mark unknown, so the spec is assumed
external, a digest is produced, and two implementations differing only in that
module land on one key. Measured: a tree whose `internal/helper.nim` is reachable
only through a command-line `--path` keeps the same closure digest when that
file's `const implementation` changes from 1 to 2. For that shape the #171
aliasing class survives.

**A second residual, fail-closed and untested.** The `staticRead` / `slurp` /
`gorge` / `gorgeEx` / `staticExec` detection is a textual whole-identifier scan
over the masked source, not a parse. A recipe that defines its own `slurp`, or
that merely contains the word `slurp` or `gorge` inside a kept single-line string
literal, is therefore refused. (A mention inside a comment is correctly masked
and does not refuse.) This costs a correct project its key rather than aliasing
two projects, but it is a way a real recipe can become permanently unkeyable, and
no test covers it.

Consolidating onto `repro_interface_artifacts.discoverNimSources` or
`macros_a.producerSourceStamp` is blocked by a hard import cycle in both
directions: `repro_interface_artifacts` imports `repro_project_dsl`, of which
this module is part, and `macros_a` is included into `repro_project_dsl.nim`,
which imports this module.

`sourceCacheEntryIdentity`, the four-argument legacy constructor every production
call site still uses, supplies none of the solved inputs and therefore remains
pending by construction; its `providerRevision` is now the source-closure digest
rather than the entry-file digest, which fixes the Reprobuild #171 aliasing of that
diagnostic field but does not by itself make anything publishable. Wiring the
solved instance through the provider/engine call sites, producer evidence and the
relocated-runtime acceptance are still open.

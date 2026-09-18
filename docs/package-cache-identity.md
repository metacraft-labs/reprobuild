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
project root, the nimble `srcDir`, every `--path` / `switch("path", "...")`
search root with a string-literal argument declared in `nim.cfg`, `config.nims`,
`<entry>.nim.cfg` or `<entry>.nims` that lies inside the project root, and every
root in the solved instance's `effectiveSearchRoots` (below). At each root it
tries the literal spec first (so `include "frag.inc"` and
`include "frag.nim"` resolve), then `.nim` / `.nims`, then the package-directory
form (`pkgdir` -> `pkgdir/pkgdir.nim`). `staticRead` / `slurp` with a
string-literal argument enter the closure; `gorge` / `gorgeEx` / `staticExec`, a
compile-time read with a non-literal path, and a read resolving outside the
project root are missing evidence. The visited-set key folds case only on
Windows, so two case-distinct files no longer merge on a case-sensitive
filesystem — two files differing only in case bind as two closure entries and
the digest moves when either changes, executed on Linux rather than asserted
through the `when` guard. Nothing outside the project root reaches the digest: a
containment check replaces `os.relativePath`, whose Windows cross-drive
behaviour is to return the absolute path rather than raise.

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

**The command-line `--path` channel.** A bare spec with no on-disk evidence under
any modelled search root is assumed external and dropped. Until the effective
search-root set became an input, that produced a real aliasing channel: a
`--path` supplied on the command line, or contributed by a nimble dependency,
leaves no trace in any scanned config file, so the scanner had nothing to mark
unknown and still produced a digest. Measured at `ca7864d0`: a tree whose
`internal/helper.nim` is reachable only that way kept closure digest
`337050709747f16f...` and cache key `2e5bde3c356780...` when that file's
`const implementation` changed from 1 to 2 — two implementations, one key.

That channel is now closed fail-closed. `SolvedSourceInstance` carries
`effectiveSearchRoots` (the `--path` set of the effective compile command) and
`searchRootsKnown`. Supplied, those roots resolve like any other and whatever
they reach is bound; a root outside the project root is accepted as resolution
evidence only, since what it reaches is external code bound through the
dependency instances, and a root that does not exist is ignored exactly as the
compiler ignores it. NOT supplied — the effective compile command was never
reconstructed — the identity refuses and names that missing evidence, the same
treatment an unresolvable candidate-local module gets. There is no third
behaviour in which a digest is produced over an unknown search-root set. The
roots never enter the digest themselves, so supplying them as the absolute paths
a compile command carries does not disturb relocation invariance.

**What that does not prove.** It does not prove a supplied set is complete or
correct. A caller that reconstructs the compile command wrongly, or sets
`searchRootsKnown` without reconstructing it, re-opens the same channel, and
nothing inside this module can detect that. The obligation moves to the call
site; the default refuses. Measured, not argued: on the tree above, a caller
that supplies a typo'd root and a caller that supplies a real but *incomplete*
root set both land back on closure digest `337050709747f16f...` and one key
across the 1 -> 2 change. The partial case digests; it does not refuse, because
a bare unresolved spec with no on-disk evidence is still classified external.
Refusal is the default for an *unsupplied* set, not a property of every
incorrect one. No production call site supplies a set today — every one still
uses the legacy four-argument constructor and is refused outright.

A `config.nims` that computes its `--path` in a loop or from an expression is a
different case and is unchanged: the switch is *seen* but its argument is not a
string literal, so the search-root set is marked unknown and every unresolved
spec becomes missing evidence. Such a project REFUSES — permanently pending, no
digest — rather than aliasing. Reprobuild's own tree is that shape. Supplying
effective roots does not lift that refusal: a seen-but-unevaluatable switch says
the scanner has an incomplete picture of the project's own configuration, which
a command line does not answer.

**Compile-time reads are no longer an identifier grep.** The `staticRead` /
`slurp` / `gorge` / `gorgeEx` / `staticExec` detection used to be a textual
whole-identifier scan over the masked source, which false-refused three shapes of
*correct* recipe (measured at `ca7864d0`): one that defines its own `slurp`, one
whose only `slurp` is inside a kept single-line string literal, and the same for
`gorge`. A permanently unkeyable project is as useless as an aliased one, so two
exclusions now apply, both provable from the text rather than heuristic: an
occurrence inside a kept single-line string literal is data rather than a call,
and a file that declares the symbol itself (a routine, or a
`let`/`var`/`const`/`type` entry in either the one-line or the indented-block
form) shadows the stdlib one. An explicit `system.<fn>` defeats both exclusions,
so shadowing cannot hide a real read.

It is still not a parse, and the shadowing exclusion has a price. A file that
declares its own `slurp` and also reaches `system`'s through an overload the
declaration does not shadow is missed — and missed here means *aliased*, not
refused: measured on such a file, the bytes it reads stay out of the closure and
the key does not move when they change, where `ca7864d0`'s bare grep refused the
same file. The exclusion is therefore not a pure improvement; it trades three
measured false refusals for one narrow new aliasing shape, on the judgement that
a permanently unkeyable correct recipe is the more common and more costly
failure. A qualifier other than `system` is still treated as a real read — the
fail-closed direction. Neither shape is covered by a test.

Consolidating onto `repro_interface_artifacts.discoverNimSources` or
`macros_a.producerSourceStamp` is blocked by a hard import cycle in both
directions: `repro_interface_artifacts` imports `repro_project_dsl`, of which
this module is part, and `macros_a` is included into `repro_project_dsl.nim`,
which imports this module.

`sourceCacheEntryIdentity`, the four-argument legacy constructor every production
call site still uses, supplies none of the solved inputs — no effective search
roots among them — and therefore remains pending by construction; its
`providerRevision` is now the source-closure digest
rather than the entry-file digest, which fixes the Reprobuild #171 aliasing of that
diagnostic field but does not by itself make anything publishable. Wiring the
solved instance through the provider/engine call sites, producer evidence and the
relocated-runtime acceptance are still open.

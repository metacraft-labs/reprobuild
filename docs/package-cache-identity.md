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
dependency instances, and a root that does not EXIST is refused rather than
ignored (see below). NOT supplied — the effective compile command was never
reconstructed — the identity refuses and names that missing evidence, the same
treatment an unresolvable candidate-local module gets. There is no third
behaviour in which a digest is produced over an unknown search-root set. The
roots never enter the digest themselves, so supplying them as the absolute paths
a compile command carries does not disturb relocation invariance.

**What that does not prove.** It does not prove a supplied set is complete. It
does prove one thing about it: a root that does not exist on disk is *refused*,
naming the bad root, because a caller that asserts the effective root set and
then names a directory that is not there has reconstructed the compile command
wrongly, and that is checkable from inside. Measured at `18e3f3b0`, where such
a root was ignored "exactly as the compiler ignores it": a typo'd `internl` for
`internal` silently dropped the module it was meant to reach and landed back on
closure digest `337050709747f16f...` with one key across the `implementation`
1 -> 2 change. The compiler ignoring an absent `-p` is not a reason for the
*identity* to ignore it — the compiler is not being asked whether the root set
is the one the recipe was built with.

**Residual: an existing but incomplete root set still aliases.** A root set
whose every root exists but which does not reach a module the project imports
still produces a digest, and still keeps one key across that module's change:
measured on the same tree, digest `337050709747f16f...` across 1 -> 2. That is
left open deliberately. Closing it the obvious way — refusing every bare spec
that resolves nowhere — makes all 336 real project roots in this repository
permanently unkeyable, which is the same uselessness as aliasing, and nothing
available inside this module distinguishes "a module the caller forgot to
mention" from "the stdlib". A caller that sets `searchRootsKnown` without
reconstructing the command re-opens the channel in the same way; the obligation
moves to the call site and the default (unsupplied) refuses. The residual is
pinned as a test case so it cannot decay into a claim. No production call site
supplies a set today — every one still uses the legacy four-argument
constructor and is refused outright.

A `config.nims` that computes its `--path` in a loop or from an expression is a
different case and is unchanged: the switch is *seen* but its argument is not a
string literal, so the search-root set is marked unknown and every unresolved
spec becomes missing evidence. Such a project REFUSES — permanently pending, no
digest — rather than aliasing. Reprobuild's own tree is that shape. Supplying
effective roots does not lift that refusal: a seen-but-unevaluatable switch says
the scanner has an incomplete picture of the project's own configuration, which
a command line does not answer.

**Compile-time reads are no longer an identifier grep — and no longer a
per-file off-switch.** The `staticRead` / `slurp` / `gorge` / `gorgeEx` /
`staticExec` detection used to be a textual whole-identifier scan over the
masked source, which false-refused three shapes of *correct* recipe (measured at
`ca7864d0`): one that defines its own `slurp`, one whose only `slurp` is inside
a kept single-line string literal, and the same for `gorge`. A permanently
unkeyable project is as useless as an aliased one, so three exclusions apply,
each provable from the text: an occurrence inside a kept single-line string
literal is data rather than a call; the *declaration* of the name is not a use
of it; and an unqualified **call** that this file's own routine declaration
provably takes is that routine rather than the stdlib's.

That third rule is decided per call, not per file, and the difference is the
whole point. Measured against the real compiler (nim 2.2.8):

| file | what the compiler does |
| --- | --- |
| `proc slurp(label: string)` + `slurp("greeting")` | binds the **local** routine; no file is read |
| `proc slurp(n: int)` + `slurp("payload.txt")` | binds **`system.slurp`** and reads the file |
| `const gorge = 3` + `gorge("echo hi")` | runs **`system.gorge`** |
| `var slurp = 3` + `slurp("payload.txt")` | reads the file via **`system.slurp`** |
| `const gorge = 3` + `const entry = gorge` | the **local** const; nothing is read |

An earlier revision (`18e3f3b0`) excluded *every* unqualified occurrence in a
file that declared the name — rows 2 to 4 of that table inverted. Its cost was
measured, and it was an **alias, not a refusal**: on `proc slurp(n: int)` plus a
real `slurp("payload.txt")`, the payload was absent from the closure and the key
did not move when the payload changed, where `ca7864d0`'s bare grep had refused
the same file. That is Reprobuild #171 itself, re-created inside the fix for it.
For a cache identity a false refusal is annoying and a false accept is the
defect, so the exclusion now has to prove itself per call, and all three of the
originally false-refused recipes remain keyable because all three are genuinely
safe under the same rule.

**A declaration only excludes a call where the compiler would apply it.** The
per-call rule above still asked the wrong question of the file: the declaration
table recorded every declaration of the name anywhere in the file at any
indentation and applied it to every occurrence. The compiler applies a
declaration only where it is in scope, textually before the call, and in a live
`when` branch. Each row below was compiled and **run** against the real compiler
(nim 2.2.8 on Windows, nim 2.2.4 on Linux) and every one of them prints the
payload, so every one is a genuine compile-time read that the previous rule
silently ignored — producing a 64-hex key that did not move when the payload
changed.

| file | what the compiler does |
| --- | --- |
| `const blob = slurp("payload.txt")` then `proc slurp(label: string)` **after** it | reads the file |
| `proc slurp(label: string)` nested **inside** another proc's body | reads the file |
| `when false:` / `proc slurp(label: string)` | reads the file |
| `when defined(flagNeverSet):` / `proc slurp(label: string)` | reads the file |
| `proc outer() = const slurp = 3` + module-scope `slurp("payload.txt")` | reads the file |

So a declaration excludes a call only when it sits at **column 0** and
**textually before** the call. A declaration at indent > 0 is either nested in a
body or under a `when`; which of those it is, and whether the guard is live, is
not decidable from the text, so it yields the **refusing** verdict rather than
the ignoring one. A non-routine declaration is exempt at any indentation,
because it cannot join an overload set at all — the last row above, where
refusing would be a false refusal rather than caution.

Where the text does not decide the overload, the identity **refuses**: a call
whose argument is not a string literal (nothing rules the local overload in or
out), a local parameter type that is neither exactly `string` nor one of the
scalars a string literal provably cannot convert to (a generic parameter, an
`untyped` template parameter, a type reachable by `converter` — any of these may
or may not beat `system`'s exact match), and a parameter list that does not
close on its own line. Each is missing evidence and refuses like any other.

A **qualified** occurrence is never excluded by shadowing at all: `system.<fn>`
is the stdlib read by construction, and a foreign qualifier (`mymod.slurp`)
names a symbol this scanner cannot see. A foreign qualifier is **not** missing
evidence by itself, which an earlier revision of this document said it was:
measured, `mymod.slurp("payload.txt")` with a literal that resolves **binds** the
payload and the key moves with it, which over-approximates and is the safe
direction. It is missing evidence only when the argument does not resolve.

It is still a better-informed textual scan, not a parse. What that costs is
stated by **direction**, because "not a parse" alone does not say which way each
gap fails, and only one of them fails the dangerous way:

- a routine whose signature spans lines is read one declaration line at a time
  and is undecidable, so it **refuses**;
- an **imported overload** is invisible here, so a call that overload would
  capture is still treated as the stdlib read: it binds the argument, or refuses
  when the argument does not resolve. It never ignores;
- **`when` is not evaluated.** A routine declaration under one is indented,
  which is undecidable and refuses; a read or an import inside one is bound
  whether or not the branch is live, which over-approximates. Both are the safe
  direction;
- **macro-generated code** is the one gap that fails the other way, and is an
  open residual rather than a caveat: a compile-time read or an import that
  exists only after expansion leaves no text to scan, is not bound, and the key
  can **alias** across a change to what it reads. It is pinned as an explicit
  residual case so it cannot decay silently.

Measured over all 336 project roots in this repository, the scope-and-order rule
costs zero new refusals and moves no closure digest.

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

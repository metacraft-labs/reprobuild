# The ambient-execution linter

Every binary reprobuild executes must be one it controls: realized from the
repro store, or invoked through a declared **execution profile**. This document
describes the rule, the check that enforces it, and the debt it is ratcheting
down.

## The rule

`reprobuild-specs/Package-Model.md` §"Executables, Libraries, And Package
Collections" (lines 254-273) defines an executable as "a strongly typed CLI
interface bound to an execution profile", in exactly three classes:

1. **External executable** — the profile records the installer kind, external
   package identity, executable path, environment shaping, and an optional
   expected execution-profile checksum.
2. **PATH-only executable** — a typed CLI interface with package provisioning
   *explicitly disabled*. The executable is resolved from `PATH`, and "the
   resulting action identity records the search path, resolved executable path,
   and configured probes". The spec is blunt about its status: "a weak, usually
   local-only profile used to develop the first build engine; it is **not** a
   reproducible package realization."
3. **Reprobuild-built executable** — a build output whose commands "call other
   strongly typed executable objects instead of **untyped ambient programs**".

A bare `findExe("tar")` followed by `execCmdEx(...)` is none of these. It
resolves an arbitrary host binary through ambient `PATH` and records nothing, so
the resulting action is neither reproducible nor auditable. Note that even
class 2 — the weakest tier — still requires the resolution to be *recorded*.
Probing for a tool and throwing the probe away is not class 2; it is
unclassified.

The runtime mechanism for doing this correctly is `BuildAction.toolIdentityRefs`:
the engine's tool-identity resolver binds `argv[0]` to a realized executable and
prepends its bin directory at fork time. `libs/repro_dsl_stdlib/.../packages/expand_archive.nim`
is a worked example — a typed archive tool that declares `toolIdentityRefs` and
lets the engine supply the binary.

## What the check does

`scripts/check_ambient_execution.sh`, run from `just lint` (and therefore from
the `just-lint` pre-commit hook wired in `flake.nix`), greps production Nim
sources for:

```
findExe | execCmdEx | execProcess | execShellCmd | startProcess
```

`getEnv` is deliberately absent. It is pervasive, mostly benign — reading
configuration rather than executing anything — and including it would drown the
signal in ~400 hits.

## It is a ratchet, not a gate

The repository currently contains roughly **170 `findExe`, 192 `execCmdEx` and
411 `getEnv` call sites across a dozen libraries**. A hard ban would make the
tree uncompilable, and the predictable outcome of a linter that blocks all work
is that someone deletes the linter.

So `scripts/ambient-execution-baseline.txt` lists the **88 files that already
violate the rule**. The check fails only when a file *not* on that list acquires
a banned call. New pollution is blocked; existing pollution is visible, counted,
and shrinking.

- **Removing entries is the work.** When a file stops using the banned APIs, the
  check prints a `note:` telling you to drop it from the baseline, locking in
  the improvement.
- **Adding entries needs a reason.** If the file is genuinely part of the class-2
  PATH-only bootstrap tier, it must first record search path, resolved path and
  probes into the action identity — then be added with that justification in the
  commit message.

## Known offenders worth migrating first

- `libs/repro_tool_profiles` — the tool-resolution layer. This is the closest
  thing the codebase has to a legitimate class-2 tier (it resolves tools before a
  store exists), but it currently discards its probes instead of recording them.
  Making it *properly* class 2 is the highest-value fix: it is the layer every
  other tool resolution flows through.
- `libs/repro_standard_provider` (29 files) — the largest single concentration.
- `repro.nim`'s Windows runtime-DLL staging edges — these resolve `clingo`,
  `zstd`, `sqlite3` and OpenSSL via `findExe` at graph-construction time and bake
  machine-specific absolute paths into copy edges.

  **Now labelled, still not fixed.** These call sites use `uncontrolledFindExe`
  so the compile closure is clean and `git grep uncontrolled` finds them, and
  `repro.nim` has left the baseline. That is honest labelling of an accepted
  hazard, not a resolution — the paths are still machine-specific and still
  resolved from ambient `PATH`. The capability gap below is what would actually
  fix them.

  **Blocked on a missing capability, not on effort.** `clingo` and `zstd` are now
  wired packages, so the obvious fix is for the edge to copy out of the realized
  store prefix. There is currently no way to express that:

  * The `provisioning:` DSL forms accept no `env:` key — `tarball` takes
    url / sha256 / archiveType / executablePath / packageId / cpu / os /
    stripComponents / mirror / lockIdentity, and `nixPackage` a similar set. So a
    package cannot export `CLINGO_ROOT=${prefix}` for consumers to address into.
    (The `env:` field on `VersionedProvisioning` is the *harvested catalog*
    surface, a different thing.)
  * The engine's tool mechanism is `toolIdentityRefs`, which prepends the
    realized tool's **bin directory to PATH**. That hands an action the
    *executable*, not the *prefix* — enough to run `clingo`, not enough to copy
    `clingo.dll` out from beside it.
  * reprobuild's own recipe declares `defaultToolProvisioning "path"`, so even
    `uses: "clingo"` resolves from ambient PATH rather than the store. That is
    deliberate (see the bootstrap floor below) and would have to change per-tool
    first.

  Closing this needs one of: `env:` support on the provisioning forms so a
  package can export a prefix-derived variable, or an action-time accessor such
  as `toolPrefix("clingo")` that the engine resolves. Both are DSL/engine
  features and a design decision, so the edges stay as they are, on the baseline,
  until one lands.

- `sqlite3` needs **no** Windows package slice, contrary to an earlier reading of
  this list. The Windows Nim distribution ships `bin/sqlite3_64.dll` inside its
  own tree — which is exactly where `scripts/build_apps.sh` already probes — and
  `nim` is a wired package. A DLL-only package would also not be expressible:
  `tarball` requires `executablePath`, and sqlite.org's DLL archive contains no
  executable.

## The bootstrap floor

Native provisioning cannot retire the env.ps1 scripts for tools needed to *build*
reprobuild itself. `scripts/build_apps.sh` must stage `clingo.dll` before
`repro.exe` exists, and the engine is what would provision it — so
`windows/ensure-clingo.ps1` is load-bearing and must not be deleted. The same
applies to `nim` and `gcc`.

What native provisioning does retire is the env.ps1 dependency for **recipes and
dev-envs**, i.e. everything after a working `repro` is installed. The
from-source bootstrap keeps its own path.

## Compile-time enforcement

The textual check is fast enough for pre-commit but is still grep: it can be
fooled by a comment or a string literal. The intended authoritative form is a
term-rewriting linter, force-imported through `config.nims` so it applies to
every compiled module without source changes, at the **warning** tier (measured
cost below; errors stay a non-starter until the baseline shrinks).

**Status: both blocking defects are resolved.** Measured per rule, one call
site each:

| rule | before | after |
| --- | --- | --- |
| `findExe` | 1 | 1 |
| `execCmdEx` | **301** | 1 |
| `execProcess` | 1 | 1 |
| `execShellCmd` | 1 | 1 |
| `startProcess` | 1 | 1 |

**Defect 1 — "the `findExe` rule never fires" — was not real.** It fires, and
appears to have been fixed by the export-marker/arity corrections made while
the rule was being written; the note outlived the problem. Recorded here rather
than quietly deleted, because a stale "this is broken" note costs real time:
the natural response to it is to go re-debug something that already works.

**Defect 2 — 301 warnings for one `execCmdEx` — was real, and is fixed.** The
cause was the declared return type. `warnExecCmdEx` spelled it as the actual
`tuple[output: string, exitCode: int]`, and the structured type makes the
compiler re-analyse the template body for a conversion; that re-analysis
re-matches the pattern despite `{.noRewrite.}`, up to Nim's rewrite-iteration
limit. The other four rules all return simple types and never recursed.
Declaring the return type `auto` fixes it — verified by changing only that and
re-measuring, 301 → 1.

It is the same class as the pattern-parameter rule already documented in the
general guide (state the type as `auto` unless a concrete type is demonstrably
fine), one position further along the signature.

### What wiring it actually costs

Also measured, because the estimate in this document was wrong by an order of
magnitude. The "~427 existing call sites" figure counted grep hits across the
tree. The number that matters is how many sites *the compiler sees*, since only
code in the compile closure can warn. Force-importing and compiling `repro.nim`:

| | count |
| --- | --- |
| total warnings | 16 |
| in reprobuild proper | 11 (10 in `repro.nim`, 1 in `repro_core`) |
| in sibling repos | 5 |

All 11 in-repo sites are now labelled with `uncontrolled*` hatches — they are
bootstrap tier, resolving a host tool before any engine-provisioned prefix
exists, so a typed profile is not available to them and honest labelling is the
correct outcome rather than a stopgap. **reprobuild's own compile closure is
clean.**

Nim reports these warnings at the `{.warning.}` pragma inside the template, not
at the call site — but it prints a `template/generic instantiation of ... from
here` line immediately above, which carries the real location. Grep for the
warning alone and you get a count with no addresses; grep with `-B1` and you
get the offender.

`scripts/check_ambient_execution.sh` remains the pre-commit ratchet. It is a
different measurement on purpose: cheap enough to run without a compile, and it
catches a violation before it is committed rather than after.

For the mechanism itself — pattern arity, `auto` parameters, the export-marker
pitfall, the warning tier and why a receive-the-call escape hatch silently fails
— see
`metacraft-dev-guidelines/policies/how-to-develop-custom-nim-linters.md`. This
document covers only what is specific to reprobuild: which APIs are banned, and
the names of the blessed escapes.

## The blessed escape hatches

A call site has exactly two compliant options: use a typed execution profile, or
state explicitly that it is stepping outside one. The second is spelled with a
named wrapper, one per banned API:

| instead of | blessed escape |
| --- | --- |
| `findExe(exe)` | `uncontrolledFindExe(exe)` |
| `execCmdEx(cmd, …)` | `uncontrolledExecCmdEx(cmd, …)` |
| `execProcess(cmd, …)` | `uncontrolledExecProcess(cmd, …)` |
| `execShellCmd(cmd)` | `uncontrolledExecShellCmd(cmd)` |
| `startProcess(cmd, …)` | `uncontrolledStartProcess(cmd, …)` |

Each wrapper contains the real call inside `{.noRewrite.}`, so the banned
identifier never appears at the call site and no warning fires. They are named
`uncontrolled*` rather than `unchecked*` or `raw*` deliberately: the hazard being
accepted is that **reprobuild does not control which binary runs**, and the name
should say so at the point of use.

`git grep uncontrolled` enumerates every blessed usage in the tree. That list is
the audit surface — it should be short, and every entry should be defensible
against `Package-Model.md:254-273`.

### When a hatch is the right answer

- **The class-2 PATH-only bootstrap tier**, which must resolve a tool before the
  store exists. Note that using a hatch does not by itself make a call site
  class 2 — the spec also requires the action identity to record the search
  path, resolved executable path and probes. A hatch without that recording is
  still unclassified; it is just honestly labelled.
- **Probing for host capabilities** where the answer, not the binary, is the
  product (e.g. asking whether a `tar` on this host understands zstd).

### When it is not

- Reaching for a tool that has, or could have, a package entry. Wire the package
  and consume the realized prefix instead — that is the whole point of the rule.
- Anywhere the engine already offers `toolIdentityRefs`, which binds `argv[0]` to
  a realized executable and prepends its bin directory at fork time. See
  `libs/repro_dsl_stdlib/.../packages/expand_archive.nim` for a worked example.

Adding a hatch for a **new** API is a deliberate act and needs review: it widens
the set of ways ambient binaries can enter the build.

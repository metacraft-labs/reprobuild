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

So `scripts/ambient-execution-baseline.txt` lists the **90 files that already
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
  machine-specific absolute paths into copy edges. They exist because those
  libraries had no package entries; as each gains one, the edge should consume
  the realized store prefix instead.

## Compile-time enforcement

The textual check is fast enough for pre-commit but is still grep: it can be
fooled by a comment or a string literal. The authoritative form is the
term-rewriting linter in `lints/ambient_execution.nim`, force-imported through
`config.nims` so it applies to every compiled module without any source changes.

It runs at the **warning** tier. With ~427 existing call sites, errors would make
the tree uncompilable; warnings make every violation visible in build output
while the baseline shrinks. Individual APIs flip to `{.error.}` as they reach
zero.

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

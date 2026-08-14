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
fooled by a comment or a string literal. The authoritative form is a
term-rewriting linter that makes the call a compile error — see
`metacraft-dev-guidelines/policies/how-to-develop-custom-nim-linters.md` for the
mechanism, including the export-marker pitfall and the default-parameter
constraint that affects `findExe` specifically. That is the intended next step;
it needs the escape hatch for the bootstrap tier to land first, or the tree stops
compiling.

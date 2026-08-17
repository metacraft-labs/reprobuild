# DSL setters: what happens when you write an expression

An audit of every `repro.nim` DSL declaration form, asking one question of each
setter: **if the value is not a string literal — a `const`, a `func` call, a
concatenation — what actually happens?**

The answer was supposed to be "it works, or it tells you why not". For most
forms it was neither.

## Why it matters

Two things in this tree are workarounds for this defect, and both name it in
their own comments:

- **~227 catalog entries** repeat one `nixpkgsRev` and one `nixpkgsNarHash` as
  bare literals, and `t_smoke_catalog_audit_m29` *enforces* the repetition by
  grepping for the literal text. The audit exists because the shared const
  could not be written.
- **Recipes carry comments** of the form *"Keep the version string in sync with
  `AptJammyAdapterVersion` in the stdlib module"*
  (`recipes/packages/adapters/apt-jammy/repro.nim`). The const already existed.
  The DSL could not accept it, so the value was pasted and a human was asked to
  keep the two aligned.

Neither is a style preference. They are both hand-maintained duplication
standing in for an assignment the compiler should have made.

## The three failure classes

Sorted by how expensive they are to discover.

### 1. Silent corruption — the value is wrong, and plausible

`stringLiteral()` falls back to `node.repr` for anything that is not a literal,
and the emitters wrap the result in `escForCode`. The field ends up holding
**its own source text**. Measured, not inferred:

| written | reached the registry as |
| --- | --- |
| `sha256 = PinnedSha` | `"PinnedSha"` — 9 chars in a 64-hex field |
| `url = condaUrl("clingo", "5.7.1", …)` | `"condaUrl(\"clingo\", \"5.7.1\", …)"` |
| `executablePath = binDir(plConda) & "/clingo.exe"` | `"binDir(plConda) & \"/clingo.exe\""` |

No error, no warning. A checksum that can never match and a URL that can never
resolve, both reported far from the declaration at fault.

### 2. Silent drop — the setter does nothing

The parser returns `nil`, or `continue`s, and the caller leaves the field at its
ground state. `description SomeConst` compiled, emitted no diagnostic, and left
the description empty. Indistinguishable afterwards from never having written
it.

Worse in one place: a `versions:` entry keyed by a non-literal was shape-matched
as an entry and then skipped **entirely** — revision, url, repository and all.

### 3. Loud error — the honest failure

Only where a whitelist happened to reject the source text as an invalid value,
which was luck rather than design.

## Verdict per form

Every row was confirmed by compiling a probe and reading what reached the
runtime registry — not by reading the parser. Rows marked *fixed* have a test
that was observed to FAIL before the change.

| form | setters | was | now |
| --- | --- | --- | --- |
| `service` | `description`, `type`, `execStart`, … | silent drop | **fixed** — expressions |
| `tarball(...)` | `url`, `sha256`, `executablePath`, `mirrors`, `packageId`, `lockIdentity`, `archiveType`, `cpu`, `os` | silent corruption | **fixed** — expressions |
| `tarball(...)` | `stripComponents` | silent `0` | **fixed** — errors |
| `nixPackage` | `executablePath`, `nixpkgsRef`, `nixpkgsRev`, `nixpkgsNarHash`, `packageId`, `lockIdentity` | silent corruption | **fixed** — expressions |
| `nixPackage` | selector, `expressionFile` | silent corruption | **fixed** — errors (see below) |
| `scoopApp` | every string field | silent corruption | **fixed** — expressions |
| `scoopApp` | `requiresExecutionProfileChecksum` | silent `true` | **fixed** — errors |
| `versions:` | `sourceRevision`, `sourceChecksum`, `sourceUrl`, `sourceRepository` | silent drop | **fixed** — expressions |
| `versions:` | entry key | silent whole-entry drop | **fixed** — errors |
| `versions:` | unknown key | silent drop | **fixed** — warns |
| variant arm `uses` | dependency argument | silent drop | **fixed** — reaches the emitter |
| `library` | `exportedPath` | rejected outright | **fixed** earlier — expressions |
| `param` / interface `param` | `alias` | silent corruption | **fixed** — errors |
| `dependencyPolicy` | `depfile`, `depfiles` | silent corruption | **fixed** — errors |
| `usesImportPath` | path | silent corruption | **fixed** — errors |
| `defaultToolProvisioning` | mode | loud (whitelist, by luck) | **fixed** — errors clearly |
| `executable` / `library` / interface command | name | ident by design | unchanged — correct |
| `library` body | unknown members | silent drop | **open** — see below |

### Where "errors" is the right answer, not a consolation

Some fields cannot take an expression, because the macro uses the text to *do*
something at compile time:

- the `nixPackage` selector is tested for the `nixpkgs#` prefix and **sliced**
  to build the default lock identity;
- `expressionFile` is resolved against the declaring file's directory;
- `depfile` entries are **deduplicated** at macro time;
- `usesImportPath` **generates a sibling shim file**;
- a `versions:` entry key is the map key the entry registers under.

For these, refusing is correct. What was wrong was refusing *silently* — or
rather, not refusing at all and quietly substituting the source text.

## The shape of the fix

The principle is **transform, don't evaluate**: the macro relocates the
argument's AST into the generated code and lets the Nim compiler resolve it,
instead of trying to compute the value itself.

Concretely, `escForCode(stringLiteral(node))` became `exprCode(node)` — which
`escape()`s a literal (so the literal path stays byte-identical) and otherwise
emits `node.repr` verbatim — and the emitters splice it rather than re-quoting.

Consequences that had to be worked through, each of which broke something on
the first attempt:

- **`.len == 0` stops meaning "absent".** An expression-valued field holds code,
  so presence had to move onto the argument *node*. `url = ""` is a different
  mistake and keeps its own diagnostic.
- **Validation runs only where there is text.** The empty string is "not
  knowable here", not "invalid" — `""` is itself `unsafeRelativePath`, which the
  first attempt got wrong and a test caught.
- **Derived defaults become emitted expressions.** `packageId` from `url`,
  `lockIdentity` from `sha256`, `nixpkgsRef` from `nixpkgsRev`, scoop's
  `packageId`/`lockIdentity` — all were macro-time concatenation over the
  macro's *view* of the fields, and would otherwise have captured source text.
- **An unset field needs `""`, not nothing.** Splicing an empty string produces
  `field: ,` — a syntax error in the generated literal. Hence `codeOrEmpty`.

## Why the literal path is safe

The 227 `nixPackage`, 29 `scoopApp`, 2 `tarball` and ~865 `versions:` call sites
are all literal today, so the literal path had to stay byte-identical.

`t_dsl_provisioning_literal_unchanged` pins it: every field set explicitly, both
tarball derived defaults, both nix derived shapes (rev+narHash, and the bare
selector fallback), both scoop shapes (version, and manifestChecksum-wins), and
a URL carrying a percent-escape and a backslash to prove the source round-trip.

Evidence: 78 `repro_project_dsl` tests pass; all 258 catalog packages and
`repro.nim` compile clean. A 12-recipe sample compiles except for 4 that fail on
missing generated sibling shims — confirmed pre-existing by reverting the macro
edits and observing the same errors, not assumed from the message.

## Open

**`library` bodies still drop unknown members silently.** The catch-all cannot
simply error, because the same body is consumed by a *second* pass: the M3
artifact lowerer walks it independently to emit `registerArtifact(...)`, and
`build:` blocks — well over a hundred of them in recipes — are handled entirely
there. Erroring would reject valid declarations.

The fix needs a cross-pass inventory of which members each pass consumes, after
which the residue can warn. Until then a `when` inside a `library` body compiles
and sets nothing, which remains the blocker for expressing per-platform library
layout (see `runtime-library-dependencies.md`).

**The catalog still repeats its pins.** Nothing forces it to now, but migrating
~227 entries to a shared const — and retiring the grep-based audit that enforces
the duplication — is a separate change.

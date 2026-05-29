# Recipes

Short, focused how-to pages for common reprobuild tasks. Each recipe
is independent — read just the ones you need.

## Available recipes

- [Refreshing the scanned-deps file](#refresh-scanned-deps)
- [Adding a build: escape hatch when the convention doesn't fit](#build-escape-hatch)
- [Wiring `repro deps refresh --check` into CI](#ci-gate)
- [Adding a new package to an existing workspace](#new-package)
- [Migrating from Mode 2 to Mode 3](#mode-2-to-mode-3)

---

## <a name="refresh-scanned-deps"></a>Refreshing the scanned-deps file

When you add or remove `import` / `use` / `#include "..."` lines in
your sources, the workspace dep graph changes. The scanner needs to
re-run:

```text
repro deps refresh
```

This rewrites `repro.scanned-deps.nim` next to your `repro.nim`. The
file has a "DO NOT EDIT" header — don't hand-edit it; manual overrides
belong in `repro.nim`.

To check the file is up-to-date in CI without rewriting:

```text
repro deps refresh --check
```

Exit code `0` = file in sync, `1` = file would change. Analogous to
`gofmt -l`.

---

## <a name="build-escape-hatch"></a>Adding a `build:` escape hatch

When the standard provider's convention doesn't fit — custom codegen,
non-stock compiler flags, a third-party tool the convention doesn't
know about — graduate that one package to **Tier 1** by adding a
`build:` block:

```nim
package my_special_pkg:
  uses:
    "gcc >=11"

  executable hello:
    discard

  build:
    # Imperative actions, executed verbatim. Same DSL as the engine
    # internals use.
    exec("my-codegen", argv = @["./codegen.sh", "src/gen.c"])
    exec("compile", argv = @["gcc", "-O2", "src/main.c", "src/gen.c",
                              "-o", ".repro/build/hello/hello"])
```

The standard provider stops trying to recognize the package and the
`build:` block runs as written. Other packages in the workspace are
unaffected — they stay in whatever mode they were in.

Use the escape hatch sparingly. Most of the time the convention will
fit, or a small change to your source layout will let it fit. The
escape hatch is for the genuine edge cases.

---

## <a name="ci-gate"></a>Wiring the CI gate

For projects using Mode 3, you want CI to fail if anyone forgets to
run `repro deps refresh` after touching imports.

**GitHub Actions:**

```yaml
- name: Check scanned-deps is up to date
  run: repro deps refresh --check
```

**pre-commit hook (.git/hooks/pre-commit):**

```bash
#!/usr/bin/env bash
set -e
repro deps refresh --check
```

**Just / Make:**

```text
verify-deps:
    repro deps refresh --check
```

The check is fast — the scanner is cheap and the comparison is a
byte-level file diff. Add it next to your formatter / linter checks.

---

## <a name="new-package"></a>Adding a new package to an existing workspace

Suppose your workspace already has two packages and you want a third.

1. **Create the new package's directory.** For Mode 3, this follows
   the language's recognized layout — see the per-language page.

2. **Add the package block to `repro.nim`:**

```nim
package my_new_pkg:
  uses:
    "<your-language>"
  library my_new_pkg     # or executable, files, etc.
```

3. **Add `import` / `use` / `#include` lines to the consumer source**
   referencing the new package.

4. **Refresh the scanned-deps file:**

```text
repro deps refresh
```

5. **Build:**

```text
repro build
```

The scanner picked up the new import, wrote the new edge, and the
build sequenced the new package before its consumers automatically.

---

## <a name="mode-2-to-mode-3"></a>Migrating from Mode 2 to Mode 3

If you have an existing Mode 2 project (with `Cargo.toml`,
`pyproject.toml`, etc.) and want to switch to Mode 3:

1. **Confirm Mode 3 is supported for your language.** See
   [the languages table](../README.md#languages). Java, Kotlin, C#,
   Swift, OCaml are Mode 2-only.

2. **Confirm your project doesn't rely on Mode 2-only features:**
   - External package deps (crates.io, PyPI, npm).
   - Build scripts (`build.rs`).
   - Codegen plugins.
   - Ecosystem-specific features (Cargo features, Python entry
     points, etc.).

   If you need any of those, stay in Mode 2.

3. **Rewrite the ecosystem manifest as a Mode 3 `repro.nim`.** The
   per-language page shows the minimal shape. For most languages it's
   a few lines per package.

4. **Re-arrange the source tree** to match the convention's expected
   layout if needed (typically `<pkg>/src/lib.<ext>` or
   `<pkg>/src/main.<ext>`).

5. **Run `repro deps refresh`** to populate the scanned-deps file.

6. **Delete the ecosystem manifest** (or keep it alongside if other
   tools need it — reprobuild will see Mode 2 takes priority and your
   migration is "incomplete" from reprobuild's perspective).

7. **Build:**

```text
repro build
```

The other direction (Mode 3 → Mode 2) is simpler: drop the
ecosystem manifest in, and the standard provider switches modes
automatically.

---

## See also

- [The Three Modes](../three-modes.md) — full mode model.
- [Getting Started](../getting-started.md) — five-minute Nim tutorial.
- [Languages](../README.md#languages) — per-language details.

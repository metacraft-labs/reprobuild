# JavaScript / TypeScript

Reprobuild's JS/TS Mode 3 uses `esbuild` to bundle TypeScript sources
into single-file Node.js executables, with a wrapper script that runs
`node` on the bundle. There's no `npm install`, no `package.json`, no
`tsconfig.json`.

## Modes available

- **Mode 3**: `repro.nim` + per-package TypeScript sources. No
  `package.json`. esbuild bundles cross-package imports inline.
- **Mode 2**: existing `package.json` triggers Mode 2 (delegates to
  `npm install` + `npm run build` / `tsc` / whatever the manifest
  declares).
- **Mode 1**: layout-as-manifest (M48, 2026-05-29). Drop sources under
  `apps/<name>/main.ts` + `libs/<name>/index.ts`, run `repro build`.
  See [The Three Modes §Mode 1](../three-modes.md#mode-1--layout-as-manifest).

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package mathlibPkg:
  uses:
    "typescript"
  library mathlib

package calcPkg:
  uses:
    "typescript"
  executable calc:
    discard

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B-src — TypeScript under `src/`):

```text
my-ts-workspace/
  repro.nim
  repro.scanned-deps.nim
  mathlib/
    src/index.ts             # `export function add(a, b) { return a + b; }`
  calc/
    src/main.ts              # `import { add } from "mathlib";`
```

The `calc/src/main.ts` `import { add } from "mathlib";` line is what
the scanner reads to emit the `depends_on calcPkg: mathlibPkg` edge.

Build:

```text
repro build
```

Outputs:

```text
.repro/build/calc/bundle.js              # esbuild bundle (includes mathlib)
.repro/build/calc/calc[.exe]             # `node bundle.js` wrapper
```

The convention runs:

```text
esbuild --bundle --platform=node \
  --alias:mathlib=<workspace>/mathlib/src/index.ts \
  --outfile=.repro/build/calc/bundle.js \
  calc/src/main.ts
```

so the cross-package import resolves at bundle time, not runtime.

Reference fixture:
[`reprobuild-examples/jsts-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/jsts-mode3/binary-with-library).

## Source layout

The JS/TS convention expects:

- Libraries: `<pkg>/src/index.ts` (or `index.js`) as the entry.
- Executables: `<pkg>/src/main.ts` (or `main.js`) as the entry.

The bundler picks up the entry, follows imports, and produces one
output bundle per executable.

## Mode 2 escape hatch

If you have a `package.json`, the standard provider delegates to npm:

```text
my-ts-pkg/
  reprobuild.nim
  package.json                # ecosystem manifest
  tsconfig.json
  src/
    main.ts
```

Use Mode 2 when:
- You depend on **npm** packages.
- You need a specific **TypeScript** version pinned via `package.json`.
- You use **bundler-specific** plugins (Webpack, Vite, Parcel).
- You ship a **browser** target (Mode 3 emits Node bundles only).

## The scanner

The JS/TS scanner reads:

- `import ... from "..."` (ES module syntax)
- `require("...")` (CommonJS)
- Dynamic `import("...")` with a literal string argument

It maps the import string against workspace package names. Bare
specifiers that don't match a workspace package are treated as npm
deps and ignored — Mode 2 / `package.json` handles those.

## Outstanding limitations

- **No npm deps in Mode 3.** Adding `package.json` is the supported
  graduation path.
- **No browser target.** Mode 3 emits Node bundles only. For browser
  builds, use Mode 2 with a bundler-specific manifest.
- **No `tsconfig.json` honored.** Mode 3 runs esbuild with its
  defaults; TypeScript settings like `strict`, `paths`, `baseUrl` are
  not threaded.
- **No type-checking.** esbuild strips types but doesn't type-check.
  Run `tsc --noEmit` separately if you need type errors caught.
- **JSX / TSX support is esbuild's default.** No custom JSX
  transformer.
- **Dynamic `import("...")` with computed paths.** The scanner only
  reads literal string arguments.

## See also

- [Language-Conventions/JavaScript-TypeScript.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/JavaScript-TypeScript.md) —
  contributor-facing convention spec.

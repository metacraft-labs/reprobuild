# OCaml

Reprobuild's OCaml support is **Mode 2 only**: existing `dune-project`
+ `dune` files are recognized and reprobuild shells out to `dune
build`.

## Modes available

- **Mode 2 (Dune)**: existing `dune-project` triggers the
  `ocaml-dune` convention.
- **Mode 3**: **not supported**. Deferred — OCaml's separate-compilation
  + `.mli`-interface tracking model would require a dedicated
  convention.
- **Mode 1**: **not meaningful**.

## Quickstart (Mode 2 + Dune)

Layout:

```text
my-ocaml-pkg/
  reprobuild.nim
  dune-project
  dune
  hello.ml
```

Minimal `reprobuild.nim`:

```nim
import repro_project_dsl

package my_ocaml_pkg:
  uses:
    "ocaml >=4.14"
    "dune >=3.0"
  executable hello:
    discard
```

Minimal `dune-project`:

```text
(lang dune 3.0)
```

Minimal `dune`:

```text
(executable
 (name hello))
```

Minimal `hello.ml`:

```ocaml
let () = print_endline "hello from ocaml"
```

Build:

```text
repro build
```

The convention runs `dune build --release -j 1` and the output binary
lands under `_build/default/hello.exe`.

Reference fixture:
[`reprobuild-examples/ocaml-dune/hello-binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/ocaml-dune/hello-binary).

## Toolchain

Required on `PATH`:

- `ocaml` (the OCaml driver — `ocaml.exe` on Windows).
- `dune` (separate `opam install dune` since Dune isn't a built-in
  part of the OCaml distribution).

The M9 harness SKIPs cleanly if either is missing.

## Installing OCaml on Windows

env.ps1 doesn't currently bundle OCaml. The documented install path:

1. Install OPAM from `ocaml.org` (the `opam-2.x.y.exe` installer)
   into `D:/metacraft-dev-deps/opam/`.
2. `opam init -y --bare`
3. `opam switch create <version>` (creates an OCaml compiler switch).
4. `opam install dune`
5. Prepend the opam switch's `bin/` directory to `PATH`.

A follow-up provisioning milestone will automate this.

## Outstanding limitations

- **No Mode 3 OCaml.** Hand-write `dune-project` + `dune`.
- **No introspection lift.** One opaque `dune build` per package.
- **No external opam deps.** The fixture is intentionally
  self-contained (only OCaml stdlib). Adding deps requires `opam`
  + a properly populated switch; the build will pick them up at
  `dune build` time but reprobuild's action cache doesn't see them.
- **OCaml ↔ C (`CAMLprim`) NOT in scope.** Cross-language with C
  through the OCaml FFI deferred.
- **No multi-package opam projects.** One `dune-project` per
  reprobuild package.
- **No `dune utop` / REPL integration.**
- **No interface (`.mli`) tracking in reprobuild's graph.** Dune
  handles it; reprobuild's view is opaque.

## See also

- [Language-Conventions/OCaml.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/OCaml.md)

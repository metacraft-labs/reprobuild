# Hello World C — Linux-Distro-Recipe-Validation M1

Minimal end-to-end C recipe used by the Linux-Distro-Recipe-Validation
campaign (M1: self-bootstrap on Arch).

## Layout

```
hello-world-c/
  repro.nim          # Mode 3 project file (executable + uses: "gcc")
  src/
    main.c           # prints "hello from reprobuild M1"
```

## Building

After bootstrapping `repro` per
`tools/multi-distro-harness/bootstrap-arch.sh`:

```sh
cd examples/hello-world-c
repro build . --tool-provisioning=path --no-runquota
./.repro/build/hello-world-c/hello-world-c
# -> hello from reprobuild M1
```

The build dispatches to `repro-standard-provider` (Tier 2b), which
routes through the `c_cpp_direct` convention. That convention emits
two actions: one `gcc -c` compile for `src/main.c` and one `gcc -o`
link for the executable. Outputs land at
`.repro/build/hello-world-c/hello-world-c`.

## Why Mode 3 and not Mode 1?

The Mode 1 (layout-as-manifest) path synthesises a project file that
lacks a `build:` block and, for C/C++ specifically, does not yet emit
a per-member source shim. The synthesised `.repro/mode1-synth/` dir
has no `src/main.c`, so the standard provider reports
"no convention matched". Mode 3 sidesteps this by giving the
`c_cpp_direct` convention what it expects directly: a `repro.nim` at
the workspace root, a `uses: "gcc"` line, an `executable ...: discard`
member, and the standard `src/main.c` layout.

See the M1 implementation notes in
`reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org`.

## Content-addressability

Same input -> same sha256 across cold rebuilds. Validated on Arch with
Nim 2.2.10 + gcc 15.x (the toolchain shipped by `provision-arch.ps1`):

```sh
rm -rf .repro ~/.cache/repro
repro build . --tool-provisioning=path --no-runquota
sha256sum .repro/build/hello-world-c/hello-world-c
# -> f602a18b0828fae7ba6ff59c33c1090b55a66836d21ed48bd15deffab9ee9a07
rm -rf .repro
repro build . --tool-provisioning=path --no-runquota
sha256sum .repro/build/hello-world-c/hello-world-c
# -> f602a18b0828fae7ba6ff59c33c1090b55a66836d21ed48bd15deffab9ee9a07  (same)
```

The literal sha256 depends on the host gcc version; the IDENTITY across
cold rebuilds is the content-addressability guarantee being tested.

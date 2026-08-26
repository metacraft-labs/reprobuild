# two-binary-dist — M0 packaging-layer sample

The reference consumer of the DSL packaging layer (the CPack analog,
`libs/repro_dsl_stdlib/.../packaging/`). A single build-graph definition
(`reprobuild.nim`) compiles two trivial C binaries and emits **all three
M0 package formats** from one `distribution` value:

| Target    | Artifact                                   | Backend       |
|-----------|--------------------------------------------|---------------|
| `deb`     | `build/two-bin-dist_1.0.0_<debArch>.deb`   | `dpkg-deb`    |
| `rpm`     | `build/two-bin-dist-1.0.0-1.<arch>.rpm`    | `rpmbuild`    |
| `tarball` | `build/two-bin-dist-1.0.0-<arch>.tar.gz`   | `tar`         |
| `packages`| all three (default target)                 | —             |

```sh
repro build examples/two-binary-dist --tool-provisioning=path
```

Each package installs `greeter` and `farewell` to `/usr/bin` as
generated **§5 env-default wrappers** that exec the real binaries under
`/usr/libexec/two-bin-dist/`. Running the installed `greeter` with no
environment prints the packaged default greeting (seeded by the wrapper),
which is what the container `.deb`-install test asserts
(`tests/e2e/packaging/t_m0_packaging_layer_deb_rpm_tarball.nim`).

The vendored-library + RPATH half of the §5 contract is a structural
no-op for these trivial binaries (they need no runtime closure); the same
`runtimeContract` field carries reprobuild's own
blake3/xxHash/sqlite/openssl/zstd/clingo closure when packaging
reprobuild itself (M1).

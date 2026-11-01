# `os-release` fixtures

Copies of `os-release(5)` files, one per base the system commands classify
(`repro_infra/host_base`). A gate passes one of them to `runRepro` under
`TestbedOsReleaseKey` (`tests/e2e/m83/profile_compile_edge_harness.nim`),
which runs the engine in its own mount namespace with the file bound over
`/etc/os-release`, so `repro infra plan` / `apply` observe that base on
whatever Linux machine runs the gate. No engine reads a variable for its
base: the `REPRO_OS_RELEASE_PATH` seam every engine once honoured is retired.
Off Linux only `reproos` is meaningful (the base there is "not Linux", which
plans in full as ReproOS does):

- `debian-13`, `ubuntu-24.04`, `raspbian-13` -- Debian-family distribution
  hosts (`ID_LIKE=debian` for the derivatives), the bases the
  `add-on-debian` realisation covers;
- `arch` -- a distribution host without an add-on realisation;
- `nixos`, `reproos` -- hosts whose whole system is a configuration's (the
  ReproOS file is the one the ReproOS image writes).

Gates that run a system command against a host the registry declares
without `system:` use `reproos`, so they do not depend on the base of the
machine running them.

# `os-release` fixtures

Copies of `os-release(5)` files, one per base the system commands classify
(`repro_infra/host_base`). Gates point `REPRO_OS_RELEASE_PATH` at one of
them so `repro infra plan` / `apply` observe that base on whatever machine
runs the gate:

- `debian-13`, `ubuntu-24.04`, `raspbian-13` -- Debian-family distribution
  hosts (`ID_LIKE=debian` for the derivatives), the bases the
  `add-on-debian` realisation covers;
- `arch` -- a distribution host without an add-on realisation;
- `nixos`, `reproos` -- hosts whose whole system is a configuration's (the
  ReproOS file is the one the ReproOS image writes).

Gates that run a system command against a host the registry declares
without `system:` use `reproos`, so they do not depend on the base of the
machine running them.

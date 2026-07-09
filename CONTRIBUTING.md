# Contributing to Reprobuild

This repository is the public `metacraft-labs/reprobuild` product repository.
The architecture is specified in
[metacraft-labs/reprobuild-specs](https://github.com/metacraft-labs/reprobuild-specs);
when a change alters behavior described there, update the spec together with
the code.

## Local Tooling

- `just build` compiles all app entry points listed in `apps/entrypoints.txt`.
- `just test` runs the local Nim test suite.
- `just lint` runs repository requirement and Nim source checks.

## Nix Dev Shell

`nix develop` activates the compiler and library toolchain. To handle private
dependency overrides on development hosts, `scripts/dev-shell.sh` auto-detects
sibling checkouts:

```bash
# Clone the sibling native recorder (if developer credentials are configured):
gh repo clone metacraft-labs/codetracer-native-recorder ../codetracer-native-recorder

# Enter the dev shell:
bash scripts/dev-shell.sh
```

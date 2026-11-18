## Fixture: a profile whose guards reach the `nixos` predicate. Whether a
## Linux target is NixOS is not part of its system name, so an evaluation
## for a target states it (`repro home export --target ... --nixos`,
## `reprobuild.lib.readIntent { nixos = ...; }`) or is refused. Exercised by
## `t_e2e_export_nixos_fact_required` and the flake check `lib-tests`;
## `export.json` and `cases.json` are described in ../README.md.
import repro_profile

profile "nixosFact":
  activity default:
    bash
    when nixos():
      `nixos-only-tool`
    when linux() and not nixos():
      `other-linux-tool`

  hosts:
    "h": [default]

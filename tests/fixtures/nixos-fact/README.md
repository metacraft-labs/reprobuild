# The `nixos` fact

`profile/home.nim` selects `nixos-only-tool` under `when nixos():` and
`other-linux-tool` under `when linux() and not nixos():`; `bash` is always
selected. Whether a Linux target is NixOS is not part of its system name, so
an evaluation for a target states it or is refused.

- `export.json` — `repro home export --host h` of the profile (the snapshot a
  Nix consumer reads). `t_e2e_export_nixos_fact_required` keeps it current
  (`--check`), and rewrites it with `REPRO_UPDATE_INTENT_FIXTURES=1`.
- `cases.json` — for each case, what `repro home export --target <system>
  [--nixos | --nixos=false]` reports: the packages the evaluation selects
  (sorted), or `"refused": true` (exit 3, naming `nixos`) when the fact is
  not stated. The Nix library's `readIntent { nixos = ...; }` over
  `export.json` must give the same answers (`lib-tests`).

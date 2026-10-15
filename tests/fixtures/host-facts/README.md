# Host-facts fixture pair (GM6)

`nix.json` and `reprobuild.json` describe the same host (`gm6-host`,
`x86_64-linux`) with exactly ONE known difference in each host-facts category,
each of a different status:

| Category | Entry | Status | Why |
|---|---|---|---|
| packages | `jq` | only-in-nix | `home.packages` has it, no activity does |
| files | `~/.zshrc` | different | `digest` differs (mode is equal) |
| environment | `var:GM6_EDITOR` | only-in-reprobuild | no `home.sessionVariables` entry |
| services | `systemd:gm6.service` | different | `enabled` differs (digest is equal) |

Every category also holds at least one `same` entry (`bash`,
`~/.config/gm6/app.conf`, `path:~/.local/bin`, `systemd:gm6-same.timer`);
`nix.json` has one `unmapped` package (`hello-2.12.2`) and each side one
`uncategorized` entry. Informational fields (`origin`, `version`) differ
freely between the sides and must never be reported.

Read by `tests/e2e/m83/t_e2e_compare_reports_each_category.nim` and
`t_e2e_compare_unmapped_is_not_different.nim`; the schema is
`docs/user-guide/host-facts.md`.

# Plan-time data-file fixtures (GM4)

Shared fixtures for the row-selection semantics of plan-time data files
(reprobuild-pm `spec/Gradual-Nix-To-Reprobuild-Migration.md` §Declarative data
files read at plan time). They are consumed by
`libs/repro_cli_support/tests/t_data_file_row_selection_fixtures.nim` (the
profile planner) and are meant to be consumed unchanged by the Nix helper
library's `reprobuild.lib.readData` tests (GM5): both implementations must
select the same rows for every case.

Each case is a directory holding the data file `data.toml` and `case.json`.
Rows may be written as `[[package]]` / `[[resource]]` tables or as an inline
array of inline tables (`package = [{ ... }]`, `[]` for none): the same TOML
data, which Nix's `builtins.fromTOML` cannot tell apart (case `inline-rows`).

`row-selection/<case>/case.json`:

```json
{
  "description": "what the case pins",
  "hosts": { "<host>": ["<activity>", ...] },
  "evaluations": [
    { "host": "<host>", "system": "<nix system double>",
      "packages": ["<canonical package>", ...],
      "resources": ["<resource address>", ...] }
  ]
}
```

The profile is `data.toml` alone plus the `hosts` map (no compiled activity
bodies). For each evaluation, `packages` is the SET (sorted) of canonical
package names the planner selects for `host` on `system`: the rows whose
`activity` is `default` or one the host's `hosts` entry names, and whose
`when` (if any) holds for the target, where `macos` / `linux` / `windows` /
`bsd` and `x86_64` / `arm64` / `arm32` come from the system double, `host`
is the evaluation's host, and `wsl` is false (WSL is a fact only a planner
running on the host knows).

An evaluation may instead carry `"undeclaredHost": true` (and no
`packages`): its host is not in the case's non-empty `hosts` map, and both the
planner and `readData` refuse it -- a profile with a `hosts:` registry
declares every host it may be applied to (reprobuild-pm spec
Gradual-Nix-To-Reprobuild-Migration.md, Open question 6). A host that should
get the `default` activity alone is declared with `["default"]`.

`resources` (present when the case has `[[resource]]` rows) is the SET
(sorted) of addresses of the resource rows that apply: a resource row without
an `activity` key is profile-wide, so it applies wherever its `when` holds,
whatever activities the host selects; a row with `activity = "<name>"` (GM9,
case `activity-scoped-resource-rows`) belongs to that activity and applies
only on a host whose selection enables it, and where its `when` holds (an
activity no package row or block declares is created, as for a package row).
Its address is the row's `address`, else the constructor's
auto-address (`<kind>:<key fields>`, e.g. `fs.userFile:~/.config/a.conf`).
A `[[resource]]` row's keys are `kind`, `when`, `activity` and the parameters of the
resource constructor `kind` names (`fsUserFile`, `envUserVariable`, ...),
with the constructor's defaults for omitted ones.

`row-rejection/<case>/case.json`:

```json
{ "description": "...", "error": ["substring", ...] }
```

The file must be refused as a whole (no row selected); the diagnostic
contains every listed substring.

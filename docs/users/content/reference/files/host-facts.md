---
title: Host facts
description: The fields of the JSON document repro home facts and reprobuild.lib.homeManagerFacts write, format repro.host-facts, schema version 1.
kind: reference
persona: machine-owner
domain: machines
order: 20
verifies:
  commands: [home facts, home compare]
  tests:
    - tests/e2e/m83/t_e2e_home_facts_from_isolated_plan.nim
    - tests/e2e/m83/t_e2e_compare_reports_each_category.nim
    - tests/e2e/m83/t_e2e_compare_unmapped_is_not_different.nim
    - nix/tests/host-facts.nix
unverified:
  - claim: "Every field and its meaning."
    reason: "Written by hand from the schema (format repro.host-facts, HostFactsSchemaVersion 1 in libs/repro_home_apply/src/repro_home_apply/host_facts.nim; nix/lib/host-facts.nix); no generator reads the schema and nothing compares this page with it."
    owner: unassigned
---

# Host facts

A host-facts document reduces one side's home for one host and one target
system to the four categories both sides can be compared on. `repro home
facts` writes the profile's side and `reprobuild.lib.homeManagerFacts` the
Home Manager side, both in format `repro.host-facts`, schema version 1.
`repro home compare` compares one document of each side
([Compare a Home Manager configuration with a profile](../../guides/machines/compare-with-home-manager.md);
the Nix functions are in [Nix library and Home Manager module](../nix-library.md)).

## Shape

```jsonc
{
  "format": "repro.host-facts",
  "schemaVersion": 1,
  "side": "reprobuild",                       // or "nix"
  "host": "laptop",
  "system": "x86_64-linux",
  "categories": {
    "packages":    [ { "id": "ripgrep", "origin": "activity default", "version": "14.1.0" } ],
    "files":       [ { "id": "~/.zshrc", "origin": "stow zsh/.zshrc", "mode": "0644", "digest": "sha256:…" } ],
    "environment": [ { "id": "var:EDITOR", "origin": "…", "value": "nvim" },
                     { "id": "path:~/.local/bin", "origin": "…" },
                     { "id": "block:~/.zshrc#repro-direnv", "origin": "…", "digest": "sha256:…" } ],
    "services":    [ { "id": "systemd:backup.service", "origin": "…", "enabled": true, "digest": "sha256:…" },
                     { "id": "launchd:org.example.agent", "origin": "…", "programArguments": ["…"],
                       "runAtLoad": true, "keepAlive": false } ]   // launchd: darwin systems only
  },
  "unmapped":      [ { "category": "packages", "id": "hello-2.12.2", "origin": "home.packages", "reason": "…" } ],
  "uncategorized": [ { "id": "dconf:org/gnome/…", "origin": "dconf.settings", "reason": "…" } ],
  "concerns": { "declared": true, "applied": ["applications"] }   // reprobuild side only
}
```

## Top-level fields

| Field | Meaning |
|---|---|
| `format` | Always `repro.host-facts`. |
| `schemaVersion` | `1`. `repro home compare` refuses a document of another version. |
| `side` | `reprobuild` (from `repro home facts`) or `nix` (from `homeManagerFacts`). A comparison takes one document of each. |
| `host` | The host the document describes. Both documents of a comparison must name the same host. |
| `system` | The target system, such as `x86_64-linux` or `aarch64-darwin`. Both documents must name the same one. |
| `categories` | The compared entries, by category (below). |
| `unmapped` | Entries their producer could not give a logical id. Listed, never compared. |
| `uncategorized` | Entries no category covers. Listed, never compared. |
| `concerns` | Reprobuild side only, informational (below). |

## Categories and ids

Every entry has an `id` both sides can produce. A category holds each id
once.

| Category | `id` | Compared fields |
|---|---|---|
| `packages` (GUI applications included) | the canonical reprobuild package name | none: identity only |
| `files` | `~/<path>` relative to the home, `/` separators; an absolute path outside the home | `mode`, `digest` |
| `environment` | `var:NAME`, `path:ENTRY`, `block:<file>#<blockId>` | `value` for a variable, `digest` for a block, nothing for a `PATH` entry |
| `services` | `systemd:<unit file name>`, `launchd:<Label>` | `enabled` and `digest` for a systemd unit; `programArguments`, `runAtLoad`, `keepAlive` for a launchd agent |

- **`id`, `origin` and `version` are never compared.** `origin` says where an
  entry came from, for the reader. `version`, when present, is the version
  the side names: the version the profile pins for the package, or the
  derivation's version on the Nix side. The two sides pin versions
  independently (`flake.lock`, `home.lock`), so comparing them would report
  every nixpkgs update as a difference.
- **`digest`** is `sha256:<lower-case hex>` of the bytes the file would hold,
  or `null` when the producer cannot know them before an apply: a file a
  command produces at apply time; on the Nix side, a file whose content it
  cannot find (an out-of-store link into a tree not passed as
  `outOfStoreRoots`, or no file at the target), and a systemd unit whose unit
  file is not in `home-files`. The Nix side then adds `(content unknown: …)`
  or `(unit file unknown: …)` to `origin`. `null` never equals a real digest.
- **`mode`** of a linked file (a stow link, a Nix store file) is `0755` when
  it is executable, else `0644`; a store's read-only bits are not a
  difference. An `fsUserFile` reports its declared mode, so `0600` differs
  from a store file. A file a package output generates is always `0644` on
  the reprobuild side, executable or not. A stow file is `0644` on a Windows
  target, and on any target when `repro home facts` runs on Windows. On the
  Nix side, a file whose content is unknown (above) has `mode` `null` as
  well.
- **A `PATH` entry** under the home is named `~/<rel>` when it spells the home
  `$HOME`, `${HOME}`, `~` or the host's home directory as an absolute path,
  on both sides, so `/home/alice/.local/bin` and `$HOME/.local/bin` are one
  entry. The host's home directory is `home.homeDirectory` on the Nix side.
  On the reprobuild side it is `repro home facts --home-dir DIR`, and the home
  of the user running the command when the flag is absent. Pass `--home-dir`
  when the facts describe another machine, or run in a build sandbox, as
  `reprobuild.lib.homeEquivalenceCheck` does with the configuration's
  `home.homeDirectory`. The directory only names entries: nothing under it is
  read.
- **Two producers with the same id on one side** describe one fact when they
  agree on every compared field, and the first entry is kept. When they
  disagree, the producer refuses, naming both origins and each differing
  field: `repro home facts` on the reprobuild side, `homeManagerFacts` on the
  Nix side, where the one such case is two `launchd.agents` with the same
  `config.Label`. The `unmapped` and `uncategorized` lists are not
  compared, and an id may repeat there (`homeManagerFacts` keeps the first
  entry for one).
- **A stow file and an `fsUserFile` on one path** are settled by the planner
  before the document is written, as `repro home apply` settles them: one
  entry when they agree, a refused plan when they do not.

## `unmapped` and `uncategorized`

Each entry has an `id` and a `reason`, which `repro home compare` requires,
and an `origin`. An `unmapped` entry also names its `category`. An
`uncategorized` entry has `category: null` on the reprobuild side and no
`category` key on the Nix side.

- **`unmapped`**: a Nix derivation or Homebrew token that no contribution
  catalog claims, a Mac App Store app, a `homebrewCask` or `homebrewFormula`
  resource (a token is not a canonical name). For an unclaimed derivation or
  token the fix is a contribution in a catalog; for a Homebrew resource in
  the profile it is to declare the canonical package instead.
- **`uncategorized`**: Home Manager `dconf.settings` keys and macOS
  `targets.darwin.defaults` keys; the profile's dconf, KDE config, gsettings,
  macOS user-default, VS Code extension, macOS app-bundle and Windows
  resources.

Neither list makes a comparison fail.

## `concerns`

`{ "declared": <bool>, "applied": [<concern>, …] }`, on the reprobuild side
only, and never compared. `declared` says whether the host's `hosts:` entry
declares `applies:`; `applied` lists the concerns reprobuild applies on the
host (every concern when it does not declare). When `declared` is true,
`repro home compare` says which side applies each category. The categories
always describe everything reprobuild *would* apply, so a concern can be
measured before the declaration hands it to reprobuild.

## Compatibility

`schemaVersion` changes when the meaning of an existing field changes or a
compared field is added. A new top-level field may be added without a change,
as `concerns` was: `repro home compare` ignores top-level keys it does not
know. A new entry field may not. `repro home compare` compares every entry
field except `id`, `origin` and `version`, so an older `repro home compare`
would compare it, and would report every entry as different when only one
producer writes it.

`repro home compare` refuses, with exit 2, a document whose `format` or
`schemaVersion` it does not know, a `side` other than `nix` or `reprobuild`,
two documents of the same side, documents for different hosts or systems, a
missing or unknown category, an entry without an `id`, a category that holds
an id twice, a missing `unmapped` or `uncategorized` list, an entry of
either without an `id` or `reason`, and a malformed `concerns`.

## Related

- [Compare a Home Manager configuration with a profile](../../guides/machines/compare-with-home-manager.md)
- [Nix library and Home Manager module](../nix-library.md)
- [Home profile export](home-export.md)

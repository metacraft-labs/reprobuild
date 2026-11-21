# Is my Nix home the same as my Reprobuild home? — host facts and `repro home compare`

When a machine is configured both by Home Manager and by a Reprobuild home
profile, you switch a concern (applications, packages, dotfiles, environment)
from one to the other only once you know the two would give the host the same
thing. Reprobuild measures that instead of asking you to trust it:

1. each side is reduced to a **host-facts** document for one host and one
   target system — `repro home facts` for the profile,
   [`reprobuild.lib.homeManagerFacts`](#the-nix-side-reprobuildlibhomemanagerfacts)
   for a Home Manager configuration;
2. [`repro home compare`](#comparing-repro-home-compare) reports, per
   category, what is the same, what only one side has, and what differs;
3. an [allowlist](#the-allowlist) records the differences you know about,
   each with its reason;
4. [`reprobuild.lib.homeEquivalenceCheck`](#as-a-flake-check) runs all of it as
   one flake check per host.

## What a host-facts document holds

```json
{
  "format": "repro.host-facts",
  "schemaVersion": 1,
  "side": "reprobuild",
  "host": "home-pc",
  "system": "x86_64-linux",
  "categories": {
    "packages":    [ { "id": "ripgrep", "origin": "activity default" } ],
    "files":       [ { "id": "~/.zshrc", "origin": "stow zsh/.zshrc", "mode": "0644", "digest": "sha256:…" } ],
    "environment": [ { "id": "var:EDITOR", "origin": "…", "value": "nvim" },
                     { "id": "path:~/.local/bin", "origin": "…" },
                     { "id": "block:~/.zshrc#repro-direnv", "origin": "…", "digest": "sha256:…" } ],
    "services":    [ { "id": "systemd:backup.service", "origin": "…", "enabled": true, "digest": "sha256:…" },
                     { "id": "launchd:org.example.agent", "origin": "…", "programArguments": ["…"], "runAtLoad": true, "keepAlive": false } ]
  },
  "unmapped":      [ { "category": "packages", "id": "hello-2.12.2", "origin": "home.packages", "reason": "…" } ],
  "uncategorized": [ { "category": null, "id": "dconf:org/gnome/…", "origin": "dconf.settings", "reason": "…" } ]
}
```

Every entry has a **logical id** both sides can produce:

| Category | Id | Compared fields |
|---|---|---|
| packages (GUI applications included) | the canonical Reprobuild package name | none — identity only |
| files | `~/<path>` (an absolute path outside the home) | `mode`, `digest` |
| environment | `var:NAME`, `path:ENTRY`, `block:<file>#<blockId>` | `value` (variables), `digest` (blocks) |
| services | `systemd:<unit file>`, `launchd:<Label>` | `enabled` + `digest` (systemd); `programArguments`, `runAtLoad`, `keepAlive` (launchd) |

- `origin` says where an entry came from and `version` which version the side
  would install; neither is ever compared. Versions come from two independent
  pins (`flake.lock`, `home.lock`), so comparing them would report every
  nixpkgs bump as a difference.
- `digest` is `sha256:<hex>` of the bytes the file would hold, or `null` when
  no producer can know them before an apply (a file produced by a command at
  apply time, an out-of-store link into a tree you did not map). `null` never
  equals a real digest.
- `mode` of a linked file is `0755` when executable, else `0644` (a link shows
  its target's bits, and a store file is read-only either way). A
  `fsUserFile(mode = "0600")` reports `0600`.
- A category holds each id once. If two producers report the same id, such as
  two `envUserPath` resources sharing an entry, and they agree on every
  compared field, the first entry is kept. If they differ, `repro home facts`
  refuses, naming both origins and each differing field.
- A stow file and an `fsUserFile` for the same path are settled by the
  planner, the same way `repro home apply` settles them. If they agree on
  `mode` and `digest`, the resource writes the file and the facts carry one
  entry from it. If they disagree, the plan is refused before anything is
  written, and the error names the path, both sources and the differing
  fields.
- **`unmapped`** entries are ones their producer could not give a logical id —
  a Nix package or Homebrew token that no contribution catalog claims, a Mac
  App Store app, a `homebrewCask` resource. They are listed, never compared,
  and never fail a comparison: the fix is a contribution in a catalog, not a
  change to either configuration.
- **`uncategorized`** entries are ones no category covers (dconf keys, user
  defaults, VS Code extensions, …). They are listed and never compared.
- **`concerns`** (Reprobuild side only, informational): `{ "declared": true,
  "applied": ["applications"] }` when the host's `hosts:` entry declares which
  concerns Reprobuild applies, `declared: false` and every concern otherwise.
  The categories always describe everything Reprobuild *would* apply, so a
  concern can be measured before the declaration hands it to Reprobuild.

## The Reprobuild side: `repro home facts`

```text
repro home facts [--host NAME] [--target SYSTEM] [--output FILE]
```

It compiles your profile and runs the planning half of `repro home apply` —
the same planner `repro home apply --plan` uses — against a **private home
and state directory** it creates for the run and deletes afterwards. It never
reads or writes your real home: the facts are what an apply would write, not
what happens to be there, and every path is reported relative to the home.

- `--host` picks the host (default: `$REPRO_HOST`, then the machine's host
  name).
- `--target` plans for another platform (default: the one `repro` runs on).
  Like `repro home export --target`, it refuses (exit 3) when the profile's
  platform probe cannot vouch that a compile-time `when defined(...)` does not
  change the profile there.

Exit status: 0 printed; 1 the profile could not be compiled or planned;
2 usage error; 3 the target cannot be described.

## The Nix side: `reprobuild.lib.homeManagerFacts`

```nix
reprobuild.lib.homeManagerFacts {
  configuration = self.homeConfigurations.workstation;  # a homeManagerConfiguration result
  host = "home-pc";
  # Home Manager has no Homebrew option; say what the host's Brewfile installs.
  homebrew = { casks = [ "ghostty" ]; formulae = [ ]; masApps = { }; };
  # mkOutOfStoreSymlink links into these prefixes are digested from these trees.
  outOfStoreRoots."/home/me/dotfiles" = self;
}
```

It returns a derivation that writes the facts (digests need the files'
bytes, so the activation package's `home-files` tree is built);
`.evaluated` holds everything known without building.

- **packages**: each `home.packages` derivation is translated to its canonical
  name through the Nix contribution catalog: the catalog names an attribute,
  and a derivation whose package name (`pname`) is that attribute's package
  name in your nixpkgs is that canonical package — whichever nixpkgs instance
  or override it came from. Homebrew tokens are translated through the
  Homebrew catalog. Anything unclaimed is `unmapped`.
- **files**: every enabled `home.file` (and so `xdg.configFile`) entry,
  expanded to the files it places. Unit files of your `systemd.user` units are
  services facts, not files.
- **environment**: `home.sessionVariables`, `home.sessionPath`.
- **services**: `systemd.user` units on Linux (enabled when Home Manager links
  them into a `.wants` directory), `launchd.agents` on macOS.

The reverse catalog lookup is available on its own as
`reprobuild.lib.lookupNixPackageName { pkgs, drv }`.

## Comparing: `repro home compare`

```text
repro home compare --facts nix.json --facts repro.json [--allow known-diffs.toml]
                   [--format text|json] [--show-same]
```

Give one document of each side for the same host and system; the order does
not matter. For every category the report lists each id as `same`,
`only-in-nix`, `only-in-reprobuild` or `different` (naming the differing
fields with both values), then the unmapped entries; uncategorized entries are
listed at the end. When the Reprobuild document says its host declares the
concerns Reprobuild applies, each category line ends with the side that
applies it there (`-- applied by reprobuild on m1`, `nix`, or for packages
`split (applications: reprobuild, packages: nix)`), and the JSON form carries
it as `owner`; it never changes a verdict. The text form counts `same` entries (`--show-same` lists
them); the JSON form lists everything.

Exit status: **0** — no difference outside the allowlist and no stale
allowlist row; **1** — a difference the allowlist does not cover, or a stale
row; **2** — the inputs cannot be compared (malformed or unreadable facts,
two documents of one side, different hosts or systems, an invalid
allowlist).

## The allowlist

```toml
[[allow]]
category = "files"                       # packages | files | environment | services
status = "only-in-nix"                   # optional: only-in-nix | only-in-reprobuild | different
id = "~/.vscode/extensions/*"            # optional: one id, or a prefix ending in `*`
hosts = ["home-pc", "m1"]                # optional: the hosts the row applies to
reason = "VS Code extensions are installed by Home Manager as files; the profile declares them as vscode.extension"
milestone = "GM9"                        # optional: what will remove the row
```

- Every row needs a non-empty `reason`; a row without one is refused (exit 2).
  An allowlist entry without a reason is a silent pass.
- Unknown keys, categories and statuses, `status = "same"` / `"unmapped"`
  (they never need an excuse), an empty `hosts` list and an `id` of just `*`
  are refused too.
- A row that applies to the compared host but matches no difference is
  **stale** and fails the comparison: remove it when the difference it
  excused is gone, so it cannot silently excuse the next one.

## As a flake check

```nix
checks.x86_64-linux.home-equivalence-home-pc = reprobuild.lib.homeEquivalenceCheck {
  configuration = self.homeConfigurations.home-pc;
  host = "home-pc";
  profileDir = ./.;                       # the directory holding home.nim
  allowlist = ./home-equivalence-allow.toml;
  homebrew = { };                         # as for homeManagerFacts
  outOfStoreRoots."/home/me/dotfiles" = self;
};
```

The check builds both documents — `repro home facts` runs in the build
sandbox with the packaged `repro` — and runs `repro home compare`. It fails,
printing the report, when the comparison exits non-zero; its output holds
`nix.json`, `reprobuild.json`, `report.txt` and `report.json`. Build one host
with `nix build .#checks.<system>.home-equivalence-<host>` and read
`result/report.txt`.

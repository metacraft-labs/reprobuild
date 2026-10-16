# Reading a home profile from Nix — `reprobuild.lib`

When a machine is configured by both Nix (Home Manager, nix-darwin, NixOS)
and a Reprobuild home profile, every fact should be written once. The
Reprobuild flake exports a small library, `reprobuild.lib`, and a Home Manager
module, `reprobuild.homeManagerModules.intent`, so a Nix configuration can
**read** what your profile says instead of repeating it:

| You want Nix to… | Use |
|---|---|
| read a plain list (applications, tools) that the profile also reads | [`readData`](#readdata--a-data-file-selected-like-the-profile) |
| use what the whole profile evaluates to for a host | [`readIntent`](#readintent--the-evaluated-profile) |
| turn a canonical package name into a nixpkgs attribute | [`nixRealizationOf`](#nixrealizationof--canonical-name-to-nixpkgs-attribute) |
| turn a canonical package name into a Homebrew token, or a Brewfile token back into a package | [`brewRealizationOf`](#brewrealizationof--canonical-name-to-homebrew-token-and-back) |
| let Home Manager install packages, files and environment from the profile | [`homeManagerModules.intent`](#the-home-manager-module) |
| check that a Home Manager configuration and the profile give a host the same thing | [`homeManagerFacts`, `homeEquivalenceCheck`](host-facts.md) |

Nix never compiles your profile and never re-implements Reprobuild's rules
beyond the one it has to: the [predicate grammar](home-export.md#predicates)
of `when` guards, which it evaluates for the system it is configuring.

## Getting the library

```nix
{
  inputs.reprobuild.url = "github:metacraft-labs/reprobuild";
  # or, in a workspace whose reprobuild pin comes from another flake:
  # reprobuild = nixos-modules.inputs.reprobuild;

  outputs = { reprobuild, ... }: {
    # reprobuild.lib.readData, reprobuild.lib.readIntent, …
  };
}
```

`reprobuild.lib` does not depend on a system; `reprobuild.packages.<system>.repro`
is the `repro` it runs when it needs one.

Target systems are named as Nix names them: `x86_64-linux`, `aarch64-linux`,
`x86_64-darwin`, `aarch64-darwin`, `x86_64-windows`, `aarch64-windows`.

## `readData` — a data file, selected like the profile

A [data file](home-export.md#data-files) is a TOML list beside `home.nim`
that the profile names in its `data:` section. Nix can read the same file
directly — no `repro` involved:

```nix
apps = reprobuild.lib.readData {
  path = ./data/apps.toml;
  system = "aarch64-darwin";
  host = "m1";
  hosts = { m1 = [ "desktop_apps" ]; };   # the profile's hosts: entries you need
};
# apps.names    == [ "ghostty" "iterm2" … ]     selected package names, sorted
# apps.packages == [ { name; version; binaries; activity; } … ]
# apps.rows     == every row of the file, validated
```

A row is selected exactly when `repro home plan` would select it: its
`activity` is `default` or one the host's `hosts:` entry names, and its `when`
holds for `system` and `host` (`wsl` is false for every target). A `hosts`
map that does not name `host` is refused, as the planner refuses a host its
profile's `hosts:` registry does not declare (an empty map, like a profile
without a registry, selects `default` for every host). Instead of
`hosts` you can pass `activities = [ … ]`, for example the activities
`readIntent` reports for the host. A package selected by several rows is
listed once, with the version and binaries of the row the planner keeps (the
activities in the order they first appear in the file, rows in file order
within each). Rows may be `[[package]]` tables or an inline array of inline
tables (`package = [{ name = "jq", activity = "cli" }]`); both readers accept
both.

`readData` refuses — throws with the same diagnostic Reprobuild prints, naming
the row and the key — every file the profile planner refuses: an unknown key
or table, a missing `name` or `activity`, an empty or non-built-in `when`
(`headless`, `onBattery`, …).

It also refuses any file with `[[resource]]` rows. A resource row is a call of
the profile's resource constructor, with that constructor's defaults and
address, and only Reprobuild evaluates those. Read resources through
[`readIntent`](#readintent--the-evaluated-profile), which carries them
expanded, or keep them in a file of their own.

## `readIntent` — the evaluated profile

`readIntent` reads a [`repro home export`](home-export.md) document and
evaluates it for one host and target system:

```nix
intent = reprobuild.lib.readIntent {
  snapshot = ./home-export.json;   # committed; see below
  host = "m1";
  system = "aarch64-darwin";
};
# intent.evaluation.activities       the activities the host runs
# intent.evaluation.packages         [ { name; version; binaries; activity; } … ], sorted by name
# intent.evaluation.resources        the resources whose guards hold, as in the export
# intent.evaluation.configOverrides  the config overrides whose guards hold
# intent.document                    the whole export
```

`evaluation` is what `repro home export --host m1 --target aarch64-darwin`
prints as `evaluation`, with one difference: packages are sorted by name. A
home profile that declares a resource the home planner does not apply (a
system-scope kind such as `fsSystemFile`) is refused by `repro home export`,
so an export never carries one.

**Two ways to get the document**, with the same result:

- **Snapshot** (`snapshot = ./file.json`): you commit the output of
  `repro home export --host <host> > file.json`, and keep it current in CI
  with `repro home export --host <host> --check file.json`. Nothing runs at
  evaluation time; this works everywhere, including restricted evaluation.
- **Import-from-derivation** (`profileDir = ./.;` and no `snapshot`): Nix
  builds a derivation that runs `repro home export` on the profile and reads
  the result. The derivation runs on the machine that evaluates
  (`buildSystem`, which defaults to `builtins.currentSystem` when the
  evaluation is impure — pass it explicitly in a pure flake evaluation), not
  on the target: a Linux machine can describe your Mac. It costs a profile
  compile per profile change, during evaluation. For a profile whose `hosts:`
  entries declare `applies:`, also pass `packagesCatalog` (a
  `reprobuild-packages` checkout, e.g. a flake input): the sandbox has no
  workspace to find it in, and the export needs it to tell which packages
  are applications.

**When `readIntent` refuses** (throws):

- the document is not a `repro home export` document, or its `schemaVersion`
  is one this library does not know (regenerate it with the `repro` the
  flake pins);
- the export cannot describe the target: its `platforms` entry for `system`
  is `differs` or `unevaluated` — typically a `when defined(macosx)` in the
  profile, compiled on Linux. The message says why. Use runtime predicates
  (`when macos():`), or export on the target platform. The platform that
  compiled the export is always accepted;
- `host` is not declared: the profile has a `hosts:` registry and it does not
  name `host`. Reprobuild refuses to plan or apply such a host too, rather
  than giving it the `default` activity alone; declare it, with
  `"<host>": [default]` if `default` is all it should run.

One snapshot describes every host: `intent` carries the whole `hosts:`
registry, and only `selection` is the exporting host's. A Nix configuration
can therefore read each host's activities from a single committed export
(`readIntent { snapshot; host = <each host>; … }.evaluation.activities`) —
the `hosts:` registry is then the one host-to-activity map both sides
read.

## `nixRealizationOf` — canonical name to nixpkgs attribute

Profiles name canonical Reprobuild packages. How a package is realized from
nixpkgs is stated once, for everyone, in the
[`reprobuild-nix-packages`](https://github.com/metacraft-labs/reprobuild-nix-packages)
catalog; the flake pins a revision of it.

```nix
reprobuild.lib.nixRealizationOf "llvm"      # => "llvm.dev"
reprobuild.lib.lookupNixRealization "llvm"  # => { found = true; attribute = "llvm.dev";
                                            #      attrPath = [ "llvm" "dev" ]; record = { nixpkgsRev; … }; … }
reprobuild.lib.lookupNixRealization "jq"    # => { found = false; reason = "no Nix realization of `jq` in …"; }
```

`nixRealizationOf` throws, with the reason, for a package the catalog does not
realize, realizes more than once, or realizes other than as a
`nixpkgs#<attribute>`; `lookupNixRealization` returns the reason instead. The
attribute is looked up in **your** nixpkgs; the catalog's pinned revision is
in `record` if you want it. When a name is missing, the fix is a contribution
to the catalog, not a mapping in your configuration.

## `brewRealizationOf` — canonical name to Homebrew token, and back

While a Mac still installs applications through Homebrew, Nix needs to know
which cask or formula installs a canonical package, and a report comparing a
Brewfile with a profile needs the reverse. Both directions are read from the
[`reprobuild-brew-packages`](https://github.com/metacraft-labs/reprobuild-brew-packages)
catalog the flake pins.

```nix
reprobuild.lib.brewRealizationOf { name = "vscode"; system = "aarch64-darwin"; }
# => { kind = "cask"; token = "visual-studio-code"; tap = ""; }
reprobuild.lib.brewRealizationOf { name = "vscode"; system = "x86_64-linux"; }
# => null   (casks are macOS-only; a formula is claimed on Linux too)
reprobuild.lib.brewRealizationOf { name = "bash"; system = "aarch64-darwin"; }
# => null   (no Homebrew record claims it)

reprobuild.lib.lookupBrewToken { token = "visual-studio-code"; }   # kind defaults to "cask"
# => { found = true; name = "vscode"; kind = "cask"; … }
reprobuild.lib.lookupBrewToken { token = "some-other-cask"; }
# => { found = false; reason = "no canonical package in … is installed by Homebrew cask `some-other-cask`"; }
reprobuild.lib.lookupBrewRealization "jdk"
# => { found = true; kind = "cask"; token = "temurin@21"; … }
reprobuild.lib.brewRecords   # every record: [ { name; kind; token; tap; catalog; } … ]
```

An unknown token maps to nothing and comes back with the reason; nothing is
guessed. A name or token the catalog states twice, or with a develop-only
interface, is refused (`lookup…` report it; `brewRealizationOf` throws).

These are **bridge records**: Reprobuild itself never installs anything
through Homebrew, and a profile cannot select a Homebrew realization. They
exist so a Nix configuration that still uses Homebrew can name applications
by the same canonical names as the profile.

## The Home Manager module

```nix
{
  imports = [ reprobuild.homeManagerModules.intent ];

  reprobuild.intent = {
    enable = true;
    host = "m1";
    snapshot = ./home-export.json;   # or profileDir = ./.; for import-from-derivation
    # system defaults to pkgs.stdenv.hostPlatform.system

    packages.enable = true;      # home.packages
    files.enable = true;         # home.file
    environment.enable = true;   # home.sessionVariables / home.sessionPath
    homebrew.enable = false;     # reprobuild.intent.homebrew.casks / .formulae
  };
}
```

Each category is opt-in on its own, so a host can let Home Manager apply its
packages from the profile while Reprobuild applies its files, and move one
category at a time.

When the host's `hosts:` entry declares which concerns Reprobuild applies
(`applies: [...]`, see [home-export.md](./home-export.md#applying-some-concerns-of-a-host)),
every switch **defaults to the complement**: a category is on unless
Reprobuild applies its concern (`packages` ↔ `packages`, `homebrew` ↔
`applications`, `files` ↔ `files`, `environment` ↔ `environment`). You can
still set any switch; enabling one whose concern Reprobuild also applies
produces a warning (both sides would apply it). Uncategorized entries of a
concern Reprobuild applies there are not reported — Reprobuild applies them.
Without a declaration every switch defaults off, as before.

Packages follow the same declaration. Which of them is an application is
Reprobuild's choice of realization for the target system (a disk image on
macOS is an application, a nixpkgs attribute is not), so the export carries
it and every evaluated package of a declaring host has a `concern`:

- a package whose concern Reprobuild applies on the host is left out;
- an application Nix applies goes to the `homebrew` category when it is on
  (its Homebrew hook claims the cask), otherwise through nixpkgs when
  `packages` is on; with `homebrew` on and neither taking it, it is reported
  in `reprobuild.intent.unmapped`;
- any other package is mapped as without a declaration.

So a host that gives Reprobuild its applications and Nix its packages (or
the reverse) needs no application list on the Nix side.

The commands of what Reprobuild applies there -- including the ones an
application carries, such as `code` or `utmctl` -- are launchers in
Reprobuild's profile bin directory. When the host gives Reprobuild
`packages` or `applications` and leaves `environment` to Nix, the evaluation
names that directory (`evaluation.profileBin`), and the `environment`
category puts it **first** on `home.sessionPath`
(`reprobuild.intent.profileBin` shows the resolved path). Outside the
module, resolve it with `reprobuild.lib.profileBinPath { evaluation;
homeDirectory = config.home.homeDirectory; xdgStateHome =
config.xdg.stateHome; }`, which returns null when there is nothing to add.
If your shell start-up prepends another directory after Home Manager's
session variables -- `eval "$(brew shellenv)"`, `path_helper` -- prepend
this one again after it, or a stale copy of a command (a Homebrew cask's
link) wins. A host that moves Reprobuild's state directory with
`$REPRO_HOME_STATE_DIR` adds `<that>/current/bin` itself. In IFD mode, pass
`reprobuild.intent.packagesCatalog` (a `reprobuild-packages` checkout): the
sandboxed export cannot classify packages that catalog defines without it,
and refuses rather than guess.

| Category | From the profile | To |
|---|---|---|
| `packages` | the host's packages | `home.packages`, through `nixRealizationOf` into `pkgs` |
| `files` | `fs.userFile` under `~/` | `home.file."<path>"` (`text`, `executable`) |
| `environment` | `env.userVariable` (string values), `env.userPath` | `home.sessionVariables`, `home.sessionPath` |
| `homebrew` | `pkg.homebrewCask` / `pkg.homebrewFormula`, and packages `homebrew.realizationOf` claims | `reprobuild.intent.homebrew.casks` / `.formulae`, for your Homebrew module (Home Manager has none) |

`homebrew.realizationOf` defaults to `reprobuild.lib.brewRealizationOf`: with
`homebrew.enable = true`, a package the Homebrew catalog claims for the
host's system goes to the token lists instead of `home.packages` (on Linux
only formulae claim). Set `homebrew.realizationOf = _: null;` to claim
nothing, or your own function of `{ name, system }` to override it.

**Nothing is dropped silently.** An entry of an enabled category that cannot
be expressed in Home Manager is listed in `reprobuild.intent.unmapped` with
the reason — a package the catalog does not realize, a version pin your
nixpkgs does not satisfy, a package not available on the system, a file with
a mode other than `0644` / `0755`, a file whose content comes from a command,
a variable that is not a plain string. Entries no category covers at all —
config overrides, managed blocks, user services and the other home-scope
resource kinds Reprobuild plans — are listed in
`reprobuild.intent.uncategorized`. Both fail the evaluation by default, with
an assertion naming every entry (`unmappedPolicy = "error"`,
`uncategorizedPolicy = "error"`). Warning instead is an explicit opt-in per
policy (`"warn"`), for example while Reprobuild applies the uncategorized
entries on that host. A disabled category reports nothing: you have left it
to Reprobuild. What the module
does not recognise is always `unmapped`, whatever categories you enabled: a
resource kind it does not know (one newer than your reprobuild flake, or a
system-scope kind in a document `repro home export` did not produce) and a
field of a mapped kind it does
not know (the entry is not applied without it).

`reprobuild.intent.evaluation` holds the evaluated intent, for your own
modules.

## Keeping a snapshot honest

A snapshot that is out of date is wrong in a way nothing at evaluation time
can see. Check it wherever the profile changes:

```sh
repro home export --host m1 --check home-export.json
```

It fails when what the snapshot says differs from the profile (an added
package, a changed guard, a data-file row), and only notes provenance changes
such as a newer `repro`.

## See also

- [Exporting a home profile](home-export.md) — the document `readIntent`
  reads, field by field.
- [Home-profile walkthrough](home-profile-walkthrough.md) — writing
  `home.nim` and its data files.

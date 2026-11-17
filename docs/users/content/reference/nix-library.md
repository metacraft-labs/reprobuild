---
title: Nix library and Home Manager module
description: Every function of reprobuild.lib and every option of reprobuild.homeManagerModules.intent, the Nix side of a home profile.
kind: reference
persona: machine-owner
domain: machines
order: 40
verifies:
  tests:
    - nix/tests/lib-reference.nix
    - nix/tests/lib.nix
    - nix/tests/home-manager.nix
    - nix/tests/host-facts.nix
    - nix/tests/home-equivalence.nix
    - nix/tests/intent-ifd.nix
unverified:
  - claim: "The descriptions under each reprobuild.lib heading."
    reason: "Written by hand from nix/lib (84b459adda, and eb60557254 for the realization sources); the lib-reference check compares each function's name and argument set, and the kinds of realization source and which take attribute, with the library, not the prose (default attribute lookups, refusals, homeManagerFacts' default)."
    owner: unassigned
---

# Nix library and Home Manager module

This page lists every function of `reprobuild.lib` and every option of
`reprobuild.homeManagerModules.intent`, the library and Home Manager module
that the reprobuild flake exports. The flake's other modules, for NixOS,
nix-darwin and Home Manager (`reprobuild`), are not covered here.

## Functions

Target systems are named as Nix names them: `x86_64-linux`, `aarch64-linux`,
`x86_64-darwin`, `aarch64-darwin`, `x86_64-windows`, `aarch64-windows`. A
function that refuses its input throws, with the reason; each `lookup…`
function returns the reason instead.

### `reprobuild.lib.readIntent`

```nix
readIntent { host, system, snapshot ? null, profileDir ? null,
             buildSystem ? builtins.currentSystem or null, nixos ? null,
             repro ? null, packagesCatalog ? null }
```

Reads a `repro home export` document and evaluates it for `host` on `system`.
Returns `{ mode, document, evaluation }`, where `evaluation` is the
document's `evaluation` for that target
([Home profile export](files/home-export.md)), with packages sorted by name.
With `snapshot`, reads that file. Otherwise runs `repro home export` on
`profileDir` in a derivation built for `buildSystem` (import from
derivation); pure evaluation exposes no `builtins.currentSystem`, so name
`buildSystem` there. `packagesCatalog` is a reprobuild-packages checkout, which
that export needs for a profile whose hosts declare `applies:`. Refuses a
document of another format or schema version, one whose intent still names
data files, a host the profile's `hosts:` block does not declare, and a
`system` the document cannot describe. `nixos` states whether the target is
NixOS, which its system name does not say (Home Manager configurations exist
for both): a profile whose guards reach the `nixos` predicate is refused while
it is `null`, never read as false.

### `reprobuild.lib.readData`

```nix
readData { path, system, host, hosts ? { }, activities ? null, name ? null,
          nixos ? null }
```

Reads a profile data file (TOML) and selects its rows as the planner does: a
row applies when its activity is enabled for the host (`default` plus
`hosts.${host}`, or `activities`) and its `when` holds for `system` (and for
`nixos`, the stated fact: a row whose `when` reaches `nixos` is refused while
it is `null`). Returns
`{ packages, names, rows, activities, system, host }`; `packages` holds one
`{ name, version, binaries, activity }` per selected package, sorted by name.
`name` labels the file in diagnostics and defaults to its base name. Refuses
a host that a non-empty `hosts` does not name, a file the planner refuses,
and any file with `[[resource]]` rows.

### `reprobuild.lib.evaluateExport`

```nix
evaluateExport document system host
```

The evaluation `readIntent` returns, for a document already read. A null
`host` means the document's `selection.host`. Refuses what `readIntent`
refuses.

### `reprobuild.lib.exportDerivation`

```nix
exportDerivation { pkgs, repro, profileDir, host, packagesCatalog ? null }
```

The derivation that runs `repro home export` on a profile, as `readIntent`'s
import-from-derivation mode uses it.

### `reprobuild.lib.hostSystemManagement`

```nix
hostSystemManagement { host, snapshot ? null, document ? null }
```

Who manages the host's operating system: `{ host, managed, managedBy, mode,
activities }`, where `managed` is `"here"` or `"elsewhere"` and `mode` is
`"full"`, `"addOn"` or `"managedElsewhere"`. Only `"full"` means the whole
system is this configuration's.

### `reprobuild.lib.profileBinPath`

```nix
profileBinPath { evaluation, homeDirectory, xdgStateHome ? "${homeDirectory}/.local/state" }
```

The directory of the launchers reprobuild places for the concerns it applies
on a host, or null when the evaluation names none. Refuses an evaluation for
Windows, whose directory is under `%LOCALAPPDATA%`.

### `reprobuild.lib.nixRealizationOf`

```nix
nixRealizationOf name
```

The nixpkgs attribute (such as `"ripgrep"` for `rg`) that reprobuild's Nix
catalog names for a canonical package. Refuses a package the catalog has no
record for, has more than one record for, binds to a develop interface, or
names other than as a `nixpkgs#` attribute.

### `reprobuild.lib.lookupNixRealization`

```nix
lookupNixRealization name
```

`{ found = true; attribute; attrPath; record; … }`, or
`{ found = false; reason; }`.

### `reprobuild.lib.lookupNixPackageName`

```nix
lookupNixPackageName { pkgs, drv, index ? null, realizationSources ? { } }
```

The reverse: the canonical package a derivation is, by its package name.
Returns `{ found = true; name; attribute; packageName; }`, or
`{ found = false; reason; packageName; }`. `index` is the reverse index of
`pkgs`, built when not given. A derivation that a
[realization source](#realization-sources) resolves to, by store path, is
named by that source's canonical name before the package-name lookup runs;
two sources that resolve to one derivation are refused as ambiguous. Without
`realizationSources` nothing changes.

### `reprobuild.lib.resolveRealizationSource`

```nix
resolveRealizationSource { name, source }
```

Where the Nix realization of the canonical package `name` comes from, given
one [realization source](#realization-sources): `{ found = true; drv; label; }`,
or `{ found = false; reason; }`. The reason says what is wrong with the source
or what the set lacks.

### `reprobuild.lib.realizationSourceProblems`

```nix
realizationSourceProblems { sources ? { }, document }
```

The refusals for a set of realization sources against an export `document`:
a list of messages, empty when there are none. A mapping for a name that is
not a canonical package, one for a canonical package that no host of the
profile selects, and a malformed source are each refused, naming the entry.
The Home Manager module throws these.

#### Realization sources

A profile names canonical packages and a Nix consumer realizes them from its
own nixpkgs. A package that comes from somewhere else (nixpkgs-unstable, the
`packages.<system>` of another flake, a flake output that is part of no set)
is mapped by its canonical name to a source, which is exactly one of:

- `{ nixpkgs = <package set>; attribute ? null; }`: a nixpkgs-like set. The
  attribute looked up in it is the one the catalog names, unless `attribute`
  says another.
- `{ packages = <package set>; attribute ? null; }`: a flake's
  `packages.<system>`. The attribute is the canonical name, unless `attribute`
  says another.
- `{ derivation = <derivation>; }`: a derivation given directly.

`attribute` is a dotted path. A mapping is realization, never selection: it
says where a package the profile selects comes from, and does not make any
host get it. A selected package with neither a mapping nor a catalog record
is still unmapped, and fails the evaluation.

### `reprobuild.lib.brewRealizationOf`

```nix
brewRealizationOf { name, system }
```

The Homebrew cask or formula, `{ kind, token, tap }`, that installs a
canonical package on `system`, or null when no record claims it there. A
cask is claimed on macOS only; a formula on macOS and Linux. Refuses a
package the Homebrew catalog states more than once or binds to a develop
interface.

### `reprobuild.lib.lookupBrewRealization`

```nix
lookupBrewRealization name
```

The Homebrew record of a canonical package, or `{ found = false; reason; }`.

### `reprobuild.lib.lookupBrewToken`

```nix
lookupBrewToken { kind ? "cask", token }
```

The canonical package a cask or formula installs, or
`{ found = false; reason; }`.

### `reprobuild.lib.brewRecords`

Every Homebrew record: a list of `{ name, kind, token, tap, catalog }`.

### `reprobuild.lib.homeManagerFacts`

```nix
homeManagerFacts { configuration, host, homebrew ? { }, outOfStoreRoots ? { }, system ? null,
                   realizationSources ? { } }
```

A derivation that writes the facts of a Home Manager configuration (its
packages, files, environment and services) for `repro home compare`.
`homebrew` lists what the host's Brewfile installs (`casks`, `formulae`,
`masApps`); `outOfStoreRoots` maps an out-of-store link prefix to the tree
whose files it points into. `realizationSources` (default: the module's
`reprobuild.intent.realizationSources` when the configuration uses it) names
the packages the configuration takes from another package set or flake: a
derivation a [realization source](#realization-sources) resolves to is
reported by its canonical name, never as an unknown derivation.
`.evaluated` holds the part known without building.

### `reprobuild.lib.reprobuildFacts`

```nix
reprobuildFacts { pkgs, repro, profileDir, host, system, nixos ? null }
```

A derivation that runs `repro home facts` on a profile. `nixos` states whether
the host is NixOS (`--nixos`), for a profile with `nixos` guards.

### `reprobuild.lib.homeEquivalenceCheck`

```nix
homeEquivalenceCheck { configuration, host, profileDir, allowlist ? null,
                       homebrew ? { }, outOfStoreRoots ? { },
                       name ? "home-equivalence-${host}", repro ? null,
                       nixos ? null }
```

A check that builds both sides' facts and runs `repro home compare`; it fails
when the comparison exits non-zero. Its output holds `nix.json`,
`reprobuild.json`, `report.txt` and `report.json`.

### `reprobuild.lib.targetSystems`

The target systems the library evaluates for.

### `reprobuild.lib.predicates.validate`

```nix
predicates.validate source
```

Parses a `when` guard and reports whether it is valid.

### `reprobuild.lib.predicates.holds`

```nix
predicates.holds facts source
```

Whether a guard holds for the given facts. A null guard holds.

### `reprobuild.lib.predicates.evaluate`

```nix
predicates.evaluate facts ast
```

Evaluates a parsed guard.

### `reprobuild.lib.predicates.factsFor`

```nix
predicates.factsFor system host
```

The facts guards are evaluated against for `host` on `system`.

### `reprobuild.lib.predicates.factsWith`

```nix
predicates.factsWith nixos system host
```

`factsFor` with the `nixos` fact stated: `true`, `false`, or `null` for not
stated (a guard that reaches the `nixos` predicate is then refused).

## Home Manager module options

Import `reprobuild.homeManagerModules.intent`. Its options are under
`reprobuild.intent`.

<!-- generated:begin nix-library-options -->
### `reprobuild.intent.buildSystem`

IFD mode: the system that runs `repro home export` -- the evaluator's, not the target's. Defaults to builtins.currentSystem where the evaluation exposes it.

- Type: null or string
- Default: `null`

### `reprobuild.intent.enable`

Whether to enable applying a Reprobuild profile's evaluated intent through Home Manager.

- Type: boolean
- Default: `false`

### `reprobuild.intent.environment.enable`

Whether to enable home.sessionVariables / home.sessionPath from env.userVariable / env.userPath resources.

- Type: boolean
- Default: on exactly when the host's `hosts:` entry declares `applies:` and does not list `environment`

### `reprobuild.intent.evaluation`

The evaluated intent (output): what `repro home export --target` reports for this host and system.

- Type: raw value
- Read-only: set by the module

### `reprobuild.intent.files.enable`

Whether to enable home.file from fs.userFile resources.

- Type: boolean
- Default: on exactly when the host's `hosts:` entry declares `applies:` and does not list `files`

### `reprobuild.intent.homebrew.casks`

Cask tokens the intent asks for (output).

- Type: list of string
- Read-only: set by the module

### `reprobuild.intent.homebrew.enable`

Whether to enable Homebrew token lists from pkg.homebrewCask / pkg.homebrewFormula resources and Homebrew-realized packages.

- Type: boolean
- Default: on exactly when the host's `hosts:` entry declares `applies:` and does not list `applications`

### `reprobuild.intent.homebrew.formulae`

Formula tokens the intent asks for (output).

- Type: list of string
- Read-only: set by the module

### `reprobuild.intent.homebrew.realizationOf`

Hook: `{ name, system }` -> null or `{ kind = "cask" | "formula"; token; tap; }`, the Homebrew realization of a canonical package. Defaults to `reprobuild.lib.brewRealizationOf`, which reads the Homebrew contribution catalog the reprobuild flake pins (reprobuild-brew-packages): a cask claims a package on darwin systems, a formula on darwin and Linux. A package it claims goes to the token lists instead of home.packages; set `_: null` to claim nothing.

- Type: function that evaluates to a(n) (null or (attribute set of string))
- Default: `reprobuild.lib.brewRealizationOf`

### `reprobuild.intent.host`

The host the profile is evaluated for (its `hosts:` entry selects the activities).

- Type: string

### `reprobuild.intent.nixos`

Whether this host is NixOS, for the profile's `nixos` guards. Whether a Linux target is NixOS is not part of its system name (Home Manager configurations for both exist), so it is stated here; null leaves it unstated, and a profile whose guards reach `nixos` then fails the evaluation instead of reading it as false.

- Type: null or boolean
- Default: `null`

### `reprobuild.intent.packages.enable`

Whether to enable home.packages from the intent's packages (nixpkgs attributes from the reprobuild-nix-packages catalog).

- Type: boolean
- Default: on exactly when the host's `hosts:` entry declares `applies:` and does not list `packages`

### `reprobuild.intent.packagesCatalog`

IFD mode: a `reprobuild-packages` checkout the sandboxed `repro home export` reads package definitions from (`$REPROBUILD_PACKAGES_ROOT`). Needed for the export's per-package classification (which packages are applications) on a host whose `hosts:` entry declares `applies:`; without it, every package that catalog defines is `unresolved`. Ignored in snapshot mode.

- Type: null or absolute path
- Default: `null`

### `reprobuild.intent.profileBin`

The directory holding the launchers of the concerns Reprobuild applies on this host (output): set when the host's `hosts:` entry gives Reprobuild `packages` or `applications` and leaves `environment` to Nix, null otherwise. The `environment` category puts it first on home.sessionPath.

- Type: null or string
- Read-only: set by the module

### `reprobuild.intent.profileDir`

The profile directory, for IFD mode (used when `snapshot` is null).

- Type: null or absolute path
- Default: `null`

### `reprobuild.intent.realizationSources`

Where the Nix realization of a canonical package comes from when it is not this configuration's nixpkgs, by canonical name. A source is `{ nixpkgs = <package set>; attribute ? null; }` (the attribute is the one the catalog names, unless given), `{ packages = <package set>; attribute ? null; }` (a flake's `packages.<system>`; the attribute is the canonical name, unless given), or `{ derivation = <derivation>; }`. A mapping is realization, never selection: it decides where a package the profile selects comes from, not whether a host gets it. A mapping for a name that is not a canonical package, and one for a canonical package the profile selects on no host, fail the evaluation. A selected package with neither a mapping nor a catalog record is still unmapped.

- Type: attribute set of raw value
- Default: `{ }`

### `reprobuild.intent.snapshot`

A committed `repro home export` document (snapshot mode). Kept current with `repro home export --check`.

- Type: null or absolute path
- Default: `null`

### `reprobuild.intent.system`

The target system the guards are evaluated for (a `repro home export --target` name).

- Type: string
- Default: `pkgs.stdenv.hostPlatform.system`

### `reprobuild.intent.uncategorized`

Entries no category covers (output): `{ category, id, reason }`.

- Type: list of attribute set of string
- Read-only: set by the module

### `reprobuild.intent.uncategorizedPolicy`

What an entry no category covers (config overrides, resource kinds Home Manager has no option for) does: fail the evaluation (an assertion, the default) or, as an explicit opt-in while Reprobuild applies those entries, warn.

- Type: one of "error", "warn"
- Default: `"error"`

### `reprobuild.intent.unmapped`

Entries of enabled categories that could not be mapped (output): `{ category, id, reason }`.

- Type: list of attribute set of string
- Read-only: set by the module

### `reprobuild.intent.unmappedPolicy`

What an entry of an enabled category that cannot be mapped does: fail the evaluation (an assertion, the default) or, as an explicit opt-in, warn.

- Type: one of "error", "warn"
- Default: `"error"`
<!-- generated:end -->

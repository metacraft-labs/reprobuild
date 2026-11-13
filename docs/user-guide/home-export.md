# Exporting a home profile — `repro home export`

`repro home export` prints what your `home.nim` evaluates to for one host, as
a versioned JSON document. Other tools read that document instead of
re-implementing Reprobuild's rules: a Nix module can take your package list
from it, a script can ask which activities a machine runs, and a CI job can
check that a committed copy is still current.

```sh
repro home export [--profile-dir DIR] [--host NAME] [--format json]
                  [--target SYSTEM | --check FILE]
```

The command compiles the profile the same way `repro home plan` and
`repro home apply` do, evaluates it for every target platform (see
[Describing other platforms](#describing-other-platforms)), and stops there:
it plans nothing, applies nothing and records no generation. An unchanged
profile is answered from the action cache for both steps.

## Choosing the host

The document describes one host: the one `repro home plan` would use.

- `$REPRO_HOST`, when set;
- otherwise `--host NAME`;
- otherwise the machine's hostname, lower-cased.

Passing `--host` while `$REPRO_HOST` names a different host is an error,
because the environment would otherwise win silently and you would get a
valid-looking document for the wrong machine. Every `repro home` command that
acts as a host (`apply`, `apply --plan`, `plan`, `list`, `why`, `export`,
`facts`) resolves it the same way. (`enable` / `disable --host NAME` name the
host entry to edit -- and, with `--now`, the host to apply remotely -- so
their `--host` may differ from `$REPRO_HOST`.)

When the profile declares a `hosts:` registry, the host must be in it: a host
the registry does not name is refused (exit 1) instead of being given the
`default` activity alone. Declare a host that should run only `default` as
`"<host>": [default]`.

```sh
repro home export --host laptop > home-export.laptop.json
```

## Committing a snapshot and keeping it current

A snapshot is a document you commit next to the profile, for consumers that
cannot run `repro` (a Nix evaluation, for example). `--check` tells you
whether it is stale:

```sh
repro home export --host laptop --check home-export.laptop.json
```

- exit `0`: the snapshot says what the profile says;
- exit `1`: it does not. Each difference is printed on stderr, followed by
  the command that regenerates the file:

```text
repro home export --check: home-export.laptop.json is stale for host laptop (1 difference(s)):
  intent.activities[name="develop_software"].body[3]: only in a fresh export: {"kind":"packageRef","name":"yq","version":""}
  hint: regenerate it with `repro home export --format json --host laptop > home-export.laptop.json`
```

- exit `2`: a usage problem, including a snapshot file that is missing or is
  not JSON.

`--check` compares what a consumer reads — `format`, `schemaVersion`,
`selection`, `intent` and `platforms` — and **never** `provenance`. Upgrading `repro`, or
editing a comment in `home.nim`, changes the provenance but not what the
snapshot tells anyone, so it does not fail the check; the changed fields are
printed as notes. Any edit that changes what the profile means (an added
package, a different host selection, a module that now produces other
resources) changes `intent` or `selection` and does fail it.

A good CI step is simply:

```sh
repro home export --host laptop --check home-export.laptop.json
```

A snapshot written in an older `schemaVersion` is reported as not comparable;
regenerate it.

## Describing other platforms

One export can describe every platform you use, whichever machine produced
it — provided the profile selects platforms with **runtime predicates**:

```nim
resources:
  when linux():
    fsUserFile(hostFile = "~/.config/foo/foo.conf", content = linuxConf)
  elif macos():
    fsUserFile(hostFile = "~/Library/Preferences/foo.conf", content = macConf)

config:
  git:
    when macos():
      credentialHelper = "osxkeychain"
    else:
      credentialHelper = "libsecret"
```

A runtime predicate travels in the document as data (the `guard` of a
resource or config override, a `whenGuard` in an activity), and is evaluated
for the platform you ask about. A compile-time `when defined(macosx):` is
different: it is decided by the machine that compiles the profile, and the
other branch is simply not in the document. `repro home export` detects
that — it evaluates the profile under every target platform's definitions and
compares — and records, per platform, whether the document describes it
(`platforms`, below).

To evaluate the guards for a platform and host, pass `--target`:

```sh
repro home export --host laptop --target aarch64-darwin
```

The document then also carries an `evaluation` object: the activities,
packages, resources and config overrides the planner would use for that host
on that platform. The targets are `x86_64-linux`, `aarch64-linux`,
`x86_64-darwin`, `aarch64-darwin`, `x86_64-windows` and `aarch64-windows`.

If the document cannot describe the target — `platforms` says `differs` or
`unevaluated` for it — the command refuses with exit `3` and says why:

```text
repro home export: cannot evaluate this export for aarch64-darwin: this export was compiled on x86_64-linux, and evaluated for aarch64-darwin the profile declares a different intent: a compile-time `when defined(...)` decided part of it for x86_64-linux. Select platforms with runtime predicates (`when macos():`) so one export describes every platform, or export on aarch64-darwin.
```

A document always describes the platform that compiled it.

## Resources that belong to an activity

A `resources:` block inside an activity declares resources that belong to
that activity. They are planned only on a host that selects the activity
(`default`, plus the host's `hosts:` entry):

```nim
activity desktop_core:
  hyprland
  resources:
    hyprlandConfig()          # a helper module's resource template
    when linux():
      fsUserFile(hostFile = "~/.config/waybar/config", content = waybarConf)

hosts:
  "workstation": [desktop_core]
  "server": [default]          # no desktop configuration here
```

The block accepts everything a profile-level `resources:` block accepts
(constructor calls, helper templates, runtime `when` chains, `for` loops); a
guard inside it still applies, on top of the activity. Two placements are
refused when the profile compiles: a `resources:` block under a `when` of the
activity body (put the `when` inside the block), and an action edge
(`inlineExecCall`, `expandArchive.build`), which carries no activity.

In the export, each such resource carries `"activity": "<name>"`; a
profile-level one carries `"activity": null`.

## Stow packages that belong to an activity

Every immediate subdirectory of the profile's `stow/` tree is a package whose
files are linked into the home directory on every host. A `stow:` block inside
an activity claims packages for that activity: a claimed package is linked
only on a host where one of its claims holds -- the host selects the activity
and the claim's guard, if any, holds there.

```nim
activity desktop_core:
  stow:
    "kitty"                    # stow/kitty/: a GUI terminal's settings
    "rdp"
    when macos():
      "hammerspoon"

activity default:
  stow:
    when windows():
      "rdp"                    # every Windows host keeps stow/rdp/ too

hosts:
  "workstation": [desktop_core]
  "server": [default]          # gets neither kitty's nor rdp's files
```

A package no activity claims is linked on every host, as before. Claims are a
union: several activities (or guards) may claim one package. Refused: a claim
of a package the `stow/` tree does not have (when the host is planned, naming
the packages that exist), a `stow:` block under a `when` of the activity body,
an entry that is not a string literal or that names a path rather than one
package directory, and one package named twice by one activity (when the
profile compiles). `repro home facts`, `repro home apply` and its `--plan`
follow the selection. The export's `intent` carries the claims as
`stowScopes` (`[{"package", "activity", "guard"}]`, present only when some
activity has a `stow:` block); the Nix helper library does not read them,
since the Nix side keeps its own links (schema version unchanged).

## The document (schema version 4)

```jsonc
{
  "format": "repro.home.export",
  "schemaVersion": 5,
  "selection": {
    "host": "laptop",
    "hostDeclared": true,
    "activities": ["default", "develop_software"],
    "unknownActivities": []
  },
  "intent": {
    "name": "me",
    "activities": [ { "name": "default", "body": [ … ] }, … ],
    "configOverrides": [ { "pkg": "git", "key": "…", "value": { … }, "guard": "macos" }, … ],
    "hosts": { "laptop": ["develop_software"] },
    "resources": [ { "kind": "fs.userFile", "address": "…", "fields": { … },
                     "dependsOn": [], "guard": null, "activity": null }, … ],
    "buildActions": [ … ],
    "adapterPreference": { … },
    "hostApplies": { "laptop": ["applications"] },  // only when a host declares
    "hostSystems": {                               // only when a host has `system:`
      "build-server": { "mode": "managedElsewhere", "managedBy": "example-org/infra", "activities": [] },
      "rpi":          { "mode": "addOn", "managedBy": null, "activities": ["monitoring"] } }
  },
  "concerns": {                                     // only when a host declares
    "names": ["packages", "applications", "files", "environment", "services", "settings"],
    "resourceKinds": { "fs.userFile": "files", "env.userPath": "environment", … },
    "configOverrides": "files",
    "packages": {                                   // per target system
      "aarch64-darwin": { "applications": ["ghostty"], "unresolved": [] },
      "x86_64-linux":   { "applications": [], "unresolved": ["ghostty"] }, …
    },
    "profileBin": {                                 // per target system
      "aarch64-darwin": { "base": "home",
                          "path": "Library/Application Support/repro/home/current/bin" },
      "x86_64-linux":   { "base": "xdgStateHome", "path": "repro/home/current/bin" },
      "x86_64-windows": { "base": "localAppData", "path": "repro/home/bin" }, …
    }
  },
  "platforms": {
    "x86_64-linux": "same", "aarch64-linux": "same",
    "x86_64-darwin": "same", "aarch64-darwin": "same",
    "x86_64-windows": "same", "aarch64-windows": "same"
  },
  "provenance": {
    "repro": { "version": "0.2.10", "sourceRevision": "1909a8f3…" },
    "hostSource": "flag",
    "profile": {
      "root": "home.nim",
      "digest": "…",
      "inputs": [ { "path": "home.nim", "blake3": "…" }, … ]
    },
    "dataFiles": [ { "path": "data/apps.toml", "blake3": "…", "rows": 12 } ],
    "compile": { "target": "x86_64-linux", "os": "linux", "cpu": "amd64",
                 "defines": [], "probe": {} }
  },
  "evaluation": { … }                     // only with --target
}
```

| Field | Meaning |
|---|---|
| `format` | Always `repro.home.export`. Refuse any other value. |
| `schemaVersion` | `5`. Adding a field does not change it; changing the meaning or shape of an existing one does. Refuse versions you do not know. Version 2 added guards on resources and config overrides — a version-1 reader would apply a guarded resource everywhere — and `platforms`. Version 3 added `activity` on resources — a version-2 reader would apply a resource on hosts that do not select its activity. Version 4 added `intent.systemManagedElsewhere` and `evaluation.system` — in a version-3 document "no host is managed elsewhere" cannot be told from "written before the attribute existed", and a reader that decides whether to take a host's system over must not guess. Version 5 replaced `intent.systemManagedElsewhere` with `intent.hostSystems` and added `evaluation.system.mode` and `.activities`, for add-on hosts: an add-on host is managed "here", so a version-4 reader would take it for a host whose whole system it may switch. |
| `selection.host` | The host the document was produced for. |
| `selection.hostDeclared` | Whether the profile's `hosts:` block has an entry for that host. A profile with a `hosts:` registry declares every host it may be applied to: exporting (or planning, applying, `repro home facts`) for a host it does not name is refused, so in a document from such a profile this is always `true`. A profile without a registry is host-agnostic: every host gets `default`, and this is `false`. |
| `selection.activities` | The activities `repro home plan` enables on that host, in the order the profile declares them. Computed by the planner's own rule. Platform-independent. |
| `selection.unknownActivities` | Activities the host's `hosts:` entry names that the profile never declares (they contribute nothing). |
| `intent` | The whole evaluated profile, exactly as the planner consumes it — every activity, not only the selected ones, and every platform's guarded elements. A `when`/`if` guard inside an activity stays a `whenGuard` element carrying its predicate text. Resources are profile-wide unless they belong to an activity (`intent.resources[].activity`), and home-scope only: a home profile that declares a system-scope resource (`fsSystemFile`, `systemdSystemUnit`, … — those belong in a system profile applied by `repro infra apply`) is refused, naming the resource. Rows of the profile's [data files](#data-files) are already expanded into the activities they name, so you never read the data files yourself; `intent` has no `dataFiles` key. |
| `intent.resources[].guard`, `intent.configOverrides[].guard` | The runtime predicate under which the element applies, as text in the [predicate grammar](#predicates), or `null` for "every host". Nested `when` blocks are conjoined (`arm64 and macos`); an `elif` / `else` branch carries the negation of the earlier conditions. Two resources may share an `address` when their guards never hold together. |
| `intent.resources[].activity` | The activity the resource belongs to — it was declared in a `resources:` block inside `activity <name>:`, or by a data-file row with `activity = "<name>"` — or `null` for a profile-wide resource. A resource with an activity applies only on a host whose selection enables that activity (`default` plus the host's `hosts:` entry), and only where its `guard` also holds. It always names an activity in `intent.activities`; refuse a document where it does not. |
| `intent.hostApplies` | Present only when some `hosts:` entry declares `applies:` (block form, below): host → the concerns Reprobuild applies on that host. A host absent from it lets Reprobuild apply every concern. |
| `intent.hostSystems` | Present only when some `hosts:` entry has a `system:` key ([below](#how-a-hosts-system-is-managed)): host → `{ "mode": "managedElsewhere", "managedBy": "<pointer>" \| null, "activities": [] }`, or `{ "mode": "addOn" \| "full", "managedBy": null, "activities": [<system activity>, …] }` (the activities the block form selects beyond `default`; empty for `system: addOn` / `system: full`). A host absent from it has its whole system managed by this configuration. |
| `concerns` | Present only with `intent.hostApplies`: the concern names, every home-scope resource kind's concern, the concern of a `config:` override, and `packages` — for every target system, the package references (keyed `name`, or `name@version` when pinned) whose selected realization there places an application (`applications`), and those that resolve to nothing there (`unresolved`); every other reference is a plain package. It is Reprobuild's classification, made from profile policy and the current catalog, without the host-local `home.lock` or the host's `PATH` / Scoop inventory, so a consumer never restates it. `--check` compares it, so a policy or catalog change that reclassifies a package shows up. `profileBin` says, for every target system, where the launchers of the active generation are reached on a host that uses the default state directory: a `base` (`home` = `$HOME`, `xdgStateHome` = `$XDG_STATE_HOME` or `$HOME/.local/state`, `localAppData` = `%LOCALAPPDATA%`) and a `/`-separated `path` below it. |
| `platforms` | For each target platform, whether this document describes it: `same` (the profile evaluated for that platform declares exactly this intent), `differs` (a compile-time `when defined(...)` changed it — refuse the document for that platform), or `unevaluated` (the profile could not be evaluated for that platform — treat as `differs`; the reason is in `provenance.compile.probe`). The compiling platform is always described, whatever its entry says. |
| `provenance.repro.version` | The `repro` release that produced the document. |
| `provenance.repro.sourceRevision` | The commit that `repro` was built from (`…-dirty` if the tree had uncommitted changes), or `null` if the build did not record it. The version alone does not identify a build. |
| `provenance.hostSource` | How the host was chosen: `env` (`$REPRO_HOST`), `flag` (`--host`) or `hostname`. |
| `provenance.profile.root` | The profile's root file. |
| `provenance.profile.inputs` | Every file under the profile directory the compile was observed to read (modules, `config.nims`, files read with `staticRead` or at run time), with the BLAKE3-256 of its current contents. Paths are relative to the profile directory. |
| `provenance.profile.digest` | BLAKE3-256 over `<path>\t<blake3>\n` for each input in order; `null` if no reads were observed. |
| `provenance.dataFiles` | The [data files](#data-files) the profile's `data:` section declares, in declaration order: `path` (relative to the profile directory), `blake3` (BLAKE3-256 of the bytes that were expanded into `intent`) and `rows` (how many rows — package and resource — they hold). They are read when the profile is planned, not compiled, so they never appear in `profile.inputs`. Empty for a profile without a `data:` section. |
| `provenance.compile.target` | The platform that compiled the profile, as a target name (`x86_64-linux`); `<cpu>-<os>` in Nim's names for a platform that is not a target. |
| `provenance.compile.os`, `.cpu` | The same platform in Nim's names (`linux`, `macosx`, `windows`; `amd64`, `arm64`). A `when defined(...)` in the profile was decided for this platform. |
| `provenance.compile.defines` | Extra `-d:` symbols the profile compile passes (none today). |
| `provenance.compile.probe` | For each `unevaluated` platform, why: the end of the compiler's diagnostic. |
| `evaluation` | Present only with `--target`: `target`, `host`, `activities`, `packages` (`name`, `version`, `binaries`, `activity`), and the `resources` and `configOverrides` from `intent` whose guards hold (a resource with an `activity` only when the host selects it) — what the home planner would use for that host on that platform — plus `applies`, the concerns the host's entry declares, when it declares any; then every package also carries `concern` (`applications` or `packages`, from `concerns.packages`) and `resolved`, and -- when the host gives Reprobuild `packages` or `applications` but not `environment` -- `profileBin`, that system's row of `concerns.profileBin`, which the side that writes the shell environment puts on `PATH`. Always `system`: `{ "managed": "elsewhere", "managedBy": "<pointer>" \| null, "mode": "managedElsewhere", "activities": [] }` for a host whose system is managed elsewhere, `{ "managed": "here", "managedBy": null, "mode": "addOn", "activities": ["default", …] }` for an add-on host, and `{ "managed": "here", "managedBy": null, "mode": "full", "activities": ["default", …] }` otherwise (more than `default` only through `system: {mode: full, activities: [...]}`). Only `mode` `full` means the whole system is this configuration's: branch on `mode`, not on `managed`. |

### Applying some concerns of a host

A host can hand some concerns to another tool (Home Manager, during a
migration) and let Reprobuild apply the rest. Its `hosts:` entry says which
ones Reprobuild applies:

```nim
hosts:
  "home-pc": [default, develop_software]   # Reprobuild applies everything
  "m1":
    activities: [default, desktop_apps]
    applies: [applications]                # everything else is Nix's
```

Concerns: `packages` (packages whose realization is not an application, and
packages with no realization), `applications` (packages realized as app
bundles; Homebrew token resources), `files` (stow links, generated files,
`fsUserFile`, `config:` overrides), `environment` (variables, PATH entries,
shell integration, managed blocks), `services` (systemd, launchd, Windows
startup), `settings` (user defaults, gsettings, dconf, KDE, registry, VS Code
extensions). On such a host `repro home apply` executes only the listed
concerns; everything else is planned and printed under `not applied on
<host>`, never executed, and never fails the apply. A concern removed from the
list is *released*: what Reprobuild placed for it stays where it is and is no
longer managed. The Home Manager module derives its category switches from
the declaration and routes each package by the concern Reprobuild classified
it into ([nix-helper-library.md](./nix-helper-library.md#the-home-manager-module)).

To classify the packages, `repro home export` resolves every package
reference for every target system from the profile's policy and current
catalog. It ignores `home.lock`: that file records this host's apply
selections and must stay out of version control, even when multiple hosts
share a profile and target. Adding, removing or changing the local lock
cannot change a committed export or its `--check` result.

If a catalog definition or an imported contribution catalog cannot be
projected, export exits `1`, names the affected package and failed extraction,
and prints no document. This also applies to `--check` and `--target`:
`--check` reports the projection error instead of snapshot drift. A successful
projection that offers no realization for a target can still classify a
reference as `unresolved` for that target.

A reference no definition it can see
names at all might be an application defined in the `reprobuild-packages`
catalog, so when there is one and no catalog checkout is reachable (beside
the profile, beside the `reprobuild` checkout, or `$REPROBUILD_PACKAGES_ROOT`),
the export fails instead of guessing. On a host that gives Reprobuild one of
`packages` / `applications` and Nix the other, `repro home apply` refuses a
package whose selection on this host — which honors the local lock and can
use the host's `PATH` — would put it in a different concern than the export
says. Inspect the current catalog and use `--relock` to replace a differing
pin, reorder `adapterPreference`, or give both concerns to the same tool.
Plan and apply keep honoring lock pins; a withdrawn pin still requires
`--relock`.

The commands of the packages Reprobuild applies -- including the ones an
application bundle carries, such as `code` or `utmctl` -- are launchers in
the profile bin directory (`~/Library/Application Support/repro/home/current/bin`
on macOS, `~/.local/state/repro/home/current/bin` on Linux). When the host
leaves `environment` to the other tool, Reprobuild cannot put that
directory on `PATH` itself, so the export tells the other side where it is
(`evaluation.profileBin`): the Home Manager module's `environment` category
puts it first on `home.sessionPath`
([nix-helper-library.md](./nix-helper-library.md#the-home-manager-module)).
Shell start-up code that prepends another directory later (`eval "$(brew
shellenv)"`) must prepend this one again after it, or a stale copy of a
command (a Homebrew cask's link) wins.

### How a host's system is managed

The registry also records how each host's *system* is managed. A host
entry without a `system:` key is managed by this configuration as a whole
(ReproOS, or a NixOS / nix-darwin configuration a system switch applies).
Otherwise `system:` takes one of two values:

```nim
hosts:
  "home-pc": [default, develop_software]   # whole system managed here
  "build-server":
    activities: [default, develop_software]
    system: managedElsewhere("example-org/infra")
  "arch-laptop":
    activities: [default]
    system: managedElsewhere               # no pointer
  "rpi":
    activities: [default]
    system: addOn                          # add-on mode, `default` only
  "validator-01":
    activities: [default]
    system:                                # add-on mode, more activities
      mode: addOn
      activities: [ethereum_validator, host_baseline]
  "reproos-box":
    activities: [default]
    system: {mode: full, activities: [host_baseline]}  # whole system here,
                                           # plus a system activity
```

- **`managedElsewhere`**: the host's home is this profile's, but something
  else manages its system -- another repository's deployment, or a
  distribution's own tooling. The argument is an optional pointer to it, one
  line of free text (normally the managing repository). `repro infra plan`,
  `repro infra apply`, `repro system sync` and `repro system rollback` refuse
  such a host -- exit 1, naming the host, the pointer and the registry, with
  nothing planned or changed.
- **`addOn`** (add-on mode): the host runs a distribution (Debian, Ubuntu,
  Raspberry Pi OS, ...) that owns its base system, and Reprobuild manages a
  declared set of systemd units, `/etc` files, system accounts, tmpfiles and
  sysctl fragments on top of it. The short form plans the system profile's
  `default` activity. The block form -- indented as above, or inline as
  `system: {mode: addOn, activities: [ethereum_validator]}` -- also plans the
  system-profile activities it lists. `default` is always planned and is not
  listed, and a block form without activities is refused (write the short
  form).
- **`full`**: what an absent key means -- this configuration manages the
  whole system. It is spelled only to select system activities on such a
  host: `system: {mode: full, activities: [...]}` (same rules as the
  `addOn` block form); the bare `system: full` is accepted and means exactly
  an absent key. On a distribution host `full` is refused like an absent
  key (below).

The system commands read the registry of the `home.nim` beside the system
profile, or of the profile `--home-profile-dir` names, and look the host up
by `--host` (else `$REPRO_HOST`, else the hostname). Before planning they
compare the registry with the host's base, read from `/etc/os-release`, and
refuse a mismatch with `EAddOnModeMismatch`:

- `system: addOn` on a host that is not a distribution host (ReproOS, NixOS,
  macOS, Windows, or a Linux without a readable `os-release`);
- a host the registry declares as fully managed -- no `system:` key, or
  `system: full` / its block form -- that runs a distribution: writing
  system objects on a distribution host must be declared (`addOn` or
  `managedElsewhere`), never inferred.

A host the registry does not declare, and a system profile with no registry
beside it, are planned as before; the report's `registry:` line says so.

**System activities and host selection.** A system profile selects per host
exactly as a home profile does. Resources inside `activity <name>:` are
planned only on hosts that select the activity (through the `system:` block
form above), and resources under a runtime predicate (`when linux():`,
`when host() == "rpi":`) only on hosts where it holds, evaluated for the
host being planned. A system profile's own `hosts:` block is refused: the
home profile's registry is the only one. The plan's `system:` line names the
activities planned and how they are realised.

**The add-on realisation.** On an add-on host every field of every planned
resource is classified by the `add-on-debian` realisation profile: *shared*
fields (units, timers, `/etc` files, accounts, tmpfiles, sysctl) are applied
as on a full ReproOS host; *add-on-specific* ones are applied in the
add-on's own place (a `linux.firewallRule` must name a chain of the add-on's
own nftables table, `inet repro`); *ignored* ones are listed in the plan
with the reason; and *invalid* ones -- the kernel, the bootloader, disks,
base networking (`os.hostname`), base configuration no add-on class covers
(`os.timezone`, `linux.udevRule`, sudoers, polkit, `/etc/environment`), a
NixOS module, another platform's resources -- refuse the plan with
`EAddOnOutOfScope`, naming the field and the activity that set it. Only
Debian-family bases have an add-on realisation; `system: addOn` on another
distribution is refused with `EAddOnUnsupportedBase`.

The export carries the attribute (`intent.hostSystems`, `evaluation.system`
with its `mode` and system `activities`), and the Nix helper library reads it
with `reprobuild.lib.hostSystemManagement`
([nix-helper-library.md](./nix-helper-library.md)), so a script that switches
a machine's system configuration can ask before taking a host over -- and
must switch only a host whose `mode` is `full`.

### Data files

A profile can keep plain lists — the applications a host runs, say — in TOML
files beside `home.nim`, read when the profile is planned:

```nim
profile "me":
  data:
    "data/apps.toml"
```

```toml
# data/apps.toml
[[package]]
name = "ghostty"          # canonical package name
activity = "desktop_apps" # the activity it joins
when = "macos"            # optional, built-in predicates only
```

A data file can also declare resources; a `[[resource]]` row takes the
parameters of the constructor its `kind` names, exactly as the call would in
`resources:`:

```toml
[[resource]]
kind = "fs.userFile"
when = "linux"
hostFile = "~/.config/foo/foo.conf"
content = "x = 1\n"
```

Add `activity = "<name>"` to a resource row to make it belong to that
activity, exactly like a call in that activity's `resources:` block
([Resources that belong to an activity](#resources-that-belong-to-an-activity)).

Editing a data file does not recompile the profile. In the export each
package row appears as an ordinary activity element (a `whenGuard` around a
`packageRef` when it has `when`), each resource row as an entry of
`intent.resources` with its `when` as `guard` (and its `activity`, if any), and `provenance.dataFiles`
records each file's digest.
`--check` therefore fails when a row changes and only notes a comment edit
(`provenance.dataFiles` differs, `intent` does not).

### Predicates

Guards use the built-in predicate grammar: `windows`, `macos`, `linux`,
`bsd`, `wsl`, `x86_64`, `arm64`, `arm32`, `host == "name"`,
`host != "name"`, `host in ["a", "b"]`, combined with `and`, `or`, `not` and
parentheses. When `repro home export --target` evaluates them, `wsl` is false
for every target and `host` is the selected host.

All digests are lower-case hex. The document adds no absolute paths of its
own (provenance paths are relative to the profile directory); anything
machine-specific in `intent` is there because the profile says it.

The `intent` shape is the same JSON the profile binary itself prints. Within
it, an activity body element is either
`{"kind":"packageRef","name":…,"version":…[,"binaries":[…]]}` or
`{"kind":"whenGuard","predicate":"…","body":[…]}`; a resource is
`{"kind":…,"address":…,"fields":{…},"dependsOn":[…],"guard":…,"activity":…}` with each
field a `{"kind":"string"|"int"|"bool"|"list"|"expr","value":…}` pair; a
config override is `{"pkg":…,"key":…,"value":{…},"guard":…}`.

## See also

- [Home-profile walkthrough](home-profile-walkthrough.md) — authoring
  `home.nim` and applying it.
- [Reading a home profile from Nix](nix-helper-library.md) — the flake's
  `reprobuild.lib.readIntent` reads this document (snapshot or
  import-from-derivation) and its Home Manager module applies it.
- Exit codes: `0` printed or current, `1` stale snapshot or the export
  failed, `2` usage, `3` the export cannot describe the `--target` platform.
- `repro home export --help` — the flags in brief.

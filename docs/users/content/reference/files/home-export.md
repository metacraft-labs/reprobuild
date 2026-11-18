---
title: Home profile export
description: The fields of the JSON document repro home export writes, format repro.home.export, schema version 5.
kind: reference
persona: machine-owner
domain: machines
order: 10
verifies:
  commands: [home export, home export --check, home export --target]
  tests:
    - tests/e2e/m83/t_e2e_home_export_matches_compiled_intent.nim
    - tests/e2e/m83/t_e2e_home_export_check_detects_stale_snapshot.nim
    - tests/e2e/m83/t_e2e_home_export_expands_data_files.nim
    - nix/tests/lib.nix
unverified:
  - claim: "Every field and its meaning."
    reason: "Written from the schema (format repro.home.export, schemaVersion 5 in home_export.nim) and checked by hand against documents written by repro 0.2.24 built from reprobuild 84b459adda; no generator reads the schema and nothing compares this page with it."
    owner: unassigned
---

# Home profile export

`repro home export` writes this document, format `repro.home.export`, schema
version 5. [Export a home profile for Nix](../../guides/machines/export-a-home-profile.md)
shows how to produce and check it, and `reprobuild.lib.readIntent` reads it
([Nix library and Home Manager module](../nix-library.md)).

## Shape

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
    "repro": { "version": "…", "sourceRevision": "…" },
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
| `intent` | The whole evaluated profile, exactly as the planner consumes it — every activity, not only the selected ones, and every platform's guarded elements. A `when`/`if` guard inside an activity stays a `whenGuard` element carrying its predicate text. Resources are profile-wide unless they belong to an activity (`intent.resources[].activity`), and home-scope only: a home profile that declares a system-scope resource (`fsSystemFile`, `systemdSystemUnit`, … — those belong in a system profile applied by `repro infra apply`) is refused, naming the resource. Rows of the profile's data files are already expanded into the activities they name, so you never read the data files yourself; `intent` has no `dataFiles` key. |
| `intent.resources[].guard`, `intent.configOverrides[].guard` | The runtime predicate under which the element applies, as text in the [predicate grammar](#predicates), or `null` for "every host". Nested `when` blocks are conjoined (`arm64 and macos`); an `elif` / `else` branch carries the negation of the earlier conditions. Two resources may share an `address` when their guards never hold together. |
| `intent.resources[].activity` | The activity the resource belongs to — it was declared in a `resources:` block inside `activity <name>:`, or by a data-file row with `activity = "<name>"` — or `null` for a profile-wide resource. A resource with an activity applies only on a host whose selection enables that activity (`default` plus the host's `hosts:` entry), and only where its `guard` also holds. It always names an activity in `intent.activities`; refuse a document where it does not. |
| `intent.hostApplies` | Present only when some `hosts:` entry declares `applies:` (the block form of a [host entry](../dsl.md#hosts)): host → the concerns Reprobuild applies on that host. A host absent from it lets Reprobuild apply every concern. |
| `intent.hostSystems` | Present only when some `hosts:` entry has a `system:` key ([host entries](../dsl.md#hosts)): host → `{ "mode": "managedElsewhere", "managedBy": "<pointer>" \| null, "activities": [] }`, or `{ "mode": "addOn" \| "full", "managedBy": null, "activities": [<system activity>, …] }` (the activities the block form selects beyond `default`; empty for `system: addOn` / `system: full`). A host absent from it has its whole system managed by this configuration. |
| `concerns` | Present only with `intent.hostApplies`: the concern names, every home-scope resource kind's concern, the concern of a `config:` override, and `packages` — for every target system, the package references (keyed `name`, or `name@version` when pinned) whose selected realization there places an application (`applications`), and those that resolve to nothing there (`unresolved`); every other reference is a plain package. It is Reprobuild's classification, made from profile policy and the current catalog, without the host-local `home.lock` or the host's `PATH` / Scoop inventory, so a consumer never restates it. `--check` compares it, so a policy or catalog change that reclassifies a package shows up. `profileBin` says, for every target system, where the launchers of the active generation are reached on a host that uses the default state directory: a `base` (`home` = `$HOME`, `xdgStateHome` = `$XDG_STATE_HOME` or `$HOME/.local/state`, `localAppData` = `%LOCALAPPDATA%`) and a `/`-separated `path` below it. |
| `platforms` | For each target platform, whether this document describes it: `same` (the profile evaluated for that platform declares exactly this intent), `differs` (a compile-time `when defined(...)` changed it — refuse the document for that platform), or `unevaluated` (the profile could not be evaluated for that platform — treat as `differs`; the reason is in `provenance.compile.probe`). The compiling platform is always described, whatever its entry says. |
| `provenance.repro.version` | The `repro` release that produced the document. |
| `provenance.repro.sourceRevision` | The commit that `repro` was built from (`…-dirty` if the tree had uncommitted changes), or `null` if the build did not record it. The version alone does not identify a build. |
| `provenance.hostSource` | How the host was chosen: `env` (`$REPRO_HOST`), `flag` (`--host`) or `hostname`. |
| `provenance.profile.root` | The profile's root file. |
| `provenance.profile.inputs` | Every file under the profile directory the compile was observed to read (modules, `config.nims`, files read with `staticRead` or at run time), with the BLAKE3-256 of its current contents. Paths are relative to the profile directory. |
| `provenance.profile.digest` | BLAKE3-256 over `<path>\t<blake3>\n` for each input in order; `null` if no reads were observed. |
| `provenance.dataFiles` | The data files the profile's `data:` section declares, in declaration order: `path` (relative to the profile directory), `blake3` (BLAKE3-256 of the bytes that were expanded into `intent`) and `rows` (how many rows — package and resource — they hold). They are read when the profile is planned, not compiled, so they never appear in `profile.inputs`. Empty for a profile without a `data:` section. |
| `provenance.compile.target` | The platform that compiled the profile, as a target name (`x86_64-linux`); `<cpu>-<os>` in Nim's names for a platform that is not a target. |
| `provenance.compile.os`, `.cpu` | The same platform in Nim's names (`linux`, `macosx`, `windows`; `amd64`, `arm64`). A `when defined(...)` in the profile was decided for this platform. |
| `provenance.compile.defines` | Extra `-d:` symbols the profile compile passes. |
| `provenance.compile.probe` | For each `unevaluated` platform, why: the end of the compiler's diagnostic. |
| `evaluation` | Present only with `--target`: `target`, `host`, `activities`, `packages` (`name`, `version`, `binaries`, `activity`), and the `resources` and `configOverrides` from `intent` whose guards hold (a resource with an `activity` only when the host selects it) — what the home planner would use for that host on that platform — plus `applies`, the concerns the host's entry declares, when it declares any; then every package also carries `concern` (`applications` or `packages`, from `concerns.packages`) and `resolved`, and — when the host gives Reprobuild `packages` or `applications` but not `environment` — `profileBin`, that system's row of `concerns.profileBin`, which the side that writes the shell environment puts on `PATH`. Always `system`: `{ "managed": "elsewhere", "managedBy": "<pointer>" \| null, "mode": "managedElsewhere", "activities": [] }` for a host whose system is managed elsewhere, `{ "managed": "here", "managedBy": null, "mode": "addOn", "activities": ["default", …] }` for an add-on host, and `{ "managed": "here", "managedBy": null, "mode": "full", "activities": ["default", …] }` otherwise (more than `default` only through `system: {mode: full, activities: [...]}`). Only `mode` `full` means the whole system is this configuration's: branch on `mode`, not on `managed`. |

## Predicates

Guards use the built-in predicate grammar: `windows`, `macos`, `linux`,
`bsd`, `wsl`, `nixos`, `x86_64`, `arm64`, `arm32`, `host == "name"`,
`host != "name"`, `host in ["a", "b"]`, combined with `and`, `or`, `not` and
parentheses. When `repro home export --target` evaluates them, `wsl` is false
for every target and `host` is the selected host. `nixos` is a fact about the
host that the target's system name does not carry (Home Manager
configurations exist for both a NixOS and another Linux), so the export states
nothing for it: pass `--nixos` (or `--nixos=false`) with `--target`, and a
profile whose guards reach `nixos` is refused (exit `3`) without it. On the
machine itself the planner reads `ID=nixos` from `/etc/os-release`.

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

Exit status of `repro home export`: `0` printed or current, `1` the export
failed or the snapshot is stale, `2` usage, `3` the export cannot describe the
`--target` platform.

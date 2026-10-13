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
valid-looking document for the wrong machine.

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

## The document (schema version 2)

```jsonc
{
  "format": "repro.home.export",
  "schemaVersion": 2,
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
                     "dependsOn": [], "guard": null }, … ],
    "buildActions": [ … ],
    "adapterPreference": { … }
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
    "dataFiles": [],
    "compile": { "target": "x86_64-linux", "os": "linux", "cpu": "amd64",
                 "defines": [], "probe": {} }
  },
  "evaluation": { … }                     // only with --target
}
```

| Field | Meaning |
|---|---|
| `format` | Always `repro.home.export`. Refuse any other value. |
| `schemaVersion` | `2`. Adding a field does not change it; changing the meaning or shape of an existing one does. Refuse versions you do not know. Version 2 added guards on resources and config overrides — a version-1 reader would apply a guarded resource everywhere — and `platforms`. |
| `selection.host` | The host the document was produced for. |
| `selection.hostDeclared` | Whether the profile's `hosts:` block has an entry for that host. An undeclared host gets `default` only. |
| `selection.activities` | The activities `repro home plan` enables on that host, in the order the profile declares them. Computed by the planner's own rule. Platform-independent. |
| `selection.unknownActivities` | Activities the host's `hosts:` entry names that the profile never declares (they contribute nothing). |
| `intent` | The whole evaluated profile, exactly as the planner consumes it — every activity, not only the selected ones, and every platform's guarded elements. A `when`/`if` guard inside an activity stays a `whenGuard` element carrying its predicate text. Resources are profile-wide. |
| `intent.resources[].guard`, `intent.configOverrides[].guard` | The runtime predicate under which the element applies, as text in the [predicate grammar](#predicates), or `null` for "every host". Nested `when` blocks are conjoined (`arm64 and macos`); an `elif` / `else` branch carries the negation of the earlier conditions. Two resources may share an `address` when their guards never hold together. |
| `platforms` | For each target platform, whether this document describes it: `same` (the profile evaluated for that platform declares exactly this intent), `differs` (a compile-time `when defined(...)` changed it — refuse the document for that platform), or `unevaluated` (the profile could not be evaluated for that platform — treat as `differs`; the reason is in `provenance.compile.probe`). The compiling platform is always described, whatever its entry says. |
| `provenance.repro.version` | The `repro` release that produced the document. |
| `provenance.repro.sourceRevision` | The commit that `repro` was built from (`…-dirty` if the tree had uncommitted changes), or `null` if the build did not record it. The version alone does not identify a build. |
| `provenance.hostSource` | How the host was chosen: `env` (`$REPRO_HOST`), `flag` (`--host`) or `hostname`. |
| `provenance.profile.root` | The profile's root file. |
| `provenance.profile.inputs` | Every file under the profile directory the compile was observed to read (modules, `config.nims`, files read with `staticRead` or at run time), with the BLAKE3-256 of its current contents. Paths are relative to the profile directory. |
| `provenance.profile.digest` | BLAKE3-256 over `<path>\t<blake3>\n` for each input in order; `null` if no reads were observed. |
| `provenance.dataFiles` | Data files the profile declares for plan-time expansion, with digests. Always empty for now. |
| `provenance.compile.target` | The platform that compiled the profile, as a target name (`x86_64-linux`); `<cpu>-<os>` in Nim's names for a platform that is not a target. |
| `provenance.compile.os`, `.cpu` | The same platform in Nim's names (`linux`, `macosx`, `windows`; `amd64`, `arm64`). A `when defined(...)` in the profile was decided for this platform. |
| `provenance.compile.defines` | Extra `-d:` symbols the profile compile passes (none today). |
| `provenance.compile.probe` | For each `unevaluated` platform, why: the end of the compiler's diagnostic. |
| `evaluation` | Present only with `--target`: `target`, `host`, `activities`, `packages` (`name`, `version`, `binaries`, `activity`), and the `resources` and `configOverrides` from `intent` whose guards hold — what the home planner would use for that host on that platform. Resources the home planner does not handle (system-scope kinds) are not listed. |

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
`{"kind":…,"address":…,"fields":{…},"dependsOn":[…],"guard":…}` with each
field a `{"kind":"string"|"int"|"bool"|"list"|"expr","value":…}` pair; a
config override is `{"pkg":…,"key":…,"value":{…},"guard":…}`.

## See also

- [Home-profile walkthrough](home-profile-walkthrough.md) — authoring
  `home.nim` and applying it.
- Exit codes: `0` printed or current, `1` stale snapshot or the export
  failed, `2` usage, `3` the export cannot describe the `--target` platform.
- `repro home export --help` — the flags in brief.

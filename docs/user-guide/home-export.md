# Exporting a home profile — `repro home export`

`repro home export` prints what your `home.nim` evaluates to for one host, as
a versioned JSON document. Other tools read that document instead of
re-implementing Reprobuild's rules: a Nix module can take your package list
from it, a script can ask which activities a machine runs, and a CI job can
check that a committed copy is still current.

```sh
repro home export [--profile-dir DIR] [--host NAME] [--format json] [--check FILE]
```

The command compiles the profile the same way `repro home plan` and
`repro home apply` do (an unchanged profile is answered from the action
cache), and stops there: it plans nothing, applies nothing and records no
generation.

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
`selection` and `intent` — and **never** `provenance`. Upgrading `repro`, or
editing a comment in `home.nim`, changes the provenance but not what the
snapshot tells anyone, so it does not fail the check; the changed fields are
printed as notes. Any edit that changes what the profile means (an added
package, a different host selection, a module that now produces other
resources) changes `intent` or `selection` and does fail it.

A good CI step is simply:

```sh
repro home export --host laptop --check home-export.laptop.json
```

## The document (schema version 1)

```jsonc
{
  "format": "repro.home.export",
  "schemaVersion": 1,
  "selection": {
    "host": "laptop",
    "hostDeclared": true,
    "activities": ["default", "develop_software"],
    "unknownActivities": []
  },
  "intent": {
    "name": "me",
    "activities": [ { "name": "default", "body": [ … ] }, … ],
    "configOverrides": [ … ],
    "hosts": { "laptop": ["develop_software"] },
    "resources": [ … ],
    "buildActions": [ … ],
    "adapterPreference": { … }
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
    "compile": { "os": "linux", "cpu": "amd64", "defines": [] }
  }
}
```

| Field | Meaning |
|---|---|
| `format` | Always `repro.home.export`. Refuse any other value. |
| `schemaVersion` | `1`. Adding a field does not change it; changing the meaning or shape of an existing one does. Refuse versions you do not know. |
| `selection.host` | The host the document was produced for. |
| `selection.hostDeclared` | Whether the profile's `hosts:` block has an entry for that host. An undeclared host gets `default` only. |
| `selection.activities` | The activities `repro home plan` enables on that host, in the order the profile declares them. Computed by the planner's own rule. |
| `selection.unknownActivities` | Activities the host's `hosts:` entry names that the profile never declares (they contribute nothing). |
| `intent` | The whole evaluated profile, exactly as the planner consumes it — every activity, not only the selected ones. A `when`/`if` guard inside an activity stays a `whenGuard` element carrying its predicate text; evaluate it for the platform you are describing. Resources are profile-wide. |
| `provenance.repro.version` | The `repro` release that produced the document. |
| `provenance.repro.sourceRevision` | The commit that `repro` was built from (`…-dirty` if the tree had uncommitted changes), or `null` if the build did not record it. The version alone does not identify a build. |
| `provenance.hostSource` | How the host was chosen: `env` (`$REPRO_HOST`), `flag` (`--host`) or `hostname`. |
| `provenance.profile.root` | The profile's root file. |
| `provenance.profile.inputs` | Every file under the profile directory the compile was observed to read (modules, `config.nims`, files read with `staticRead` or at run time), with the BLAKE3-256 of its current contents. Paths are relative to the profile directory. |
| `provenance.profile.digest` | BLAKE3-256 over `<path>\t<blake3>\n` for each input in order; `null` if no reads were observed. |
| `provenance.dataFiles` | Data files the profile declares for plan-time expansion, with digests. Always empty for now. |
| `provenance.compile.os`, `.cpu` | The platform the profile was compiled for, in Nim's names (`linux`, `macosx`, `windows`; `amd64`, `arm64`). A `when defined(...)` in the profile was decided for this platform. |
| `provenance.compile.defines` | Extra `-d:` symbols the profile compile passes (none today). |

All digests are lower-case hex. The document adds no absolute paths of its
own (provenance paths are relative to the profile directory); anything
machine-specific in `intent` is there because the profile says it.

The `intent` shape is the same JSON the profile binary itself prints. Within
it, an activity body element is either
`{"kind":"packageRef","name":…,"version":…[,"binaries":[…]]}` or
`{"kind":"whenGuard","predicate":"…","body":[…]}`; a resource is
`{"kind":…,"address":…,"fields":{…},"dependsOn":[…]}` with each field a
`{"kind":"string"|"int"|"bool"|"list"|"expr","value":…}` pair.

## See also

- [Home-profile walkthrough](home-profile-walkthrough.md) — authoring
  `home.nim` and applying it.
- `repro home export --help` — the flags in brief.

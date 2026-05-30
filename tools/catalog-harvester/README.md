# catalog-harvester (M66)

A Nim CLI that mines [Scoop](https://scoop.sh/) bucket manifests and
emits `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/<tool>.nim`
catalog entries per the M63 `VersionedProvisioning` schema.

## Build

The harvester sits outside `apps/entrypoints.txt` (it is a maintainer
tool, not a shipped reprobuild binary). Compile it from the repo root:

```bash
nim c \
  --path:libs/repro_dsl_stdlib/src \
  --out:build/bin/repro_catalog_harvester \
  tools/catalog-harvester/repro_catalog_harvester.nim
```

## Usage

```bash
build/bin/repro_catalog_harvester harvest \
  --bucket scoopinstaller/main \
  --bucket ScoopInstaller/Java \
  --app jdk --app maven \
  --output-dir libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
```

`--bucket` is repeatable. Each spec is one of:

* `<org>/<repo>` — GitHub shortname, cloned to the cache root.
* `https://…` git URL.
* Local directory path — used in place, no clone / pull.

The default `--output-dir` is the canonical catalog location.

### Subcommands

| Subcommand | Purpose |
|------------|---------|
| `harvest`  | Bulk emit `<tool>.nim` files. |
| `inspect`  | Translate ONE manifest and print to stdout (no write). |
| `verify`   | Re-harvest a checked-in `<tool>.nim` and assert byte-identical output. |

### Common options

| Option | Default | Notes |
|--------|---------|-------|
| `--bucket <spec>` | (required) | Repeatable. |
| `--app <name>` | (none) | If omitted, every manifest in the bucket is harvested. |
| `--output-dir <path>` | `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/` | Where `<tool>.nim` files land. |
| `--version-history <N>` | `1` | Walk N historical versions; N > 1 unshallows the clone. |
| `--dry-run` | off | Print intended writes (and first 10 lines of each) without touching disk. |
| `--no-refresh` | off | Skip `git pull` for cached buckets. |

## Idempotence

Re-running the harvester with the same inputs produces byte-identical
`<tool>.nim` files. Determinism is enforced via:

* `serializeAsCode` (from `packages_schema.nim`) emits a stable
  field order.
* `env` Table keys are sorted before serialization.
* `architecture` keys are walked in a fixed order (`64bit` first,
  `arm64` second) regardless of JSON-author insertion order.
* The catalog seq is sorted newest-first by a coarse SemVer
  comparator before emission.
* The emitted file carries no timestamp / no commit SHA — only the
  bucket spec + version list, both of which are functions of the
  input.

## Mapping reference

| Scoop field | `VersionedProvisioning` field | Notes |
|-------------|--------------------------------|-------|
| `version` | `version` | Required. |
| `architecture.64bit.url` | `platforms[].url` (cpu=pcX86_64, os=poWindows) | |
| `architecture.arm64.url` | `platforms[].url` (cpu=pcAArch64, os=poWindows) | |
| `architecture.32bit.*` | (dropped) | M63 has no `pcX86` for Windows; `HManifest32BitIgnored` diagnostic emitted. |
| top-level `url` + `hash` | single `(pcAny, poWindows)` slice | For arch-agnostic apps. |
| `hash` with no prefix | `sha256` | Scoop's default. |
| `hash` `sha256:` prefix | `sha256` | |
| `hash` `sha512:` prefix | `sha512` | |
| `hash` `md5:` prefix | (rejected) | `HHashAlgorithmUnsupported` + skip. |
| `extract_dir` | `platforms[].extract_path` | Array form pairs with array-form `url`. |
| `bin` (string) | `bin_relpath = [string]` | |
| `bin` (string seq) | `bin_relpath = seq` | |
| `bin` (`[exe, alias]` pair) | `bin_relpath = [exe]` | Alias dropped; `HBinRenameIgnored` diagnostic. |
| `installer` present | `install_method = imInstallerSilent` | |
| `installer.args` | `installer_args` | Heuristic default `/S` (NSIS) or `/quiet /norestart` (MSI). |
| `env_set` | `env` (Table) | `$dir` rewritten to `${prefix}`. |
| URL extension | `archive_format` | `.zip` → afZip, `.tar.gz` → afTarGz, `.tar.xz` → afTarXz, `.7z` → afSevenZip, `.msi` → afInstallerMsi, `.exe` + installer → afInstallerNsis, `.exe` otherwise → afRaw. |

## Diagnostics

| Kind | When emitted |
|------|--------------|
| `HBinRenameIgnored` | `bin` entry was an `[exe, alias]` pair. |
| `HInstallerArgsUnknown` | Installer block lacks `args` and we can't synthesize a default. |
| `HManifestNoHash` | No `hash` field anywhere — the slice is skipped. |
| `HManifestNoUrl` | No `url` field anywhere. |
| `HManifest32BitIgnored` | `architecture.32bit` present; M63 has no `pcX86`. |
| `HUnknownArchitecture` | An architecture key other than `64bit`, `32bit`, `arm64`. |
| `HHashAlgorithmUnsupported` | `hash` carries a non-sha256, non-sha512 prefix (e.g. `md5:`). |
| `HBucketShadowed` | A later `--bucket` carries the same app as an earlier one; ignored. |
| `HArchiveFormatUnknown` | URL extension didn't match any known archive format. |

## Out of scope (v1)

* Auto-checksum mode (`--auto-verify`) that downloads each URL and
  recomputes the SHA. Deferred — v1 trusts the Scoop maintainer's
  digest.
* Non-Scoop sources (winget, Chocolatey, Homebrew, GitHub Releases
  API). Deferred — Scoop covers the Windows surface this campaign
  needs.
* Authenticated buckets. Public-only.
* CI auto-update scheduling. The harvester is run by maintainers on
  demand; a future milestone may wire it into CI as a `verify` cron.

## Testing

```bash
# All harvester tests
nim c -r --path:libs/repro_dsl_stdlib/src \
  tools/catalog-harvester/tests/test_manifest_parser.nim

nim c -r --path:libs/repro_dsl_stdlib/src \
  tools/catalog-harvester/tests/test_harvester_idempotent.nim

nim c -r --path:libs/repro_dsl_stdlib/src \
  tools/catalog-harvester/tests/test_harvester_verify.nim

nim c -r --path:libs/repro_dsl_stdlib/src \
  tools/catalog-harvester/tests/test_harvester_history.nim
```

The fixture buckets under `tests/fixtures/` are synthetic — no
network access required.

## Live-bucket smoke test (opt-in)

Set `REPRO_M66_LIVE_BUCKET=1` and clone a real scoopinstaller bucket
manually, then point `--bucket` at it. The default test suite does
NOT hit the network.

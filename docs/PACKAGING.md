# Reprobuild Packaging & Distribution

Status: design (Phase 4, Windows-migration completion). The installer artifacts
themselves are not yet produced — this document fixes the target shape so the
shared CI workflow, the `setup-reprobuild` GitHub Action, and future
package-repo publishing scripts can converge.

## Goals

- One blessed install path per supported OS.
- A "tarball" / "zip" portable channel that any CI workflow can consume without
  privileged installs — this is what the `setup-reprobuild` GitHub Action
  downloads.
- A native installer channel (MSI / pkg / deb / rpm) for IT-managed
  workstations and long-lived build servers.
- Reproducible: the same git tag produces byte-identical installer artifacts
  given the same toolchain pin.

## Supported Platforms

| Platform              | Triplet               | Tier |
| --------------------- | --------------------- | ---- |
| Windows 10/11 x64     | `x86_64-pc-windows`   | 1    |
| macOS 13+ x64         | `x86_64-apple-darwin` | 1    |
| macOS 13+ arm64       | `aarch64-apple-darwin`| 1    |
| Linux glibc x64       | `x86_64-linux-gnu`    | 1    |
| Linux glibc arm64     | `aarch64-linux-gnu`   | 2    |
| Linux musl x64        | `x86_64-linux-musl`   | 2    |

Tier 1 platforms publish every release; Tier 2 publishes major/minor releases
plus opt-in nightly tags.

## Distribution Channels

### Windows

| Channel | Artifact                                | Notes                                    |
| ------- | --------------------------------------- | ---------------------------------------- |
| MSI     | `reprobuild-<ver>-x86_64-windows.msi`   | Recommended for IT-managed installs.     |
| Zip     | `reprobuild-<ver>-x86_64-windows.zip`   | Portable; consumed by `setup-reprobuild`.|
| Scoop   | `bucket/reprobuild.json`                | `scoop install reprobuild`.              |

The MSI installs to `%ProgramFiles%\Reprobuild\` and adds that directory to the
machine `PATH`. The zip unpacks the same layout; the GitHub Action prepends
`<extract>/bin` to `GITHUB_PATH`.

### macOS

| Channel  | Artifact                                       | Notes                          |
| -------- | ---------------------------------------------- | ------------------------------ |
| pkg      | `reprobuild-<ver>-<arch>-apple-darwin.pkg`     | Notarized; signed Developer ID.|
| Tarball  | `reprobuild-<ver>-<arch>-apple-darwin.tar.zst` | Portable; signed via codesign. |
| Homebrew | `Formula/reprobuild.rb` (metacraft-labs/tap)   | `brew install reprobuild`.     |

### Linux

| Channel | Artifact                                         | Notes                          |
| ------- | ------------------------------------------------ | ------------------------------ |
| deb     | `reprobuild_<ver>_amd64.deb` (apt.metacraft.dev) | Debian 12+, Ubuntu 22.04+.     |
| rpm     | `reprobuild-<ver>-1.x86_64.rpm` (yum repo)       | Fedora 39+, RHEL 9+.           |
| Tarball | `reprobuild-<ver>-<triplet>.tar.zst`             | Portable.                      |
| AUR     | `reprobuild` (binary), `reprobuild-bin` (source) | Community-maintained.          |
| Nix     | `flake.nix#packages.<system>.default`            | Already shipped.               |

## Versioning & Release Cadence

- Semantic versioning (`MAJOR.MINOR.PATCH`).
- Release tags: `vMAJOR.MINOR.PATCH` (e.g. `v1.4.0`). Tag push triggers the
  release workflow.
- Pre-release tags: `vMAJOR.MINOR.PATCH-rc.N`, `…-nightly.YYYYMMDD`.
- LTS minors (`v1.6.x`, …) receive security backports for 12 months after
  superseding minor ships.
- `setup-reprobuild@v1` is a floating tag that always tracks the most recent
  v1.x action release. Pinning by SHA is supported for supply-chain–sensitive
  consumers.

## Signing

- **Windows MSI / portable zip**: signed with a DigiCert / Azure Trusted
  Signing certificate. Signatures verified by Windows SmartScreen.
- **macOS pkg + tarball**: signed with the Metacraft Labs Developer ID and
  notarized via `notarytool`; stapled before upload.
- **Linux deb / rpm**: signed with the Metacraft Labs apt/yum repo GPG key
  (`E…`). The repo metadata is signed; the package files themselves carry a
  detached signature alongside the artifact in the GitHub release.
- **Tarballs (all OSes)**: a `*.sigstore` Sigstore bundle published alongside
  every artifact; `cosign verify-blob` documented in the release notes.

Signing happens in the release workflow inside dedicated jobs that hold the
secrets; no secret material is ever exposed to PR runners.

## Release Artifact List

Per platform a single GitHub release carries:

- The native installer (MSI / pkg / deb / rpm).
- The portable archive (`.zip` / `.tar.zst`).
- Detached signature(s) — `.asc` for gpg, `.sigstore` for cosign.
- `SHA256SUMS` + `SHA256SUMS.asc` covering every artifact.
- `manifest.json` — machine-readable index used by `setup-reprobuild` to
  resolve `version: latest`.

## Release Workflow

`.github/workflows/release.yml` (future):

```
on:
  push:
    tags: [v*]

jobs:
  build-windows:   # runs-on: windows-latest, produces .zip + .msi
  build-macos:     # runs-on: macos-14 (arm64) and macos-13 (x64)
  build-linux:     # runs-on: ubuntu-latest (matrix glibc/musl, x64/arm64)
  sign:            # consumes per-platform unsigned artifacts, attaches sigs
  publish-release: # uploads everything to the GitHub release + manifest.json
  publish-repos:   # apt repo push, yum repo push, brew bump, scoop bump
```

## Bundled Runtime Dependencies

The compiled engine has a small set of runtime dependencies that must be
co-located with `repro` itself:

- `clingo.dll` (Windows) / `libclingo.so` (Linux) / `libclingo.dylib`
  (macOS) — Potassco ASP solver. Shipped inside the installer next to
  `repro`. Already present at `build/bin/clingo.dll` today.
- `librepro_monitor_shim.{dll,so,dylib}` — the IAT / `LD_PRELOAD` /
  `DYLD_INSERT_LIBRARIES` shim. Ships under `lib/` next to `bin/`.
- `librepro_project_dsl_runtime.{dll,so,dylib}` — Tier-1 DSL runtime DLL.
  Ships under `lib/`.

The sibling apps (`repro-harvest-apt`, `repro-binary-cache`,
`repro-peer-cache-tier2`, `repro-cmake-trycompile-provider`,
`repro-standard-provider`, `repro-cmake-dyndep-fragment`, …) all live in `bin/`
inside the installer and pick up the shared libraries via the platform's normal
search rules (DLL search dir on Windows, RPATH on Linux/macOS).

### `runquota` (sibling daemon)

`runquota` (separate repository) hosts the per-action time/IO accounting
daemon (`runquotad`). It is NOT bundled inside the reprobuild installer:

- On Linux/macOS the user installs the `runquota` package separately
  (debian/rpm package `runquotad`, brew formula `runquota`).
- On Windows the `runquota` MSI installs `runquotad.exe` to
  `%ProgramFiles%\Runquota\` and registers it as a Windows service.

Reprobuild's engine auto-detects a running `runquotad` and falls back to a
build-from-sibling code path (today's developer workflow) when one is not
present. The setup action documents `runquota` as an optional companion.

## Installation Layout

All channels install to the same logical layout:

```
<prefix>/
  bin/
    repro[.exe]
    repro-*[.exe]
    clingo.dll                    (Windows only — co-located by convention)
  lib/
    librepro_monitor_shim.{dll,so,dylib}
    librepro_project_dsl_runtime.{dll,so,dylib}
  share/reprobuild/
    recipes/
    examples/                     (optional — not in the slim installer)
    LICENSE
    SBOM.spdx.json
```

`<prefix>` defaults:

- Windows MSI: `%ProgramFiles%\Reprobuild\`
- macOS pkg: `/usr/local/` (Intel) / `/opt/homebrew/` (Apple Silicon)
- Linux deb/rpm: `/usr/`
- Tarballs: caller-chosen; the `setup-reprobuild` action extracts under
  `${RUNNER_TOOL_CACHE}/reprobuild/<ver>/<arch>/`.

## Backward-Compatibility Policy

- The CLI surface (`repro …` subcommands, flags, exit codes) and the
  on-disk catalog format are versioned. Breaking changes require a major
  version bump and a deprecation window of at least one minor release with a
  prominent deprecation notice.
- The `setup-reprobuild` action follows independent semver: a v1 → v2
  bump indicates an incompatible input/output change. v1 continues to receive
  bug fixes for at least 6 months after v2 ships.
- The `manifest.json` format is forward-compatible: consumers MUST ignore
  unknown fields.

## Open Items (follow-up PRs)

- Wire `release.yml` and the per-OS packager scripts (msi, pkg, deb, rpm).
- Procure / load signing certs into GitHub Actions secrets.
- Stand up `apt.metacraft.dev` and `yum.metacraft.dev` (or reuse an existing
  Cloudflare R2 + signed-repo setup).
- Publish `metacraft-labs/setup-reprobuild` as a standalone action repo (the
  current in-repo composite action becomes a thin shim that delegates).
- Migrate the recorder repos' `ci-reprobuild.yml` from the build-from-source
  path to `uses: metacraft-labs/setup-reprobuild@v1`.

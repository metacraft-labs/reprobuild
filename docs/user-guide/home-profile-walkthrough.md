# Home-profile walkthrough — end-to-end provisioning via `home.nim`

This page is the operator-facing walkthrough for the M71 home-profile
provisioning flow. By the end of it you will have:

- a `home.nim` profile declaring every toolchain your projects need;
- a single `repro home apply` invocation that realizes those toolchains
  through the built-in catalog (no Scoop, no manual installer hunting);
- a Windows PATH that picks up the realized binaries automatically
  whenever you open a new shell.

The walkthrough mirrors the M71 validation harness verbatim — the
campaign's verification gate copies the reference `home.nim` shipped at
[`reprobuild-examples/m71-home-profile-walkthrough/home.nim`](../../../reprobuild-examples/m71-home-profile-walkthrough/home.nim)
into a sandbox and runs the same `repro home apply` invocation you'll
run yourself.

## Prerequisites

- A working `repro.exe` on PATH (`bash scripts/build_apps.sh` from the
  reprobuild repo root produces it under `build/bin/`).
- Windows 10 or later. Linux home-profile validation is deferred per
  the M71 outstanding-tasks list; macOS continues to use `cakNix`.
- ~4 GB of free disk under your chosen home-state directory if you
  realize every activity in the reference profile.

You do NOT need any pre-existing toolchain install. The whole point of
the home profile is that `repro home apply` realizes everything from
upstream URLs through the M64 built-in adapter.

## Step 1 — author your `home.nim`

Copy the M71 reference profile into your home-state directory:

```pwsh
$env:REPRO_HOME_PROFILE_DIR = "$env:LOCALAPPDATA\repro\home"
New-Item -ItemType Directory -Force -Path $env:REPRO_HOME_PROFILE_DIR | Out-Null
Copy-Item .\reprobuild-examples\m71-home-profile-walkthrough\home.nim `
  -Destination "$env:REPRO_HOME_PROFILE_DIR\home.nim"
```

Open the copied `home.nim` in your editor and:

1. Change the host entry from `m71-test-host` to your real hostname.
   The hostname must match `$env:COMPUTERNAME` (lowercased) — or set
   `$env:REPRO_HOST=<name>` to pin a chosen identity.

2. Trim the activities to the languages you actually use. Each
   activity is independent — keeping only `dev` skips the 350 MB JDK,
   the 1.2 GB GHC + cabal stack, the 600 MB Swift toolchain, etc.

3. Optionally pin newer versions. The reference profile pins the M67/M68
   catalog HEAD; if you want a specific version, edit the version string
   in the `package(<id>, "<version>")` call. The catalog's currently-
   shipping versions live in `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/<tool>.nim`
   — each module's header comment lists the available versions.

## Step 2 — run `repro home apply`

```pwsh
repro home apply
```

That single command:

1. Parses `home.nim` via the M83 Phase-A `repro/profile` macro library.
2. Resolves the host-activity map (`hosts:`) against `$env:REPRO_HOST`
   to produce the active activity set.
3. For each `package(<id>, "<version>")`, asks the M65 adapter chain
   to pick a realization strategy. On Windows the default chain is
   `[cakBuiltin, cakScoop, cakPath]` — every package in the reference
   profile resolves to `cakBuiltin` because the M67/M68 catalogs
   contain a slice for the requested `(cpu, os)` tuple.
4. Downloads the catalog URL (cached in the M56 content-addressed
   store; a second `repro home apply` cache-hits without re-fetching).
5. Verifies the recorded SHA-256/SHA-512 against the downloaded bytes
   BEFORE any extraction — a mismatch fails closed with
   `EBuiltinDigestMismatch`.
6. Extracts (or runs the silent installer) into a stable prefix under
   the M56 store.
7. Writes one launcher shim per declared `bin_relpath` into the
   activation generation's `bin/` dir AND into the Windows stable
   `bin` dir at `$env:REPRO_HOME_STATE_DIR\bin`.
8. Updates the M82 activation manifest, contributing the per-package
   bin dirs to the user PATH via the M68 `env.userPath` driver and
   the per-tool `env:` entries (e.g. `JAVA_HOME`) via
   `env.userVariable`.

Expected output (abridged):

```
==> applying generation a3f7c2e9...
    realized: jdk@21.0.5 (cakBuiltin, 348 MB; from https://github.com/adoptium/...)
    realized: maven@3.9.16 (cakBuiltin, 9 MB; from https://archive.apache.org/...)
    realized: gradle@9.5.1 (cakBuiltin, 92 MB; from https://services.gradle.org/...)
    realized: cmake@4.3.3 (cakBuiltin, 38 MB; from https://github.com/Kitware/...)
    realized: ghc@9.12.1 (cakBuiltin, 1180 MB; from https://downloads.haskell.org/...)
    realized: cabal@3.16.1.0 (cakBuiltin, 18 MB; from https://downloads.haskell.org/...)
    realized: crystal@1.20.2 (cakBuiltin, 117 MB; from https://github.com/crystal-lang/...)
    realized: php@8.5.6 (cakBuiltin, 32 MB; from https://downloads.php.net/...)
    [...]
    apply: eager gc reclaimed 0 prefixes (ranAt 2026-05-31T...)
applied generation a3f7c2e9... in 8m 12s
```

## Step 3 — verify your PATH

Open a fresh PowerShell session (the user-PATH update only takes effect
in new shells) and check that your tools resolve:

```pwsh
Get-Command javac
Get-Command cmake
Get-Command ghc
Get-Command crystal
```

Each should point under `$env:REPRO_HOME_STATE_DIR\bin\<tool>.cmd`, the
launcher that redirects to the realized prefix in the M56 store.

## Step 4 — run a Mode 2 fixture

The M71 campaign graduates the M55 Haskell, M57 PHP, M58 Ada, M59
Pascal, and M60 Crystal fixtures. The CLEAN ones (Haskell, Crystal,
PHP-core) PASS end-to-end through `repro build` once their toolchains
are on PATH:

```pwsh
repro build (Resolve-Path .\reprobuild-examples\haskell-cabal\hello-binary)#default --tool-provisioning=path
```

The fixture's `validate-standard-provider-haskell-cabal-hello-binary.ps1`
script SKIPped before M71 (because `ghc` wasn't on PATH); after the
home apply it PASSes. Same story for `crystal-shards`, `crystal-mode3`,
and `php-composer` (modulo the composer realize-time gap).

## What WON'T graduate

Five Phase-2 partials remain blocked after M71:

| Fixture                          | Tool       | Blocker                                                          |
|----------------------------------|------------|------------------------------------------------------------------|
| `ada-mode3/binary-with-library`  | `gnat`     | No Scoop bucket source; needs MSYS2 pacman or upstream harvest.  |
| `pascal-mode3/binary-with-library` | `fpc`    | Scoop manifest exists but ships sha1 hashes; M63 schema needs ≥sha256. |
| `ocaml-dune/hello-binary`        | `ocaml/dune` | OCaml ships via MSYS2 pacman + dune via source bootstrap; no Scoop source. |
| `swift-swiftpm/hello-binary`     | `swift`    | Catalog entry present BUT M69-deferred realize path + M51 VS Build Tools env gap. |
| `erlang-rebar3/hello-binary`     | `erlang`   | Catalog entry present BUT M69-deferred (rebar3 escript bootstrap gap). |

The harness reports these as `BLOCKED-NO-CATALOG` or `STILL-SKIPPED`
respectively and exits 0 in plan mode (they're not regressions — the
gaps are documented in the campaign's wrap-up section).

## Disk footprint

Realizing every activity in the reference profile costs about 4 GB:

- JDK 21: ~350 MB
- GHC 9.12 + cabal: ~1.2 GB
- Swift 6.3 toolchain: ~600 MB
- Crystal: ~120 MB
- gcc 15 + Maven + Gradle + dotnet-sdk: ~700 MB
- cmake + ninja + meson + git + node + python3 + nim + zig: ~500 MB
- the rest (just / gh / php / composer / ruby / elixir / erlang): ~500 MB

The M56 content-addressed store de-duplicates across generations, so
re-applying the same profile costs nothing on disk. A future
`repro home gc` will reclaim unused generations; until it lands, the
prefix directories are stable and inspectable under your store root.

## Co-existence with `env.ps1`

Per the M70 deprecation contract, `D:/metacraft/env.ps1` continues to
dot-source the legacy `windows/ensure-*.ps1` modules. Each module
checks the home-profile detection helper and SKIPs with an info banner
when the home profile owns the tool:

```
Ensure-Jdk: SKIPPED (home profile owns jdk; run `repro home apply` to realize via the catalog)
```

A fully-migrated user keeps `env.ps1` only as a thin PATH-priming
shim — or drops `env.ps1` entirely if they apply the home profile as a
Windows login script. The M49–M62 `ensure-*.ps1` modules will be
removed in a milestone post-2026-11-30; until then both paths coexist.

## Troubleshooting

- **`repro home apply` exits with "unknown package <id>"**: the package
  isn't in the M65 registry. Check
  `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/catalog_registry.nim`'s
  `RegisteredTools` array for the canonical name (some tools rename
  for Nim-identifier reasons — e.g. `python3` not `python`,
  `dotnet-sdk` not `dotnet`).
- **`repro home apply` exits with "version X not in catalog"**: edit
  your `home.nim` and either drop the version pin (uses the catalog's
  default) or update it to a version that exists in
  `packages/<tool>.nim`.
- **`repro home apply` exits with "cakBuiltin realize not yet
  implemented for <tool>"**: you've hit one of the M69-deferred-8
  tools. Fall back to env.ps1's `Ensure-<Tool>` for now; the realize-
  time hooks land in a follow-up milestone.
- **The realized binary is on PATH but a fixture FAILs**: the M9
  per-fixture validate scripts probe via `Get-Command`. If your shell
  has stale PATH from before the apply, open a fresh shell.

## See also

- [`migrating-from-env-ps1.md`](./migrating-from-env-ps1.md) — operator
  guide for replacing `D:/metacraft/env.ps1` with a home profile,
  including the `repro home migrate-from-env-scripts` synthesizer.
- [`Builtin-Catalog-And-Home-Profile-Provisioning.milestones.org`](../../../reprobuild-specs/Builtin-Catalog-And-Home-Profile-Provisioning.milestones.org)
  — the campaign spec (M63–M71) covering the full design.
- [`Home-Profile-Intent-Layer.md`](../../../reprobuild-specs/Home-Profile-Intent-Layer.md)
  — the `home.nim` schema reference.

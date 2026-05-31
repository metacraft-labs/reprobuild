# Migrating from `env.ps1` to a home profile

This page walks through replacing the legacy `D:/metacraft/env.ps1` +
`windows/ensure-*.ps1` provisioning path with a home-profile-driven
flow. Per the M70 deprecation contract, both paths coexist for a
6-month grace window (removal target: 2026-11-30) — this guide is
optional until then.

## When to migrate

Migrate when ANY of these apply:

- You want a single declarative source-of-truth for your toolchains.
  `home.nim` lives in source control; `ensure-*.ps1` invocations are
  imperative shell calls and easy to drift between machines.
- You want to switch toolchain versions without editing PowerShell.
  `home.nim` carries `package(<id>, "<version>")` lines; bumping a
  version is a single-line edit, then `repro home apply`.
- You want fast cold provisioning on a new machine. `repro home apply`
  runs every realize in parallel (M64 dispatch); the legacy
  `ensure-*.ps1` modules are serial PowerShell.

Do NOT migrate yet if:

- You depend on a tool in M69's deferred-8 list (`swift`, `gcc`,
  `git`, `meson`, `python3`, `composer`, `erlang`, `ruby`). Those
  tools have catalog entries but their cakBuiltin realize-time hooks
  haven't landed — `repro home apply` will fail closed on them with a
  structured "not yet implemented" diagnostic. Keep using `env.ps1`
  for these until a follow-up milestone closes the gap.
- You depend on a tool NOT in the catalog (`gnat`, `alire`, `fpc`,
  `ocaml`, `dune`). Same fallback: stay on `env.ps1` for those.

## Step 1 — synthesize a starter `home.nim`

The `repro home migrate-from-env-scripts` subcommand reads
`D:/metacraft/windows/toolchain-versions.env` and produces a
`home.nim` covering every tool whose pin maps to a catalog entry:

```pwsh
repro home migrate-from-env-scripts --dry-run
```

`--dry-run` prints the proposed `home.nim` content to stdout without
writing anything. Inspect it, then re-run without `--dry-run` to
write the file to `$env:REPRO_HOME_PROFILE_DIR\home.nim`:

```pwsh
$env:REPRO_HOME_PROFILE_DIR = "$env:LOCALAPPDATA\repro\home"
repro home migrate-from-env-scripts
```

### What gets migrated cleanly

Per the M70 implementation note, only `JDK_VERSION=21.0.5` migrates
cleanly out of the 12 pins in `toolchain-versions.env`. The reason is
catalog-version drift: `env.ps1` carries older pins for stability while
the M67/M68 catalogs track Scoop HEAD.

**Before** (`windows/toolchain-versions.env`):

```
JUST_VERSION=1.47.1
GH_VERSION=2.88.1
PYTHON_VERSION=3.12.10
JDK_VERSION=21.0.5
JDK_BUILD=11
MAVEN_VERSION=3.9.9
GRADLE_VERSION=8.10.2
SWIFT_VERSION=5.10.1
ZIG_VERSION=0.13.0
```

**After** (synthesized `home.nim`):

```nim
import repro_profile

profile "migrated-from-env-scripts":
  activity dev:
    package(jdk, "21.0.5")
    # TODO: just@1.47.1 — version not in catalog (catalog HEAD: 1.51.0).
    # Pin the catalog HEAD or backfill 1.47.1 into packages/just.nim.
    # TODO: gh@2.88.1 — version not in catalog (catalog HEAD: 2.93.0).
    # TODO: python3@3.12.10 — version not in catalog (catalog HEAD: 3.14.5).
    # TODO: maven@3.9.9 — version not in catalog (catalog HEAD: 3.9.16).
    # TODO: gradle@8.10.2 — version not in catalog (catalog HEAD: 9.5.1).
    # TODO: swift@5.10.1 — DEFERRED (M69 deferred-8; cakBuiltin realize
    #       has a gap. Keep using env.ps1's Ensure-Swift until fix.)
    # TODO: zig@0.13.0 — version not in catalog (catalog HEAD: 0.16.0).
  hosts:
    "<your-hostname>": [dev]
```

The synthesizer emits TODO comments for everything it can't migrate
cleanly. Audit each comment and either:

- bump the version pin to a catalog-HEAD version (the M71 reference
  profile takes this approach);
- backfill the historical version into the catalog by re-running
  `tools/catalog-harvester` with `--version-history N>1`;
- leave the TODO comment in place — the legacy `Ensure-<Tool>` will
  continue to provision that tool until you take action.

### Re-running the synthesizer is safe

The synthesizer refuses to overwrite an existing `home.nim`:

```
repro home migrate-from-env-scripts: ~/.config/repro/home/home.nim
  already exists; wrote to ~/.config/repro/home/home.nim.migrated
  instead. Merge manually via the structural editor or hand-edit.
```

When migrating later you can `diff home.nim home.nim.migrated` and
cherry-pick the changes you want.

## Step 2 — apply the home profile

```pwsh
repro home apply
```

See [`home-profile-walkthrough.md`](./home-profile-walkthrough.md) for
the full walkthrough of what this command does and the expected
output.

## Step 3 — coexistence with `env.ps1`

After `repro home apply` succeeds:

- `env.ps1`'s `Ensure-<Tool>` calls detect the home profile owns each
  migrated tool and SKIP with an info banner:

  ```
  Ensure-Jdk: SKIPPED (home profile owns jdk; run `repro home apply` to realize via the catalog)
  ```

- Tools NOT in the home profile (the TODO comments above, plus
  anything `toolchain-versions.env` doesn't pin) continue to flow
  through the legacy path unchanged.

- A re-source of `env.ps1` in the same shell is silent — each
  `Ensure-<Tool>` checks the M70-detection helper once per session.

If you want to drop `env.ps1` sourcing entirely:

1. Verify your `home.nim` covers EVERY tool you actually use.
2. Replace the `. D:/metacraft/env.ps1` line in your PowerShell profile
   with a one-liner that adds the home profile's stable bin dir to
   PATH (the M82 activation manifest writes this to a HKCU registry
   value automatically, so a Windows login is enough — no shell
   profile mutation needed if you're applying via login script).
3. Open a fresh PowerShell and verify your tools still resolve.

## Reverting a migration

If something doesn't work after the home apply:

1. The M70 detection branch in `env.ps1` activates only when a
   `home.nim` exists at `$env:REPRO_HOME_PROFILE_DIR\home.nim`. Move
   or delete that file and re-source `env.ps1` — every `Ensure-<Tool>`
   runs the legacy path as before.
2. Or, edit the `home.nim` to remove the problematic `package(...)`
   line and re-run `repro home apply` — the legacy `Ensure-<Tool>`
   reactivates for that one tool.
3. Or, run `repro home rollback` to revert to the previous activation
   generation. The M82 generation pointer rotates back; the PATH
   contributions come from the previous generation's manifest.

## Disk usage

The home apply realizes each tool exactly once into the M56 content-
addressed store. A second apply with the same `home.nim` cache-hits;
a third apply with a bumped version pin realizes the new version
alongside the old (a future `repro home gc` will reclaim the old
prefix when no active generation references it).

Compare with the legacy `D:/metacraft-dev-deps/<tool>/<version>/` tree
that `ensure-*.ps1` writes: the per-tool root is the same shape, but
the home profile's CAS de-duplicates across generations and supports
atomic rollback. The legacy tree is unconditionally retained during
the 6-month coexistence window so you can fall back if needed.

## See also

- [`home-profile-walkthrough.md`](./home-profile-walkthrough.md) — the
  full end-to-end walkthrough; the M71 validation harness mirrors it
  verbatim.
- [`Builtin-Catalog-And-Home-Profile-Provisioning.milestones.org`](../../../reprobuild-specs/Builtin-Catalog-And-Home-Profile-Provisioning.milestones.org)
  — the campaign spec; §M70 documents the synthesizer's design, §M71
  the validation flow.

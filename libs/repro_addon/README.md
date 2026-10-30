# repro_addon

Add-on mode: Reprobuild managing a declared set of systemd services and
system files on a Linux host whose operating system belongs to a
distribution (Debian 12 and 13, Raspberry Pi OS 13, Ubuntu 24.04). The
distribution keeps its packages, kernel and boot; the add-on owns only the
objects its ownership ledger lists, and can remove every one of them again.

## Modules

| Module | Purpose |
|---|---|
| `repro_addon/fingerprint` | Deterministic base fingerprint (dpkg status, `/etc`, units, accounts, sysctl, mounts, diversions, listening sockets) with a diff mode and exact expectations. |
| `repro_addon/preflight` | Read-only host inventory and checks; a canonical JSON plan identified by its SHA-256. |
| `repro_addon/ledger` | The ownership ledger (v2: with the plan-time observation, how a collision was resolved, the preserved pre-write bytes and the base's unit state), its drift check, and the fingerprint delta two ledgers account for. |
| `repro_addon/collision` | The collision observer behind a per-distribution driver interface (the dpkg driver: `info/*.list`, `*.conffiles`, the diversion database, `systemctl show`), the decision table, the plan-time symlink refusal and the before-each-write re-check. |
| `repro_addon/etc_write` | Writing a file as root without ever following a symbolic link (`openat`/`O_NOFOLLOW`/`renameat`). |
| `repro_addon/generation0` | The add-on's own objects (target, read-only store mount, report-only re-assert unit, apt hook, trust anchors). |
| `repro_addon/store_root` | `/repro/store` (a btrfs subvolume on btrfs roots), the add-on's prefixes, generation GC roots, the private writable store view. |
| `repro_addon/addon_apply` | The add-on layer over `repro infra apply`: scope (`managedEtcPrefixes`), the collision pass and its opt-ins (`collision = divert | dropIn | replace`, `--reconcile-drift`, `repro system adopt`), composition, removal by ledger with restoration from preserved bytes, side-effect objects. |
| `repro_addon/bootstrap` / `uninstall` / `verify` | The `repro system addon` verbs. |
| `repro_addon/cli` | Command-line surface shared by the engine and the static binary. |
| `repro_addon/mutations` | Compile-time falsifying mutations for the acceptance gates. |

## The static binary

`apps/repro-addon` is the musl-static `repro` an operator fetches onto a
host to bootstrap it (`scripts/build_addon_static.sh amd64 arm64 armhf`,
which verifies static linking and writes `SHA256SUMS`). Fetch it, check
its digest, then run the preflight and acknowledge the plan digest it
prints:

```sh
sha256sum -c repro.sha256 && chmod +x repro
sudo ./repro system addon preflight
sudo ./repro system addon bootstrap --plan <digest>
```

## Applying a profile on an add-on host

```sh
sudo repro infra plan --profile gen.profile      # ledger diff + collision report, writes nothing
sudo repro infra apply --profile gen.profile [--reconcile-drift]
sudo repro system adopt systemFile:/etc/app/app.conf --profile gen.profile
```

A profile declares the `/etc` prefixes it may own once, and every file or
diversion outside them is refused:

```
addOn {
  managedEtcPrefixes = ["/etc/app/", "/etc/issue.net"]
}
```

## Tests

Unit tests are under `tests/`. The acceptance gates run in disposable VMs
and live in `tests/e2e/addon/` (`just e2e_addon_*`).

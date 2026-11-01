# Reference services: Vaultwarden and an Ethereum validator

Reprobuild ships two reference system activities. Each is written once and
realised either by add-on mode on a Debian or Ubuntu host, or by a host whose
system Reprobuild manages in full:

- `vaultwarden`, a password server;
- `ethereum_validator`, an execution client (geth), a consensus client
  (prysm's beacon node) and a validator client (prysm's validator).

The profile is `tests/e2e/addon/fixtures/reference_services/system.nim`.
Copy it as a starting point; the pins it imports (`reference_pins.nim`) are
written by the gates for their test network.

## What each activity declares

Both activities declare the same kinds of things:

- **Store packages.** Each package is a substitute-only build-action edge
  declared inside the activity that runs it. A host builds none of them: it
  fetches each from the binary cache and refuses any archive whose digest is
  not the one the profile pins. Because each edge belongs to its activity, a
  host fetches only the packages of the activities it selects. A host that
  selects only `vaultwarden` never downloads geth or prysm.
- **A system account and a state directory**, declared through `sysusers.d`
  and `tmpfiles.d` fragments.
- **Configuration files under `/etc`.**
- **Secrets as credentials.** These are the admin token, the engine-API
  secret and the validator's wallet password. A unit reads each one from
  `$CREDENTIALS_DIRECTORY`. Secrets never appear in the profile. Deliver one
  with `repro system secret put --service <unit name without .service>
  --name <name>`; on an add-on host that command hands over to `repro system
  addon secret put`. Secrets live on a RAM-only filesystem. At boot, a
  oneshot unit that every credential-loading unit is ordered after restores
  them from the host's sealed envelope. This works on add-on hosts and on
  hosts realised in full.
- **A hardening floor in each unit**: `ProtectSystem=strict`, private `/tmp`
  and devices, no new privileges, a system-call filter, no capabilities,
  `MemoryDenyWriteExecute=yes`, and execution confined to the unit's own
  store prefix.
- **A health check** that an add-on switch waits for before it commits.

## Running a validator safely

The validator client is declared `exclusive = true`. When the client
restarts, is renamed, moves to a new package, or is rolled back, the old
instance is stopped and confirmed exited before the new one starts. If the
old instance cannot be confirmed stopped, the switch refuses.

Three properties of the activity protect the signing keys:

1. **One slashing-protection database, at a fixed path.** The database lives
   in `/var/lib/ethereum/validator`. No unit name, package version or
   generation is part of that path. The client holds an exclusive lock on the
   database while it runs. A second instance on the same host therefore
   cannot open it and signs nothing, whether it was started outside the unit
   or by an activation the switch did not see.
2. **The doppelganger check.** Before it signs, the client asks the beacon
   node whether any of its keys signed in the recent epochs, ignoring what
   its own database recorded. If they did, it exits. This catches the same
   keys running on another host.
3. **A rename takes a new resource address.** Use the default address, which
   names the unit. If you keep an explicit address while renaming the unit,
   the switch refuses; it never leaves the old instance running.

### Keys on two hosts: your responsibility

Placing the keys is the operator's job: **run one host per validator key
set.** No control on a single host can see another machine. The
doppelganger check narrows the risk but does not remove it. It cannot detect
two hosts holding the same keys that start inside one detection window. Nor
can it detect a second host starting while the first was stopped for the
whole window. Do not copy a validator's keystores to a second host, a spare
or a restored backup while the first may still be running.

### Moving or restoring the database

Keep `/var/lib/ethereum/validator` across every change. A client started
against an empty database can sign messages the old database had already
refused. When you move a validator to a new host, stop the old client first
and make sure it stays stopped. Then carry the database across and restore it
before the new client first starts.

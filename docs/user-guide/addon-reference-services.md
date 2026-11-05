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

## When an upgrade changes the hardening floor

The floor is versioned. A newer Reprobuild can tighten it, and an add-on
host records with each installed unit the floor version it was written
under. Upgrading the engine therefore changes the bytes of every floored
unit, and each such unit restarts. A host upgraded from an engine that
wrote version 2 to one that writes version 3 or later is one example.
The add-on handles this in four ways:

- **Every plan lists the units whose floor changes**, under `service floor
  changed`, and lists each one as a restart in the transition list too.
  Removing a floor exception from a unit counts as a floor change, because
  the unit loses something it ran with.
- **The deploy agent refuses such a generation** and reports it as an
  operator action. A running service's floor changes only in an apply an
  operator has reviewed, never in an unattended tick. Run
  `repro system addon plan` with the new engine, read the list, and apply
  from the operator's shell. Later generations that change no floor go
  back to the agent.
- **A stored generation keeps the floor it was installed with.** A revert
  or a rollback to an older generation renders that generation's units
  under their own floor version. If the add-on cannot tell which version
  a stored unit was written under, it refuses the switch. It does not
  guess, because a wrong guess would rewrite the unit with other bytes than
  were installed.
- **Before anything starts, systemd's own view is checked.** From just
  before the switch reloads systemd until this check passes, the switch
  holds every floored unit, so no socket, timer or other start request can
  run it. The add-on then reads everything `systemctl show` reports for
  each floored unit and compares it with the floor the unit was written
  under, minus its named exceptions. A property the floor neither checks
  nor lists as harmless is refused, so a setting from a newer systemd is
  refused until it is reviewed. If anything differs, the switch starts
  nothing and reverts. The check also refuses:
  - any drop-in the add-on did not write, wherever systemd would read it
    for the unit or for any instance of a templated unit. This includes a
    package's drop-in under `/usr/lib/systemd` and a type-wide
    `service.d/` drop-in;
  - a command flag that leaves the sandbox (`+`, `!`, `!!`);
  - a file the service manager would open as root (`OpenFile=`,
    `StandardOutput=file:`);
  - a privileged group, including one the service's account belongs to in
    `/etc/group`, or a second group name for the same gid;
  - an `EnvironmentFile=` that the service or another user could have
    written: a wildcard, a missing file, or a file under a writable place
    or a parent directory that someone other than root can write. The
    manager reads it as root;
  - a socket, timer or path unit that starts a floored service and does
    more than listen on a network address or a unix socket under `/run`,
    or watch a path, for example a socket that opens a device or a FIFO,
    or one that runs a command;
  - realtime scheduling, a reboot `FailureAction=`, or a resource limit
    above the service manager's default.

  This check runs on every switch: an apply, an agent tick, a revert, a
  rollback and a crash recovery. It does not run between switches. A
  drop-in that someone with root, or a package, installs later takes
  effect at the next reload or boot without the check. The next switch
  then refuses it.

Each newer floor version can refuse settings an older one accepted. For
example, it may forbid a writable or executable path the unit relied on,
quoting or `%` specifiers in a path, `PAMName=`, or a key outside the
floor's list of known keys. The plan names each refusal and the exception
that would waive it, where one exists. An exception can name only the
floor's own settings. A service that must run as root, or in a privileged
group such as `adm` or `shadow`, needs the whole-floor waiver
`serviceFloor`: no narrower exception allows it. `PAMName=` cannot be
waived, because a PAM session can run code as root outside the unit's
sandbox.

## Running a validator safely

The validator client is declared `exclusive = true`. On an add-on host,
when the client restarts, is renamed, moves to a new package, or is rolled
back, the add-on switch stops the old instance and confirms it has exited
before the new one starts. If the old instance cannot be confirmed stopped,
the switch refuses.

This stop-and-confirm, and the refusal of a rename that keeps its address
(property 3 below), belong to the add-on switch: it plans every change of
the unit from its ledger. A host realised in full does not run the switch.
Its apply writes the units in place and leaves restarts to systemd, which
also never runs two instances of one unit at once. A rename there replaces
one unit with another without that confirmation. On such a host the
validator is protected by properties 1 and 2, which hold on both kinds of
host. When you rename the validator's unit on a host realised in full, stop
the old unit yourself before you apply.

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
3. **A rename takes a new resource address** (add-on hosts). Use the default
   address, which names the unit. If you keep an explicit address while
   renaming the unit, the add-on switch refuses; it never leaves the old
   instance running.

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

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
  run it. The hold is an assertion that `/` does not exist, so nothing a
  unit creates or removes can lift it. The add-on then reads everything `systemctl show` reports for
  each floored unit and compares it with the floor the unit was written
  under, minus its named exceptions. A property the floor neither checks
  nor lists as harmless is refused, so a setting from a newer systemd is
  refused until it is reviewed. If anything differs, the switch starts
  nothing and reverts. It prints one refusal per line, each ending with
  the rule that refused it and the setting it judged, for example
  `[rule:existing-tree key:RuntimeDirectory]`. This check applies every rule the profile was
  checked against once more, to the unit files systemd actually loaded, so
  it does not rely on the earlier check. It also refuses:
  - any drop-in the add-on did not write, wherever systemd would read it
    for the unit or for any instance of a templated unit. This includes a
    package's drop-in under `/usr/lib/systemd` and a type-wide
    `service.d/` drop-in;
  - a command flag that leaves the sandbox (`+`, `!`, `!!`);
  - a file the service manager would open as root (`OpenFile=`,
    `StandardOutput=file:`);
  - a privileged group, including one the service's account belongs to in
    `/etc/group`, or a second group name for the same gid;
  - an `EnvironmentFile=` that is neither a file the generation installs
    from the add-on's store nor a file in the service's own secrets
    directory, after every link in its path is followed. The manager reads
    the file as root and passes its contents to the service, so a file
    the service could not read itself, such as another service's secret
    or a host file under `/etc`, is refused whatever its owner or mode.
    A store file counts only when the add-on has recorded its digest; on
    a host whose store predates that record, review the store and run
    `repro system addon store-verify --adopt-unverified`;
  - a socket, timer or path unit that starts a floored service and does
    more than listen on a network address or on a unix socket named after
    the unit under `/run`, or watch a path. Examples are a socket that
    opens a device or a FIFO, one that runs a command, and one that sets
    an option needing a capability the service does not have
    (`Mark=`, `Transparent=`, `BindToDevice=`, a `Priority=` above 6);
  - a directory or link that the service manager would create for the
    unit and that is not the unit's own: each `RuntimeDirectory=`,
    `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=` and
    `ConfigurationDirectory=` must be named exactly after the unit (`foo`
    for `foo.service`, with anything more below it: `foo/data`), never
    inside another program's tree (`systemd/system/...`, `udev/rules.d`)
    or the add-on's own directories. A directory's link must have the
    same name, so in practice a floored unit sets none. A unit may not be
    named after a directory the base system already has
    (`systemd.service`, `udev.service`, `ssh.service`), whatever
    directories it sets. A directory that already exists on the host is
    refused unless the add-on recorded it when the unit's own start, in an
    earlier apply, created it, and it is still that same directory (the
    same device, inode and birth time; on a file system that reports no
    birth time it is always refused); who owns it does not matter. The
    instances of a template share their directories. A directory that
    was absent when an apply checked the unit and exists once the apply
    has started its units is recorded as the unit's, whether the apply
    started the unit by name, a dependency pulled it in, or its socket's
    start made the directory. When the unit is restarted or activated
    between applies, systemd removes such a directory and makes it again;
    the next apply accepts it only if it is exactly one of the unit's
    directories, systemd reports a different run of the unit than the one
    recorded, and the directory was born no earlier than 100 ms before
    that run's reported start (systemd 252 makes it a few milliseconds
    before it records the start) and no later than 250 ms after the
    start of that run's main process (a tree made later in the run, by
    the unit or by anything else, is not the one systemd made for it); for
    a unit that is not running, it must also have been born before that
    run ended. A template's directory is
    judged by the instances that can have run: the one recorded, any that
    systemd reports running, and any the profile names. Every instance of
    the template reaches the same verdict. The apply records such a
    directory again once, after it has checked every instance, and only
    if none of them refused it, so a refused apply leaves the record as it
    was. The apply logs each such acceptance
    in the generation's audit log (if the log cannot be written, the
    directory is refused). A tree a root process makes at the path
    within those 100 ms before a start, or within 250 ms after its main
    process starts, is taken as the unit's. On a host
    upgraded from an add-on version that kept no such record, the first
    apply records, once, the directories the installed services exactly
    declare and the existing sockets of their socket units, and logs each
    one. A directory first created outside an apply (the unit's first
    start by its timer, or by hand) is refused at the next apply, and so
    is one another package installs. If an apply is refused and goes
    back to the previous generation, the step back is not refused for
    such a directory: the unit it refuses stays stopped, held from
    starting, until a later apply finds nothing to refuse, and the hold
    is logged. The hold is a file,
    `/etc/systemd/system/<unit>.d/zz-repro-addon-revert-hold.conf`, so it
    holds across a reboot too. The add-on counts as its own hold only a
    file of that name holding exactly the text it writes, on a unit the
    add-on installs: a file of that name with anything else in it is
    judged like any other drop-in, and no apply removes or overwrites it.
    If the hold cannot be written (a full or read-only `/etc`, an
    immutable directory), the unit keeps the hold the switch put in
    `/run`, the step back is not completed, and the host stays pending
    until the hold can be written and you run
    `repro system addon recover`.
  - **a unit that only a timer or a path unit starts** never has its
    directories recorded by an apply, because no apply starts it. After
    the first run its timer starts, the next apply refuses the unit's
    directories (none was recorded), and the step back holds the unit,
    so its timer no longer runs it, until you act. A directory that is
    kept between runs (`StateDirectory=`, `CacheDirectory=`,
    `LogsDirectory=`) and that any run but the last made again is
    refused from then on, whatever later runs do. To recover: stop the
    timer or path unit, save what the unit's directories hold if you
    need it, remove the directories, and apply a profile in which the
    apply starts the unit once -- enable it (`[Install]` with
    `WantedBy=` and `enabled = true`) or pull it in with `Wants=` from a
    unit the apply starts. The apply then records the directories that
    start makes, and later runs of the timer reuse them.
    The list of base-system directory names was measured on the amd64
    Debian 12 and 13 and Ubuntu 24.04 and 26.04 test images; on other
    bases, such as Raspberry Pi OS, only the existence check applies;
  - a unix socket of such a unit must be `/run/foo` or below `/run/foo/`,
    named after the service the socket starts (`foo.service`) whatever
    the socket is called; deeper than `/run/foo/<name>` (for example
    `/run/foo/sub/control`), it is refused when the service, or any
    other unit named `foo` -- a template `foo@.service` and its
    instances, the profile's or the host's, and their drop-ins -- can
    write a directory on its path (a `RuntimeDirectory=foo`, a
    `ReadWritePaths=`), since that unit's account could turn the
    directory into a link the service manager then follows; the paths
    are compared as the kernel resolves them, so `ReadWritePaths=/var/run/foo`
    covers `/run/foo/sub/control`; a socket or timer named
    after a directory the base system has (`udev.socket`,
    `systemd.socket`) is refused, and so is a socket path that already
    exists, that this socket did not create, or whose identity cannot be
    read;
  - realtime scheduling, a reboot `FailureAction=`, or a resource limit
    above the service manager's default;
  - a dependency such as `OnFailure=` or `Wants=` that starts a unit
    which changes the whole system's state, such as `reboot.target`,
    `poweroff.target`, `shutdown.target`, `suspend.target` or
    `emergency.target`, whether directly or through other units. An
    `OnFailureJobMode=` other than `replace` or `fail`, and
    `AllowIsolate=yes`, are refused too;
  - a `Conflicts=` naming a unit the profile does not define, on the
    unit or on any unit of the profile it starts. Starting it would stop
    the named unit, whether a base target such as `multi-user.target` or
    another package's service. An exclusive successor that must stop a
    predecessor the profile does not define needs the whole-floor waiver;
  - a credential (`LoadCredential=`) read from outside the add-on's own
    secrets directory for the service, and any `ImportCredential=`,
    `NFTSet=` or `RootImageOptions=`. `systemctl show` does not print
    these settings, so the add-on reads them from the unit files systemd
    loaded;
  - a property that is missing from `systemctl show`. Every entry of a
    property that systemd prints on several lines is checked.

  The service's account is the one systemd will use. Specifiers such as
  `%u` and `%i` are expanded first. With `DynamicUser=yes`, an existing
  account of the configured name is used, along with its groups. A second
  account name for uid 0 counts as root. An account or group that cannot
  be resolved is refused.

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

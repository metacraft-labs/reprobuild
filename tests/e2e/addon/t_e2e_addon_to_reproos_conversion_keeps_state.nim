## Gate ``e2e_addon_to_reproos_conversion_keeps_state`` (milestone A13;
## ReproOS Add-On Mode §11.1, §13 decisions 32 and 41).
##
## The conversion of an add-on host, rehearsed by reinstall (decision 41):
## ReproOS Anywhere installs only its fixture payload until it is qualified,
## so the gate converts the way Anywhere would have the host end up -- a
## fresh install of the same stock base on a new root disk, the activities
## realised in full by the engine (decision 32), the state carried over --
## without exercising Anywhere's own protocol.
##
## The fixture host runs the reference activities (``reference_services``:
## ``vaultwarden`` and ``ethereum_validator``, the converged forms of the
## services A13 adopts) on an add-on guest, driven by the deploy agent,
## with the state set the fixture profile declares:
##
## - ``keep:/var/lib/vaultwarden``: a second disk, mounted there by the
##   operator's own ``/etc/fstab`` line; the conversion keeps the disk;
## - ``carry:`` the execution client's, the beacon node's and the
##   validator's directories (the validator's holds its slashing-protection
##   database and its wallet).
##
## The rehearsal:
##
## 1. On the add-on guest, once the validators have signed (the chain
##    justified, or its head moved four epochs), the operator stops the
##    set's units and runs ``repro system addon state backup``. Every unit
##    of the set is then held: an operator's ``systemctl start`` of the
##    validator fails, the deploy agent's next tick is refused (nothing is
##    applied under a hold), and after a reboot of the add-on guest the
##    hold is still there. ``state verify --source`` against the manifest
##    passes immediately before the "conversion" (it also checks every
##    hold is loaded); the guest is powered off and its root disk
##    discarded.
## 2. A new guest boots a fresh overlay of the same stock image with the
##    kept disk attached, mounts it as the old host did, gets the engine
##    and the carried directory (``/var/lib/repro/system/carried``), and is
##    re-identified as ReproOS for the engine's commands only (decision
##    32). ``repro infra apply`` and ``repro system sync`` before the
##    restore are each refused with ``ECarriedStatePending`` and write no
##    unit (the validator cannot start on an empty directory).
## 3. The first-boot unit (``repro system state unit``) is installed and
##    the guest rebooted: the unit restores the carried directories before
##    ``sysinit.target``, and ``state verify`` finds every directory --
##    carried and kept -- at the manifest's digest.
## 4. The full apply realises the activities; every unit passes its health
##    check, and the beacon node resumes on the add-on host's chain (its
##    carried database), not at genesis.
## 5. The validator never ran between backup and restore: on the add-on
##    guest no validator start after the backup; on the new guest its first
##    start is after the restore unit finished (the same boot's monotonic
##    clock). It signs again: its slashing-protection history, exported as
##    EIP-3076, holds every key's history from the epochs it signed on the
##    add-on host *and* attestations whose target is past the epoch the
##    restore ran in, with no conflicting signature.
## 6. The kept disk is required: with it missing (its fstab line naming a
##    disk that does not exist, ``nofail``), vaultwarden does not start and
##    writes nothing on the root file system (``RequiresMountsFor=``).
##
## Falsifying mutations:
## - add-on build ``state-units-not-held`` (the backup holds nothing): the
##   operator's start of the validator after the backup succeeds; red;
## - add-on build ``hold-runtime-only`` (the hold in ``/run``): after the
##   reboot the validator starts; red;
## - engine build ``apply-ignores-carried-state``: the apply and the sync
##   before the restore go ahead; red;
## - engine build ``keep-without-mount-requirement``: vaultwarden starts
##   with its kept disk missing; red;
## - ``REPRO_A13_MUTATION=carried-archive-tampered`` (one byte of the
##   validator's archive changed in transit): the restore unit refuses it;
##   red;
## - ``REPRO_A13_MUTATION=rev-execution-dropped`` (the restored execution
##   client's directory emptied before the apply): the node cannot extend
##   its carried chain and the validator signs nothing new; red at the
##   post-conversion signing check;
## - ``REPRO_A13_MUTATION=rev-beacon-dropped`` (the beacon directory
##   emptied): the node starts at genesis; red;
## - ``REPRO_A13_MUTATION=rev-slashing-db-reset`` (``validator.db``
##   deleted): the carried history is gone; red (either at the history
##   step, or earlier when prysm's doppelganger check finds the keys live
##   and refuses to start);
## - ``REPRO_A13_MUTATION=rev-slashing-db-reset-no-doppelganger`` (the same,
##   with the doppelganger check off in the profile): the validator signs on
##   an empty history; red at the history step, the history beginning after
##   the add-on host's epoch on a chain that progressed
##   (``historyEvidence``);
## - ``REPRO_A13_MUTATION=rev-inode-reuse`` (the restored validator directory
##   replaced in place by an empty one; ext4 usually hands it the freed
##   inode): the apply refuses with ``ECarriedStatePending``; red there;
## - engine build ``restore-not-required-by-units``: at the boot after the
##   restored validator directory is replaced and the archives damaged, the
##   validator starts although the restore failed; red.
## - engine build ``restore-unordered`` with seams (no ordering on the
##   restore): the execution client, without default dependencies, starts
##   while the restore is held at its seam, not waiting on its start job;
##   red at the ordering step;
## - engine build ``restore-required-by-link`` (round 2's ``.requires/``
##   link): the disable and preset of the restore unit remove it, and the
##   validator starts; red at the same step;
## - engine build ``carried-reach-by-unit-name``: the renamed unit that
##   reaches the carried directory only by its path is applied before the
##   restore; red at the path-reach step.
##
## The last check (after the kept disk's): the boot path is governed by the
## restore. The restore unit is installed with ``repro system state
## install-unit``, which makes every carried unit require it; with the
## validator's directory replaced and the archives damaged, the next boot's
## restore fails and the validator does not start.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``, ``REPRO_ADDON_ENGINE_CLOSURE`` (the
## full engine built from this tree) and ``REPRO_A12_PACKAGES``. Bases:
## ``REPRO_ADDON_BASES`` (amd64).
##
## *Mocking.* None: real images, real disks, real packages, a real chain,
## the real agent and engine. What is not real is said above: the
## conversion is a reinstall, and ReproOS is the engine's full realisation
## on a re-identified guest.

import std/[json, os, sequtils, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/generation0
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support
import ./reference_services
import ./validator_safety

const
  Gate = "e2e_addon_to_reproos_conversion_keeps_state"
  ReidentifiedOsRelease = "/etc/repro-testbed/os-release-reproos"
  ReidentifyPrefix = "unshare --mount -- sh -c 'mount --bind " &
    ReidentifiedOsRelease & " /etc/os-release && exec \"$@\"' sh "
    ## As the parity gate (decision 32): the engine is shown a ReproOS base
    ## in its own mount namespace only.
  RefDir = "/root/reference-services"
  KeepDir = "/var/lib/vaultwarden"
  KeepFstab = "LABEL=repro-keep " & KeepDir & " ext4 defaults,nofail 0 2"
  CarriedDir = "/var/lib/repro/system/carried"
  SetUnits = ["vaultwarden.service", "eth-execution.service",
              "eth-beacon.service", DefaultValidatorUnit]
  RestoreUnit = "repro-state-restore.service"
  PathReachProfile = """import repro_profile

profile "pathReach":
  activity vaultwarden:
    resources:
      fsSystemFile(path = "/etc/a13-path-reach/marker", content = "x\n",
        address = "pathReachMarker")
  activity ethereum_validator:
    resources:
      systemdSystemUnit(name = "eth-validator-renamed.service",
        content = "[Unit]\nDescription=A13 path-reach probe\n\n[Service]\n" &
          "User=eth-validator\nGroup=eth-validator\n" &
          "ReadWritePaths=/var/lib/ethereum/validator\n" &
          "ExecStart=/bin/true\n",
        hardening = "serviceFloor",
        floorExceptions = @["NoExecPaths: the conversion gate's path-reach " &
          "probe runs /bin/true"],
        address = "pathReachRenamed")
      linuxSysusersEntry(name = "eth-validator", kind = "user", id = "924",
        address = "pathReachUser")
"""
    ## The profile of the path-reach step: the host's two activities, and in
    ## the validator's one unit that touches the carried directory by path
    ## only.
  # The chain clients' lines that say where each resumed and whether they
  # agree on the head: geth's loaded and repaired heads and its fork-choice
  # refusals, prysm's start head and its errors.
  ChainLogPattern = "Loaded most recent|repairing|Rewound|Rewinding|" &
    "Ignoring beacon update|Skipping beacon update|Refusing too deep|" &
    "Blockchain stopped|Persisted|Writing cached state|Using Head root|" &
    "starting with justified|Synced new block|level=error|ERROR|WARN"

type MutationStop = object of CatchableError
  ## Raised by a gate's step under a mutation once a step is red.

proc gateMutation(): string = getEnv("REPRO_A13_MUTATION")

proc stopAtRed(): bool =
  ## A falsifier cell of an engine build (its mutation is in the engine,
  ## not in ``REPRO_ADDON_MUTATION``): its first red step is the verdict.
  getEnv("REPRO_A13_STOP_AT_RED") == "1"

proc probeFile(label: string): string =
  ## The file a round-4 probe profile is written to. The engine compiles a
  ## profile as a Nim module, whose name must be an identifier
  ## (https://nim-lang.org/docs/manual.html#modules); a name that is not
  ## would fail to compile and could pass for a refusal, so it is refused
  ## here, before any VM work.
  result = "r4_" & label & ".nim"
  let stem = result[0 ..< result.len - 4]
  if stem.len == 0 or stem[0] notin IdentStartChars or
      not stem.allCharsInSet(IdentChars):
    raise newException(ValueError, "probe profile " & result &
      " is not a valid Nim module name")

proc judged(output: string): bool =
  ## Whether an apply got as far as being judged: its profile compiled, so
  ## its result -- applied, or refused for a reason -- is the engine's
  ## decision rather than a compile error.
  "profile compilation failed" notin output and
    "nim compile failed" notin output

const ProbeMarkerDir = "/var/lib/a13-r5"
  ## Where a round-5/6 probe unit's ``ExecStart=`` writes its uid
  ## (``<unit>.ran``) when it runs: evidence, read from the guest, that a
  ## probe a falsifier let in really ran (a ``Type=simple`` unit reports its
  ## start done before it can fail). Mode 1777: any probe account may write.

proc r5Unit(name, body, address: string; install = ""): string =
  ## A round-5 probe unit without the floor: its own ``[Service]`` lines
  ## ``body`` (newline-separated), writing nowhere near the carried state;
  ## ``install`` is extra ``[Install]`` text, in the DSL's escaped form.
  "      systemdSystemUnit(name = \"" & name & "\",\n" &
    "        content = \"[Unit]\\nDescription=A13 round-5 probe\\n\\n" &
    "[Service]\\n" & body.replace("\n", "\\n") &
    "ReadWritePaths=/var/lib/a13-r5\\nExecStart=/bin/sh -c 'id -u > " &
    ProbeMarkerDir & "/" & name & ".ran'\\n" & install &
    "\",\n        address = \"" & address & "\")\n"

proc probeProfile(name, resources: string): string =
  ## A profile of the host's two activities whose validator activity is
  ## ``resources`` (lines indented for it): one reach case of A13's
  ## review round 4, applied while the carried directory is pending.
  "import repro_profile\n\nprofile \"" & name & "\":\n" &
    "  activity vaultwarden:\n    resources:\n" &
    "      fsSystemFile(path = \"/etc/a13-path-reach/marker\", content = \"x\\n\",\n" &
    "        address = \"" & name & "Marker\")\n" &
    "  activity ethereum_validator:\n    resources:\n" &
    "      linuxSysusersEntry(name = \"eth-validator\", kind = \"user\", id = \"924\",\n" &
    "        address = \"" & name & "User\")\n" & resources

const
  R4MarkerDir = "/var/lib/a13-r4"
    ## Where a round-4 probe unit writes its uid (``<unit>.ran``, through
    ## systemd's ``%n``) when it runs: the evidence that a probe let in ran
    ## (A13 review round 7, finding 4; the round-5/6 probes' marker).
  R4Run = "ExecStart=/bin/sh -c 'id -u > " & R4MarkerDir & "/%n.ran'\\n"
  R4Confined = "[Unit]\\nDescription=A13 round-4 probe\\n\\n[Service]\\n" &
    "User=eth-validator\\nGroup=eth-validator\\n" &
    "ReadWritePaths=/var/lib/a13-r4\\n" & R4Run
    ## A confined, non-root service elsewhere (with the floor's
    ## ProtectSystem=strict): let in while the directory is pending.
  R4ConfinedUnfloored = "[Unit]\\nDescription=A13 round-4 probe\\n\\n" &
    "[Service]\\nProtectSystem=strict\\nNoNewPrivileges=yes\\n" &
    "User=eth-validator\\nGroup=eth-validator\\n" &
    "ReadWritePaths=/var/lib/a13-r4\\n" & R4Run
    ## The same confinement written out, without the floor: only the
    ## carried-state reach analysis judges what activates it. With
    ## ``NoNewPrivileges=yes``, which round 5 made part of confinement:
    ## without it the unit is refused for that rule whatever reach says, so
    ## the falsifier of the path unit's reach would let in nothing that
    ## runs (A13 review round 7).
  R4UidAlias = "a13r4uid0"
    ## The account probe's ``User=``: a second name for uid 0, which the gate
    ## adds to ``/etc/passwd`` for that probe only. systemd runs
    ## ``DynamicUser=yes`` with an existing static account as that account
    ## (systemd.exec(5), ``DynamicUser=``; measured as a premise), so the
    ## unit runs as root. Not ``User=root``: under ``account-as-written``
    ## that unit is let past the account rule but refused by decision 58's,
    ## the D-Bus system policy's ``<policy user="root">`` naming its
    ## account, so it never runs and the falsifier's red is not its own
    ## (A13 review round 7). An alias is what the account resolution alone
    ## sees through: round 3's reading takes it as a dynamic user.
  R4UidAliasAdd = "grep -q '^" & R4UidAlias & ":' /etc/passwd || echo '" &
    R4UidAlias & ":x:0:0:A13 uid-0 alias:/root:/usr/sbin/nologin' >> /etc/passwd"
  R4UidAliasRemove = "sed -i '/^" & R4UidAlias & ":/d' /etc/passwd"
  R4Floor = "        hardening = \"serviceFloor\",\n" &
    "        floorExceptions = @[\"NoExecPaths: the conversion gate's " &
    "round-4 probe runs /bin/sh\"],\n"
  R4Probes = [
    ("account", "r4Account",
     "      systemdSystemUnit(name = \"eth-r4-account.service\",\n" &
     "        content = \"[Unit]\\nDescription=A13 round-4 account probe\\n\\n" &
     "[Service]\\nDynamicUser=yes\\nUser=" & R4UidAlias & "\\nNoNewPrivileges=yes\\n" &
     "ReadWritePaths=/var/lib/a13-r4\\n" &
     R4Run & "\",\n        address = \"r4Account\")\n",
     "runs as root (" & R4UidAlias & ")", "reach"),
    ("timer", "r4Timer",
     "      systemdSystemUnit(name = \"eth-r4-timed.service\",\n" &
     "        content = \"" & R4Confined & "\",\n" & R4Floor &
     "        address = \"r4Timed\")\n" &
     "      systemdSystemTimer(name = \"eth-r4.timer\",\n" &
     "        content = \"[Timer]\\nOnActiveSec=1d\\nUnit=eth-r4-timed.service\\n\",\n" &
     "        address = \"r4Timer\")\n" &
     "      systemdSystemDropIn(unit = \"eth-r4.timer\", name = \"retarget\",\n" &
     "        content = \"[Timer]\\nUnit=apt-daily.service\\n\",\n" &
     "        address = \"r4TimerDropIn\")\n",
     "apt-daily.service", "reach"),
    ("pathfloored", "r4PathFloored",
     "      systemdSystemUnit(name = \"eth-r4-timed.service\",\n" &
     "        content = \"" & R4Confined & "\",\n" & R4Floor &
     "        address = \"r4Timed\")\n" &
     "      systemdSystemUnit(name = \"eth-r4-watch.path\",\n" &
     "        content = \"[Path]\\nDirectoryNotEmpty=/var/lib/ethereum/validator/spool\\n" &
     "MakeDirectory=yes\\nUnit=eth-r4-timed.service\\n\",\n" &
     "        address = \"r4PathFloored\")\n",
     "activates a floored service", "floor"),
    ("path", "r4Path",
     "      systemdSystemUnit(name = \"eth-r4-watched.service\",\n" &
     "        content = \"" & R4ConfinedUnfloored & "\",\n" &
     "        address = \"r4Watched\")\n" &
     "      systemdSystemUnit(name = \"eth-r4-watch.path\",\n" &
     "        content = \"[Path]\\nDirectoryNotEmpty=/var/lib/ethereum/validator/spool\\n" &
     "MakeDirectory=yes\\nUnit=eth-r4-watched.service\\n\",\n" &
     "        address = \"r4Path\")\n",
     "/var/lib/ethereum/validator (r4Path)", "reach")]
    ## (case, the resource the refusal must name, its lines, a fragment of
    ## the reason, the layer that refuses it). A ``reach`` case is refused
    ## by the carried-state check (``ECarriedStatePending``) and let in by
    ## the engine build of its finding: ``account-as-written``,
    ## ``reach-timer-dropins-unread``, ``reach-path-unit-paths-ignored``. The
    ## ``floor`` case is the same path unit activating a floored service,
    ## which the hardening floor refuses first, at parse time, whatever
    ## reach says: defence in depth, so a change that drops either layer
    ## turns a step red. It runs before the reach case, so the path
    ## falsifier shows the floor still refusing and the reach step red.
    ## The unfloored units set ``NoNewPrivileges=yes`` themselves (the
    ## floor sets it for the others), so each ``reach`` case's falsifier is
    ## the only guard between its probe and a run.
  R4Host = "      systemdSystemUnit(name = \"eth-r4-host.service\",\n" &
    "        content = \"" & R4Confined & "\",\n" & R4Floor &
    "        address = \"r4Host\")\n"
  R4HostDropIn = "/run/systemd/system/eth-r4-host.service.d/10-foreign.conf"
  R5Probes = [
    ("values", "r5Values",
     r5Unit("eth-r5-values.service", "ProtectSystem=Strict\nNoNewPrivileges=yes\n" &
       "User=eth-validator\nGroup=eth-validator\n", "r5Values"),
     "not confined (no ProtectSystem=strict", "", ""),
    ("alias", "r5Alias",
     r5Unit("eth-r5-alias.service", "ProtectSystem=strict\nNoNewPrivileges=yes\n" &
       "User=eth-validator\nGroup=eth-validator\n", "r5Alias",
       "\\n[Install]\\nWantedBy=multi-user.target\\nAlias=eth-r5-aliased.service\\n"),
     "runs as root (root)",
     "mkdir -p /run/systemd/system/eth-r5-aliased.service.d && printf " &
       "'[Service]\\nUser=root\\n' > /run/systemd/system/" &
       "eth-r5-aliased.service.d/10-root.conf && systemctl daemon-reload",
     "rm -rf /run/systemd/system/eth-r5-aliased.service.d && systemctl daemon-reload"),
    ("group", "r5Group",
     r5Unit("eth-r5-group.service", "ProtectSystem=strict\nNoNewPrivileges=yes\n" &
       "User=eth-validator\nGroup=disk\n", "r5Group"),
     "holds the privileged group disk", "", ""),
    ("nnp", "r5Nnp",
     r5Unit("eth-r5-nnp.service", "ProtectSystem=strict\n" &
       "User=eth-validator\nGroup=eth-validator\n", "r5Nnp"),
     "NoNewPrivileges= is not yes", "", ""),
    ("userdb", "r5Userdb",
     r5Unit("eth-r5-userdb.service", "DynamicUser=yes\nNoNewPrivileges=yes\n" &
       "User=a13r5ops\n", "r5Userdb"),
     "runs as root (a13r5ops)",
     "mkdir -p /etc/userdb && printf '{\"userName\":\"a13r5ops\",\"uid\":0," &
       "\"gid\":0,\"disposition\":\"system\"}\\n' > /etc/userdb/a13r5ops.user",
     "rm -f /etc/userdb/a13r5ops.user"),
    ("prefix", "r5Prefix",
     r5Unit("root@r5.service", "DynamicUser=yes\nNoNewPrivileges=yes\n", "r5Prefix"),
     "runs as root (root)", "", "")]
    ## Round 5 (A13 review): (case, the resource the refusal must name, its
    ## lines, a fragment of the reason, host set-up, clean-up). Each is a
    ## service without the floor, so only the reach analysis judges it, and
    ## each is let in by the engine build of its finding:
    ## ``reach-values-as-text`` (systemd ignores ``ProtectSystem=Strict``),
    ## ``reach-alias-dropins-unread`` (a drop-in under the ``Alias=`` name),
    ## ``confined-without-nnp-or-groups`` (a privileged primary group; no
    ## ``NoNewPrivileges=yes``), ``account-nss-unread`` (a userdb record of
    ## uid 0 under ``DynamicUser=yes``), ``account-dynamic-name-from-stem``
    ## (an instance of ``root@.service`` under ``DynamicUser=yes``).
    ##
    ## The values, alias and prefix probes are each also refused by the full
    ## apply's live cross-check (§13 decision 59): systemd loads each unit
    ## unconfined, and that check judges the unit as systemd loaded it,
    ## through readings the three builds above leave intact. Under those
    ## builds the probe is let in by the static analysis and then held by
    ## the live check, so it never runs and the red is not its own (A13
    ## review round 7). Their falsifiers are therefore the engine builds
    ## ``reach-values-as-text-without-live-check``,
    ## ``reach-alias-dropins-unread-without-live-check`` and
    ## ``account-dynamic-name-from-stem-without-live-check``: the same
    ## reading broken, and the live check off as in
    ## ``infra-live-reach-skipped``. That build's own cell is the other half
    ## of the pair: with the live check off and the static readings intact,
    ## all three probes are refused for their reasons
    ## (``scripts/addon_a13_classify.py`` requires both).
  R6Confined = "ProtectSystem=strict\nNoNewPrivileges=yes\n" &
    "User=eth-validator\nGroup=eth-validator\n"
  R6Probes = [
    ("lines", r5Unit("eth-r6-lines.service", R6Confined, "r6Lines"),
     "/var/lib/ethereum/validator (r6Lines)",
     "mkdir -p /run/systemd/system/eth-r6-lines.service.d && printf " &
       "'[Service]\\nEnvironment=X=a\\\\\\\\\\n" &
       "ReadWritePaths=-/var/lib/ethereum/validator\\n' > " &
       "/run/systemd/system/eth-r6-lines.service.d/10-env.conf",
     "rm -rf /run/systemd/system/eth-r6-lines.service.d"),
    ("exec", r5Unit("eth-r6-exec.service", R6Confined &
       "ExecStartPre=/bin/true ; +/bin/sh -c 'id -u > " & ProbeMarkerDir &
       "/eth-r6-exec.service.priv'\n", "r6Exec"),
     "a privileged command", "", ""),
    ("aliaschain", r5Unit("eth-r6-chain.service", R6Confined, "r6Chain"),
     "/var/lib/ethereum/validator (r6Chain)",
     "ln -sf /etc/systemd/system/eth-r6-chain.service " &
       "/etc/systemd/system/eth-r6-l1.service && ln -sf " &
       "/etc/systemd/system/eth-r6-l1.service /etc/systemd/system/eth-r6-l2.service" &
       " && mkdir -p /run/systemd/system/eth-r6-l2.service.d && printf " &
       "'[Service]\\nReadWritePaths=-/var/lib/ethereum/validator\\n' > " &
       "/run/systemd/system/eth-r6-l2.service.d/10-rw.conf",
     "rm -rf /etc/systemd/system/eth-r6-l1.service /etc/systemd/system/eth-r6-l2.service " &
       "/run/systemd/system/eth-r6-l2.service.d"),
    ("wantslink", r5Unit("eth-r6-wants.service", R6Confined, "r6Wants"),
     "it starts a13r6-dist5.service",
     "mkdir -p /etc/systemd/system/eth-r6-wants.service.wants && ln -sf " &
       "/usr/lib/systemd/system/a13r6-dist5.service " &
       "/etc/systemd/system/eth-r6-wants.service.wants/a13r6-dist5.service",
     "rm -rf /etc/systemd/system/eth-r6-wants.service.wants"),
    ("reserved", r5Unit("eth-r6-name.service", R6Confined, "r6Name") &
       "      systemdSystemDropIn(unit = \"eth-r6-name.service\", " &
       "name = \"state-restore\",\n        content = \"[Unit]\\nDescription=x\\n\", " &
       "address = \"r6NameDropIn\")\n",
     "reserved for the carried-state restore requirement", "", ""),
    ("polkit", r5Unit("eth-r6-polkit.service", R6Confined, "r6Polkit"),
     "a privileged daemon may act for its account",
     "mkdir -p /etc/polkit-1/rules.d && printf 'polkit.addRule(function(" &
       "action, subject) {\\n  if (subject.user == \"eth-validator\") " &
       "{ return polkit.Result.YES; }\\n});\\n' > /etc/polkit-1/rules.d/50-a13r6.rules",
     "rm -f /etc/polkit-1/rules.d/50-a13r6.rules"),
    ("live", r5Unit("eth-r6-gen.service", R6Confined, "r6Gen"),
     "eth-r6-gen.service as systemd loaded it is not confined",
     "mkdir -p /etc/systemd/system-generators && printf '#!/bin/sh\\n" &
       "mkdir -p \"$1/eth-r6-gen.service.d\"\\nprintf \"[Service]\\\\nUser=root\\\\n\" " &
       "> \"$1/eth-r6-gen.service.d/10-root.conf\"\\n' > " &
       "/etc/systemd/system-generators/a13r6-gen && chmod 755 " &
       "/etc/systemd/system-generators/a13r6-gen",
     "rm -f /etc/systemd/system-generators/a13r6-gen && rm -rf " &
       "/etc/systemd/system/eth-r6-gen.service.d && systemctl daemon-reload"),
    ("liverw", r5Unit("eth-r6-genrw.service", R6Confined, "r6GenRw"),
     "decided again after the reload",
     "mkdir -p /etc/systemd/system-generators && printf '#!/bin/sh\\n" &
       "mkdir -p \"$1/eth-r6-genrw.service.d\"\\nprintf \"[Service]\\\\n" &
       "ReadWritePaths=-/var/lib/ethereum/validator\\\\n\" " &
       "> \"$1/eth-r6-genrw.service.d/10-rw.conf\"\\n' > " &
       "/etc/systemd/system-generators/a13r6-genrw && chmod 755 " &
       "/etc/systemd/system-generators/a13r6-genrw",
     "rm -f /etc/systemd/system-generators/a13r6-genrw && rm -rf " &
       "/etc/systemd/system/eth-r6-genrw.service.d && systemctl daemon-reload")]
    ## Round 6 (A13 review) and owner decisions 58 and 59: (case, its lines,
    ## a fragment the refusal must hold, host set-up, clean-up), each applied
    ## while the carried directory is pending and refused, each let in by
    ## the engine build of its finding: ``unit-lines-continue-as-text`` (a
    ## line ending in ``\\`` continues no line), ``exec-first-command-only``
    ## (a privileged second command), ``alias-chain-first-link-only`` (the
    ## drop-ins of an alias of an alias), ``dependency-links-unread`` (a host
    ## ``.wants/`` link), ``requirement-name-not-reserved``,
    ## ``privileged-daemons-unread`` (a polkit rule granting the account),
    ## and ``infra-live-reach-skipped`` (a generator, installed without a
    ## reload, makes the unit root from the apply's own reload on: only the
    ## live cross-check sees it; the unit must never start).
  R6DistA = "a13r6-dista.service"
  R6DistB = "a13r6-distb.service"
  R6DistB_DropIn = "/etc/systemd/system/a13r6-distb.service.d/50-repro-state-restore.conf"
  R6Dist7 = "a13r6-dist7.service"
  R6Dist7_DropIn = "/etc/systemd/system/a13r6-dist7.service.d/50-repro-state-restore.conf"
  R6Resources = """
      # A13 owner decision 60: a profile unit that wants a distribution-like
      # unit, which wants another; the second is started only through the
      # first's dependencies.
      systemdSystemUnit(name = "eth-r6-closure.service",
        content = unitText("A13 round-6 probe: wants a distribution unit",
          "User=eth-validator\nGroup=eth-validator\n" &
          "ReadWritePaths=/var/lib/a13-r6\nExecStart=/bin/sleep infinity\n",
          after = "a13r6-dista.service"),
        hardening = "serviceFloor",
        floorExceptions = @["NoExecPaths: the conversion gate's round-6 " &
          "probe runs /bin/sleep"],
        address = "r6Closure")
      # A13 review round 6, finding 4 (R7-7): a profile unit a host
      # .wants/ link makes start a unit the profile does not define.
      systemdSystemUnit(name = "eth-r6-linked.service",
        content = unitText("A13 round-6 probe: a host .wants/ link",
          "User=eth-validator\nGroup=eth-validator\n" &
          "ReadWritePaths=/var/lib/a13-r6\nExecStart=/bin/sleep infinity\n"),
        hardening = "serviceFloor",
        floorExceptions = @["NoExecPaths: the conversion gate's round-6 " &
          "probe runs /bin/sleep"],
        address = "r6Linked")"""
  R7MarkerDir = "/var/lib/a13-r7"
    ## Where the decision-79 probe services write their uid when they run.
  R7TargetSvc = "eth-r7-tsvc.service"
  R7SocketSvc = "eth-r7-ssvc.service"
  R7Socket = "eth-r7-sock.socket"
  R7Timer = "eth-r7-tmr.timer"
  R7TimerSvc = "eth-r7-tmsvc.service"
  R7Resources = """
      # A13 owner decision 79: confined static services (not enabled, no
      # [Install]) that only another unit's start pulls in -- an enabled
      # target's Wants=, an enabled socket's Wants= -- held by the full
      # apply's carried-state check while the drivers start that unit, and
      # brought up after the check by the start job issued again. The
      # socket is declared BEFORE the service it names, on purpose: the
      # planner orders a trigger unit after the unit it triggers, so the
      # natural order must apply (a regression guard for that ordering).
      systemdSystemUnit(name = "eth-r7-tgt.target",
        content = "[Unit]\nDescription=A13 decision-79 probe: a target\n" &
          "Wants=eth-r7-tsvc.service\n\n[Install]\nWantedBy=multi-user.target\n",
        address = "r7Target")
      systemdSystemUnit(name = "eth-r7-tsvc.service",
        content = "[Unit]\nDescription=A13 decision-79 probe: pulled in by a " &
          "target\n\n[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\n" &
          "User=eth-validator\nGroup=eth-validator\nReadWritePaths=/var/lib/a13-r7\n" &
          "ExecStart=/bin/sh -c 'id -u > /var/lib/a13-r7/%n.ran; exec /bin/sleep infinity'\n",
        enabled = false,
        address = "r7TargetSvc")
      systemdSystemUnit(name = "eth-r7-sock.socket",
        content = "[Unit]\nDescription=A13 decision-79 probe: a socket\n" &
          "Wants=eth-r7-ssvc.service\n\n[Socket]\nListenStream=/run/eth-r7.sock\n" &
          "Service=eth-r7-ssvc.service\n\n[Install]\nWantedBy=sockets.target\n",
        address = "r7Socket")
      systemdSystemUnit(name = "eth-r7-ssvc.service",
        content = "[Unit]\nDescription=A13 decision-79 probe: pulled in by a " &
          "socket\n\n[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\n" &
          "User=eth-validator\nGroup=eth-validator\nReadWritePaths=/var/lib/a13-r7\n" &
          "ExecStart=/bin/sh -c 'id -u > /var/lib/a13-r7/%n.ran; exec /bin/sleep infinity'\n",
        enabled = false,
        address = "r7SocketSvc")
      # §13 decision 137: a timer declared BEFORE the service it names, as
      # the socket above is. The planner applies a trigger after the unit
      # it triggers (systemd refuses to start a timer whose unit is not
      # loaded). Its service is judged by the live check, so decision 151
      # holds this timer too and starts it only after the check: that hold
      # orders it as well, and the engine build ``trigger-edges-omitted``
      # is green here (A13 review round 9, measured at reprobuild
      # 9e78a755bd). The R11 probes, which no hold orders, falsify it.
      systemdSystemUnit(name = "eth-r7-tmr.timer",
        content = "[Unit]\nDescription=A13 decision-137 probe: a timer " &
          "declared before its service\n\n[Timer]\nOnActiveSec=1s\n" &
          "Unit=eth-r7-tmsvc.service\n\n[Install]\nWantedBy=timers.target\n",
        address = "r7Timer")
      systemdSystemUnit(name = "eth-r7-tmsvc.service",
        content = "[Unit]\nDescription=A13 decision-137 probe: started by a " &
          "timer\n\n[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\n" &
          "User=eth-validator\nGroup=eth-validator\nReadWritePaths=/var/lib/a13-r7\n" &
          "ExecStart=/bin/sh -c 'id -u > /var/lib/a13-r7/%n.ran; exec /bin/sleep infinity'\n",
        enabled = false,
        address = "r7TimerSvc")"""
  R9MarkerDir = "/var/lib/a13-r9"
    ## Where the decision-135 template's instances write their uid.
  R9Instances = ["eth-r9-tpl@a.service", "eth-r9-tpl@b.service"]
  R9Resources = """
      # A13 owner decision 135: a confined template service (static, not
      # enabled) whose instances an enabled target pulls in. The full
      # apply's live check judges it through its observation instance and
      # its instances -- systemd refuses to show a template by name -- and
      # the instances come up after the check.
      systemdSystemUnit(name = "eth-r9-tpl@.service",
        content = "[Unit]\nDescription=A13 decision-135 probe: a confined " &
          "template\n\n[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\n" &
          "User=eth-validator\nGroup=eth-validator\nReadWritePaths=/var/lib/a13-r9\n" &
          "ExecStart=/bin/sh -c 'id -u > /var/lib/a13-r9/%n.ran; exec /bin/sleep infinity'\n",
        enabled = false,
        address = "r9Template")
      systemdSystemUnit(name = "eth-r9-tpl.target",
        content = "[Unit]\nDescription=A13 decision-135 probe: wants two " &
          "instances\nWants=eth-r9-tpl@a.service eth-r9-tpl@b.service\n\n" &
          "[Install]\nWantedBy=multi-user.target\n",
        address = "r9TemplateTarget")"""
  R10MarkerDir = "/var/lib/a13-r10"
    ## Where the decision-151 probes write their uid.
  R10Port = 18710
  R10Socket = "eth-r10-sock.socket"
  R10SocketSvc = "eth-r10-sock.service"
  R10Path = "eth-r10-path.path"
  R10PathSvc = "eth-r10-path.service"
  R10Job = "/var/lib/a13-r10/job"
  R10Resources = """
      # A13 owner decision 151: a socket (Accept=no) and a path unit whose
      # confined services are held by the full apply's live check. While an
      # apply holds them, a connection keeps arriving and the path exists;
      # the triggers are stopped and held with their services, and both
      # come back up and start their services once the check passes. Red
      # under the engine build ``triggers-left-running``: each trigger
      # fires at its held service until systemd's trigger rate limit fails
      # it for good.
      systemdSystemUnit(name = "eth-r10-sock.socket",
        content = "[Unit]\nDescription=A13 decision-151 probe: a socket\n\n" &
          "[Socket]\nListenStream=127.0.0.1:18710\n\n" &
          "[Install]\nWantedBy=sockets.target\n",
        address = "r10Socket")
      systemdSystemUnit(name = "eth-r10-sock.service",
        content = "[Unit]\nDescription=A13 decision-151 probe: socket-activated\n\n" &
          "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\n" &
          "User=eth-validator\nGroup=eth-validator\nReadWritePaths=/var/lib/a13-r10\n" &
          "ExecStart=/bin/sh -c 'id -u > /var/lib/a13-r10/%n.ran; exec /bin/sleep infinity'\n",
        enabled = false,
        address = "r10SocketSvc")
      systemdSystemUnit(name = "eth-r10-path.path",
        content = "[Unit]\nDescription=A13 decision-151 probe: a path unit\n\n" &
          "[Path]\nPathExists=/var/lib/a13-r10/job\n\n" &
          "[Install]\nWantedBy=paths.target\n",
        address = "r10Path")
      systemdSystemUnit(name = "eth-r10-path.service",
        content = "[Unit]\nDescription=A13 decision-151 probe: path-activated\n\n" &
          "[Service]\nType=oneshot\nRemainAfterExit=yes\nProtectSystem=strict\n" &
          "NoNewPrivileges=yes\nUser=eth-validator\nGroup=eth-validator\n" &
          "ReadWritePaths=/var/lib/a13-r10\n" &
          "ExecStart=/bin/sh -c 'id -u > /var/lib/a13-r10/%n.ran'\n",
        enabled = false,
        address = "r10PathSvc")"""
  R11MarkerDir = "/var/lib/a13-r11"
    ## Where the decision-137 unheld probes write their uid.
  R11Port = 18711
  R11Socket = "eth-r11-sock.socket"
  R11SocketSvc = "eth-r11-ssvc.service"
  R11Timer = "eth-r11-tmr.timer"
  R11TimerSvc = "eth-r11-tmsvc.service"
  R11Resources = """
      # A13 owner decision 137, on triggers no hold orders: a socket and a
      # timer, each declared BEFORE the service it triggers, whose services
      # are not confined (root, as a host's maintenance jobs are). The full
      # apply's live check judges only the services the static analysis
      # takes as confined (``liveReachUnits``: a unit that reaches
      # everything is refused or requires the restore instead), so neither
      # these services nor their triggers are held (decision 151 stops and
      # holds only the triggers of held units), and nothing but the
      # planner's trigger edges applies a trigger after its service. Only in
      # the next generation, applied after the restore. Red under the engine
      # build ``trigger-edges-omitted``: systemd refuses each trigger whose
      # service is not loaded yet.
      systemdSystemUnit(name = "eth-r11-sock.socket",
        content = "[Unit]\nDescription=A13 decision-137 probe: an unheld " &
          "socket declared before its service\n\n[Socket]\n" &
          "ListenStream=127.0.0.1:18711\nService=eth-r11-ssvc.service\n\n" &
          "[Install]\nWantedBy=sockets.target\n",
        address = "r11Socket")
      systemdSystemUnit(name = "eth-r11-ssvc.service",
        content = "[Unit]\nDescription=A13 decision-137 probe: an unconfined " &
          "socket-activated service\n\n[Service]\n" &
          "ExecStart=/bin/sh -c 'mkdir -p /var/lib/a13-r11; id -u > " &
          "/var/lib/a13-r11/%n.ran; exec /bin/sleep infinity'\n",
        enabled = false,
        address = "r11SocketSvc")
      systemdSystemUnit(name = "eth-r11-tmr.timer",
        content = "[Unit]\nDescription=A13 decision-137 probe: an unheld " &
          "timer declared before its service\n\n[Timer]\nOnActiveSec=1s\n" &
          "Unit=eth-r11-tmsvc.service\n\n[Install]\nWantedBy=timers.target\n",
        address = "r11Timer")
      systemdSystemUnit(name = "eth-r11-tmsvc.service",
        content = "[Unit]\nDescription=A13 decision-137 probe: an unconfined " &
          "timer-activated service\n\n[Service]\nType=oneshot\n" &
          "ExecStart=/bin/sh -c 'mkdir -p /var/lib/a13-r11; id -u > " &
          "/var/lib/a13-r11/%n.ran'\n",
        enabled = false,
        address = "r11TimerSvc")"""
  R12EssResource = """
      # Decision 177 (A13 review round 11): a drop-in that makes an
      # essential unit, a console getty, require a unit the live check
      # judges. The apply must be refused before it writes anything.
      systemdSystemDropIn(unit = "getty@tty6.service", name = "a13-ess",
        content = "[Unit]\nRequires=eth-r10-sock.service\nAfter=eth-r10-sock.service\n",
        address = "r12Ess")"""
  R13SshResource = """
      # A13 review round 13, M-C: a profile drop-in that points ssh.socket,
      # a host trigger unit, at a unit the live check judges. ssh.socket is
      # essential, so the apply must be refused before it writes anything
      # (decision 177(c)) -- not hold it, which on a socket-activated ssh
      # would cut remote access.
      systemdSystemDropIn(unit = "ssh.socket", name = "a13-repoint",
        content = "[Socket]\nService=eth-r10-path.service\n",
        address = "r13Ssh")"""
  R5Plan = r5Unit("eth-r5-plan.service", "ProtectSystem=strict\n" &
    "NoNewPrivileges=yes\nUser=eth-validator\nGroup=eth-validator\n" &
    "ReadWritePaths=/var/lib/ethereum/validator\n", "r5Plan")
    ## A confined unit that reaches the carried directory by its path:
    ## planned before install-unit (no requirement due), applied after it.
  R5DistUnit = "a13r5-dist.service"
    ## A unit the profile does not define (as a distribution's), which a
    ## profile unit wants: it must get the restore requirement itself.
  R5DistDropIn = "/etc/systemd/system/a13r5-dist.service.d/50-repro-state-restore.conf"
  R5TunedUnit = "a13r5-tuned.service"
    ## A second unit the profile does not define, carrying the drop-in the
    ## next generation drops (finding 3). Apart from ``R5DistUnit``, so that
    ## unit gets the restore requirement only because a profile unit wants
    ## it: a drop-in for an undefined unit reaches everything and would give
    ## it the requirement too (the confound of the first round-5 cell).
  R5TuneDropIn = "/etc/systemd/system/a13r5-tuned.service.d/50-repro-tune.conf"
  R5Resources = """
      # A13 review round 5, finding 5: a profile unit that wants a unit the
      # profile does not define.
      systemdSystemUnit(name = "eth-r5-wants.service",
        content = unitText("A13 round-5 probe: wants a distribution unit",
          "User=eth-validator\nGroup=eth-validator\n" &
          "ReadWritePaths=/var/lib/a13-r5\nExecStart=/bin/sleep infinity\n",
          after = "a13r5-dist.service"),
        hardening = "serviceFloor",
        floorExceptions = @["NoExecPaths: the conversion gate's round-5 " &
          "probe runs /bin/sleep"],
        address = "r5Wants")"""
  R5TuneResource = """
      # A13 review round 5, finding 3: a drop-in the next generation drops.
      systemdSystemDropIn(unit = "a13r5-tuned.service", name = "tune",
        content = "[Service]\nEnvironment=A13R5=1\n", address = "r5Tune")"""
  ShadowUnit = "eth-validator-shadow.service"
  ShadowResource = """
      # A13 review round 4, finding 4: on the converted host only, a unit
      # the manifest does not name that reaches the carried directory.
      systemdSystemUnit(name = "eth-validator-shadow.service",
        content = unitText("A13 round-4 probe: a unit the manifest does not name",
          "User=eth-validator\nGroup=eth-validator\n" &
          "ReadWritePaths=/var/lib/ethereum/validator\n" &
          "ExecStart=/bin/sleep infinity\n"),
        hardening = "serviceFloor",
        floorExceptions = @["NoExecPaths: the conversion gate's round-4 " &
          "probe runs /bin/sleep"],
        address = "validatorShadow")"""

const ProbeWritableDirs = ["/var/lib/a13-r4", "/var/lib/a13-r5", "/var/lib/a13-r6",
                           "/var/lib/a13-r7", "/var/lib/a13-r9", "/var/lib/a13-r10"]
  ## The writable directories the probe units name besides the carried one,
  ## created on the converted host before any probe is applied. systemd
  ## refuses to start a unit whose ``ReadWritePaths=`` names a missing path
  ## (226/NAMESPACE, "Failed to set up mount namespacing"); a probe a
  ## falsifier lets in must start, or its red is not its own (A13 round 6:
  ## the exec probe, whose ``ExecStartPre=`` made the start synchronous,
  ## failed this way; a probe with only a ``Type=simple`` ``ExecStart=``
  ## reported its start done before the namespace failed).

proc probeWritablePaths(text: string): seq[string] =
  ## Every ``ReadWritePaths=`` path in a probe's lines.
  var i = 0
  const Key = "ReadWritePaths="
  while true:
    i = text.find(Key, i)
    if i < 0: return
    var j = i + Key.len
    var p = ""
    while j < text.len and text[j] notin {'\\', '\n', '"', ' '}:
      p.add(text[j]); inc j
    result.add(p)
    i = j

static:
  # Every probe unit's writable path is one the gate creates, or the carried
  # directory itself: checked when the gate compiles.
  var all = PathReachProfile & R4Host & R5Plan & R5Resources & R6Resources &
    R7Resources & R9Resources & R10Resources & R11Resources & ShadowResource
  for (_, _, res, _, _) in R4Probes: all.add(res)
  for (_, _, res, _, _, _) in R5Probes: all.add(res)
  for (_, res, _, _, _) in R6Probes: all.add(res)
  for p in probeWritablePaths(all):
    doAssert p in ProbeWritableDirs or p == "/var/lib/ethereum/validator",
      "a probe unit's ReadWritePaths= names " & p & ", which the gate does " &
      "not create (add it to ProbeWritableDirs)"

proc unitRan(g: Guest; unit: string; marker: string): (bool, JsonNode)

proc startAgitator(g: Guest) =
  ## While a full apply runs (§13 decision 151): keep connecting to the
  ## decision-151 socket and keep its path unit's path in place, so either
  ## trigger fires at once if anything leaves it running under the hold.
  discard g.exec("rm -f /run/a13r10-stop; touch " & R10Job & "; " &
    "nohup bash -c 'while [ ! -e /run/a13r10-stop ]; do " &
    "timeout 1 bash -c \"exec 3<>/dev/tcp/127.0.0.1/" & $R10Port & "\" " &
    "2>/dev/null; touch " & R10Job & "; sleep 0.3; done' >/dev/null 2>&1 &")

proc stopAgitator(g: Guest) =
  discard g.exec("touch /run/a13r10-stop; sleep 1; true")

proc triggerCase(g: Guest): (bool, JsonNode) =
  ## After a full apply: each decision-151 trigger is active (not failed by
  ## its rate limit) and its service ran, the socket's on a connection made
  ## now. Waits for the markers a little.
  var ev = newJObject()
  var ok = true
  discard g.exec("timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" & $R10Port &
    "' 2>/dev/null; true")
  for (label, trig, svc) in [("socket", R10Socket, R10SocketSvc),
                             ("path", R10Path, R10PathSvc)]:
    let show = g.exec("systemctl show -p ActiveState -p Result " & trig).stdout
    let active = "ActiveState=active" in show
    let (ran, e) = g.unitRan(svc, R10MarkerDir & "/" & svc & ".ran")
    e["trigger"] = %show.strip()
    e["triggerActive"] = %active
    e["ran"] = %ran
    ev[label] = e
    ok = ok and active and ran and e["markerContent"].getStr != "0"
  (ok, ev)

proc unitRan(g: Guest; unit: string; marker: string): (bool, JsonNode) =
  ## Whether ``unit`` really ran: the file its command writes when it runs
  ## (``marker``) is there, and its journal shows no failure after its last
  ## start (``journalFailedAfterStart``). A "Started" line alone is no
  ## evidence (A13 review round 7, finding 4): every probe that must be
  ## shown to run writes a marker. Waits a few seconds for the marker of a
  ## unit still starting.
  var journal = ""
  var m = ""
  for i in 0 ..< 10:
    m = g.exec("cat " & marker & " 2>/dev/null").stdout.strip()
    if m.len > 0: break
    discard g.exec("sleep 1")
  journal = g.exec("journalctl -b --no-pager -o short-monotonic -u " & unit &
    " 2>&1").stdout
  result = (m.len > 0 and not journalFailedAfterStart(journal, unit),
            %*{"journal": journal, "marker": marker, "markerContent": m})
  if not result[0]:
    # Why it did not run, while the guest is still there: how systemd sees
    # the unit, whether a hold is still loaded (its drop-in and mtime), and
    # the apply's audit log.
    let gen = g.exec("ls -t /var/lib/repro/system/generations 2>/dev/null | " &
      "head -1").stdout.strip()
    result[1]["diagnosis"] = %g.exec("systemctl status --no-pager -l " & unit &
      " 2>&1 | tail -30; echo '--- is-enabled'; systemctl is-enabled " & unit &
      " 2>&1; echo '--- drop-ins'; ls -la --time-style=full-iso " &
      "/run/systemd/system/" & unit & ".d /etc/systemd/system/" & unit &
      ".d 2>&1; date --iso-8601=ns; echo '--- audit'; grep -a " & unit &
      " /var/lib/repro/system/generations/" & gen & "/log/apply.log 2>&1 | " &
      # The audit log is binary: keep printable text only, so the record
      # stays valid UTF-8 JSON (a raw byte made a round-8 record unreadable).
      "tail -10 | LC_ALL=C tr -cd '\\11\\12\\15\\40-\\176'").stdout

proc unitDiagnosis(g: Guest; unit: string): JsonNode =
  ## How systemd sees ``unit`` now, kept in the record of every run: its
  ## status, this boot's journal, the properties a start depends on, and
  ## every hold drop-in in force for it (A13 round 7: the decision-79
  ## socket's start failed under the hold with no journal to say why).
  %*{
    "status": g.exec("systemctl status --no-pager -l " & unit & " 2>&1 | tail -40").stdout,
    "journal": g.exec("journalctl -u " & unit & " -b --no-pager -o short-monotonic 2>&1 | tail -80").stdout,
    "show": g.exec("systemctl show -p Result,ActiveState,SubState,ConditionResult," &
      "Requires,Wants,After,Triggers,TriggeredBy " & unit & " 2>&1").stdout,
    "holds": g.exec("for d in /run/systemd/system/" & unit & ".d /etc/systemd/system/" &
      unit & ".d; do [ -d $d ] || continue; for f in $d/*.conf; do echo \"== $f\"; " &
      "cat $f; done; done 2>&1").stdout}

proc managerStartJobsDone*(verbose: string): int =
  ## How many start jobs systemd (PID 1) completed for a unit, from
  ## ``journalctl -o verbose _PID=1 UNIT=<unit>``: the entries whose fields
  ## carry ``JOB_TYPE=start`` and ``JOB_RESULT=done``. A line the service
  ## itself writes ("Started ...") is not the manager's and is not counted
  ## (A13 round 7: counting every "Started" line of ``journalctl -u``
  ## counted a line of the validator's own output as a second start).
  var start, done = false
  for l in verbose.splitLines():
    if l.len > 0 and l[0] != ' ':
      # An entry's header line: the previous entry is complete.
      if start and done: inc result
      start = false
      done = false
    let t = l.strip()
    if t == "JOB_TYPE=start": start = true
    if t == "JOB_RESULT=done": done = true
  if start and done: inc result

const
  CapturedValidatorStart = """
Fri 2026-11-13 03:25:39.519523 UTC [s=23bf;i=efd]
    JOB_TYPE=start
    MESSAGE=Starting eth-validator.service - Ethereum validator client (reference activity)...
    JOB_ID=3106
    INVOCATION_ID=55feea00d759497483a46cda9c50578a
Fri 2026-11-13 03:25:39.603467 UTC [s=23bf;i=efe]
    JOB_TYPE=start
    JOB_RESULT=done
    JOB_ID=3106
    INVOCATION_ID=55feea00d759497483a46cda9c50578a
    MESSAGE=Started eth-validator.service - Ethereum validator client (reference activity).
"""
    ## Captured, debian-13 (A13 round 7): one start job of the validator.

static:
  doAssert managerStartJobsDone(CapturedValidatorStart) == 1
  doAssert managerStartJobsDone(CapturedValidatorStart & CapturedValidatorStart) == 2
  # The service's own output is not the manager's.
  doAssert managerStartJobsDone("Fri 2026-11-13 03:26:00 UTC [x]\n" &
    "    MESSAGE=Started beacon node connection\n") == 0

proc unitStarts(g: Guest; unit: string): JsonNode =
  ## Every message systemd (PID 1) logged about ``unit`` this boot, with the
  ## job and the invocation each belongs to (``-o verbose``'s JOB_ID,
  ## JOB_TYPE, JOB_RESULT, INVOCATION_ID), so each start can be attributed
  ## to a job; and the manager's own journal around them.
  %*{
    "verbose": g.exec("journalctl -b --no-pager -o verbose _PID=1 UNIT=" & unit &
      " 2>&1 | grep -E '^[A-Z][a-z]{2} |^    (MESSAGE|JOB_ID|JOB_TYPE|JOB_RESULT|" &
      "INVOCATION_ID|_SOURCE_MONOTONIC_TIMESTAMP)=' | tail -200").stdout,
    "manager": g.exec("journalctl -b --no-pager -o short-monotonic _PID=1 2>&1 | " &
      "grep -E 'eth-|repro-|a13r|Starting|Started|Stopp|Failed|Dependency' | " &
      "tail -400").stdout}

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc enginePath(engine: string): string = engine / "bin" / "reprobuild"

proc mountKeep(g: Guest; format: bool) =
  ## The operator's disk layout: the second disk, labelled, mounted where
  ## vaultwarden keeps its data, by an fstab line.
  if format:
    discard g.run("mkfs.ext4 -q -L repro-keep /dev/vdb")
  discard g.run("mkdir -p " & KeepDir & " && grep -q repro-keep /etc/fstab || " &
    "echo '" & KeepFstab & "' >> /etc/fstab; systemctl daemon-reload; " &
    "mount " & KeepDir)

proc monotonicOf(g: Guest; unit, prop: string): int64 =
  try: parseBiggestInt(g.run("systemctl show -P " & prop & " " & unit).strip())
  except ValueError: -1

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var old, nw: Guest
  var dd: DataDisk
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok:
      fails.add(b.name & ": " & name & ": " & detail)
      # Under a falsifying mutation the first red step is the verdict;
      # the rest of the run would only spend a VM slot.
      if mutation().len > 0 or gateMutation().len > 0 or stopAtRed():
        raise newException(MutationStop, name)
  try:
    let engine = engineFromEnv()
    record["engine"] = %engine
    record["engineBuild"] = engineBuild(engine)
    let eng = enginePath(engine)
    dd = newDataDisk(4)
    # ------------------------------------------------------------------
    # The add-on host.
    old = newGuest(b, diskGiB = 16, cpus = 4, memoryMB = 6144)
    old.dataDisks = @[dd.path]
    old.boot()
    old.prepareBase()
    old.mountKeep(format = true)
    let (repro, sha) = old.installArtefact()
    record["artefactSha256"] = %sha
    let work = old.runDir.parentDir / (old.name & "-a13")
    createDir(work)
    defer: removeDir(work)
    let pk = refPackages(work)
    record["packages"] = packageSha256s(pk)
    let cache = old.startCache()
    defer: cache.stop()
    let kp = peerAuth.generateKeypair()
    let bs = old.bootstrapWithAgent(repro, step, cacheUrl = cache.guestUrl,
      cachePublishers = @[hexKey(kp.publicKey)])
    if not bs.ok: return fails
    defer: bs.producer.stop()
    let net = makeTestnet(pk, work)
    record["genesisTime"] = %net.genesisTime
    let pins = basePins(pk, net)
    let addC = compileReference(engine, pins, "addOn", ReferenceActivities)
    let digests = publishAll(cache, kp, pk, net, pins, addC.actions)
    let jwt = jwtHex()
    let adminToken = "a13-admin-" & jwtHex()[0 ..< 24]
    putReferenceSecrets(old, repro & " system addon secret put", jwt,
                        adminToken, [DefaultValidatorUnit], step)
    provisionWallet(old, net)
    discard bs.producer.publish(PublishSpec(sequence: 1,
      profileText: addC.canonical, buildActions: addC.actions,
      closureDigests: digests))
    let t1 = old.tickUnits()
    step("the add-on host applies the reference activities",
         t1.outcome == "aoApplied", $t1 & "\n" & t1.fetchLog & t1.applyLog &
         "\n" & old.serviceJournal(SetUnits))
    if fails.len > 0: return fails
    let guestNow = parseInt(old.run("date +%s").strip())
    let startEpoch = max(guestNow - net.genesisTime, 0) div SecondsPerEpoch
    # The validators must have signed before the backup, so there is a
    # history to carry. Justification shows it directly, but on a loaded
    # host a one-host network with short slots can run for long
    # stretches without justifying (late attestations miss inclusion;
    # measured at load 150 on the 32-core host, 2026-11-02). Every
    # validator still attests once per epoch, so four epochs of head
    # progress is accepted too; the decisive check is the carried history
    # itself (step 5: every key's history begins on this host).
    var justifiedOk = false
    var headMoved = false
    let deadline = epochTime() + 1800
    while epochTime() < deadline:
      if old.justifiedEpoch() >= startEpoch + 2: justifiedOk = true
      if old.headSlot() >= (startEpoch + 4) * SlotsPerEpoch: headMoved = true
      if justifiedOk or headMoved: break
      discard old.exec("sleep 10")
    record["signedBy"] = %(if justifiedOk: "justification" elif headMoved:
                             "head progress" else: "none")
    step("the validators sign on the add-on host (justified, or four " &
         "epochs of head progress)", justifiedOk or headMoved,
         "justified " & $old.justifiedEpoch() & ", head " & $old.headSlot() &
         ", started at epoch " & $startEpoch)
    # Let the validators attest in a few more epochs before the backup.
    discard old.waitHeadSlot(old.headSlot() + 2 * SlotsPerEpoch,
                         60 + 4 * SecondsPerEpoch)
    let oldHead = old.headSlot()
    let oldEpoch = oldHead div SlotsPerEpoch
    record["addOnHead"] = %oldHead
    step("vaultwarden is healthy on the add-on host, on the kept disk",
         old.exec(repro & " system addon probe http://127.0.0.1:8000/alive").exitCode == 0 and
         old.exec("findmnt -n -o SOURCE " & KeepDir).stdout.strip().len > 0 and
         old.exec("test -f " & KeepDir & "/db.sqlite3").exitCode == 0, "")

    # --- 1. Backup and hold.
    writeFile(work / "ref.profile", addC.canonical)
    old.copyTo(work / "ref.profile", "/root/ref.profile")
    discard old.run("systemctl stop " & SetUnits.join(" "))
    let backupAt = old.run("date +%s.%N").strip()
    let bk = old.exec(repro & " system addon state backup --profile " &
      "/root/ref.profile --out /root/carry")
    step("the state set is backed up", bk.exitCode == 0, bk.stdout & bk.stderr)
    record["backup"] = %bk.stdout
    # How each chain client stopped for the backup (its last head and
    # whether it shut down cleanly): what the converted host resumes from.
    record["addOnStop"] = %old.exec("journalctl -b -q --no-pager " &
      "-u eth-execution.service -u eth-beacon.service | grep -E " &
      quoteShell(ChainLogPattern) & " | tail -n 40").stdout
    let tryStart = old.exec("systemctl start " & DefaultValidatorUnit)
    discard old.exec("sleep 5")
    let started = old.exec("journalctl -u " & DefaultValidatorUnit &
      " -o short-unix --no-pager --since @" & backupAt.split('.')[0] &
      " | grep -c 'Started' || true").stdout.strip()
    step("after the backup the validator is held: a start fails and none ran",
         tryStart.exitCode != 0 and started == "0" and
         old.exec("systemctl is-active " & DefaultValidatorUnit).stdout.strip() != "active",
         "start exit " & $tryStart.exitCode & ", starts since backup " & started &
         "\n" & tryStart.stderr)
    # The hold survives a reboot of the source host.
    old.rebootGuest()
    let tryAgain = old.exec("systemctl start " & DefaultValidatorUnit)
    step("after a reboot the validator is still held",
         tryAgain.exitCode != 0 and
         old.exec("systemctl is-active " & DefaultValidatorUnit).stdout.strip() != "active",
         "start exit " & $tryAgain.exitCode & "\n" & tryAgain.stderr)
    # Nothing is applied under the hold: the deploy agent's next tick is
    # refused (the same profile, a new sequence).
    discard bs.producer.publish(PublishSpec(sequence: 2,
      profileText: addC.canonical, buildActions: addC.actions,
      closureDigests: digests))
    let t2 = old.tickUnits()
    step("under the hold the deploy agent's tick is refused",
         t2.outcome != "aoApplied" and "holds" in t2.applyLog & t2.fetchLog &
           $t2, $t2 & "\n" & t2.applyLog)
    let ver = old.exec(repro & " system addon state verify --source --from /root/carry")
    step("immediately before the conversion the source matches the manifest " &
         "and every unit is held", ver.exitCode == 0, ver.stdout & ver.stderr)
    old.copyFrom("/root/carry", work / "carry")
    let manifest = parseJson(readFile(work / "carry" / "state-set.json"))
    record["manifest"] = manifest
    if gateMutation() == "carried-archive-tampered":
      for e in manifest["entries"]:
        if e["path"].getStr() == "/var/lib/ethereum/validator":
          let a = work / "carry" / e["archive"].getStr()
          var bytes = readFile(a)
          bytes[bytes.len div 2] = char((ord(bytes[bytes.len div 2]) + 1) mod 256)
          writeFile(a, bytes)
    # The "conversion": the add-on host is powered off and its root disk
    # is never booted again (its run directory, which also holds the
    # binary cache's store, is removed with the rest at the end).
    old.shutdown()
    if fails.len > 0: return fails

    # ------------------------------------------------------------------
    # --- 2. The reinstalled host.
    nw = newGuest(b, diskGiB = 16, cpus = 4, memoryMB = 6144)
    nw.dataDisks = @[dd.path]
    nw.boot()
    nw.prepareBase()
    nw.mountKeep(format = false)
    nw.installEngineClosure(engine)
    discard nw.run("mkdir -p " & ProbeWritableDirs.join(" ") & " && chmod 1777 " &
      ProbeWritableDirs.join(" "))
    discard nw.run("mkdir -p /etc/repro /etc/repro-testbed " & CarriedDir &
      " " & RefDir & " && printf 'ID=reproos\\nNAME=\"ReproOS (re-identified " &
      "by the test bed)\"\\nVERSION_ID=test\\nREPRO_TESTBED_REIDENTIFIED=1\\n' > " &
      ReidentifiedOsRelease)
    writeFile(work / "caches.conf", renderCachesConf(cache.guestUrl,
                                                     @[hexKey(kp.publicKey)]))
    nw.copyTo(work / "caches.conf", "/etc/repro/caches.conf")
    for f in walkDir(work / "carry"):
      nw.copyTo(f.path, CarriedDir / f.path.extractFilename)
    discard nw.run("chmod -R go-rwx " & CarriedDir)
    let anchor = "address = \"ethValidatorUser\")"
    let src0 = readFile(ProfileSource)
    if src0.count(anchor) != 1:
      raise newException(CatchableError, "the reference profile's " &
        "validator account is not where the gate adds the shadow unit")
    writeFile(work / "system.nim", src0.replace(anchor, anchor & ShadowResource &
      R5Resources & R6Resources & R7Resources & R9Resources & R10Resources &
      R5TuneResource))
    # The next generation: the same, without the tune drop-in (finding 3).
    # And the decision-137 unheld triggers (R11), new in this generation.
    writeFile(work / "system_next.nim", src0.replace(anchor, anchor &
      ShadowResource & R5Resources & R6Resources & R7Resources & R9Resources &
      R10Resources & R11Resources))
    # The next generation with one profile drop-in that makes a console
    # getty require a judged unit (decision 177's essential-unit case).
    writeFile(work / "system_ess.nim", src0.replace(anchor, anchor &
      ShadowResource & R5Resources & R6Resources & R7Resources & R9Resources &
      R10Resources & R11Resources & R12EssResource))
    writeFile(work / PinsModule, pinsSource(pins))
    writeFile(work / "home.nim", readFile(FixtureDir / "home.nim"))
    writeFile(work / "system_ssh.nim", src0.replace(anchor, anchor &
      ShadowResource & R5Resources & R6Resources & R7Resources & R9Resources &
      R10Resources & R11Resources & R13SshResource))
    for f in ["system.nim", "system_next.nim", "system_ess.nim", "system_ssh.nim",
              PinsModule, "home.nim"]:
      nw.copyTo(work / f, RefDir / f)
    let env = ReidentifyPrefix
    putReferenceSecrets(nw, env & eng & " system secret put", jwt, adminToken,
                        [DefaultValidatorUnit], step)
    let applyCmd = env & eng & " infra apply --profile " & RefDir &
      "/system.nim --host " & AgentTarget & " --no-preview"
    let early = nw.exec(applyCmd, timeoutSec = 3600)
    step("an apply before the restore is refused (ECarriedStatePending)",
         early.exitCode != 0 and "ECarriedStatePending" in
           early.stdout & early.stderr,
         early.stdout & early.stderr)
    step("... and wrote no unit",
         nw.exec("test -e /etc/systemd/system/" & DefaultValidatorUnit).exitCode != 0 and
         nw.exec("systemctl is-active " & DefaultValidatorUnit).stdout.strip() != "active",
         "")
    let sync = nw.exec(env & eng & " system sync --profile " & RefDir &
      "/system.nim --host " & AgentTarget, timeoutSec = 3600)
    step("`repro system sync` before the restore is refused " &
         "(ECarriedStatePending) and wrote no unit",
         sync.exitCode != 0 and "ECarriedStatePending" in
           sync.stdout & sync.stderr and
         nw.exec("test -e /etc/systemd/system/" & DefaultValidatorUnit).exitCode != 0,
         sync.stdout & sync.stderr)

    # Reach by path, end to end: a profile whose only link to the carried
    # validator directory is a path -- a renamed, confined, non-root unit
    # with ReadWritePaths= on it, no credentials, nothing it starts -- is
    # refused while the directory is pending, and the refusal names the path
    # (``<dir> (<address>)``, no "reaches everything" reason). Red when the
    # reach is decided by unit name (engine build
    # ``carried-reach-by-unit-name``).
    writeFile(work / "pathreach.nim", PathReachProfile)
    nw.copyTo(work / "pathreach.nim", RefDir / "pathreach.nim")
    let pr = nw.exec(env & eng & " infra apply --profile " & RefDir &
      "/pathreach.nim --host " & AgentTarget & " --no-preview", timeoutSec = 3600)
    let prOut = pr.stdout & pr.stderr
    step("a unit that reaches the carried directory only by its path is " &
         "refused for it (path-based reach)",
         pr.exitCode != 0 and "ECarriedStatePending" in prOut and
           "/var/lib/ethereum/validator (pathReachRenamed)" in prOut and
         nw.exec("test -e /etc/systemd/system/eth-validator-renamed.service").exitCode != 0,
         prOut)

    # --- Review round 4, while the directory is pending. First the
    # premises, measured on this systemd: the accounts the resolver says
    # are root are root here (systemd.exec(5) DynamicUser=, systemd.unit(5)
    # specifiers).
    let idOf = proc (unit, body: string): string =
      discard nw.run("printf '" & body & "' > /etc/systemd/system/" & unit &
        " && systemctl daemon-reload")
      let u = if unit.endsWith("@.service"): unit.replace("@.service", "@root.service")
              else: unit
      discard nw.exec("systemctl start " & u)
      result = nw.exec("journalctl -b -u " & u & " -o cat --no-pager | " &
        "grep -E '^[0-9]+$' | tail -1").stdout.strip()
      discard nw.run("rm -f /etc/systemd/system/" & unit &
        " && systemctl daemon-reload")
    let premises = %*{
      "DynamicUser=yes User=root": nw.exec("systemd-run --wait --pipe " &
        "--quiet -p DynamicUser=yes -p User=root /usr/bin/id -u").stdout.strip(),
      "DynamicUser=yes User=nosuchr4": nw.exec("systemd-run --wait --pipe " &
        "--quiet -p DynamicUser=yes -p User=nosuchr4 /usr/bin/id -u").stdout.strip(),
      "User=%i on a13r4id@root": idOf("a13r4id@.service",
        "[Service]\\nType=oneshot\\nUser=%%i\\nExecStart=/usr/bin/id -u\\n"),
      "User=%U": idOf("a13r4idu.service",
        "[Service]\\nType=oneshot\\nUser=%%U\\nExecStart=/usr/bin/id -u\\n")}
    discard nw.run(R4UidAliasAdd)
    premises["DynamicUser=yes User=" & R4UidAlias & " (uid 0 in /etc/passwd)"] =
      %nw.exec("systemd-run --wait --pipe --quiet -p DynamicUser=yes -p User=" &
        R4UidAlias & " /usr/bin/id -u").stdout.strip()
    discard nw.run(R4UidAliasRemove)
    record["accountPremises"] = premises
    var dynId = -1
    try: dynId = parseInt(premises["DynamicUser=yes User=nosuchr4"].getStr())
    except ValueError: discard
    step("systemd runs DynamicUser=yes with User=root or a uid-0 alias, " &
         "User=%i of the instance root and User=%U as uid 0, and a missing " &
         "name as a dynamic user (the resolver's premises)",
         premises["DynamicUser=yes User=root"].getStr() == "0" and
         premises["DynamicUser=yes User=" & R4UidAlias &
           " (uid 0 in /etc/passwd)"].getStr() == "0" and
         premises["User=%i on a13r4id@root"].getStr() == "0" and
         premises["User=%U"].getStr() == "0" and dynId >= 61184,
         $premises)
    # Each reach case of the review's round 4, refused while the directory
    # is pending, naming the resource: a unit that runs as root (through a
    # uid-0 alias) under DynamicUser=yes; a profile drop-in that retargets a
    # profile timer at a distribution unit; a path unit that creates a
    # directory inside the carried one.
    let probes = newJObject()
    record["roundFourProbes"] = probes
    for (label, address, resources, reason, layer) in R4Probes:
      discard nw.run("rm -f " & R4MarkerDir & "/*.ran")
      if label == "account": discard nw.run(R4UidAliasAdd)
      let pf = probeFile(label)
      writeFile(work / pf, probeProfile("r4" & label, resources))
      nw.copyTo(work / pf, RefDir / pf)
      let r = nw.exec(env & eng & " infra apply --profile " & RefDir & "/" &
        pf & " --host " & AgentTarget & " --no-preview", timeoutSec = 3600)
      let o = r.stdout & r.stderr
      # Judged, then refused for the expected reason: a compile error or
      # any other failure is red here, and is never the falsifier's red
      # either (the record keeps whether each probe was judged).
      let refused =
        # The floor's refusal, by its stable parts: no error code reaches
        # the output (ESystemProfileInvalid is printed as "invalid system
        # profile"), and the floor's wording of the rule is A9's to change.
        if layer == "floor": r.exitCode != 0 and
                             "invalid system profile" in o and reason in o and
                             "MakeDirectory=yes" in o and
                             "eth-r4-watch.path" in o
        else: r.exitCode != 0 and "ECarriedStatePending" in o and
              ("(" & address) in o and reason in o
      probes[label] = %*{"exit": r.exitCode, "judged": judged(o),
        "layer": layer, "refusedForReason": refused}
      if r.exitCode == 0:
        # Let in (a falsifier's cell): evidence that its units ran.
        var ranAll = true
        let ev = newJObject()
        for l in resources.splitLines():
          let i = l.find("systemdSystemUnit(name = \"")
          if i >= 0:
            let n = l[i + len("systemdSystemUnit(name = \"") .. ^1]
            let u = n[0 ..< n.find('"')]
            if not u.endsWith(".service"): continue
            let (ok, e) = nw.unitRan(u, R4MarkerDir & "/" & u & ".ran")
            ranAll = ranAll and ok
            ev[u] = e
        probes[label]["ran"] = %ranAll
        probes[label]["runEvidence"] = ev
      if label == "account": discard nw.run(R4UidAliasRemove)
      step("round 4, " & label & ": refused while the directory is pending, " &
           (if layer == "floor": "by the hardening floor, " else: "") &
           "naming " & address,
           judged(o) and refused,
           (if judged(o): "" else: "NOT JUDGED (the profile did not compile): ") & o)
    # A host drop-in the profile does not have (here in /run): read as
    # systemd reads it. Without it the confined unit is let in (control);
    # with it, a ReadWritePaths= from the host gives the unit the carried
    # directory and the apply is refused. Writable paths, not the unit's
    # confinement: the full apply's live cross-check judges confinement as
    # systemd loaded the unit and so would refuse an unconfining drop-in
    # too, leaving the falsifier's probe held and never run (A13 review
    # round 7). Optional ("-"): the directory may not exist while pending.
    let hf = probeFile("host")
    writeFile(work / hf, probeProfile("r4host", R4Host))
    nw.copyTo(work / hf, RefDir / hf)
    let hostApply = env & eng & " infra apply --profile " & RefDir & "/" & hf &
      " --host " & AgentTarget & " --no-preview"
    discard nw.run("rm -f " & R4MarkerDir & "/*.ran")
    let ctl = nw.exec(hostApply, timeoutSec = 3600)
    probes["hostControl"] = %*{"exit": ctl.exitCode,
      "judged": judged(ctl.stdout & ctl.stderr)}
    step("round 4, host drop-in (control): without it the confined unit is " &
         "let in while the directory is pending",
         ctl.exitCode == 0, ctl.stdout & ctl.stderr)
    let (ctlRan, ctlEv) = nw.unitRan("eth-r4-host.service",
      R4MarkerDir & "/eth-r4-host.service.ran")
    probes["hostControl"]["ran"] = %ctlRan
    probes["hostControl"]["runEvidence"] = ctlEv
    step("round 4, host drop-in (control): the unit let in really ran",
         ctlRan, $ctlEv)
    discard nw.run("mkdir -p " & R4HostDropIn.parentDir & " && printf " &
      "'[Service]\\nReadWritePaths=-/var/lib/ethereum/validator\\n' > " &
      R4HostDropIn & " && systemctl daemon-reload")
    discard nw.run("rm -f " & R4MarkerDir & "/*.ran")
    let hr = nw.exec(hostApply, timeoutSec = 3600)
    let ho = hr.stdout & hr.stderr
    let hostRefused = hr.exitCode != 0 and "ECarriedStatePending" in ho and
      "/var/lib/ethereum/validator (r4Host)" in ho
    probes["host"] = %*{"exit": hr.exitCode, "judged": judged(ho),
      "refusedForReason": hostRefused}
    if hr.exitCode == 0:
      # Let in (the falsifier's cell): the apply starts the enabled unit
      # after its live check, and it must be shown to have run.
      let (ok, e) = nw.unitRan("eth-r4-host.service",
        R4MarkerDir & "/eth-r4-host.service.ran")
      probes["host"]["ran"] = %ok
      probes["host"]["runEvidence"] = e
    step("round 4, host drop-in: a drop-in in /run the profile does not " &
         "have makes the unit reach the carried directory, and the apply " &
         "is refused",
         judged(ho) and hostRefused,
         (if judged(ho): "" else: "NOT JUDGED (the profile did not compile): ") & ho)
    discard nw.run("rm -rf " & R4HostDropIn.parentDir &
      " && systemctl daemon-reload")

    # --- Review round 5, while the directory is pending: each case
    # refused for its own reason, judged (its profile compiled), and named.
    # The NSS sources this host names: the account lookup is authoritative
    # (a name it does not know is no account) only over files and userdb.
    record["nsswitch"] = %nw.exec("grep -E '^(passwd|group):' " &
      "/etc/nsswitch.conf || true").stdout
    for (label, address, resources, reason, setup, cleanup) in R5Probes:
      discard nw.run("rm -f " & ProbeMarkerDir & "/*.ran")
      if setup.len > 0: discard nw.run(setup)
      let pf = probeFile("r5" & label)
      writeFile(work / pf, probeProfile("r5" & label, resources))
      nw.copyTo(work / pf, RefDir / pf)
      let r = nw.exec(env & eng & " infra apply --profile " & RefDir & "/" &
        pf & " --host " & AgentTarget & " --no-preview", timeoutSec = 3600)
      let o = r.stdout & r.stderr
      let refused = r.exitCode != 0 and "ECarriedStatePending" in o and
        ("(" & address) in o and reason in o
      probes["r5" & label] = %*{"exit": r.exitCode, "judged": judged(o),
        "layer": "reach", "refusedForReason": refused}
      if r.exitCode == 0:
        let u = resources[resources.find("name = \"") + 8 .. ^1]
        let unitName = u[0 ..< u.find('"')]
        let (ok, e) = nw.unitRan(unitName, ProbeMarkerDir & "/" & unitName & ".ran")
        probes["r5" & label]["ran"] = %ok
        probes["r5" & label]["runEvidence"] = e
      if label == "userdb":
        # What this host's NSS says of the record (nss-systemd serves it
        # where installed); the analysis reads the record itself either way.
        record["userdbGetent"] = %nw.exec("getent passwd a13r5ops || true").stdout
      if cleanup.len > 0: discard nw.run(cleanup)
      step("round 5, " & label & ": refused while the directory is pending, " &
           "naming " & address, judged(o) and refused,
           (if judged(o): "" else: "NOT JUDGED (the profile did not compile): ") & o)
    # --- Review round 6 and owner decisions 58 and 59 (a privileged
    # daemon's grant; the units as systemd loaded them), while the directory
    # is pending: each refused for its own reason and judged.
    for (label, resources, needle, setup, cleanup) in R6Probes:
      discard nw.run("rm -f " & ProbeMarkerDir & "/*.ran " & ProbeMarkerDir & "/*.priv")
      if setup.len > 0: discard nw.run(setup)
      let pf = probeFile("r6" & label)
      writeFile(work / pf, probeProfile("r6" & label, resources))
      nw.copyTo(work / pf, RefDir / pf)
      let r = nw.exec(env & eng & " infra apply --profile " & RefDir & "/" &
        pf & " --host " & AgentTarget & " --no-preview", timeoutSec = 3600)
      let o = r.stdout & r.stderr
      var refused = r.exitCode != 0 and "ECarriedStatePending" in o and
        needle in o
      var detail = o
      if label in ["live", "liverw"]:
        # Held from before the first write to the refusal: never started.
        let liveUnit = if label == "live": "eth-r6-gen.service"
                       else: "eth-r6-genrw.service"
        # From its journal: systemctl show cannot tell (an unloaded unit
        # reports its start timestamps as zero whether it ran or not).
        let journal = nw.exec("journalctl -b --no-pager -o short-monotonic -u " &
          liveUnit & " 2>&1").stdout
        let held = nw.exec("test -f /etc/systemd/system/" & liveUnit & ".d/" &
          "zz-repro-carried-check-hold.conf").exitCode == 0
        refused = refused and held and not journalStarted(journal, liveUnit)
        detail = o & "\n" & journal & "\nheld: " & $held
      probes["r6" & label] = %*{"exit": r.exitCode, "judged": judged(o),
        "layer": (if label in ["live", "liverw"]: "live" else: "reach"),
        "refusedForReason": refused}
      if r.exitCode == 0:
        # Let in (a falsifier's cell): the probe's unit really ran, and --
        # for the exec probe -- its privileged command did, as root,
        # observed on the guest (A13 round 6: a let-in unit can fail after
        # its start is reported, and then proves nothing).
        let u0 = resources[resources.find("name = \"") + 8 .. ^1]
        let unitName = u0[0 ..< u0.find('"')]
        var (ok, e) = nw.unitRan(unitName, ProbeMarkerDir & "/" & unitName & ".ran")
        if label == "exec":
          let priv = nw.exec("cat " & ProbeMarkerDir &
            "/eth-r6-exec.service.priv 2>/dev/null").stdout.strip()
          e["privilegedUid"] = %priv
          ok = ok and priv == "0"
        if label == "live":
          ok = ok and e["markerContent"].getStr() == "0"
        probes["r6" & label]["ran"] = %ok
        probes["r6" & label]["runEvidence"] = e
      if r.exitCode != 0 and "ECarriedStatePending" notin o:
        # Failed for another reason (a falsifier let the probe in, and its
        # unit did not start): what systemd says of the probe's units, so
        # the record explains it after the guest is gone.
        var units = ""
        for l in resources.splitLines():
          let i = l.find("systemdSystemUnit(name = \"")
          if i >= 0:
            let n = l[i + len("systemdSystemUnit(name = \"") .. ^1]
            units.add(" " & n[0 ..< n.find('"')])
        var cmds = "systemctl status --no-pager -l" & units & " 2>&1 | tail -60"
        for u in units.splitWhitespace():
          cmds.add("; echo '--- " & u & "'; journalctl -u " & u &
            " -b --no-pager -o short-monotonic 2>&1 | tail -60; " &
            "systemctl show " & u & " -p ExecStartPre -p ExecStartPreEx " &
            "-p Result -p ExecMainStatus 2>&1; systemctl cat " & u & " 2>&1")
        probes["r6" & label]["unitStatus"] = %nw.exec(cmds).stdout
        detail.add("\n" & probes["r6" & label]["unitStatus"].getStr())
      if cleanup.len > 0: discard nw.run(cleanup)
      step("round 6, " & label & ": refused while the directory is pending" &
           (if label in ["live", "liverw"]: ", after the apply's reload, never started"
            else: ""), judged(o) and refused,
           (if judged(o): "" else: "NOT JUDGED (the profile did not compile): ") &
           detail)
    # The premise of decision 153 for units outside the judged set (A13
    # review round 10, finding 8), measured on this host's systemd with
    # units of the gate's own and no repro in the loop: a unit that
    # Requires= a unit whose start a condition hold skips (the full apply's
    # hold, ConditionPathExists=!/) starts and runs, the skipped start
    # counting as satisfied (systemd.unit(5), "Conditions and Asserts").
    block:
      discard nw.run("mkdir -p /run/systemd/system/a13m-held.service.d && " &
        "printf '[Unit]\\nDescription=A13 decision-153 premise: held\\n\\n" &
        "[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/bin/true\\n' " &
        "> /run/systemd/system/a13m-held.service && printf '[Unit]\\n" &
        "ConditionPathExists=!/\\n' > /run/systemd/system/a13m-held.service.d/" &
        "zz-hold.conf && printf '[Unit]\\nDescription=A13 decision-153 premise: " &
        "requires the held unit\\nRequires=a13m-held.service\\nAfter=" &
        "a13m-held.service\\n\\n[Service]\\nType=oneshot\\nRemainAfterExit=yes\\n" &
        "ExecStart=/bin/true\\n' > /run/systemd/system/a13m-req.service && " &
        "systemctl daemon-reload")
      let st = nw.exec("systemctl start a13m-req.service")
      let show = nw.exec("systemctl show -p ActiveState -p Result a13m-req.service " &
        "| tr '\\n' ' '; echo; systemctl show -p ActiveState -p ConditionResult " &
        "a13m-held.service | tr '\\n' ' '").stdout
      let lines = show.splitLines()
      let reqRan = st.exitCode == 0 and lines.len > 0 and
        "ActiveState=active" in lines[0]
      let heldSkipped = "ConditionResult=no" in show
      discard nw.run("systemctl stop a13m-req.service a13m-held.service; rm -rf " &
        "/run/systemd/system/a13m-held.service /run/systemd/system/a13m-held.service.d " &
        "/run/systemd/system/a13m-req.service; systemctl daemon-reload")
      record["decision153Premise"] = %*{"startExit": st.exitCode, "show": show,
        "requirerRan": reqRan, "heldSkipped": heldSkipped}
      step("decision 153's premise: on this systemd a unit that requires a " &
           "condition-held unit starts, the held unit's start skipped",
           reqRan and heldSkipped, show & "\n" & st.stdout & st.stderr)
    # Owner decision 153 (decided 2026-11-15): on a partial refusal, a unit
    # that Requires= a refused unit stays held with it, and the apply says
    # so. As decided again in A13 review round 10, every unit of the
    # generation that requires it, judged or not: a13r12ureq.slice is not a
    # service, so the live check does not judge it (a slice, like a target,
    # runs nothing). eth-r10-ureq.target requires it too, and is NOT held:
    # the owner decision "never hold .target units" (A13 review round 12) --
    # a target is followed through to the units that require it. eth-r10-gen.service is refused by the live check (a generator
    # makes it root at the apply's reload, as round 6's live probe);
    # eth-r10-req.service is confined, enabled and Requires= it. Without
    # the rule it is released and started, and systemd counts its
    # requirement's condition-skipped start as satisfied.
    block:
      discard nw.run("rm -f " & ProbeMarkerDir & "/*.ran")
      discard nw.run("mkdir -p /etc/systemd/system-generators && printf '#!/bin/sh\\n" &
        "mkdir -p \"$1/eth-r10-gen.service.d\"\\nprintf \"[Service]\\\\nUser=root\\\\n\" " &
        "> \"$1/eth-r10-gen.service.d/10-root.conf\"\\n' > " &
        "/etc/systemd/system-generators/a13r10-gen && chmod 755 " &
        "/etc/systemd/system-generators/a13r10-gen")
      let req = "      systemdSystemUnit(name = \"eth-r10-req.service\",\n" &
        "        content = \"[Unit]\\nDescription=A13 decision-153 probe: " &
        "requires a refused unit\\nRequires=eth-r10-gen.service\\n" &
        "After=eth-r10-gen.service\\n\\n[Service]\\n" &
        R6Confined.replace("\n", "\\n") &
        "ReadWritePaths=/var/lib/a13-r5\\nExecStart=/bin/sh -c 'id -u > " &
        ProbeMarkerDir & "/eth-r10-req.service.ran'\\n\\n[Install]\\n" &
        "WantedBy=multi-user.target\\n\",\n        address = \"r10Req\")\n"
      let ureq = "      systemdSystemUnit(name = \"eth-r10-ureq.target\",\n" &
        "        content = \"[Unit]\\nDescription=A13 decision-153 probe: an " &
        "unjudged unit that requires a refused unit\\nRequires=eth-r10-gen.service\\n" &
        "After=eth-r10-gen.service\\n\\n[Install]\\nWantedBy=multi-user.target\\n\",\n" &
        "        address = \"r10Ureq\")\n" &
        "      systemdSystemUnit(name = \"a13r12ureq.slice\",\n" &
        "        content = \"[Unit]\\nDescription=A13 decision-153 probe: an " &
        "unjudged slice that requires a refused unit\\nRequires=eth-r10-gen.service\\n" &
        "After=eth-r10-gen.service\\n\\n[Install]\\nWantedBy=multi-user.target\\n\",\n" &
        "        address = \"r12Uslice\")\n"
      let pf = probeFile("r10req")
      writeFile(work / pf, probeProfile("r10req",
        r5Unit("eth-r10-gen.service", R6Confined, "r10Gen") & req & ureq))
      nw.copyTo(work / pf, RefDir / pf)
      let r = nw.exec(env & eng & " infra apply --profile " & RefDir & "/" &
        pf & " --host " & AgentTarget & " --no-preview", timeoutSec = 3600)
      let o = r.stdout & r.stderr
      let reported = "eth-r10-req.service requires eth-r10-gen.service" in o
      let heldReq = nw.exec("test -f /etc/systemd/system/eth-r10-req.service.d/" &
        "zz-repro-carried-check-hold.conf").exitCode == 0
      let journal = nw.exec("journalctl -b --no-pager -o short-monotonic " &
        "-u eth-r10-req.service 2>&1").stdout
      let ran = nw.exec("test -s " & ProbeMarkerDir &
        "/eth-r10-req.service.ran").exitCode == 0
      let started = journalStarted(journal, "eth-r10-req.service") or ran
      # Decision 153: a unit that requires a refused unit stays held.
      record["decision153"] = %*{"exit": r.exitCode, "reported": reported,
        "heldInEtc": heldReq, "started": started, "judged": judged(o)}
      let ureqReported = "a13r12ureq.slice requires eth-r10-gen.service" in o
      let ureqHeld = nw.exec("test -f /etc/systemd/system/a13r12ureq.slice.d/" &
        "zz-repro-carried-check-hold.conf").exitCode == 0
      let ureqActive = nw.exec("systemctl is-active a13r12ureq.slice").stdout.strip()
      # The target is never held (the owner decision "never hold .target
      # units"), in /run or /etc.
      let targetHeld = nw.exec("ls /etc/systemd/system/eth-r10-ureq.target.d/" &
        "zz-repro-carried-check-hold.conf /run/systemd/system/" &
        "eth-r10-ureq.target.d/zz-repro-carried-check-hold.conf " &
        "2>/dev/null").stdout.strip().len > 0
      discard nw.run("rm -f /etc/systemd/system-generators/a13r10-gen && rm -rf " &
        "/etc/systemd/system/eth-r10-gen.service.d && systemctl daemon-reload")
      step("decision 153: a unit that requires a unit the live check refuses " &
           "stays held with it, never started, and the apply says why",
           r.exitCode != 0 and reported and heldReq and not started,
           o & "\n" & journal & "\nheld: " & $heldReq & " ran: " & $ran)
      record["decision153Unjudged"] = %*{"unit": "a13r12ureq.slice",
        "reported": ureqReported, "heldInEtc": ureqHeld, "active": ureqActive,
        "targetHeld": targetHeld}
      step("decision 153: a unit the live check does not judge that requires " &
           "a refused unit stays held with it, not active, and the apply " &
           "says why; a target that requires it is not held",
           ureqReported and ureqHeld and ureqActive != "active" and
             not targetHeld,
           o & "\nheld: " & $ureqHeld & " active: " & ureqActive &
           " target held: " & $targetHeld)
    # A stored plan made now, before install-unit: no requirement is due
    # yet, so the plan has none (finding 4; applied after the restore).
    let planFile = probeFile("r5plan")
    writeFile(work / planFile, probeProfile("r5plan", R5Plan))
    nw.copyTo(work / planFile, RefDir / planFile)
    let planOut = nw.exec(env & eng & " infra plan --profile " & RefDir & "/" &
      planFile & " --host " & AgentTarget, timeoutSec = 3600)
    var r5PlanId = ""
    for l in planOut.stdout.splitLines():
      if "plan-id" in l and ':' in l:
        r5PlanId = l.split(':', maxsplit = 1)[1].strip()
    record["r5PlanId"] = %r5PlanId
    step("round 5, plan: a plan of a unit that reaches the carried " &
         "directory is made before install-unit",
         planOut.exitCode == 0 and r5PlanId.len > 0,
         planOut.stdout & planOut.stderr)

    # --- 3. The first-boot unit restores before anything starts.
    # Installed as a conversion installs it: the unit, enabled, and the
    # drop-in that makes every carried unit require it.
    let inst = nw.exec(eng & " system state install-unit --from " & CarriedDir)
    step("the restore unit is installed and the carried units require it",
         inst.exitCode == 0 and DefaultValidatorUnit in inst.stdout,
         inst.stdout & inst.stderr)
    nw.rebootGuest()
    let res = nw.run("systemctl show -p Result -p ActiveState " & RestoreUnit)
    step("the first-boot unit restored the carried state",
         "Result=success" in res and "ActiveState=active" in res,
         res & "\n" & nw.serviceJournal([RestoreUnit]))
    let ver2 = nw.exec(eng & " system state verify --from " & CarriedDir)
    step("every carried and kept directory is at the manifest's digest",
         ver2.exitCode == 0 and "DIFFERS" notin ver2.stdout and
         ver2.stdout.count("ok ") == 4, ver2.stdout & ver2.stderr)
    # Finding 4: the plan made before install-unit, applied now that the
    # requirement is due, is stale (the text the apply runs has it).
    discard nw.run("rm -f " & ProbeMarkerDir & "/*.ran")
    let planApply = nw.exec(env & eng & " infra apply --profile " & RefDir & "/" &
      planFile & " --plan " & r5PlanId & " --host " & AgentTarget,
      timeoutSec = 3600)
    let po = planApply.stdout & planApply.stderr
    probes["r5plan"] = %*{"exit": planApply.exitCode, "judged": judged(po),
      "layer": "plan", "refusedForReason": planApply.exitCode != 0 and
        "is stale" in po and "carried-state requirements" in po}
    if planApply.exitCode == 0:
      # Let in (the falsifier's cell): evidence that its unit ran.
      let (ok, e) = nw.unitRan("eth-r5-plan.service",
        ProbeMarkerDir & "/eth-r5-plan.service.ran")
      probes["r5plan"]["ran"] = %ok
      probes["r5plan"]["runEvidence"] = e
    step("round 5, plan: a plan made before install-unit is refused as " &
         "stale once the requirement is due",
         judged(po) and planApply.exitCode != 0 and "is stale" in po and
           "carried-state requirements" in po, po)
    let restoredDone = nw.monotonicOf(RestoreUnit, "ExecMainExitTimestampMonotonic")
    let restoreEpoch = max(parseInt(nw.run("date +%s").strip()) -
                           net.genesisTime, 0) div SecondsPerEpoch
    record["restoreEpoch"] = %restoreEpoch
    # The falsifiers of the post-conversion checks: the carried state is
    # broken after it was restored and verified, before the apply.
    case gateMutation()
    of "rev-execution-dropped":
      discard nw.run("find /var/lib/ethereum/execution -mindepth 1 -delete")
    of "rev-beacon-dropped":
      discard nw.run("find /var/lib/ethereum/beacon -mindepth 1 -delete")
    of "rev-slashing-db-reset":
      discard nw.run("find /var/lib/ethereum/validator -name validator.db -delete")
    of "rev-slashing-db-reset-no-doppelganger":
      # The same reset, with the doppelganger check off in the profile the
      # apply realises: the validator then signs on an empty history, and
      # only the carried-history assertion can tell (review round 2).
      discard nw.run("find /var/lib/ethereum/validator -name validator.db -delete")
      discard nw.run("sed -i 's/enable-doppelganger: true/enable-doppelganger: false/' " &
        RefDir & "/system.nim && grep -c 'enable-doppelganger: false' " &
        RefDir & "/system.nim")
    of "rev-inode-reuse":
      # The restored validator directory replaced in place by an empty one
      # of the same owner and mode; on ext4 the new directory usually gets
      # the inode just freed (review round 2, finding 1). The apply must
      # still see the carried state as pending.
      let v = "/var/lib/ethereum/validator"
      record["inodeReuse"] = %nw.run("own=$(stat -c %u:%g " & v & "); " &
        "mode=$(stat -c %a " & v & "); b=$(stat -c %d:%i " & v & "); " &
        "rm -rf " & v & "; sleep 40; mkdir " & v & " && chown $own " & v &
        " && chmod $mode " & v & "; echo \"before $b after $(stat -c %d:%i " &
        v & ")\"")
    else: discard

    # A unit the profile does not define (as a distribution ships one), in
    # the distribution's directory, not enabled: only the profile's
    # eth-r5-wants.service pulls it in (finding 5).
    for u in [R5DistUnit, R5TunedUnit, R6DistB, R6Dist7]:
      discard nw.run("printf '[Unit]\\n" &
        "Description=A13 distribution-like unit\\n[Service]\\n" &
        "ExecStart=/bin/sleep infinity\\n' > /usr/lib/systemd/system/" & u)
    # Decision 60: a distribution-like unit that wants another.
    discard nw.run("printf '[Unit]\\nDescription=A13 distribution-like " &
      "unit\\nWants=" & R6DistB & "\\n[Service]\\n" &
      "ExecStart=/bin/sleep infinity\\n' > /usr/lib/systemd/system/" & R6DistA)
    # R7-7: a host .wants/ link on a profile unit.
    discard nw.run("mkdir -p /etc/systemd/system/eth-r6-linked.service.wants && " &
      "ln -sf /usr/lib/systemd/system/" & R6Dist7 &
      " /etc/systemd/system/eth-r6-linked.service.wants/" & R6Dist7)
    discard nw.run("systemctl daemon-reload")
    # --- 4. The full realisation, with the decision-151 triggers agitated
    # throughout.
    nw.startAgitator()
    let applied = nw.exec(applyCmd, timeoutSec = 3600)
    nw.stopAgitator()
    record["applyOutput"] = %((applied.stdout & applied.stderr)[0 ..< min(
      4000, (applied.stdout & applied.stderr).len)])
    step("the reinstalled host realises the activities in full",
         applied.exitCode == 0, applied.stdout & applied.stderr & "\n" &
         nw.serviceJournal(SetUnits))
    # Review round 4, finding 4: the requirement follows reach, at every
    # apply, written by the generation -- here for a unit the manifest does
    # not name. Red under the engine build
    # ``restore-requirement-by-manifest-only``.
    let shadowDropIn = "/etc/systemd/system/" & ShadowUnit &
      ".d/50-repro-state-restore.conf"
    let shadowDeps = nw.run("systemctl show -p Requires -p After " & ShadowUnit)
    step("a unit the manifest does not name that reaches the carried " &
         "directory requires the restore, through the generation's drop-in",
         nw.exec("test -f " & shadowDropIn).exitCode == 0 and
         shadowDeps.count(RestoreUnit) >= 2,
         shadowDeps & "\n" & nw.exec("cat " & shadowDropIn).stdout)
    # Finding 5: the unit the profile wants but does not define requires
    # the restore itself, through the generation's drop-in. Red under the
    # engine build ``restore-requirement-skips-activated``.
    let distDeps = nw.run("systemctl show -p Requires -p After " & R5DistUnit)
    step("round 5, wants: a unit a profile unit wants but the profile does " &
         "not define requires the restore, through the generation's drop-in",
         nw.exec("test -f " & R5DistDropIn).exitCode == 0 and
         distDeps.count(RestoreUnit) >= 2,
         distDeps & "\n" & nw.exec("cat " & R5DistDropIn).stdout)
    # Finding 5's other derivation path: a unit the profile does not define
    # but drops in on reaches everything, so it requires the restore through
    # that drop-in. Red under ``restore-requirement-skips-dropin-targets``.
    let tunedReq = "/etc/systemd/system/" & R5TunedUnit &
      ".d/50-repro-state-restore.conf"
    let tunedDeps = nw.run("systemctl show -p Requires -p After " & R5TunedUnit)
    step("round 5, dropin: a unit the profile drops in on but does not " &
         "define requires the restore, through the generation's drop-in",
         nw.exec("test -f " & tunedReq).exitCode == 0 and
         tunedDeps.count(RestoreUnit) >= 2, tunedDeps)
    # Round 6, finding 4 (R7-7): the unit a host .wants/ link on a profile
    # unit starts requires the restore itself. Red under the engine build
    # ``dependency-links-unread`` (whose first red is the pending probe).
    let d7Deps = nw.run("systemctl show -p Requires -p After " & R6Dist7)
    step("round 6, wants-link: a unit a host .wants/ link on a profile unit " &
         "starts requires the restore, through the generation's drop-in",
         nw.exec("test -f " & R6Dist7_DropIn).exitCode == 0 and
         d7Deps.count(RestoreUnit) >= 2, d7Deps)
    # Owner decision 60: a unit started only through a distribution unit's
    # dependencies requires the restore too. Red under the engine build
    # ``restore-requirement-skips-closure``.
    let dbDeps = nw.run("systemctl show -p Requires -p After " & R6DistB)
    step("round 6, closure: a unit started only through a distribution " &
         "unit's dependencies requires the restore",
         nw.exec("test -f " & R6DistB_DropIn).exitCode == 0 and
         dbDeps.count(RestoreUnit) >= 2, dbDeps)
    # Owner decision 79 (decided 2026-11-08): after the full apply's
    # carried-state check passes, the start jobs the drivers issued are
    # issued again, so a held service another unit's start pulled in comes
    # up as on a host without carried state. Each is shown up and to have
    # run (its marker, as the probe account), not merely "Started". Red
    # under the engine builds ``reissue-skips-targets`` and
    # ``reissue-skips-sockets``, each on its own step.
    record["decision79"] = newJObject()
    # Kept in every run (A13 round 7): how systemd saw the units whose start
    # decision 79 re-issues, and the validator's starts right after the full
    # apply.
    record["decision79Diagnosis"] = %*{
      "socket": nw.unitDiagnosis("eth-r7-sock.socket"),
      "socketService": nw.unitDiagnosis(R7SocketSvc),
      "targetService": nw.unitDiagnosis(R7TargetSvc),
      "validatorStarts": nw.unitStarts(DefaultValidatorUnit)}
    # Both halves are recorded before either is asserted: under a falsifier
    # the run stops at its first red step, and the classifier requires the
    # other half's evidence -- that it is up and ran -- in every decision-79
    # falsifier cell (A13 round 7: recorded one after the other, the target
    # falsifier's stop left the socket half unrecorded).
    var d79: seq[tuple[label, svc, active: string; ran: bool; ev: JsonNode]]
    for (label, svc) in [("target", R7TargetSvc), ("socket", R7SocketSvc)]:
      let active = nw.exec("systemctl is-active " & svc).stdout.strip()
      let (ran, ev) = nw.unitRan(svc, R7MarkerDir & "/" & svc & ".ran")
      ev["active"] = %active
      record["decision79"][label] = ev
      record["decision79"][label]["ran"] = %ran
      d79.add((label, svc, active, ran, ev))
    for (label, svc, active, ran, ev) in d79:
      step("decision 79, " & label & ": a confined static service an enabled " &
           label & " pulls in is up after the apply",
           active == "active" and ran and ev["markerContent"].getStr != "0",
           $ev & "\n" & nw.exec("systemctl status --no-pager " & svc &
             " 2>&1 | tail -15").stdout)
    # Owner decision 151 (decided 2026-11-15): the triggers of the held
    # units are stopped and held for the apply, so a connection or a path
    # event during it fails neither; both are active after it, and their
    # services run.
    block:
      let (ok, ev) = nw.triggerCase()
      record["decision151"] = %*{"firstApply": ev}
      step("decision 151, full apply (first realisation): a socket with " &
           "connections arriving and a path unit whose path exists, held " &
           "through the apply, are active after it and their services run",
           ok, $ev)
    # Owner decision 137 (decided 2026-11-14): a trigger declared before the
    # unit it triggers -- the socket and the timer above -- is applied after
    # it, so systemd does not refuse its start, and the unit it triggers
    # runs. Kept as a regression case: decision 151 holds these triggers
    # (their services are judged) and orders them too, so the engine build
    # ``trigger-edges-omitted`` is red on the R11 probes after the next
    # generation's apply, not here.
    block:
      let applyOut = applied.stdout & applied.stderr
      var d137 = newJObject()
      for (label, trig, svc) in [("socket", R7Socket, R7SocketSvc),
                                 ("timer", R7Timer, R7TimerSvc)]:
        # The timer fires 1 s after it starts; give it the time.
        discard nw.exec("for i in $(seq 20); do [ -s " & R7MarkerDir & "/" &
          svc & ".ran ] && break; sleep 1; done; true")
        let active = nw.exec("systemctl is-active " & trig).stdout.strip()
        let (ran, ev) = nw.unitRan(svc, R7MarkerDir & "/" & svc & ".ran")
        # Refused for the order: the apply reports the trigger's
        # ``enable --now`` failed (it says only "Job failed"), and systemd's
        # own reason in this boot's journal of the trigger is that the unit
        # it triggers was not loaded ("Socket service ... not loaded,
        # refusing", "Refusing to start, unit ... to trigger not loaded").
        var applyRefused = false
        for l in applyOut.splitLines():
          if ("'" & trig & "' failed") in l: applyRefused = true
        let journalNotLoaded = "not loaded" in nw.exec("journalctl -b -u " &
          trig & " --no-pager 2>&1").stdout
        let refused = applyRefused and journalNotLoaded
        ev["triggerActive"] = %active
        ev["applyRefused"] = %applyRefused
        ev["journalNotLoaded"] = %journalNotLoaded
        ev["refusedNotLoaded"] = %refused
        ev["ran"] = %ran
        d137[label] = ev
        step("decision 137, " & label & " first: a " & label & " declared " &
             "before the service it triggers is applied, active, and its " &
             "service ran", active == "active" and ran and not refused and
             ev["markerContent"].getStr != "0",
             $ev & "\n" & nw.exec("systemctl status --no-pager " & trig &
               " " & svc & " 2>&1 | tail -25").stdout)
      record["decision137"] = d137
    # Owner decision 135 (decided 2026-11-14): a confined template service
    # is judged through its instances, never by its own name, so on the
    # converted host its instances come up after the full apply's check.
    # Red under the engine build ``template-live-by-name`` (the template
    # read by name, refused by systemd, held: the instances never start).
    block:
      var ev = newJObject()
      var allRan = true
      for inst in R9Instances:
        let (ran, e) = nw.unitRan(inst, R9MarkerDir & "/" & inst & ".ran")
        e["active"] = %nw.exec("systemctl is-active " & inst).stdout.strip()
        ev[inst] = e
        allRan = allRan and ran and e["active"].getStr == "active"
      # What the full apply's live check read from systemd (its
      # ``live check`` line): the template must be in it, through its
      # observation instance and both instances, or this case judged
      # nothing and its green says nothing about decision 135.
      var judged: seq[string]
      for l in applied.stdout.splitLines():
        let k = l.find("live check   : ")
        if k >= 0: judged = l[k + len("live check   : ") .. ^1].splitWhitespace()
      let observe = "eth-r9-tpl@repro-addon-observe.service"
      let judgedTemplate = observe in judged and
        R9Instances.allIt(it in judged)
      record["decision135Converted"] = %*{"instances": ev, "ran": allRan,
        "judged": judged, "judgedTemplate": judgedTemplate,
        "judgedByName": "eth-r9-tpl@.service" in judged,
        "applyRefusedTemplate": "eth-r9-tpl@.service: its loaded unit cannot be read" in
          (applied.stdout & applied.stderr)}
      step("decision 135, converted host: the full apply's live check judged " &
           "the template through its observation instance and its instances",
           judgedTemplate, judged.join(" "))
      step("decision 135, converted host: a confined template's instances " &
           "an enabled target pulls in are up after the full apply",
           allRan, $ev)
    # Finding 3: the next generation no longer declares the tune drop-in;
    # a host realised in full removes it (and keeps the requirement). Red
    # under the engine build ``full-apply-keeps-undeclared-dropins``.
    let tuneBefore = nw.exec("test -f " & R5TuneDropIn).exitCode == 0
    # Decision 151 again, with both triggers active before the apply: their
    # services stopped, the socket's backlog flushed and the path gone, so
    # each fires as soon as anything lets it while the apply holds them.
    discard nw.exec("systemctl stop " & R10Socket & " " & R10SocketSvc & " " &
      R10Path & " " & R10PathSvc & "; rm -f " & R10Job & " " & R10MarkerDir &
      "/*.ran; systemctl start " & R10Socket & " " & R10Path & "; true")
    nw.startAgitator()
    let nextApply = nw.exec(env & eng & " infra apply --profile " & RefDir &
      "/system_next.nim --host " & AgentTarget & " --no-preview",
      timeoutSec = 3600)
    nw.stopAgitator()
    # Owner decision 137 on triggers no hold orders (R11): the next
    # generation adds an unheld socket and an unheld timer, each declared
    # before its unconfined service. Applied after their services, both
    # are active and their services ran (the socket's on a connection made
    # now). Recorded for both before either is asserted.
    block:
      let applyOut = nextApply.stdout & nextApply.stderr
      var judged: seq[string]
      for l in nextApply.stdout.splitLines():
        let k = l.find("live check   : ")
        if k >= 0: judged = l[k + len("live check   : ") .. ^1].splitWhitespace()
      discard nw.exec("timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" &
        $R11Port & "' 2>/dev/null; true")
      var d137u = newJObject()
      var cases: seq[(string, bool, JsonNode)]
      for (label, trig, svc) in [("socket", R11Socket, R11SocketSvc),
                                 ("timer", R11Timer, R11TimerSvc)]:
        discard nw.exec("for i in $(seq 20); do [ -s " & R11MarkerDir & "/" &
          svc & ".ran ] && break; sleep 1; done; true")
        let active = nw.exec("systemctl is-active " & trig).stdout.strip()
        let (ran, ev) = nw.unitRan(svc, R11MarkerDir & "/" & svc & ".ran")
        var applyRefused = false
        for l in applyOut.splitLines():
          if ("'" & trig & "' failed") in l: applyRefused = true
        let journalNotLoaded = "not loaded" in nw.exec("journalctl -b -u " &
          trig & " --no-pager 2>&1").stdout
        ev["triggerActive"] = %active
        ev["applyRefused"] = %applyRefused
        ev["journalNotLoaded"] = %journalNotLoaded
        ev["refusedNotLoaded"] = %(applyRefused and journalNotLoaded)
        ev["ran"] = %ran
        # The premise: neither the service nor its trigger was held -- the
        # live check did not judge the service, and no hold drop-in names
        # either.
        ev["serviceJudged"] = %(svc in judged)
        ev["holdLeft"] = %nw.exec("ls /run/systemd/system/" & trig & ".d " &
          "/run/systemd/system/" & svc & ".d 2>/dev/null").stdout.strip()
        d137u[label] = ev
        cases.add((label, active == "active" and ran and
          not (applyRefused and journalNotLoaded), ev))
      d137u["exit"] = %nextApply.exitCode
      record["decision137Unheld"] = d137u
      for (label, ok, ev) in cases:
        step("decision 137, unheld " & label & " first: a " & label &
             " declared before the unconfined service it triggers, which no " &
             "hold orders, is applied, active, and its service ran",
             ok and not ev["serviceJudged"].getBool, $ev)
    block:
      let (ok, ev) = nw.triggerCase()
      record["decision151"]["nextApply"] = ev
      step("decision 151, full apply (next generation, triggers active " &
           "before it): the socket and the path unit, held through the " &
           "apply, are active after it and their services run", ok, $ev)
    # A13 review round 11, H1, as round 12 (M3, the owner decision "re-hold,
    # start after check") changed it: a full apply that died between its
    # hold and its release leaves its record of triggers and its /run holds.
    # The gate stages that state for the unheld R11 socket (stopped, held by
    # the full apply's own hold drop-in in /run, named in the record); the
    # next full apply adopts the trigger and its hold into its own held set
    # and starts it after its check, and keeps the record until it is up.
    # (Round 11's falsifier, live-check-restart-before-stale-holds-cleared,
    # went with the early restart it falsified; the step after this one is
    # red under round 12's dead-apply-holds-lifted.)
    block:
      discard nw.run("systemctl stop " & R11Socket & " " & R11SocketSvc &
        "; mkdir -p " &
        "/run/systemd/system/" & R11Socket & ".d && printf '[Unit]\\n" &
        "ConditionPathExists=!/\\n' > /run/systemd/system/" & R11Socket &
        ".d/zz-repro-carried-check-hold.conf && printf '" & R11Socket &
        "\\n' > /var/lib/repro/system/live-check-triggers && systemctl daemon-reload")
      let staged = nw.exec("systemctl is-active " & R11Socket).stdout.strip()
      let h1Apply = nw.exec(env & eng & " infra apply --profile " & RefDir &
        "/system_next.nim --host " & AgentTarget & " --no-preview",
        timeoutSec = 3600)
      let h1Active = nw.exec("systemctl is-active " & R11Socket).stdout.strip()
      let h1Record = nw.exec("cat /var/lib/repro/system/live-check-triggers " &
        "2>/dev/null").stdout.strip()
      let h1Hold = nw.exec("ls /run/systemd/system/" & R11Socket &
        ".d/zz-repro-carried-check-hold.conf 2>/dev/null").stdout.strip()
      let h1Ok = staged != "active" and h1Active == "active" and
        R11Socket notin h1Record and h1Hold.len == 0
      record["decisionH1"] = %*{"staged": staged, "exit": h1Apply.exitCode,
        "active": h1Active, "recordLeft": h1Record, "holdLeft": h1Hold,
        "ok": h1Ok}
      step("H1: the next full apply adopts a dead apply's held trigger and " &
           "its hold, starts it after its own check, and keeps the record " &
           "until it is up", h1Ok, h1Apply.stdout & h1Apply.stderr &
           "\nactive: " & h1Active & "\nrecord: " & h1Record & "\nhold: " & h1Hold)
    # A13 review round 12, M3 (the owner decision "re-hold, start after
    # check"): a full apply that died before its release left a judged
    # service held, with its socket stopped and on record, while
    # connections keep arriving. The next full apply must not lift that
    # hold before its own check: it adopts the service and the socket and
    # starts them only after the check -- and here the check refuses the
    # service (a generator makes it root at the apply's own reload, as the
    # decision-153 case's does: installed after the staging's reload, so
    # the static analysis before the apply does not see it and the live
    # check judges the service), so it never runs. The order is measured
    # on the guest: when the new apply's check began (a hold of the judged
    # path service appears), when it released (that hold goes), and when
    # the service first ran. Falsifier: the engine build
    # dead-apply-holds-lifted (round 11's order: every stale hold lifted and
    # the socket started first, so a connection starts the service before
    # the new apply's release).
    block:
      discard nw.run("rm -f " & R10MarkerDir & "/" & R10SocketSvc & ".ran; " &
        "systemctl stop " & R10Socket & " " & R10SocketSvc & "; for u in " &
        R10Socket & " " & R10SocketSvc & "; do mkdir -p " &
        "/run/systemd/system/$u.d && printf '[Unit]\\nConditionPathExists=!/\\n' > " &
        "/run/systemd/system/$u.d/zz-repro-carried-check-hold.conf; done; " &
        "printf '" & R10Socket & "\\n' > /var/lib/repro/system/live-check-triggers; " &
        "printf '" & R10SocketSvc & "\\twas-active\\n' > " &
        "/var/lib/repro/system/live-check-units; systemctl daemon-reload")
      # After the reload: the generator runs first at the apply's own.
      discard nw.run("mkdir -p /etc/systemd/system-generators && printf '#!/bin/sh\\n" &
        "mkdir -p \"$1/" & R10SocketSvc & ".d\"\\nprintf \"[Service]\\\\nUser=root\\\\n\" " &
        "> \"$1/" & R10SocketSvc & ".d/10-root.conf\"\\n' > " &
        "/etc/systemd/system-generators/a13r12-m3 && chmod 755 " &
        "/etc/systemd/system-generators/a13r12-m3")
      let watch = "H=/run/systemd/system/" & R10PathSvc &
        ".d/zz-repro-carried-check-hold.conf\nh=; r=; s=\n" &
        "while [ ! -e /run/a13m3-stop ]; do\n" &
        "  t=$(cut -d' ' -f1 /proc/uptime)\n" &
        "  if [ -z \"$h\" ] && [ -e \"$H\" ]; then h=$t; echo \"check $t\" >> /run/a13m3.log; fi\n" &
        "  if [ -n \"$h\" ] && [ -z \"$r\" ] && [ ! -e \"$H\" ]; then r=$t; echo \"release $t\" >> /run/a13m3.log; fi\n" &
        "  if [ -z \"$s\" ] && systemctl is-active --quiet " & R10SocketSvc &
        "; then s=$t; echo \"service $t\" >> /run/a13m3.log; fi\n" &
        "  sleep 0.1\ndone\n"
      writeFile(work / "a13m3-watch.sh", watch)
      nw.copyTo(work / "a13m3-watch.sh", "/run/a13m3-watch.sh")
      discard nw.exec("rm -f /run/a13m3.log /run/a13m3-stop; nohup bash " &
        "/run/a13m3-watch.sh >/dev/null 2>&1 &")
      let m3Since = nw.exec("date +%s").stdout.strip()
      nw.startAgitator()
      let m3Apply = nw.exec(env & eng & " infra apply --profile " & RefDir &
        "/system_next.nim --host " & AgentTarget & " --no-preview",
        timeoutSec = 3600)
      nw.stopAgitator()
      discard nw.exec("sleep 1; touch /run/a13m3-stop; sleep 1; true")
      let m3Order = nw.exec("cat /run/a13m3.log 2>/dev/null").stdout
      var checkAt, releaseAt, serviceAt = -1.0
      for l in m3Order.splitLines():
        let w = l.splitWhitespace()
        if w.len != 2: continue
        var t = -1.0
        try: t = parseFloat(w[1])
        except ValueError: continue
        case w[0]
        of "check": checkAt = t
        of "release": releaseAt = t
        of "service": serviceAt = t
        else: discard
      let beforeRelease = serviceAt >= 0 and (releaseAt < 0 or serviceAt < releaseAt)
      let beforeCheck = serviceAt >= 0 and (checkAt < 0 or serviceAt < checkAt)
      let m3Out = m3Apply.stdout & m3Apply.stderr
      let m3Refused = (R10SocketSvc & " as systemd loaded it is not confined") in m3Out
      let m3Ran = nw.exec("test -s " & R10MarkerDir & "/" & R10SocketSvc &
        ".ran").exitCode == 0
      let m3Journal = nw.exec("journalctl -b --no-pager -o short-monotonic " &
        "--since @" & m3Since & " -u " & R10SocketSvc & " -u " & R10Socket &
        " 2>&1").stdout
      let m3Started = journalStarted(m3Journal, R10SocketSvc) or m3Ran
      let m3HeldEtc = nw.exec("test -f /etc/systemd/system/" & R10SocketSvc &
        ".d/zz-repro-carried-check-hold.conf").exitCode == 0
      let m3Ok = m3Refused and not m3Started and m3HeldEtc and
        not beforeRelease and checkAt >= 0
      record["deadApplyAdopted"] = %*{"exit": m3Apply.exitCode,
        "refusedForReason": m3Refused, "ran": m3Ran, "started": m3Started,
        "heldInEtc": m3HeldEtc, "checkBeganAt": checkAt,
        "releasedAt": releaseAt, "serviceActiveAt": serviceAt,
        "serviceStartedBeforeCheck": beforeCheck,
        "serviceStartedBeforeRelease": beforeRelease, "ok": m3Ok}
      discard nw.run("rm -f /etc/systemd/system-generators/a13r12-m3 " &
        "/var/lib/repro/system/live-check-units " &
        "/var/lib/repro/system/live-check-triggers; for u in " & R10Socket &
        " " & R10SocketSvc & "; do rm -f /etc/systemd/system/$u.d/" &
        "zz-repro-carried-check-hold.conf /run/systemd/system/$u.d/" &
        "zz-repro-carried-check-hold.conf; done; systemctl daemon-reload; " &
        "systemctl reset-failed " & R10Socket & " " & R10SocketSvc &
        "; systemctl start " & R10Socket)
      step("M3: a judged service a dead full apply held, with connections " &
           "arriving, stays held until the next apply's check, and never " &
           "starts when that check refuses it", m3Ok,
           m3Out & "\n" & m3Journal & "\nheld in /etc: " & $m3HeldEtc &
           " ran: " & $m3Ran & "\norder (uptime s): " & m3Order)
    # A13 review round 12, M2 (the owner decision "yes, same as 175"): a
    # full apply whose generation resolves an entry of the record of
    # triggers to restart starts it, confirmed, before its commit. Staged:
    # the unheld R11 socket on record, stopped, and its service's unit file
    # gone, so the guard's retry cannot start it (systemd refuses a socket
    # whose service is not loaded); the generation rewrites the service and
    # leaves the socket's file unchanged, so no driver starts the socket.
    # Falsifier: the engine build full-apply-fixing-skips-starts (the apply
    # commits and clears the record, the socket down).
    block:
      discard nw.run("systemctl stop " & R11Socket & " " & R11SocketSvc &
        "; rm -f /etc/systemd/system/" & R11SocketSvc & "; systemctl " &
        "daemon-reload; printf '" & R11Socket & "\\trendered=" & R11Socket &
        ":0," & R11SocketSvc & ":0\\n' > /var/lib/repro/system/" &
        "triggers-to-restart; chmod 600 /var/lib/repro/system/triggers-to-restart")
      let m2Staged = nw.exec("systemctl start " & R11Socket & " 2>&1; " &
        "systemctl is-active " & R11Socket).stdout.strip()
      let m2Apply = nw.exec(env & eng & " infra apply --profile " & RefDir &
        "/system_next.nim --host " & AgentTarget & " --no-preview",
        timeoutSec = 3600)
      let m2Out = m2Apply.stdout & m2Apply.stderr
      let m2Active = nw.exec("systemctl is-active " & R11Socket).stdout.strip()
      let m2Record = nw.exec("cat /var/lib/repro/system/triggers-to-restart " &
        "2>/dev/null").stdout.strip()
      let m2StagedState = m2Staged.splitLines()[^1].strip()
      let m2Ok = m2StagedState != "active" and m2Apply.exitCode == 0 and m2Active == "active" and m2Record.len == 0
      record["fullApplyFixing"] = %*{"staged": m2Staged,
        "exit": m2Apply.exitCode, "active": m2Active,
        "recordLeft": m2Record, "ok": m2Ok}
      discard nw.run("rm -f /var/lib/repro/system/triggers-to-restart; " &
        "systemctl start " & R11Socket & "; true")
      step("M2: a full apply whose generation resolves a recorded trigger " &
           "starts it before its commit, and clears the record", m2Ok,
           m2Out & "\nstaged: " & m2Staged & "\nactive: " & m2Active &
           "\nrecord: " & m2Record)
    # A13 review round 13, M-B: a full apply that died before its release
    # held a judged service that was running and is not enabled (the R10
    # socket's service, started by a connection), with its socket stopped:
    # staged as such an apply leaves the host -- both stopped, both held,
    # the socket on the record of triggers and the service on the record of
    # units as one that ran -- and no connection afterwards. The next full
    # apply's check passes it and must start it again, only after its own
    # check: "ran before the dead hold" is kept for a unit this apply judges
    # too. The order is measured on the guest, as in the M3 step: when the
    # check began (a hold of the judged path service appears), when it
    # released (that hold goes), when the service first ran. Falsifier: the
    # engine build dead-judged-was-active-lost (the service stays down).
    block:
      discard nw.exec("timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" &
        $R10Port & "' 2>/dev/null; for i in $(seq 15); do systemctl " &
        "is-active --quiet " & R10SocketSvc & " && break; sleep 1; done; true")
      let mbBefore = nw.exec("systemctl is-active " & R10SocketSvc).stdout.strip()
      discard nw.run("systemctl stop " & R10Socket & " " & R10SocketSvc &
        "; for u in " & R10Socket & " " & R10SocketSvc & "; do mkdir -p " &
        "/run/systemd/system/$u.d && printf '[Unit]\\nConditionPathExists=!/\\n' > " &
        "/run/systemd/system/$u.d/zz-repro-carried-check-hold.conf; done; " &
        "printf '" & R10Socket & "\\n' > /var/lib/repro/system/live-check-triggers; " &
        "printf '" & R10SocketSvc & "\\twas-active\\n' > " &
        "/var/lib/repro/system/live-check-units; systemctl daemon-reload")
      let mbStaged = nw.exec("systemctl is-active " & R10SocketSvc).stdout.strip()
      let mbSocketStaged = nw.exec("systemctl is-active " & R10Socket).stdout.strip()
      let mbWatch = "H=/run/systemd/system/" & R10PathSvc &
        ".d/zz-repro-carried-check-hold.conf\nh=; r=; s=\n" &
        "while [ ! -e /run/a13mb-stop ]; do\n" &
        "  t=$(cut -d' ' -f1 /proc/uptime)\n" &
        "  if [ -z \"$h\" ] && [ -e \"$H\" ]; then h=$t; echo \"check $t\" >> /run/a13mb.log; fi\n" &
        "  if [ -n \"$h\" ] && [ -z \"$r\" ] && [ ! -e \"$H\" ]; then r=$t; echo \"release $t\" >> /run/a13mb.log; fi\n" &
        "  if [ -z \"$s\" ] && systemctl is-active --quiet " & R10SocketSvc &
        "; then s=$t; echo \"service $t\" >> /run/a13mb.log; fi\n" &
        "  sleep 0.1\ndone\n"
      writeFile(work / "a13mb-watch.sh", mbWatch)
      nw.copyTo(work / "a13mb-watch.sh", "/run/a13mb-watch.sh")
      discard nw.exec("rm -f /run/a13mb.log /run/a13mb-stop; nohup bash " &
        "/run/a13mb-watch.sh >/dev/null 2>&1 &")
      let mbApply = nw.exec(env & eng & " infra apply --profile " & RefDir &
        "/system_next.nim --host " & AgentTarget & " --no-preview",
        timeoutSec = 3600)
      discard nw.exec("for i in $(seq 15); do systemctl is-active --quiet " &
        R10SocketSvc & " && break; sleep 1; done; sleep 1; touch /run/a13mb-stop; " &
        "sleep 1; true")
      let mbOrder = nw.exec("cat /run/a13mb.log 2>/dev/null").stdout
      var mbCheck, mbRelease, mbService = -1.0
      for l in mbOrder.splitLines():
        let w = l.splitWhitespace()
        if w.len != 2: continue
        var t = -1.0
        try: t = parseFloat(w[1])
        except ValueError: continue
        case w[0]
        of "check": mbCheck = t
        of "release": mbRelease = t
        of "service": mbService = t
        else: discard
      let mbAfter = nw.exec("systemctl is-active " & R10SocketSvc).stdout.strip()
      let mbEnabled = nw.exec("systemctl is-enabled " & R10SocketSvc &
        " 2>&1").stdout.strip()
      let mbHold = nw.exec("ls /run/systemd/system/" & R10SocketSvc &
        ".d/zz-repro-carried-check-hold.conf 2>/dev/null").stdout.strip()
      let mbAfterRelease = mbService >= 0 and mbCheck >= 0 and
        mbRelease >= 0 and mbService >= mbRelease
      let mbOk = mbBefore == "active" and mbStaged != "active" and
        mbSocketStaged != "active" and mbApply.exitCode == 0 and
        mbAfter == "active" and mbHold.len == 0 and mbAfterRelease
      record["deadJudgedActive"] = %*{"before": mbBefore, "staged": mbStaged,
        "socketStaged": mbSocketStaged, "exit": mbApply.exitCode,
        "after": mbAfter, "enabled": mbEnabled, "holdLeft": mbHold,
        "checkBeganAt": mbCheck, "releasedAt": mbRelease,
        "serviceActiveAt": mbService, "ok": mbOk}
      discard nw.run("rm -f /var/lib/repro/system/live-check-units " &
        "/var/lib/repro/system/live-check-triggers; for u in " & R10Socket &
        " " & R10SocketSvc & "; do rm -f /run/systemd/system/$u.d/" &
        "zz-repro-carried-check-hold.conf; done; systemctl daemon-reload; " &
        "systemctl start " & R10Socket & "; true")
      step("M-B: a judged service a dead full apply held while it ran, not " &
           "enabled, is started again once the next apply's check passes it",
           mbOk, mbApply.stdout & mbApply.stderr & "\nbefore: " & mbBefore &
           " staged: " & mbStaged & " socket staged: " & mbSocketStaged &
           " after: " & mbAfter & " enabled: " & mbEnabled & " hold: " &
           mbHold & "\norder (uptime s): " & mbOrder)
    # A13 review round 13, M-C: a profile drop-in that points ssh.socket at a
    # judged unit makes an essential trigger of it; the apply is refused
    # before it writes anything, by that refusal and no other, and ssh.socket
    # is neither stopped nor held. On ubuntu-24.04 ssh is socket-activated.
    block:
      let sshBefore = nw.exec("systemctl show -p ActiveState ssh.socket").stdout.strip()
      let r = nw.exec(env & eng & " infra apply --profile " & RefDir &
        "/system_ssh.nim --host " & AgentTarget & " --no-preview",
        timeoutSec = 3600)
      let o = r.stdout & r.stderr
      let essText = "ssh.socket would be held for the carried-state check"
      let written = nw.exec("ls /etc/systemd/system/ssh.socket.d 2>&1").stdout
      let heldAnywhere = nw.exec("ls /etc/systemd/system/ssh.socket.d/" &
        "zz-repro-carried-check-hold.conf /run/systemd/system/ssh.socket.d/" &
        "zz-repro-carried-check-hold.conf 2>/dev/null").stdout.strip()
      let sshAfter = nw.exec("systemctl show -p ActiveState ssh.socket").stdout.strip()
      let refusedSsh = r.exitCode != 0 and essText in o
      let dropInWritten = "a13-repoint" in written
      discard nw.run("rm -f /etc/systemd/system/ssh.socket.d/50-repro-a13-repoint.conf; " &
        "rmdir /etc/systemd/system/ssh.socket.d 2>/dev/null; systemctl daemon-reload; true")
      let sshOk = refusedSsh and not dropInWritten and heldAnywhere.len == 0 and
        sshAfter == sshBefore
      record["essentialHostTrigger"] = %*{"exit": r.exitCode,
        "refused": refusedSsh, "dropInWritten": dropInWritten,
        "held": heldAnywhere, "before": sshBefore, "after": sshAfter,
        "ok": sshOk}
      step("M-C: an apply whose drop-in points ssh.socket at a judged unit " &
           "is refused before it writes anything, and ssh.socket is neither " &
           "stopped nor held", sshOk, o & "\nwritten: " & written &
           "\nheld: " & heldAnywhere & "\nbefore: " & sshBefore &
           " after: " & sshAfter)
    # Decision 177 (A13 review round 11): with carried state restored, an
    # apply of the next generation plus a drop-in that makes a console getty
    # require a judged unit would hold an essential unit, so it is refused
    # before it writes anything -- by that refusal and no other (its text,
    # and the absence of every other refusal the apply reports). Falsifier:
    # the engine build essential-requirers-held.
    block:
      let r = nw.exec(env & eng & " infra apply --profile " & RefDir &
        "/system_ess.nim --host " & AgentTarget & " --no-preview",
        timeoutSec = 3600)
      let o = r.stdout & r.stderr
      let essText = "getty@tty6.service would be held for the carried-state check"
      let otherRefusal = "carried state is not restored yet" in o or
        "carried state's owners would not match" in o or
        "ECarriedStatePending" in o.replace("ECarriedStatePending: getty@tty6.service would be held", "")
      let refusedEss = r.exitCode != 0 and essText in o and not otherRefusal
      let written = nw.exec("ls /etc/systemd/system/getty@tty6.service.d 2>&1").stdout
      let dropInWritten = "a13-ess" in written
      discard nw.run("rm -rf /etc/systemd/system/getty@tty6.service.d " &
        "/run/systemd/system/getty@tty6.service.d; systemctl daemon-reload")
      record["decisionEssential"] = %*{"exit": r.exitCode,
        "refused": refusedEss, "essentialRefusalText": essText in o,
        "otherRefusal": otherRefusal, "dropInWritten": dropInWritten}
      step("decision 171: an apply in which an essential requirer would be held " &
           "(a console getty that requires a judged unit) is refused before " &
           "it writes anything", refusedEss and not dropInWritten,
           o & "\n" & written)
    # Decision 151 with the socket's service running and connections
    # arriving during the apply (the common case): a trigger whose unit runs
    # cannot fire at the hold and is left alone -- with Accept=no the
    # service holds the listening socket, so a stopped socket could not be
    # started again -- and the service stays reachable.
    block:
      discard nw.exec("timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" &
        $R10Port & "' 2>/dev/null; for i in $(seq 15); do [ -s " & R10MarkerDir &
        "/" & R10SocketSvc & ".ran ] && break; sleep 1; done; true")
      let before = nw.exec("systemctl show -p ActiveState " & R10SocketSvc).stdout.strip()
      nw.startAgitator()
      let runApply = nw.exec(env & eng & " infra apply --profile " & RefDir &
        "/system_next.nim --host " & AgentTarget & " --no-preview",
        timeoutSec = 3600)
      nw.stopAgitator()
      let after = nw.exec("systemctl show -p ActiveState " & R10SocketSvc &
        "; systemctl show -p ActiveState -p Result " & R10Socket &
        "; timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/" & $R10Port &
        "' && echo reachable").stdout
      let ok = runApply.exitCode == 0 and before == "ActiveState=active" and
        after.count("ActiveState=active") == 2 and "reachable" in after
      record["decision151"]["running"] = %*{"exit": runApply.exitCode,
        "before": before, "after": after, "ok": ok}
      step("decision 151, full apply (service running): a socket whose " &
           "service runs with connections arriving stays active through the " &
           "apply, and the service stays reachable", ok,
           runApply.stdout & runApply.stderr & "\nbefore: " & before &
           "\nafter: " & after)
    step("round 5, undeclared: a drop-in the next generation no longer " &
         "declares is removed by the full apply, the requirement kept",
         tuneBefore and nextApply.exitCode == 0 and
         nw.exec("test -e " & R5TuneDropIn).exitCode != 0 and
         nw.exec("test -f " & R5DistDropIn).exitCode == 0,
         "before: " & $tuneBefore & "\n" & nextApply.stdout & nextApply.stderr &
         "\n" & nw.exec("ls -la /etc/systemd/system/" & R5DistUnit & ".d " &
           "/etc/systemd/system/" & R5TunedUnit & ".d").stdout)
    for (u, check) in [("vaultwarden.service", "http://127.0.0.1:8000/alive"),
                       ("eth-execution.service", "tcp:127.0.0.1:8545"),
                       ("eth-beacon.service",
                        "http://127.0.0.1:3500/eth/v1/node/version"),
                       (DefaultValidatorUnit, "http://127.0.0.1:8081/healthz")]:
      var ok = false
      for i in 0 ..< 60:
        if nw.exec(eng & " system addon probe " & check).exitCode == 0:
          ok = true
          break
        discard nw.exec("sleep 2")
      step(u & " passes its health check after the conversion", ok,
           nw.serviceJournal([u]))
    # The carried beacon database: the node resumes on the add-on host's
    # chain, not at genesis. (Prysm restarts its fork choice from its last
    # justified checkpoint, so the head it reports can be below the one the
    # add-on host last reported; a node with an empty database has no
    # block but genesis, slot 0.)
    var resumed = -1
    for i in 0 ..< 60:
      resumed = nw.headSlot()
      if resumed > 0: break
      discard nw.exec("sleep 2")
    step("the beacon node resumes from the carried chain, not from genesis",
         resumed > 0 and oldHead > 0,
         "head " & $resumed & ", add-on host had " & $oldHead)

    # --- 5. The validator never ran between backup and restore, and never
    # signed a conflicting message.
    let firstStart = nw.monotonicOf(DefaultValidatorUnit,
                                    "ExecMainStartTimestampMonotonic")
    # The manager's completed start jobs this boot, not every "Started"
    # line of the unit's journal: the validator's own output has them too.
    let starts = $managerStartJobsDone(nw.exec("journalctl -b --no-pager " &
      "-o verbose _PID=1 UNIT=" & DefaultValidatorUnit & " 2>&1").stdout)
    step("on the new host the validator first started after the restore",
         restoredDone > 0 and firstStart > restoredDone and starts == "1",
         "restore done " & $restoredDone & ", validator start " & $firstStart &
         ", starts this boot " & starts)
    # It signs again: the chain moves past the restore's epoch (the
    # validators hold every key, so no epoch is justified without them).
    var progressed = false
    let deadline2 = epochTime() + 1500
    while epochTime() < deadline2:
      if nw.justifiedEpoch() > restoreEpoch or
          nw.headSlot() >= (restoreEpoch + 4) * SlotsPerEpoch:
        progressed = true
        break
      discard nw.exec("sleep 10")
    discard nw.waitHeadSlot(nw.headSlot() + 2 * SlotsPerEpoch,
                        60 + 4 * SecondsPerEpoch)
    record["afterConversion"] = %*{"head": nw.headSlot(),
      "justified": nw.justifiedEpoch(), "restoreEpoch": restoreEpoch}
    discard nw.run("systemctl stop " & DefaultValidatorUnit)
    let hist = block:
      let r = nw.exec("rm -rf /var/tmp/a13-hist && mkdir -p /var/tmp/a13-hist && chown " &
        "eth-validator: /var/tmp/a13-hist && runuser -u eth-validator -- " &
        pins.validatorPrefix & "/bin/validator slashing-protection-history " &
        "export --accept-terms-of-use --datadir " & pins.validatorStateDir &
        " --slashing-protection-export-dir /var/tmp/a13-hist >/var/tmp/a13-hist.log 2>&1 " &
        "&& cat /var/tmp/a13-hist/*.json")
      if r.exitCode != 0: newJObject() else: parseJson(r.stdout)
    if not hist.hasKey("data"):
      step("the validator's slashing-protection history can be exported",
           false, nw.exec("tail -c 2000 /var/tmp/a13-hist.log").stdout)
    let cs = conflicts([hist])
    let earliest = earliestTarget([hist])
    var latest = 0
    for rec in hist{"data"}.getElems():
      for a in rec{"signed_attestations"}.getElems():
        latest = max(latest, parseInt(a{"target_epoch"}.getStr("0")))
    var carriedHistory = earliest.len == InteropValidators
    var earliestMin = high(int)
    for k, ep in earliest:
      if ep > oldEpoch: carriedHistory = false
      earliestMin = min(earliestMin, ep)
    # What the history step decides on, recorded before it is decided: a
    # history that is red because it begins after the add-on host's epoch on
    # a chain that progressed is distinct from one that is merely empty.
    record["historyEvidence"] = %*{"keys": earliest.len,
      "earliestMin": (if earliest.len > 0: earliestMin else: -1),
      "addOnEpoch": oldEpoch, "progressed": progressed,
      "attestations": attestationCount([hist]), "conflicts": cs.len}
    step("the slashing-protection history was carried: every key's history " &
         "begins on the add-on host, and it holds no conflicting signature",
         cs.len == 0 and carriedHistory and attestationCount([hist]) > 0,
         "conflicts " & $cs.len & ", earliest " & $earliest & ", latest " &
         $latest & ", add-on epoch " & $oldEpoch)
    let chainStart = nw.exec("journalctl -b -q --no-pager " &
      "-u eth-execution.service -u eth-beacon.service | grep -E " &
      quoteShell(ChainLogPattern) & " | head -n 60").stdout
    record["convertedStart"] = %chainStart
    var latestPerKey = initTable[string, int]()
    for rec in hist{"data"}.getElems():
      for a in rec{"signed_attestations"}.getElems():
        let k = rec{"pubkey"}.getStr()
        latestPerKey[k] = max(latestPerKey.getOrDefault(k),
                              parseInt(a{"target_epoch"}.getStr("0")))
    var allSignedAfter = latestPerKey.len == InteropValidators
    for k, ep in latestPerKey:
      if ep <= restoreEpoch: allSignedAfter = false
    step("the validator signs on the converted host: every key attested " &
         "for an epoch past the one the restore ran in",
         progressed and allSignedAfter,
         "chain progressed " & $progressed & ", latest per key " &
         $latestPerKey & ", restore epoch " & $restoreEpoch &
         (if progressed: "" else: "\n" & chainStart))

    # --- 6. The kept disk is required.
    discard nw.run("systemctl stop vaultwarden.service; umount " & KeepDir &
      "; sed -i 's#^LABEL=repro-keep .*#LABEL=repro-missing " & KeepDir &
      " ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2#' /etc/fstab; " &
      "systemctl daemon-reload")
    let vwStart = nw.exec("systemctl start vaultwarden.service", timeoutSec = 120)
    discard nw.exec("sleep 5")
    let vwState = nw.exec("systemctl is-active vaultwarden.service").stdout.strip()
    let onRoot = nw.exec("ls -A " & KeepDir).stdout.strip()
    step("with its kept disk missing vaultwarden does not start and writes " &
         "nothing on the root file system",
         vwStart.exitCode != 0 and vwState != "active" and onRoot.len == 0,
         "start exit " & $vwStart.exitCode & ", state " & vwState &
         ", on the root file system: " & onRoot)
    # --- 7. The boot path is governed by the restore too: with the restored
    # validator directory replaced and its archive damaged, the restore unit
    # fails at the next boot, and the validator, which requires it, is not
    # started (review round 2, finding 4).
    # Durability: the restore unit is disabled and preset, which removes
    # every link to it; the requirement is the carried units' own drop-in,
    # so the next boot's restore still runs, fails on the replaced validator
    # directory's damaged archive, and the carried units stay down. Red under
    # the engine build ``restore-required-by-link``.
    const Exe = "eth-execution.service"
    var validatorArchive, executionArchive = ""
    for e in manifest["entries"]:
      if e["path"].getStr() == "/var/lib/ethereum/validator":
        validatorArchive = e["archive"].getStr()
      if e["path"].getStr() == "/var/lib/ethereum/execution":
        executionArchive = e["archive"].getStr()
    proc replaceDir(v: string): string =
      "own=$(stat -c %u:%g " & v & "); mode=$(stat -c %a " & v & "); rm -rf " &
        v & " && mkdir " & v & " && chown $own " & v & " && chmod $mode " & v
    discard nw.run("systemctl stop " & DefaultValidatorUnit & "; " &
      replaceDir("/var/lib/ethereum/validator") & "; printf x | dd of=" &
      CarriedDir & "/" & validatorArchive & " bs=1 seek=4096 conv=notrunc " &
      "2>/dev/null; systemctl disable " & RestoreUnit & "; systemctl preset " &
      RestoreUnit & " || true")
    record["bootPathSetup"] = %(nw.exec("systemctl is-enabled " & RestoreUnit &
      " || true").stdout & "damaged " & validatorArchive)
    nw.rebootGuest()
    # The restore unit is started more than once at boot (a carried unit's
    # start queues it again after the first failure), so a single read can
    # race a later run (A13 review round 12: conv-debian-12 at 6b8fa94fc6
    # read it `activating`). Wait on the guest until it has left
    # `activating` for 15 s in a row, up to 120 s -- a timeout fails the
    # step -- and, at every poll of the wait, record any carried unit that
    # is active, so one that starts between the restore's runs is caught.
    let settleUnits = [DefaultValidatorUnit, Exe, ShadowUnit, R5DistUnit]
    writeFile(work / "a13-restore-settle.sh",
      "calm=0; i=0\nwhile [ $i -lt 240 ]; do\n" &
      "  for u in " & settleUnits.join(" ") & "; do\n" &
      "    systemctl is-active --quiet $u && echo \"ACTIVE $u $(cut -d' ' -f1 /proc/uptime)\"\n" &
      "  done\n" &
      "  s=$(systemctl show -p ActiveState --value " & RestoreUnit & ")\n" &
      "  if [ \"$s\" = activating ]; then calm=0; else calm=$((calm+1)); fi\n" &
      "  [ $calm -ge 30 ] && { echo \"SETTLED $s\"; exit 0; }\n" &
      "  i=$((i+1)); sleep 0.5\ndone\necho TIMEOUT\n")
    nw.copyTo(work / "a13-restore-settle.sh", "/run/a13-restore-settle.sh")
    let settle = nw.exec("bash /run/a13-restore-settle.sh", timeoutSec = 200).stdout
    let settled = "SETTLED " in settle and "TIMEOUT" notin settle
    var activeDuring: seq[string]
    for l in settle.splitLines():
      if l.startsWith("ACTIVE "): activeDuring.add(l)
    let rres = nw.run("systemctl show -p Result -p ActiveState " & RestoreUnit)
    var bad: seq[string]
    for u in [DefaultValidatorUnit, Exe, ShadowUnit, R5DistUnit]:
      let st = nw.exec("systemctl is-active " & u).stdout.strip()
      let n = nw.exec("journalctl -b -u " & u &
        " --no-pager | grep -c 'Started' || true").stdout.strip()
      if st == "active" or n != "0": bad.add(u & " " & st & ", starts " & n)
    record["bootPathSettle"] = %*{"settled": settled,
      "activeDuring": activeDuring, "final": rres}
    step("a carried unit does not start at boot while its restore fails",
         settled and activeDuring.len == 0 and "Result=success" notin rres and
           bad.len == 0,
         "settle: " & settle & "\n" & rres & "\nstarted: " & bad.join("; ") & "\n" &
         nw.serviceJournal([RestoreUnit, Exe, DefaultValidatorUnit]))

    # Ordering, observed while the restore is provably still running. The
    # execution client is given no default dependencies (it has no ordering
    # of its own), and its directory is emptied, so the restore must write it
    # back. The engine's seam build (``REPRO_A13_ENGINE_SEAMS=1``: the engine
    # built with ``REPRO_ADDON_TEST_SEAMS``; the product engine carries no
    # seam) holds the restore at ``restore-before-archive``. A start of the
    # client queues the restore; while the restore is shown paused at the
    # seam, the client must still be waiting on its start job. Resumed, the
    # restore writes the execution directory back and then fails on the
    # validator's damaged archive, and the client must never have started.
    # Red under the engine build ``restore-unordered`` (with seams). Nothing
    # here depends on timing.
    if getEnv("REPRO_A13_ENGINE_SEAMS") != "1":
      # The product engine has no seam: the check runs in the cell that
      # uses the engine's seam build, and this record says it did not run.
      record["orderingCheck"] = %("not run: the product engine carries no " &
        "seam (the seam-build cell runs it)")
    else:
      record["orderingCheck"] = %"run (engine seam build)"
      const SeamDir = "/var/lib/repro/system/addon"
      discard nw.run(replaceDir("/var/lib/ethereum/execution") & "; mkdir -p " &
        "/etc/systemd/system/" & Exe & ".d && printf '[Unit]\\n" &
        "DefaultDependencies=no\\n' > /etc/systemd/system/" & Exe &
        ".d/95-a13-no-default-deps.conf && systemctl daemon-reload && " &
        "systemctl reset-failed " & RestoreUnit & " " & Exe & " " &
        DefaultValidatorUnit & " || true; mkdir -p " & SeamDir & " && rm -f " &
        SeamDir & "/test-paused-at " & SeamDir & "/test-resume && echo " &
        "restore-before-archive > " & SeamDir & "/test-pause-at")
      discard nw.run("systemctl start --no-block " & Exe)
      let paused = nw.exec("for i in $(seq 1 120); do grep -qx " &
        "restore-before-archive " & SeamDir & "/test-paused-at 2>/dev/null && " &
        "[ \"$(systemctl show -p ActiveState --value " & RestoreUnit &
        ")\" = activating ] && exit 0; sleep 1; done; exit 1")
      let held = nw.exec("systemctl show -p ActiveState -p SubState " & Exe &
        "; systemctl list-jobs --no-legend 2>/dev/null | grep -F " & Exe &
        " || true").stdout
      let waiting = paused.exitCode == 0 and "ActiveState=inactive" in held and
        "waiting" in held
      discard nw.run("touch " & SeamDir & "/test-resume")
      discard nw.exec("for i in $(seq 1 300); do s=$(systemctl show -p " &
        "ActiveState --value " & RestoreUnit & "); [ \"$s\" = activating ] || " &
        "break; sleep 1; done")
      discard nw.exec("for i in $(seq 1 30); do systemctl list-jobs " &
        "--no-legend 2>/dev/null | grep -qF " & Exe & " || break; sleep 1; done")
      let after = nw.exec("systemctl show -p Result -p ActiveState " &
        RestoreUnit & "; systemctl is-active " & Exe & "; journalctl -b -u " &
        Exe & " --no-pager | grep -c 'Started' || true").stdout
      let lines = after.strip().splitLines()
      let neverStarted = "Result=success" notin after and lines.len >= 4 and
        lines[^2].strip() != "active" and lines[^1].strip() == "0"
      step("a carried unit without default dependencies waits for the " &
           "restore (held at its seam) and does not start when it fails",
           waiting and neverStarted,
           "restore paused at the seam: " & $(paused.exitCode == 0) &
           "; while held:\n" & held & "after the release:\n" & after & "\n" &
           nw.serviceJournal([RestoreUnit, Exe]))
    record["history"] = %*{"keys": earliest.len, "latestTarget": latest,
                           "addOnEpoch": oldEpoch, "restoreEpoch": restoreEpoch,
                           "conflicts": cs.len}
  except MutationStop as e:
    steps.add(%*{"step": "stopped at the first red step under the mutation",
                 "ok": false, "detail": e.msg})
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    var logs: seq[string]
    for g in [old, nw]:
      if g != nil:
        logs.add(g.log)
        g.destroy()
    record["log"] = %logs
    try: dd.release()
    except CatchableError: discard
  fails

suite Gate:
  test "a converted add-on host keeps and carries its state and never " &
       "runs the validator before the restore":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1, " &
           "REPRO_ADDON_ENGINE_CLOSURE and REPRO_A12_PACKAGES")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(),
          "gateMutation": gateMutation(), "reprobuild": gitHead(),
          "gosti": gostiHead(), "started": $now().utc,
          "conversion": "rehearsed by reinstall (decision 41); ReproOS " &
            "Anywhere's protocol not exercised"}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

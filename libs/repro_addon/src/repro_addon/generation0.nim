## Generation 0: the add-on's own objects.
##
## Bootstrap's last step applies one generation through ``repro infra
## apply``, the same path every later generation takes; bootstrap has no
## apply code of its own. That generation contains only what the add-on
## needs to exist on the host:
##
## - ``repro-addon.target``: the target the add-on's units hang off, wanted
##   by ``multi-user.target``. Nothing of the base ``Requires=`` it, so a
##   broken add-on cannot hold up the base's boot;
## - ``repro-store.mount``: ``/repro/store`` bind-mounted read-only over
##   itself, so no process on the host can write the store through the
##   ordinary mount namespace (the apply process gets a private writable
##   view; see ``store_root.withWritableStore``);
## - ``repro-addon-reassert.service``: at boot, finishes or reverts an
##   interrupted switch and reports whether every ledger object still
##   matches its digest. It never re-applies on drift, and it has no
##   network;
## - the apt hook ``/etc/apt/apt.conf.d/90repro-addon``: a report-only
##   ``DPkg::Post-Invoke`` that can never fail or stall a dpkg run, even when
##   the binary it names is missing, fails or hangs (``aptHookCommand``);
## - ``/etc/profile.d/repro-addon.sh``: the add-on's ``repro`` on ``PATH``
##   (appended). The profile DSL's ``addOnToolPath()`` writes a file of its
##   own, ``/etc/profile.d/repro-addon-tools.sh`` (``repro_profile``
##   ``AddOnToolPathFile``): one file, one writer -- spec §4.1;
## - the trust anchors under ``/etc/repro/anchors``.
##
## Every path here must be absent before bootstrap (the preflight checks
## it), which is what makes "bootstrap changes nothing pre-existing" a
## property of this list rather than a hope. The pre-bootstrap inputs the
## preflight takes over (spec §6.1) are never on this list.
##
## The text this module renders is the canonical system-profile text
## ``repro infra apply`` parses (``repro_infra/profile.parseSystemProfile``).
## That format has no escapes, so file bodies are not written inline: each
## is a content-addressed file in the add-on's own store prefix, named by
## its SHA-256 and referenced with ``sourceLocal``. Unit bodies are inline,
## and ``assertInlineSafe`` refuses any character the format cannot carry
## rather than letting the parser misread it.

import std/[algorithm, strutils]

import repro_elevation/posix_system_parse
from repro_infra/profile import SecretsBootUnit

import ./fingerprint
import ./mutations

type
  OwnObjectKind* = enum
    ookUnit, ookEtcFile

  OwnObject* = object
    kind*: OwnObjectKind
    path*: string        ## absolute target path
    unit*: string        ## unit name (ookUnit)
    content*: string
    enabled*: bool       ## ookUnit: ``systemctl enable --now``

  Gen0Inputs* = object
    reproExe*: string           ## the add-on's ``repro`` inside the store
    deploySigners*: seq[string] ## deploy-manifest signer keys (hex), canonical
    cacheUrl*: string           ## the binary cache to substitute from, or ""
    cachePublishers*: seq[string] ## the only producer keys trusted for it
    agent*: AgentUnitsInputs    ## the deploy agent's units (A8); none when
                                ## ``agent.target`` is empty
    egress*: EgressObserverInputs
      ## The egress observer; none when ``egress.nft`` is empty.
    evidence*: EvidenceUnitsInputs
      ## The Evidence sink and the units that ship to it (A11, spec §10.4);
      ## none when ``evidence.sinkAddress`` is empty, so a host bootstrapped
      ## without a sink keeps the generation 0 it had.

  EgressObserverInputs* = object
    ## The deploy agent's egress observer (owner decision 2026-11-04, threat
    ## model G40, DET-AO-3): the add-on's own nftables table, counting and
    ## logging every packet from the fetch unit's slice to an address the
    ## unit may not reach. Present on a host with both the deploy agent and
    ## an Evidence sink; bootstrap refuses one whose base cannot carry it.
    nft*: string                     ## the base's ``nft`` ("" = none)
    allowedAddresses*: seq[string]   ## the fetch unit's, as its allow-list

  EvidenceUnitsInputs* = object
    ## Where this host's evidence records go (spec §10.4): one Evidence sink
    ## (reprobuild's ``repro-evidence-sink``), named by address -- the
    ## shipping unit has no DNS -- and pinned by its own CA certificate, the
    ## only certificate the shipping unit trusts for it.
    sinkAddress*: string        ## an IPv4 or IPv6 literal
    sinkPort*: int
    sinkCaPem*: string          ## the sink's host CA (PEM)
    sinkHostId*: string         ## its host id (64 hex), derived from the CA
    heartbeatSec*: int          ## the shipping unit's timer (0: the default)

  AgentUnitsInputs* = object
    ## What generation 0 needs to carry the deploy agent's two units (spec
    ## §9.1): the target, the manifest sources, the addresses the fetch
    ## unit may reach, and the names it resolves through its own hosts
    ## file (it has no DNS).
    target*: string
    sources*: seq[string]
    allowedAddresses*: seq[string]   ## sorted, for ``IPAddressAllow=``
    hosts*: seq[tuple[address, name: string]]  ## sorted
    profileCompiler*: string         ## "" when none is configured
    pollIntervalSec*: int
      ## The fetch timer's ``OnUnitActiveSec=`` in seconds; 0 is the default
      ## (``DefaultAgentPollSec``). A tick's evidence record carries it, so
      ## the off-host silence check knows when a tick is overdue (DET-AO-8).

const
  SystemdUnitDir* = "/etc/systemd/system"
  AddonTarget* = "repro-addon.target"
  StoreMountUnit* = "repro-store.mount"
  ReassertUnit* = "repro-addon-reassert.service"
  ReassertTimeoutMin* = 90
    ## The re-assert unit's start timeout: a recovery killed at it leaves
    ## its marker for the next boot.
  BootConfirmCapSec* = 30 * 60
    ## At boot a recovery may run two confirms -- the replay's and, when it
    ## fails, its revert's -- each capped at this, whatever the profile's
    ## ``confirmTimeout``, so both fit inside ``ReassertTimeoutMin`` with
    ## half an hour left for the transitions themselves.
  SecretsUnit* = SecretsBootUnit
    ## ``repro-addon-secrets.service`` (``secretsUnit``).
  SecretsUnitTimeoutSec* = 60
    ## The secrets unit's start timeout: it is on the base's boot path.
  ReassertReportPath* = "/var/lib/repro/system/addon/reassert-report"
    ## Where the re-assert unit's last report is kept (``reassert.nim``).
  AptHookPath* = "/etc/apt/apt.conf.d/90repro-addon"
  ProfileDPath* = "/etc/profile.d/repro-addon.sh"
  AnchorsDir* = "/etc/repro/anchors"
  DeploySignersPath* = AnchorsDir & "/deploy-signers.anchors"
  CachesConfPath* = "/etc/repro/caches.conf"
  SupersedableOwnPaths* = [DeploySignersPath, CachesConfPath]
    ## The generation-0 objects a profile may take over (spec §9,
    ## "Generation-0 objects a profile supersedes"): the two configuration
    ## files bootstrap only seeds -- whom manifests may be signed by, and
    ## which cache with which publisher keys. A profile that declares one
    ## becomes its single writer; generation 0's copy comes back when the
    ## profile stops declaring it (a rollback to generation 0 among them).
    ## Every other object of generation 0 is the add-on's runtime (its
    ## units, the apt hook, /etc/profile.d) or the deploy agent's
    ## confinement (agent.conf, the fetch unit's pinned hosts): a profile,
    ## and so a deploy manifest, that could replace those could switch off
    ## the add-on's recovery or widen the agent's sandbox, so they stay
    ## refused.
    ## The system binary-cache client configuration (``repro_binary_cache_client
    ## /caches_config``): the cache list every substitution on the host reads,
    ## each cache with the only producer keys trusted for it.
  StoreRoot* = "/repro/store"
  # --- Milestone A11: evidence (spec §10.4, §10.5). ----------------------
  EvidenceConfPath* = "/etc/repro/evidence.conf"
    ## The Evidence sink this host ships to and the intervals the off-host
    ## silence check expects records at (``renderEvidenceConf``).
  EvidenceSinkCaPath* = "/etc/repro/evidence-sink.crt"
    ## The sink's host CA: the one certificate the shipping unit trusts for
    ## the sink (never the peer-cache anchors, threat model G28's rule).
  EvidenceStateDir* = "/var/lib/repro/evidence"
    ## ``0700 root``: the host's sink write credential (``host-ca.key``,
    ## ``host-ca.crt``), the shipping cursor and the sink's last receipt.
    ## Nothing else can read the credential; the shipping unit cannot read
    ## the attestation key or the recipient key (they are under
    ## ``/var/lib/repro/agent``, hidden from it).
  EvidenceCredentialCertPath* = EvidenceStateDir & "/host-ca.crt"
  EvidenceCredentialKeyPath* = EvidenceStateDir & "/host-ca.key"
  AttestationKeyPath* = "/var/lib/repro/agent/attestation.key"
    ## The host's generation-attestation key (``0400 root``, beside the
    ## recipient key), generated at bootstrap; its public half is in the
    ## first evidence record. Readable by the root units that write records
    ## (apply, re-assert, apt hook), never by the shipping unit.
  AttestationPubPath* = "/var/lib/repro/agent/attestation.pub"
  EvidenceDirPath* = "/var/lib/repro/system/addon/evidence"
    ## The local records (one JSON document per event, spec §10.4).
  EvidenceOutboxPath* = EvidenceDirPath & "/outbox"
    ## Each record as the sink receives it, until the sink acknowledges it.
  EvidenceShipUnit* = "repro-addon-evidence.service"
  EvidenceShipPathUnit* = "repro-addon-evidence.path"
  EvidenceShipTimer* = "repro-addon-evidence.timer"
  AgentSlice* = "system-reproagent.slice"
    ## The fetch unit's slice when the egress observer is present: a slice
    ## of its own, active for as long as the observer is, so the table's
    ## ``socket cgroupv2`` match (resolved when the rule is loaded) names a
    ## cgroup that exists. Under ``system.slice``, so it adds no parent.
  AgentSliceCgroup* = "system.slice/" & AgentSlice
  EgressNftPath* = "/etc/repro/egress.nft"
  EgressUnit* = "repro-addon-egress.service"
  EgressCheckUnit* = "repro-addon-egress-check.service"
  EgressCheckTimer* = "repro-addon-egress-check.timer"
  DefaultEvidenceHeartbeatSec* = 300
  DefaultAgentPollSec* = 300
  AgentPollRandomDelaySec* = 30
  AgentConfPath* = "/etc/repro/agent.conf"
    ## The deploy agent's configuration on an add-on host (A8): ``target``,
    ## one ``source`` line per manifest source, ``profile-compiler``.
  AgentHostsPath* = "/etc/repro/agent-hosts"
    ## The fetch unit's ``/etc/hosts``: the origins named by host name,
    ## with the addresses they had when generation 0 was rendered.
  AgentFetchUnit* = "repro-agent-fetch.service"
  AgentFetchTimer* = "repro-agent-fetch.timer"
  AgentApplyUnit* = "repro-agent-apply.service"
  AgentFetchStateName* = "repro-agent-fetch"
  AgentCompileDirName* = "compile"
    ## The profile compile's directory under the fetch unit's state
    ## directory (its caches persist between ticks).
    ## The fetch unit's ``StateDirectory=``: ``/var/lib/repro-agent-fetch``
    ## (``/var/lib/private/...`` under ``DynamicUser=``), the staging area.
  AgentApplyCapabilities* = ["CAP_CHOWN", "CAP_DAC_OVERRIDE",
    "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID", "CAP_KILL",
    "CAP_SETGID", "CAP_SETUID", "CAP_SETPCAP", "CAP_SYS_ADMIN",
    "CAP_SYS_PTRACE", "CAP_MKNOD", "CAP_IPC_LOCK", "CAP_AUDIT_WRITE",
    "CAP_LINUX_IMMUTABLE"]
    ## The apply unit's bounding set: what the switch's typed operations
    ## need (file ownership and modes across /etc and the store, account
    ## creation, mlock of plaintext secrets) and NOT ``CAP_NET_ADMIN``:
    ## every class that would need it -- firewall, network, sshd drop-ins --
    ## is refused in agent applies (spec §9.1).
    ##
    ## Two are broad and each is needed for one thing (A8 review, low):
    ##
    ## - ``CAP_SYS_ADMIN``: the store's private writable view
    ##   (``repro_elevation/store_view``) is ``unshare(CLONE_NEWNS)`` and a
    ##   bind remount of ``/repro/store``, both of which require it
    ##   (unshare(2), mount(2)). ``AgentApplyConfinement`` then restricts
    ##   namespaces to mount namespaces, so it cannot enter or create any
    ##   other.
    ## - ``CAP_SYS_PTRACE``: the secrets directory is reached through
    ##   ``/proc/1/root`` (PID 1's mount namespace, since this unit has its
    ##   own), and following another process's ``/proc/<pid>/root`` takes a
    ##   ptrace-mode access check that a process with fewer capabilities
    ##   than PID 1 passes only with it (proc(5), ptrace(2) "Ptrace access
    ##   mode checking"). The ``@debug`` system calls (``ptrace``,
    ##   ``process_vm_readv``/``writev``) are filtered out, so it is no
    ##   more than that check.
  PrivilegedWritablePaths* = "/etc /var /run -/usr/local/etc -" &
    "/repro/store"
    ## ``ReadWritePaths=`` of the add-on's root units under
    ## ``ProtectSystem=strict`` (spec §9.1, §10.1): what an apply writes --
    ## ``/etc`` (managed files, units, accounts, fragments) and
    ## ``/usr/local/etc`` (the other managed root, spec §4.4; ``-``
    ## because a base need not have it), ``/var`` (its
    ## state, the ``.deb`` cache, tmpfiles targets), ``/run`` (the pending
    ## marker's lock, the secrets tmpfs) -- and the store, which stays a
    ## read-only bind there too: a writer enters its private writable view
    ## (``store_view``). ``-`` because the re-assert unit must still run,
    ## and report ``degraded``, when the store is gone. ``/usr``, ``/boot``,
    ## ``/opt``, ``/srv`` and the rest of the base are read-only to them;
    ## ``ProtectHome=yes`` hides ``/home`` and ``/root``.

  PrivilegedSyscallFilter* =
    when mutated("privileged-filter-without-mount-chown"):
      # Falsifying build of the syscall-trace gate: the traced additions
      # left out, so the store view's mount and tmpfiles' fchown are denied.
      "SystemCallFilter=@system-service\n" &
      "SystemCallFilter=~@privileged @resources @obsolete @clock " &
      "@cpu-emulation @debug @module @raw-io @reboot @swap\n" &
      "SystemCallFilter=capset\n"
    else:
      "SystemCallFilter=@system-service @mount\n" &
      "SystemCallFilter=~@privileged @resources @obsolete @clock " &
      "@cpu-emulation @debug @module @raw-io @reboot @swap\n" &
      "SystemCallFilter=@chown capset\n"
    ## The root units' syscall filter (CONF-3): the deployment policy's
    ## recipe (``@system-service``, then ``~@privileged ~@resources
    ## ~@obsolete``) with what the trace of the units shows they use and
    ## the recipe takes away: ``@mount`` (the store's private writable
    ## view; ``unshare`` is in ``@process``, the bind remount is
    ## ``mount``), and ``@chown`` and ``capset`` from ``@privileged``
    ## (tmpfiles and account ownership, and the tools the apply runs
    ## setting their capabilities). systemd reads the lines in order: the
    ## first is the allow-list, a ``~`` line removes, a later plain line
    ## adds back (systemd.exec(5)). Derived with
    ## ``t_e2e_addon_unit_syscall_filters_cover_their_traces`` under
    ## ``REPRO_ADDON_SYSCALL_BASELINE=1``, which logs every call outside the
    ## recipe: on Debian 13 the apply unit made ``capset``, ``fchown`` and
    ## ``mount``, the re-assert, secrets and fetch units none. The groups
    ## are named rather than the calls, so the 32-bit spellings
    ## (``fchown32``) an armhf host makes are covered too.

  FetchSyscallFilter* = "SystemCallFilter=@system-service\n" &
    "SystemCallFilter=~@privileged @resources @obsolete\n"
    ## The fetch unit's filter (CONF-3): the policy recipe as it stands.
    ## Its trace (the fetch, the substitution and a profile compile with
    ## the host's C compiler) uses nothing it takes away; see
    ## ``PrivilegedSyscallFilter`` for how it is derived.

proc privilegedConfinement*(network: bool): string =
  ## The CONF-1 floor of the add-on's root units -- the apply unit, and the
  ## re-assert and secrets units, which run "the apply unit's confinement"
  ## (spec §7.7, §9.1). Root, but a bounded capability set
  ## (``AgentApplyCapabilities``), a read-only base outside
  ## ``PrivilegedWritablePaths``, private ``/tmp`` and devices, the kernel,
  ## clock and host-name protections, mount namespaces only, no realtime,
  ## no setuid creation, no write-and-execute memory, a native-only syscall
  ## filter whose denials fail the call (``EPERM``) instead of killing a
  ## switch half-way, and -- unless ``network`` -- no network at all.
  ##
  ## Not set, and why: ``UMask=0077`` (the apply creates directories under
  ## ``/etc`` and ``/var`` that the services it runs must read; their
  ## modes come from the umask); ``ProcSubset=pid`` (the units read
  ## ``/proc/1/root`` and mount tables only, but the tools they run --
  ## ``useradd``, ``systemd-tmpfiles`` -- read ``/proc`` beyond PIDs).
  ## systemd ignores a key starting ``X-`` (systemd.syntax(7)), so the
  ## reasons are carried in the unit itself (CONF-1: "document per setting,
  ## in the unit, why it cannot").
  let caps = when mutated("agent-apply-has-cap-net-admin"):
               AgentApplyCapabilities.join(" ") & " CAP_NET_ADMIN"
             else: AgentApplyCapabilities.join(" ")
  let protectSystem = when mutated("apply-unit-without-protect-system"): ""
                      else: "ProtectSystem=strict\n" &
                            "ReadWritePaths=" & PrivilegedWritablePaths & "\n"
  result = "NoNewPrivileges=yes\n" &
    "CapabilityBoundingSet=" & caps & "\n" &
    protectSystem &
    "ProtectHome=yes\n" &
    "PrivateTmp=yes\n" &
    "PrivateDevices=yes\n" &
    "ProtectKernelTunables=yes\n" &
    "ProtectKernelModules=yes\n" &
    "ProtectKernelLogs=yes\n" &
    "ProtectControlGroups=yes\n" &
    "ProtectClock=yes\n" &
    "ProtectHostname=yes\n" &
    "ProtectProc=invisible\n" &
    "RestrictNamespaces=mnt\n" &
    "RestrictRealtime=yes\n" &
    "RestrictSUIDSGID=yes\n" &
    "LockPersonality=yes\n" &
    "MemoryDenyWriteExecute=yes\n" &
    "SystemCallArchitectures=native\n" &
    PrivilegedSyscallFilter &
    "SystemCallErrorNumber=EPERM\n" &
    "X-Repro-Floor-Unset=UMask: the directories it creates for services " &
      "take their modes from it; ProcSubset: the tools it runs read /proc " &
      "beyond PIDs\n"
  if not network:
    result.add("PrivateNetwork=yes\nIPAddressDeny=any\n" &
               "RestrictAddressFamilies=AF_UNIX AF_NETLINK\n")

proc unitPath*(name: string): string =
  ## The unit file the driver writes for ``name``: the driver's own
  ## derivation (``systemUnitPath``), so what the collision pass observes
  ## and what the write lands on are one string by construction.
  systemUnitPath(name)

proc assertInlineSafe*(what, text: string) =
  ## The canonical profile text has no escapes: a double quote ends the
  ## value, ``#`` on a continuation line starts a comment, and a brace can
  ## end the stanza. A unit body containing one would be silently misread,
  ## so it is refused here instead.
  for c in text:
    if c in {'"', '#', '{', '}', '\\'}:
      raise newException(ValueError, what & " contains '" & c &
        "', which the canonical system-profile text cannot carry inline")

proc targetUnit(): string =
  # Wanted by multi-user.target so the add-on's units come up at boot, but
  # NOT ordered before it: a target complements every unit it wants with
  # `After=` unless that unit sets `DefaultDependencies=no` (systemd.target(5),
  # "Default Dependencies"). With the default, multi-user.target would wait
  # for this target, which waits for the re-assert unit -- the add-on's
  # recovery would hold up the base's boot. The shutdown ordering the
  # default would have added is stated explicitly.
  when mutated("addon-target-in-boot-order"):
    # The falsifying mutation: the default dependencies, which put this
    # target -- and the recovery ordered before it -- in multi-user's way.
    """[Unit]
Description=Reprobuild add-on services
Documentation=man:systemd.special(7)

[Install]
WantedBy=multi-user.target
"""
  else:
    """[Unit]
Description=Reprobuild add-on services
Documentation=man:systemd.special(7)
DefaultDependencies=no
Conflicts=shutdown.target
Before=shutdown.target

[Install]
WantedBy=multi-user.target
"""

proc storeMountUnit(): string =
  # A bind mount of the store over itself, read-only. ``DefaultDependencies``
  # stays on: this is not needed early, and leaving it on keeps the mount out
  # of the base's local-fs.target.
  when mutated("store-mount-writable"):
    # The falsifying mutation (e2e_addon_store_is_read_only_to_everything_else):
    # the bind without `ro`, so every root process can write the store.
    return """[Unit]
Description=Reprobuild add-on store, read-only
RequiresMountsFor=/repro
Before=repro-addon.target

[Mount]
What=/repro/store
Where=/repro/store
Type=none
Options=bind

[Install]
WantedBy=repro-addon.target
"""
  """[Unit]
Description=Reprobuild add-on store, read-only
RequiresMountsFor=/repro
Before=repro-addon.target

[Mount]
What=/repro/store
Where=/repro/store
Type=none
Options=bind,ro

[Install]
WantedBy=repro-addon.target
"""

const NoSwapLine* =
  # Both boot units open sealed envelopes. The plaintext is locked in RAM
  # (``locked_buffer``), which LimitMEMLOCK=infinity lets them do whatever
  # the size; where a cgroup v2 memory controller exists their control
  # group also may not swap, as defence in depth (spec §10.3).
  when mutated("secrets-plaintext-swappable"): "LimitMEMLOCK=infinity\n"
  else: "MemorySwapMax=0\nLimitMEMLOCK=infinity\n"

proc reassertUnit(reproExe: string): string =
  # Boot-time re-assertion (§7.7): finishes or reverts an interrupted
  # switch, checks the current generation and reports ok / drift /
  # degraded. It never re-applies on drift.
  #
  # It must not be able to hold up the base's boot: it is wanted only by
  # the add-on's target, never by multi-user.target, and that target is
  # out of multi-user's ordering (see `targetUnit`), so ordering the target
  # after recovery delays only the add-on's own target. It is only ORDERED
  # after the store mount (`After=`), never `Requires=` it -- a missing
  # store must still let it run and report `degraded`. A recovery may
  # replay a switch and revert it, each confirm capped at
  # `BootConfirmCapSec`, hence the timeout; a recovery that is killed leaves its marker for the next boot. For the
  # same reason the binary, which lives in the store, is tested before it
  # is executed: with the store gone the shell reports `degraded` itself
  # instead of the unit failing silently with ENOENT. `reassert --boot`
  # always exits 0. No network: it needs none, and its health probes run
  # in the host's namespaces through PID 1.
  when mutated("reassert-required-by-boot"):
    # The falsifying mutation: in the base's boot path, and requiring the
    # store mount, so a missing store fails the unit before it can report.
    let unitDeps = "Requires=repro-store.mount\n" &
                   "After=local-fs.target repro-store.mount\n"
    let wantedBy = "multi-user.target"
  else:
    # After the secrets unit (its own step 3 then never races it); in the
    # `secrets-after-recovery` build the order is the other way round,
    # and both at once would be a cycle.
    let secretsOrder = when mutated("secrets-after-recovery"): ""
                       else: " " & SecretsUnit
    let unitDeps = "After=local-fs.target repro-store.mount" & secretsOrder &
                   "\n" & "Before=repro-addon.target\n"
    let wantedBy = "repro-addon.target"
  "[Unit]\n" &
  "Description=Reprobuild add-on boot-time re-assertion\n" &
  unitDeps &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "RemainAfterExit=yes\n" &
  "TimeoutStartSec=" & $ReassertTimeoutMin & "min\n" &
  # The fallback also rewrites the report, so a stale `ok` from an earlier
  # boot is never what an operator reads.
  "ExecStart=/bin/sh -c 'if [ -x " & reproExe & " ]; then exec " & reproExe &
    " system addon reassert --boot; else echo repro-addon reassert: " &
    "degraded: the add-on binary " & reproExe & " is unavailable, the " &
    "store is missing or unreadable; echo repro-addon reassert: degraded, " &
    "the store is missing or unreadable > " & ReassertReportPath & "; fi'\n" &
  # The apply unit's confinement, and no network (§7.7; threat model G16).
  privilegedConfinement(network = mutated("reassert-has-network")) &
  NoSwapLine &
  "\n" &
  "[Install]\n" &
  "WantedBy=" & wantedBy & "\n"

proc secretsUnit(reproExe: string): string =
  # Boot-time secrets (§7.7, §10.3): re-materialise the current
  # generation's secrets into the tmpfs from the retained envelope, before
  # the units that load them start. A unit with `credentials` wants this
  # unit and is ordered after it (`SecretsOrderingUnit` in
  # `repro_infra/profile`), and such a unit is wanted by multi-user.target,
  # so THIS unit is on the base's boot path. It is therefore bounded and
  # waits for nothing slow: no recovery (the re-assert unit is ordered
  # after it, not before), no network, no lock wait (it tries the host
  # apply lock once and, when an apply holds it, leaves the secrets to that
  # apply), and a start timeout of a minute. It never fails the boot
  # transaction: like the re-assert unit it tests the store binary before
  # running it, and the verb always exits 0; a secret it cannot materialise
  # is reported, and the unit that loads it then fails to start, which the
  # re-assert unit reports as `degraded`.
  when mutated("secrets-after-recovery"):
    # The falsifying mutation: the secrets step waits for the boot
    # recovery, so every unit that loads credentials does too -- the
    # ordering A7 first shipped (credential units `After=` the re-assert
    # unit) -- and multi-user.target with them.
    let order = "After=local-fs.target repro-store.mount " & ReassertUnit &
                "\nBefore=repro-addon.target\n"
  else:
    let order = "After=local-fs.target repro-store.mount\n" &
                "Before=" & ReassertUnit & " repro-addon.target\n"
  # Default dependencies (after basic.target, so after sockets.target and
  # the system bus's socket): the secrets ramfs is mounted in the host's
  # mount namespace by a transient unit (`runInHostNamespaces`, i.e.
  # systemd-run), which needs the system bus. Measured on Debian 12/13 and
  # Ubuntu 24.04 with `DefaultDependencies=no`: "Failed to connect to
  # system scope bus via local transport", and every credential unit
  # failed. A unit with credentials is an ordinary service, after
  # basic.target itself, so this costs it nothing.
  "[Unit]\n" &
  "Description=Reprobuild add-on secrets for this boot\n" &
  order &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "RemainAfterExit=yes\n" &
  "TimeoutStartSec=" & $SecretsUnitTimeoutSec & "s\n" &
  "ExecStart=/bin/sh -c 'if [ -x " & reproExe & " ]; then exec " & reproExe &
    " system addon secrets --boot; else echo repro-addon secrets: " &
    "degraded: the add-on binary " & reproExe & " is unavailable; fi'\n" &
  # The re-assert unit's confinement: the apply unit's, no network.
  privilegedConfinement(network = false) &
  NoSwapLine &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

const
  AptHookTimeoutSeconds* = 60
    ## How long the apt hook lets one verification run (spec §7.8). At the
    ## deadline the hook's watchdog sends SIGTERM to the verification's
    ## whole process group, and SIGKILL five seconds later.
  AptHookKillGraceSeconds* = 5
  AptHookLogPath* = "/var/lib/repro/system/addon/apt-hook.log"
    ## The hook's event log: one line per event, ``<UTC time> <kind>
    ## <detail>``. The wrapper appends ``verify-missing``,
    ## ``verify-failed`` and ``verify-timeout``; the verification appends
    ## its findings (``apt_hook.nim``), and rotates the file at
    ## ``apt_hook.AptHookLogMaxBytes``. Plain text, not JSON, because the
    ## wrapper is a shell command inside an apt.conf string, which cannot
    ## carry a double quote.
  AptHookSetsidTool* = "/usr/bin/setsid"     ## util-linux (Essential)
  AptHookLoggerTool* = "/usr/bin/logger"     ## bsdutils / util-linux

proc aptHookCommand*(reproExe: string;
                     timeoutSeconds = AptHookTimeoutSeconds;
                     logPath = AptHookLogPath;
                     setsidTool = AptHookSetsidTool;
                     loggerTool = AptHookLoggerTool;
                     pidDir = "/run"): string =
  ## The shell command of the ``DPkg::Post-Invoke`` hook (apt runs it with
  ## ``/bin/sh -c``). Report-only by construction (threat model G19, T39):
  ##
  ## - the verification runs as its own session and process group
  ##   (``setsid``), and the test for its binary runs inside it, so even a
  ##   store that hangs on ``stat`` is bounded;
  ## - a watchdog, a second group, kills the verification's whole group
  ##   at the deadline (SIGTERM, then SIGKILL after five seconds), so a
  ##   verification that ignores SIGTERM or leaves children still ends and
  ##   nothing of it keeps apt's or ``unattended-upgrades``' terminal open.
  ##   The deadline does not use ``timeout(1)``: uutils' ``timeout`` (Ubuntu
  ##   26.04's coreutils) signals only its child, not the child's group
  ##   (measured 2026-10-31, uutils 0.10.0: a grandchild survived ``-k``);
  ## - a non-clean outcome is first appended to the hook's event log, then
  ##   sent to the journal by a ``logger`` the hook does not wait for; the
  ##   command ends in ``exit 0`` whatever happened.
  ##
  ## It uses no double quote and no backslash: apt.conf(5) strings carry
  ## neither. Everything but ``reproExe`` is a parameter only for the
  ## hermetic test, which runs this very command on a build host whose
  ## tools live elsewhere; generation 0 uses the defaults.
  let t = $timeoutSeconds
  let g = $AptHookKillGraceSeconds
  # The verification's shell records its own pid -- its session's and
  # process group's id -- in ``$f``: ``setsid`` forks first when its
  # caller leads a process group, so the background job's pid is not
  # always the group's (measured on a NixOS build host; ``-w`` keeps the
  # job's exit status the verification's either way).
  # ``$f`` is on ``/run`` (tmpfs, always writable by root): the deadline
  # must not depend on the state directory being writable.
  let verify = "f=" & pidDir & "/repro-addon-hook.$$; rm -f $f; " &
    setsidTool & " -w /bin/sh -c " &
    "'echo $$ > $2; [ -x $1 ] || exit 127; exec $1 system addon verify " &
    "--after-dpkg' repro-addon-hook $r $f & p=$!; "
  let watchdog =
    when mutated("apt-hook-without-timeout"):
      # FALSIFYING MUTATION: no deadline; a hung verification stalls dpkg.
      "w=0; "
    else:
      # The watchdog acts only while the verification's job (``$p``) is
      # alive -- the hook kills the watchdog as soon as it has ended, so a
      # watchdog that outlives it cannot signal a group whose id a later
      # process reused -- and it signals the group named in ``$f``, or ``$p``
      # itself when ``$f`` is empty or missing (``/run`` full): a background
      # job of a non-interactive shell never leads a process group, so
      # ``setsid`` did not fork and ``$p`` is the group's id.
      setsidTool & " -w /bin/sh -c 'sleep $1; kill -0 $3 2>/dev/null || exit 0; " &
        "g=$(cat $2 2>/dev/null); [ -z $g ] && g=$3; kill -TERM -$g; " &
        "sleep " & g & "; kill -0 $3 2>/dev/null || exit 0; kill -KILL -$g' " &
        "repro-addon-hook-watchdog " & t & " $f $p </dev/null >/dev/null 2>&1 & w=$!; "
  let ending =
    when mutated("apt-hook-without-exit0"):
      # FALSIFYING MUTATION: the verification's status is the hook's, so a
      # failing or timed-out verification fails dpkg's caller.
      "exit $c"
    else:
      "exit 0"
  "r=" & reproExe & "; l=" & logPath & "; " & verify & watchdog &
    "wait $p; c=$?; [ $w = 0 ] || kill -KILL $w 2>/dev/null; rm -f $f; " &
    "case $c in 0) ;; 127) k=verify-missing ;; " &
    "137|143) k=verify-timeout ;; *) k=verify-failed ;; esac; " &
    "if [ $c != 0 ]; then " &
    "echo $(date -u +%Y-%m-%dT%H:%M:%SZ) $k exit=$c timeout=" & t &
    "s >> $l 2>/dev/null; " &
    loggerTool & " -t repro-addon-apt-hook -p user.warning " &
    "repro-addon apt hook: $k exit=$c timeout=" & t & "s " &
    "</dev/null >/dev/null 2>&1 & fi; " & ending

proc aptHook*(reproExe: string): string =
  ## ``/etc/apt/apt.conf.d/90repro-addon`` (spec §7.8).
  "// Reprobuild add-on: report-only verification after every dpkg run.\n" &
  "// It never fails or stalls dpkg: the verification is bounded by a\n" &
  "// " & $AptHookTimeoutSeconds & " s deadline over its whole process " &
    "group and the command always\n" &
  "// exits 0; a missing, failing or hung verification is recorded in\n" &
  "// " & AptHookLogPath & " and the journal.\n" &
  "DPkg::Post-Invoke { \"" & aptHookCommand(reproExe) & "\"; };\n"

proc renderAgentConf*(a: AgentUnitsInputs): string =
  ## ``/etc/repro/agent.conf``: ``key = value`` lines, ``#`` comments.
  result = "# Reprobuild add-on: the deploy agent's target and manifest sources.\n"
  result.add("target = " & a.target & "\n")
  for src in a.sources: result.add("source = " & src & "\n")
  if a.profileCompiler.len > 0:
    result.add("profile-compiler = " & a.profileCompiler & "\n")

proc renderAgentHosts*(a: AgentUnitsInputs): string =
  ## The fetch unit's private ``/etc/hosts``.
  result = "# Reprobuild add-on: the deploy agent's origins, pinned when\n" &
           "# generation 0 was rendered (the fetch unit has no DNS).\n"
  for h in a.hosts: result.add(h.address & " " & h.name & "\n")

const ResolverSocketsHidden* =
  "InaccessiblePaths=-/run/systemd/resolve -/run/nscd -/var/run/nscd\n"
  ## The host's resolver services, reached over AF_UNIX: systemd-resolved's
  ## varlink and D-Bus endpoints (``nss-resolve``) and nscd. The IP filter
  ## never sees those connections, so without this a unit with no network
  ## egress could still have any name resolved -- a DNS channel out
  ## (measured on Debian 13: ``getent hosts`` answered inside the fetch
  ## unit's sandbox). With them hidden, the NSS ``dns`` fallback is a UDP
  ## query the IP filter denies. AF_UNIX itself stays: the apply unit talks
  ## to PID 1 over it, and the fetch unit's profile compiler may use it
  ## locally.

const
  AgentCompileMemoryMax* = "40%"
    ## The ``MemoryMax=`` of every unit that compiles a profile (the fetch
    ## unit, and the engine agent's transient compile unit): a share of the
    ## host's physical memory, which systemd resolves on each host
    ## (systemd.resource-control(5): "a percentage ... of the total
    ## physical memory"), so one unit text bounds a 1 GB Raspberry Pi 2 at
    ## about 400 MB and a larger host proportionally. Past it the kernel
    ## kills the compile in its own control group and the tick reports
    ## it, instead of the host's own services meeting the global OOM
    ## killer. https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html#MemoryMax=bytes
  AgentCompileNice* = 10
    ## The compile yields the CPU to the host's own services, and its
    ## ``CPUWeight=`` / ``IOWeight=`` (``AgentCompileWeight``) to every
    ## default-weight (100) unit.
  AgentCompileWeight* = 20
  AgentCompileOomScoreAdjust* = 500
    ## ``MemoryMax=`` bounds the compile's own control group; it does not
    ## keep the host's global OOM killer off the host's services when the
    ## whole host runs short. A positive ``OOMScoreAdjust=`` makes the
    ## compile the killer's first choice instead (systemd.exec(5)).
    ## https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#OOMScoreAdjust=

proc agentCompileBounds*(): string =
  ## The resource lines of a unit that compiles a profile.
  "MemoryMax=" & AgentCompileMemoryMax & "\n" &
  "MemorySwapMax=0\n" &
  "Nice=" & $AgentCompileNice & "\n" &
  "CPUWeight=" & $AgentCompileWeight & "\n" &
  "IOWeight=" & $AgentCompileWeight & "\n" &
  "OOMScoreAdjust=" & $AgentCompileOomScoreAdjust & "\n"

proc renderEgressNft*(allowed: seq[string]): string =
  ## ``/etc/repro/egress.nft``: the add-on's table, replaced as a whole on
  ## every load (declare, delete, define: one transaction), so loading it
  ## twice never duplicates a rule and nothing outside it is touched. It
  ## drops nothing -- the unit's ``IPAddressDeny=`` does that, after the
  ## netfilter output hook -- it counts each refused destination (a dynamic
  ## set with per-element counters), counts all of them, and logs them,
  ## rate-limited, to the kernel log.
  var v4, v6: seq[string]
  for a in allowed:
    if ':' in a: v6.add(a) else: v4.add(a)
  proc elements(xs: seq[string]): string =
    if xs.len == 0: "" else: "\t\telements = { " & xs.join(", ") & " }\n"
  let match = "socket cgroupv2 level 2 \"" & AgentSliceCgroup & "\""
  "# Reprobuild add-on: the deploy agent's egress observer. The add-on's\n" &
  "# only table; it never touches another.\n" &
  "table inet repro_addon_egress\n" &
  "delete table inet repro_addon_egress\n" &
  "table inet repro_addon_egress {\n" &
  "\tset allowed4 {\n\t\ttype ipv4_addr\n" & elements(v4) & "\t}\n" &
  "\tset allowed6 {\n\t\ttype ipv6_addr\n" & elements(v6) & "\t}\n" &
  "\tset refused4 {\n\t\ttype ipv4_addr\n\t\tsize 4096\n" &
    "\t\tflags dynamic\n\t\tcounter\n\t}\n" &
  "\tset refused6 {\n\t\ttype ipv6_addr\n\t\tsize 4096\n" &
    "\t\tflags dynamic\n\t\tcounter\n\t}\n" &
  "\tcounter refused {\n\t}\n" &
  "\tchain output {\n" &
  "\t\ttype filter hook output priority filter - 10; policy accept;\n" &
  "\t\t" & match & " meta nfproto ipv4 ip daddr != @allowed4 " &
    "update @refused4 { ip daddr } counter name \"refused\"\n" &
  "\t\t" & match & " meta nfproto ipv6 ip6 daddr != @allowed6 " &
    "update @refused6 { ip6 daddr } counter name \"refused\"\n" &
  "\t\t" & match & " meta nfproto ipv4 ip daddr != @allowed4 " &
    "limit rate 10/second log prefix \"repro-addon-egress-refused \" level warn\n" &
  "\t\t" & match & " meta nfproto ipv6 ip6 daddr != @allowed6 " &
    "limit rate 10/second log prefix \"repro-addon-egress-refused \" level warn\n" &
  "\t}\n}\n"

proc agentSliceUnit*(): string =
  "[Unit]\n" &
  "Description=Reprobuild add-on: the deploy agent's fetch slice (egress observer)\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

proc egressUnit*(nft: string): string =
  ## ``repro-addon-egress.service``: loads the table and deletes it when
  ## stopped (uninstall stops it). Root with ``CAP_NET_ADMIN`` alone and no
  ## IP socket; ordered before the fetch unit, which requires it, and the
  ## re-assert unit, which checks the table.
  let load = when mutated("egress-observer-not-installed"): "/bin/true"
             else: nft & " -f " & EgressNftPath
  "[Unit]\n" &
  "Description=Reprobuild add-on: egress observer (its own nftables table)\n" &
  "Requires=" & AgentSlice & "\n" &
  "After=" & AgentSlice & "\n" &
  "Before=" & AgentFetchUnit & " " & ReassertUnit & "\n" &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "RemainAfterExit=yes\n" &
  "ExecStart=" & load & "\n" &
  "ExecStop=" & nft & " delete table inet repro_addon_egress\n" &
  "CapabilityBoundingSet=CAP_NET_ADMIN\n" &
  "AmbientCapabilities=\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectSystem=strict\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
  "ProtectKernelTunables=yes\n" &
  "ProtectControlGroups=yes\n" &
  "RestrictAddressFamilies=AF_NETLINK AF_UNIX\n" &
  "IPAddressDeny=any\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

proc egressCheckUnit*(reproExe: string): string =
  ## ``repro-addon-egress-check.service``: reads the table's counters and
  ## records every refused destination (DET-AO-3), and heartbeats. Started
  ## after every fetch, whatever its result, and by its timer.
  "[Unit]\n" &
  "Description=Reprobuild add-on: egress observer check (DET-AO-3)\n" &
  "After=" & EgressUnit & "\n" &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "ExecStart=" & reproExe & " system addon egress-check\n" &
  "CapabilityBoundingSet=CAP_NET_ADMIN\n" &
  "AmbientCapabilities=\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectSystem=strict\n" &
  "ReadWritePaths=" & EvidenceDirPath & "\n" &
  "InaccessiblePaths=-/var/lib/repro/agent -/run/repro -/repro\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
  "PrivateDevices=yes\n" &
  "ProtectKernelTunables=yes\n" &
  "ProtectKernelModules=yes\n" &
  "ProtectControlGroups=yes\n" &
  "RestrictAddressFamilies=AF_NETLINK AF_UNIX\n" &
  "IPAddressDeny=any\n"

proc egressCheckTimer*(heartbeatSec: int): string =
  "[Unit]\n" &
  "Description=Reprobuild add-on: egress observer heartbeat\n" &
  "\n" &
  "[Timer]\n" &
  "OnBootSec=1min\n" &
  "OnUnitActiveSec=" & $heartbeatSec & "s\n" &
  "Unit=" & EgressCheckUnit & "\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

proc observeFetchUnit*(content: string): string =
  ## The fetch unit under the egress observer: in its own slice, which the
  ## table matches; not run without the table; and every run, whatever its
  ## result, followed by the check that reads the table. A transformation of
  ## the unobserved unit, so bootstrap and ``evidence-enrol`` (which has only
  ## the unit as installed) render the same bytes.
  for line in content.splitLines(keepEol = true):
    if line.startsWith("After=network-online.target") and EgressUnit notin line:
      result.add(line.strip(leading = false) & " " & EgressUnit & "\n")
      result.add("Requires=" & EgressUnit & "\n")
    elif line == "OnSuccess=" & AgentApplyUnit & "\n":
      result.add("OnSuccess=" & AgentApplyUnit & " " & EgressCheckUnit & "\n")
      result.add("OnFailure=" & EgressCheckUnit & "\n")
    elif line.startsWith("ExecStart=") and "agent-fetch" in line:
      result.add(line)
      result.add("Slice=" & AgentSlice & "\n")
    else:
      result.add(line)

proc unobservedFetchUnit(reproExe: string; a: AgentUnitsInputs): string =
  ## ``repro-agent-fetch.service`` (spec §9.1): a dynamic user with no
  ## capabilities, a read-only system, no access to the add-on's state
  ## (the recipient key, the sequence floor), and egress to the pinned
  ## origin addresses only. Its one product is the staging directory;
  ## when it succeeds, systemd starts the apply unit.
  let egress =
    when mutated("agent-fetch-unrestricted-egress"): ""
    else:
      "IPAddressDeny=any\n" &
      (if a.allowedAddresses.len > 0:
         "IPAddressAllow=" & a.allowedAddresses.join(" ") & "\n" else: "")
  let hostsBind = if a.hosts.len > 0:
                    "BindReadOnlyPaths=" & AgentHostsPath & ":/etc/hosts\n"
                  else: ""
  # The compile links and runs the profile binary under the state
  # directory, which systemd mounts noexec for a dynamic user; the state
  # directory alone is made exec-capable again (systemd.exec(5) ExecPaths=).
  # The whole state directory, which exists before the unit's namespace is
  # set up (the compile directory below it may not yet); "-" tolerates a
  # spelling the host does not have.
  let compileExec = "ExecPaths=-/var/lib/private/" & AgentFetchStateName &
    " -/var/lib/" & AgentFetchStateName & "\n"
  let stateHidden = when mutated("agent-floor-in-fetch-state"): ""
                    else: "InaccessiblePaths=-/var/lib/repro\n"
  # The fetch unit needs no system bus either (resolved answers there too).
  let noResolver = when mutated("agent-dns-via-resolved"): ""
                   else: ResolverSocketsHidden &
                         "InaccessiblePaths=-/run/dbus -/var/run/dbus\n"
  "[Unit]\n" &
  "Description=Reprobuild add-on deploy agent: fetch (unprivileged)\n" &
  "After=network-online.target repro-store.mount\n" &
  "Wants=network-online.target\n" &
  "OnSuccess=" & AgentApplyUnit & "\n" &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "ExecStart=" & reproExe & " system addon agent-fetch\n" &
  "DynamicUser=yes\n" &
  "StateDirectory=" & AgentFetchStateName & "\n" &
  "TimeoutStartSec=30min\n" &
  # It compiles a source profile (when the manifest ships one).
  agentCompileBounds() &
  # The CONF-1 floor, whole: the unit that parses what the network brings.
  "CapabilityBoundingSet=\n" &
  "AmbientCapabilities=\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectSystem=strict\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
  "PrivateDevices=yes\n" &
  "ProtectKernelTunables=yes\n" &
  "ProtectKernelModules=yes\n" &
  "ProtectKernelLogs=yes\n" &
  "ProtectControlGroups=yes\n" &
  "ProtectClock=yes\n" &
  "ProtectHostname=yes\n" &
  "ProtectProc=invisible\n" &
  "RestrictNamespaces=yes\n" &
  "RestrictRealtime=yes\n" &
  "RestrictSUIDSGID=yes\n" &
  "LockPersonality=yes\n" &
  "MemoryDenyWriteExecute=yes\n" &
  "SystemCallArchitectures=native\n" &
  FetchSyscallFilter &
  "SystemCallErrorNumber=EPERM\n" &
  # UMask= stays systemd's 0022: the outputs the fetch materialises keep
  # the modes the cache archive records only through it, and the archive
  # digest the manifest pins covers them (a 0077 umask made every staged
  # executable hash differently, measured on Debian 13). The staging area
  # is private anyway: the state directory of a dynamic user is 0700.
  "X-Repro-Floor-Unset=UMask: materialised outputs take the archive's " &
    "modes through it, and the pinned digest covers them; ProcSubset: the " &
    "profile compile and the C compiler read /proc/cpuinfo and /proc/meminfo\n" &
  "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n" &
  stateHidden & noResolver & compileExec & egress & hostsBind

proc agentPollSec*(a: AgentUnitsInputs): int =
  if a.pollIntervalSec > 0: a.pollIntervalSec else: DefaultAgentPollSec

proc agentFetchUnit*(reproExe: string; a: AgentUnitsInputs;
                     observed = false): string =
  ## ``repro-agent-fetch.service``; ``observed``: under the egress observer
  ## (``observeFetchUnit``).
  let u = unobservedFetchUnit(reproExe, a)
  if observed: observeFetchUnit(u) else: u

proc agentFetchTimer*(a: AgentUnitsInputs = AgentUnitsInputs()): string =
  # The default renders as it always did (``5min``), so a host bootstrapped
  # without an interval keeps the bytes of its generation 0.
  let every = if a.pollIntervalSec <= 0: "5min" else: $a.pollIntervalSec & "s"
  "[Unit]\n" &
  "Description=Reprobuild add-on deploy agent: poll for desired state\n" &
  "\n" &
  "[Timer]\n" &
  "OnBootSec=2min\n" &
  "OnUnitActiveSec=" & every & "\n" &
  "RandomizedDelaySec=" & $AgentPollRandomDelaySec & "s\n" &
  "Unit=" & AgentFetchUnit & "\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

const AgentApplyMemoryMax* = "512M"
  ## The apply unit's ``MemoryMax=`` (spec §9.1): a ceiling that leaves room
  ## on the smallest supported host (a 1 GB Raspberry Pi 2) while bounding a
  ## runaway apply. Past it the kernel kills the apply inside its own
  ## control group and the tick fails, instead of pushing the host into
  ## swap or its global OOM killer. The staging copy and the closure-digest
  ## check stream in fixed-size chunks (``copyTreeFd``,
  ## ``prefixSubsetArchiveDigestHex``), and so does the ``.deb`` realiser
  ## (``apt_jammy``: ar(5) headers by offset, the data member copied in
  ## chunks), so none of them grows with the staged or archived bytes.
  ## ``LimitMEMLOCK=infinity`` locks plaintext secrets inside it too.

proc agentApplyUnit*(reproExe: string): string =
  ## ``repro-agent-apply.service`` (spec §9.1): root, but no network of
  ## any kind, a bounded capability set without ``CAP_NET_ADMIN``, and,
  ## because it opens sealed envelopes, plaintext locked in RAM and no
  ## swap (§10.3, decision 25). It reads the fetch unit's staging only
  ## through descriptors, into its own copy.
  let net = when mutated("agent-apply-has-network"): ""
            else: ResolverSocketsHidden
  "[Unit]\n" &
  "Description=Reprobuild add-on deploy agent: apply\n" &
  "After=repro-store.mount " & AgentFetchUnit & "\n" &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "ExecStart=" & reproExe & " system addon agent-apply\n" &
  "TimeoutStartSec=3h\n" &
  privilegedConfinement(network = mutated("agent-apply-has-network")) &
  "MemoryMax=" & AgentApplyMemoryMax & "\n" &
  net & NoSwapLine

proc evidenceHeartbeatSec*(e: EvidenceUnitsInputs): int =
  if e.heartbeatSec > 0: e.heartbeatSec else: DefaultEvidenceHeartbeatSec

proc sinkEndpoint*(e: EvidenceUnitsInputs): string =
  ## ``address:port``, IPv6 in brackets.
  (if ':' in e.sinkAddress: "[" & e.sinkAddress & "]" else: e.sinkAddress) &
    ":" & $e.sinkPort

proc renderEvidenceConf*(e: EvidenceUnitsInputs; agent: AgentUnitsInputs): string =
  ## ``/etc/repro/evidence.conf``: ``key = value`` lines, ``#`` comments.
  ## ``tick-interval`` is the longest a deploy agent's tick may take to
  ## follow the previous one (its timer plus the timer's random delay); 0
  ## when the host has no agent, so no tick is expected.
  let tick = if agent.target.len > 0:
               agentPollSec(agent) + AgentPollRandomDelaySec
             else: 0
  "# Reprobuild add-on: the Evidence sink this host ships its records to\n" &
  "# (spec §10.4) and the intervals the off-host silence check expects.\n" &
  "sink = " & sinkEndpoint(e) & "\n" &
  "sink-host = " & e.sinkHostId & "\n" &
  "heartbeat-interval = " & $evidenceHeartbeatSec(e) & "\n" &
  "tick-interval = " & $tick & "\n"

proc evidenceShipUnit*(reproExe: string; e: EvidenceUnitsInputs): string =
  ## ``repro-addon-evidence.service`` (spec §10.4): ships the outbox to the
  ## Evidence sink and heartbeats. Root -- the records and the credential
  ## are root's files -- but with NO capability, a read-only system apart
  ## from its own two directories, the attestation and recipient keys and
  ## the secrets hidden, and egress to the sink's address only. It is the
  ## only add-on unit that talks to the sink; the units that write records
  ## (apply, re-assert, the apt hook) have no network and cannot sign as
  ## the sink credential, and this one cannot sign attestations.
  let egress = when mutated("evidence-ship-unrestricted-egress"): ""
               else: "IPAddressDeny=any\nIPAddressAllow=" & e.sinkAddress & "\n"
  let hidden = when mutated("evidence-ship-sees-agent-keys"): "-/run/repro -/repro"
               else: "-/var/lib/repro/agent -/run/repro -/repro"
  "[Unit]\n" &
  "Description=Reprobuild add-on: ship evidence records to the Evidence sink\n" &
  "After=network-online.target\n" &
  "Wants=network-online.target\n" &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "ExecStart=" & reproExe & " system addon evidence-ship\n" &
  "TimeoutStartSec=5min\n" &
  "CapabilityBoundingSet=\n" &
  "AmbientCapabilities=\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectSystem=strict\n" &
  "ReadWritePaths=" & EvidenceStateDir & " " & EvidenceOutboxPath & "\n" &
  "InaccessiblePaths=" & hidden & "\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
  "PrivateDevices=yes\n" &
  "ProtectKernelTunables=yes\n" &
  "ProtectKernelModules=yes\n" &
  "ProtectKernelLogs=yes\n" &
  "ProtectControlGroups=yes\n" &
  "ProtectClock=yes\n" &
  "ProtectHostname=yes\n" &
  "ProtectProc=invisible\n" &
  "RestrictNamespaces=yes\n" &
  "RestrictRealtime=yes\n" &
  "RestrictSUIDSGID=yes\n" &
  "LockPersonality=yes\n" &
  "MemoryDenyWriteExecute=yes\n" &
  "SystemCallArchitectures=native\n" &
  FetchSyscallFilter &
  "SystemCallErrorNumber=EPERM\n" &
  "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n" &
  ResolverSocketsHidden &
  "InaccessiblePaths=-/run/dbus -/var/run/dbus\n" &
  egress

proc evidenceShipPathUnit*(): string =
  ## Starts the shipping unit whenever a record lands in the outbox (DET-6:
  ## it leaves at once, not at the next timer).
  "[Unit]\n" &
  "Description=Reprobuild add-on: ship each evidence record as it is written\n" &
  "\n" &
  "[Path]\n" &
  "PathChanged=" & EvidenceOutboxPath & "\n" &
  "MakeDirectory=yes\n" &
  "DirectoryMode=0700\n" &
  "Unit=" & EvidenceShipUnit & "\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

proc evidenceShipTimer*(e: EvidenceUnitsInputs): string =
  ## The shipping unit's heartbeat (DET-5) and its retry while the sink is
  ## unreachable.
  "[Unit]\n" &
  "Description=Reprobuild add-on: evidence heartbeat\n" &
  "\n" &
  "[Timer]\n" &
  "OnBootSec=1min\n" &
  "OnUnitActiveSec=" & $evidenceHeartbeatSec(e) & "s\n" &
  "Unit=" & EvidenceShipUnit & "\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

proc profileD(reproExe: string): string =
  let bindir = reproExe[0 ..< reproExe.rfind('/')]
  "# Reprobuild add-on: put the add-on's repro on PATH.\n" &
  "case \":$PATH:\" in\n" &
  "  *\":" & bindir & ":\"*) ;;\n" &
  "  *) PATH=\"$PATH:" & bindir & "\" ;;\n" &
  "esac\n"

proc isPublicKeyHex*(s: string): bool =
  ## A 65-byte uncompressed ECDSA-P256 public key in lower- or upper-case
  ## hex (the anchor-file and ``caches.conf`` spelling).
  s.len == 130 and s[0 .. 1] == "04" and s.allCharsInSet(HexDigits)

proc parseAnchorKeys*(text, what: string): seq[string] =
  ## The keys of an anchor file (one hex key per line, ``#`` comments),
  ## lower-cased, de-duplicated and sorted, so the same set always renders
  ## to the same bytes. A malformed line raises.
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    if not isPublicKeyHex(line):
      raise newException(ValueError, what & ": not an uncompressed P-256 " &
        "public key in hex: " & line)
    let k = line.toLowerAscii()
    if k notin result: result.add(k)
  result.sort()

proc renderAnchors*(keys: seq[string]): string =
  ## The deploy-signer anchor file, in the format the deploy agent's
  ## ``--allowed-signers`` reads (``repro_peer_cache/auth.loadTrustAnchors``).
  result = "# Reprobuild add-on: deploy-manifest signers this host accepts.\n"
  for k in keys: result.add(k & "\n")

proc renderCachesConf*(url: string; keys: seq[string]): string =
  ## ``/etc/repro/caches.conf`` holding exactly one cache, trusted for
  ## exactly the publisher anchors given at bootstrap. With no cache, the
  ## file lists none, and the default-untrusted client substitutes nothing.
  ## A cache without a key would be one nothing may be substituted from, so
  ## it is refused rather than written.
  result = "# Reprobuild add-on: the binary cache this host substitutes from,\n" &
           "# and the only producer keys trusted for it (default-untrusted).\n"
  if url.len == 0:
    if keys.len > 0:
      raise newException(ValueError, "cache publisher anchors were given " &
        "without a cache URL")
    result.add("# No cache is configured: nothing is substituted.\n")
    return
  if keys.len == 0:
    raise newException(ValueError, "a cache URL was given without publisher " &
      "anchors; under default-untrusted it could never be used")
  if not (url.startsWith("https://") or url.startsWith("http://")) or
      url.find({' ', '"', '\n', '\r', '\t'}) >= 0:
    raise newException(ValueError, "invalid cache URL: " & url)
  result.add("[addon]\n")
  result.add("url = \"" & url & "\"\n")
  result.add("trusted-public-keys = \"" & keys.join(", ") & "\"\n")

proc egressObjects*(inp: Gen0Inputs): seq[OwnObject] =
  ## The egress observer's objects, in apply order (the slice before the
  ## unit that requires it, the table's unit before the check).
  @[OwnObject(kind: ookEtcFile, path: EgressNftPath,
              content: renderEgressNft(inp.egress.allowedAddresses)),
    OwnObject(kind: ookUnit, unit: AgentSlice, path: unitPath(AgentSlice),
              content: agentSliceUnit(), enabled: true),
    OwnObject(kind: ookUnit, unit: EgressUnit, path: unitPath(EgressUnit),
              content: egressUnit(inp.egress.nft), enabled: true),
    OwnObject(kind: ookUnit, unit: EgressCheckUnit,
              path: unitPath(EgressCheckUnit),
              content: egressCheckUnit(inp.reproExe), enabled: false),
    OwnObject(kind: ookUnit, unit: EgressCheckTimer,
              path: unitPath(EgressCheckTimer),
              content: egressCheckTimer(evidenceHeartbeatSec(inp.evidence)),
              enabled: true)]

proc evidenceObjects*(inp: Gen0Inputs): seq[OwnObject]
  ## Below.

proc generation0Objects*(inp: Gen0Inputs): seq[OwnObject] =
  ## The add-on's own objects, in apply order: the target first (the other
  ## units are wanted by it), the mount before the unit that is ordered
  ## after it.
  if inp.reproExe.len == 0 or not inp.reproExe.startsWith(StoreRoot & "/"):
    raise newException(ValueError,
      "generation 0 needs the add-on's repro inside " & StoreRoot &
      ", got '" & inp.reproExe & "'")
  result = @[
    OwnObject(kind: ookEtcFile, path: DeploySignersPath,
              content: renderAnchors(inp.deploySigners)),
    OwnObject(kind: ookEtcFile, path: CachesConfPath,
              content: renderCachesConf(inp.cacheUrl, inp.cachePublishers)),
    OwnObject(kind: ookUnit, unit: AddonTarget, path: unitPath(AddonTarget),
              content: targetUnit(), enabled: true),
    OwnObject(kind: ookUnit, unit: StoreMountUnit,
              path: unitPath(StoreMountUnit), content: storeMountUnit(),
              enabled: true),
    OwnObject(kind: ookUnit, unit: SecretsUnit, path: unitPath(SecretsUnit),
              content: secretsUnit(inp.reproExe), enabled: true),
    OwnObject(kind: ookUnit, unit: ReassertUnit, path: unitPath(ReassertUnit),
              content: reassertUnit(inp.reproExe), enabled: true),
    OwnObject(kind: ookEtcFile, path: AptHookPath,
              content: aptHook(inp.reproExe)),
    OwnObject(kind: ookEtcFile, path: ProfileDPath,
              content: profileD(inp.reproExe)),
  ]
  if inp.agent.target.len > 0:
    # The deploy agent's units (A8): present only on a host bootstrapped
    # with a target and manifest sources, so a host without them keeps the
    # generation 0 it had.
    result.add(OwnObject(kind: ookEtcFile, path: AgentConfPath,
                         content: renderAgentConf(inp.agent)))
    if inp.agent.hosts.len > 0:
      result.add(OwnObject(kind: ookEtcFile, path: AgentHostsPath,
                           content: renderAgentHosts(inp.agent)))
    result.add(OwnObject(kind: ookUnit, unit: AgentApplyUnit,
      path: unitPath(AgentApplyUnit), content: agentApplyUnit(inp.reproExe),
      enabled: false))
    let observed = inp.egress.nft.len > 0
    if observed:
      result.add(egressObjects(inp))
    result.add(OwnObject(kind: ookUnit, unit: AgentFetchUnit,
      path: unitPath(AgentFetchUnit),
      content: agentFetchUnit(inp.reproExe, inp.agent, observed),
      enabled: false))
    result.add(OwnObject(kind: ookUnit, unit: AgentFetchTimer,
      path: unitPath(AgentFetchTimer), content: agentFetchTimer(inp.agent),
      enabled: true))
  if inp.evidence.sinkAddress.len > 0:
    # The Evidence sink (A11): present only on a host bootstrapped with
    # one, so a host without it keeps the generation 0 it had.
    result.add(evidenceObjects(inp))

proc evidenceObjects*(inp: Gen0Inputs): seq[OwnObject] =
  ## Generation 0's evidence objects (the sink's configuration and CA, the
  ## shipping unit, its path unit and timer).
  if true:
    result.add(OwnObject(kind: ookEtcFile, path: EvidenceConfPath,
                         content: renderEvidenceConf(inp.evidence, inp.agent)))
    result.add(OwnObject(kind: ookEtcFile, path: EvidenceSinkCaPath,
                         content: inp.evidence.sinkCaPem))
    result.add(OwnObject(kind: ookUnit, unit: EvidenceShipUnit,
      path: unitPath(EvidenceShipUnit),
      content: evidenceShipUnit(inp.reproExe, inp.evidence), enabled: false))
    result.add(OwnObject(kind: ookUnit, unit: EvidenceShipPathUnit,
      path: unitPath(EvidenceShipPathUnit), content: evidenceShipPathUnit(),
      enabled: true))
    result.add(OwnObject(kind: ookUnit, unit: EvidenceShipTimer,
      path: unitPath(EvidenceShipTimer),
      content: evidenceShipTimer(inp.evidence), enabled: true))

proc contentFileName*(o: OwnObject): string =
  ## The file under the generation's files prefix that holds ``o``'s body.
  sha256Hex(o.content)

proc renderOwnProfile*(objects: seq[OwnObject]; filesDir: string): string =
  ## Canonical system-profile text for the add-on's own objects. File
  ## bodies are read from ``filesDir/<sha256>``.
  for o in objects:
    case o.kind
    of ookEtcFile:
      result.add("fs.systemFile {\n")
      result.add("  path = \"" & o.path & "\"\n")
      result.add("  sourceLocal = \"" & filesDir & "/" & contentFileName(o) &
                 "\"\n")
      result.add("}\n\n")
    of ookUnit:
      assertInlineSafe("unit " & o.unit, o.content)
      result.add("systemd.systemUnit {\n")
      result.add("  name = \"" & o.unit & "\"\n")
      result.add("  content = \"" & o.content & "\"\n")
      result.add("  enabled = " & (if o.enabled: "true" else: "false") & "\n")
      result.add("}\n\n")

proc ownObjectPaths*(objects: seq[OwnObject]): seq[string] =
  ## Every path generation 0 writes, sorted: the preflight requires all of
  ## them to be absent.
  for o in objects:
    result.add(o.path)
  result.sort()

proc installTargets*(unitContent: string): seq[tuple[kind, target: string]] =
  ## Every ``[Install]`` directive of a unit (systemd.unit(5) "[Install]
  ## Section Options", systemd 252-260): ``WantedBy`` / ``RequiredBy`` /
  ## ``UpheldBy`` (a symlink in ``<target>.wants`` / ``.requires`` /
  ## ``.upholds``), ``Alias`` (a symlink with the alias name), and the two
  ## that make ``systemctl enable`` do more than link this unit: ``Also``
  ## (enable those units too) and ``DefaultInstance`` (the instance a
  ## template is enabled as). Space-separated lists are split; the caller
  ## decides what each kind may do.
  when mutated("install-targets-ignore-alias-also"):
    const known = ["WantedBy", "RequiredBy"]
  else:
    const known = ["WantedBy", "RequiredBy", "UpheldBy", "Alias", "Also",
                   "DefaultInstance"]
  var inInstall = false
  for raw in unitContent.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inInstall = line == "[Install]"
      continue
    if not inInstall or line.len == 0 or line[0] in {'#', ';'}:
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip()
    if key in known:
      for v in line[eq + 1 .. ^1].splitWhitespace():
        result.add((kind: key, target: v))

proc hasInstallSection*(unitContent: string): bool =
  for raw in unitContent.splitLines():
    if raw.strip() == "[Install]": return true
  false

proc mountWhere*(unitContent: string): string =
  ## ``Where=`` of a ``.mount`` unit, "" if none.
  var inMount = false
  for raw in unitContent.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inMount = line == "[Mount]"
      continue
    if inMount and line.startsWith("Where="):
      return line["Where=".len .. ^1].strip()
  ""

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
    ## The system binary-cache client configuration (``repro_binary_cache_client
    ## /caches_config``): the cache list every substitution on the host reads,
    ## each cache with the only producer keys trusted for it.
  StoreRoot* = "/repro/store"
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
    ## The fetch unit's ``StateDirectory=``: ``/var/lib/repro-agent-fetch``
    ## (``/var/lib/private/...`` under ``DynamicUser=``), the staging area.
  AgentApplyCapabilities* = ["CAP_CHOWN", "CAP_DAC_OVERRIDE",
    "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID", "CAP_KILL",
    "CAP_SETGID", "CAP_SETUID", "CAP_SETPCAP", "CAP_SYS_ADMIN",
    "CAP_SYS_PTRACE", "CAP_MKNOD", "CAP_IPC_LOCK", "CAP_AUDIT_WRITE",
    "CAP_LINUX_IMMUTABLE"]
    ## The apply unit's bounding set: what the switch's typed operations
    ## need (file ownership and modes across /etc and the store, the
    ## store's private writable mount view, account creation, mlock of
    ## plaintext secrets, reading other units' /proc entries) and NOT
    ## ``CAP_NET_ADMIN``: every class that would need it -- firewall,
    ## network, sshd drop-ins -- is refused in agent applies (spec §9.1).

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

const NoSwapLine =
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
  "PrivateNetwork=yes\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
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
  "PrivateNetwork=yes\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
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
      # The watchdog acts only while ``$f`` exists: the hook removes it as
      # soon as the verification has ended, so a watchdog that outlives it
      # can never signal a group a later process reused the id of.
      setsidTool & " -w /bin/sh -c 'sleep $1; [ -f $2 ] || exit 0; " &
        "g=$(cat $2); kill -TERM -$g; sleep " & g & "; [ -f $2 ] || exit 0; " &
        "kill -KILL -$g' repro-addon-hook-watchdog " & t &
        " $f </dev/null >/dev/null 2>&1 & w=$!; "
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

proc agentFetchUnit*(reproExe: string; a: AgentUnitsInputs): string =
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
  let stateHidden = when mutated("agent-floor-in-fetch-state"): ""
                    else: "InaccessiblePaths=-/var/lib/repro\n"
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
  "CapabilityBoundingSet=\n" &
  "AmbientCapabilities=\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectSystem=strict\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
  "PrivateDevices=yes\n" &
  "ProtectKernelTunables=yes\n" &
  "ProtectKernelModules=yes\n" &
  "ProtectControlGroups=yes\n" &
  "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n" &
  stateHidden & egress & hostsBind

proc agentFetchTimer*(): string =
  "[Unit]\n" &
  "Description=Reprobuild add-on deploy agent: poll for desired state\n" &
  "\n" &
  "[Timer]\n" &
  "OnBootSec=2min\n" &
  "OnUnitActiveSec=5min\n" &
  "RandomizedDelaySec=30s\n" &
  "Unit=" & AgentFetchUnit & "\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=repro-addon.target\n"

proc agentApplyUnit*(reproExe: string): string =
  ## ``repro-agent-apply.service`` (spec §9.1): root, but no network of
  ## any kind, a bounded capability set without ``CAP_NET_ADMIN``, and,
  ## because it opens sealed envelopes, plaintext locked in RAM and no
  ## swap (§10.3, decision 25). It reads the fetch unit's staging only
  ## through descriptors, into its own copy.
  let net = when mutated("agent-apply-has-network"): ""
            else: "PrivateNetwork=yes\nIPAddressDeny=any\n" &
                  "RestrictAddressFamilies=AF_UNIX AF_NETLINK\n"
  "[Unit]\n" &
  "Description=Reprobuild add-on deploy agent: apply\n" &
  "After=repro-store.mount " & AgentFetchUnit & "\n" &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "ExecStart=" & reproExe & " system addon agent-apply\n" &
  "TimeoutStartSec=3h\n" &
  "NoNewPrivileges=yes\n" &
  "CapabilityBoundingSet=" & AgentApplyCapabilities.join(" ") & "\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
  net & NoSwapLine

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
    result.add(OwnObject(kind: ookUnit, unit: AgentFetchUnit,
      path: unitPath(AgentFetchUnit),
      content: agentFetchUnit(inp.reproExe, inp.agent), enabled: false))
    result.add(OwnObject(kind: ookUnit, unit: AgentFetchTimer,
      path: unitPath(AgentFetchTimer), content: agentFetchTimer(),
      enabled: true))

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

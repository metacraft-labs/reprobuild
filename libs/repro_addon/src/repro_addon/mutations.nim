## Compile-time falsifying mutations for the add-on's acceptance gates.
##
## Each do-no-harm gate of the add-on must be shown to fail when the
## property it checks is broken (a falsifying mutation or negative
## control, recorded red and then green). The breakage is compiled into a
## SEPARATE build of the add-on binary, selected with
## ``-d:reproAddonMutation=<name>``; a build without the define contains
## none of this code. Keeping the mutation out of the product binary means
## no runtime switch, environment variable or flag can ever turn one on in
## a real deployment, and the mutated binary has a different SHA-256, so it
## can never be mistaken for the published artefact.
##
## ``scripts/build_addon_static.sh --mutation <name>`` builds one; the gates
## take ``REPRO_ADDON_MUTATION=<name>`` to select which build they run, and
## invert their expectation (the gate must go red).
##
## =========================================  ==============================
## name                                       what the build does wrong
## =========================================  ==============================
## ``uninstall-skips-diversion-removal``      uninstall leaves every dpkg
##                                            diversion in place
## ``bootstrap-installs-jq``                  bootstrap also runs
##                                            ``apt-get install -y jq tree``
##                                            (``tree`` so the mutation
##                                            changes a base that already
##                                            ships ``jq``, as Ubuntu does)
## ``preflight-writes``                       the preflight writes a marker
##                                            file under ``/var/lib`` and
##                                            swallows a write error, so
##                                            only observing the write can
##                                            catch it
## ``apply-skips-kind-check``                 the apply does not refuse a
##                                            resource kind the add-on
##                                            does not manage before
##                                            applying it
## ``uninstall-discards-state-on-drift``      uninstall removes the state
##                                            directory and ledger even
##                                            when it left drift behind
## ``recipient-key-0644``                     bootstrap writes the recipient
##                                            key group- and world-readable
## ``provisions-publisher-key``               bootstrap also leaves a binary
##                                            cache publisher keypair
## ``observer-never-package-owned``           the collision observer reports
##                                            no package provenance: no
##                                            path is package-owned and no
##                                            unit is provided by a package
## ``observer-checks-path-text-only``         the collision observer never
##                                            ``lstat``s the components of
##                                            a target path (a link on it
##                                            goes unnoticed)
## ``exclusive-as-plain-restart``             an ``exclusive`` unit is
##                                            restarted like any other
##                                            (new instance started, then
##                                            the old one stopped) instead
##                                            of stopped and confirmed
##                                            before the switch
## ``sysctl-in-apply-namespace``              sysctl fragments are applied
##                                            by running systemd-sysctl in
##                                            the apply's own namespaces
##                                            instead of as a transient
##                                            unit in the host's
## ``exclusive-exited-by-top-level-procs``    an exclusive unit counts as
##                                            exited when the top-level
##                                            ``cgroup.procs`` of its group
##                                            is empty, and an unreadable
##                                            group as exited (a delegated
##                                            child group goes unseen)
## ``plan-id-omits-unit-state``               the add-on plan id covers the
##                                            units but not their observed
##                                            state, so a pinned apply does
##                                            not see a unit that crashed
##                                            since the plan
## ``partof-not-propagated``                  the plan leaves the stops and
##                                            restarts systemd carries along
##                                            ``PartOf=``/``BindsTo=``
##                                            implicit (no confirmed
##                                            stop-start of a dependent)
## ``trigger-not-paused``                     a stop-start unit's active
##                                            sockets/timers/paths are not
##                                            paused across the switch
## ``idle-unit-triggers-left-paused``         the triggers of a stop-start
##                                            unit that ended before step 2
##                                            are not started again
## ``removed-exclusive-stop-unconfirmed``     a removed exclusive unit is
##                                            stopped without confirming
##                                            its control group is empty
## ``unmanaged-predecessor-not-refused``      an unmanaged predecessor that
##                                            runs, is enabled or can be
##                                            triggered does not refuse the
##                                            plan, and no predecessor's
##                                            group is confirmed empty
##                                            before a start
## ``exclusive-planned-by-active-state``      exclusive units are planned by
##                                            ``ActiveState`` alone and no
##                                            group is confirmed empty before
##                                            a start (the pre-round-2 rule)
## ``reassert-required-by-boot``              the re-assert unit is wanted
##                                            by multi-user.target and
##                                            ``Requires=`` the store
##                                            mount, so a missing store
##                                            fails it before it reports
## ``reassert-skips-recovery``                the re-assert unit leaves an
##                                            interrupted switch as it
##                                            finds it (a negative control
##                                            of the hard-reset gate: the
##                                            resets must leave mixtures)
## ``addon-target-in-boot-order``             ``repro-addon.target`` keeps its
##                                            default dependencies, so
##                                            multi-user.target waits for
##                                            it and for the recovery
##                                            ordered before it
## ``current-remove-then-create``             the commit removes `current`
##                                            before creating the new link
##                                            (``repro_infra/state_dir``)
## ``nofollow-write-skips-fsync``             the no-follow writer neither
##                                            fsyncs the file it writes nor
##                                            its directory
##                                            (``repro_elevation``)
## ``refused-recovery-forgets-marker``        a refusal (an exclusive unit
##                                            that will not stop) inside a
##                                            replay or a revert is undone
##                                            like a fresh switch's: the
##                                            pending marker and plan are
##                                            removed while the host is
##                                            half-switched
## ``secrets-after-recovery``                 the boot secrets unit is
##                                            ordered after the boot
##                                            recovery
##                                            (``repro-addon-reassert``),
##                                            so every unit that loads
##                                            credentials -- ordered after
##                                            it -- and multi-user.target
##                                            wait for the recovery again
##                                            (the ordering A7 first
##                                            shipped)
## ``path-based-write-follows-links``         the drivers write managed
##                                            files with a path-based
##                                            ``open``, following any link
##                                            on the path
## ``scope-accepts-unnormalised-paths``       a target path or managed
##                                            prefix with a ``//``, ``.``
##                                            or ``..`` segment is not
##                                            refused (the parser's and
##                                            the scope check's canonical
##                                            form check is compiled out)
## ``pause-before-write``                     NOT a breakage: the test seam
##                                            of the write-time re-check
##                                            gate. The apply pauses after
##                                            planning, before the first
##                                            write, while the FIFO
##                                            ``/run/repro-addon-test-seam/
##                                            continue`` exists, so the
##                                            gate can change the host
##                                            deterministically in between
## ``pause-before-write-no-recheck``          the same seam, and the
##                                            write-time re-check (the
##                                            ``PreWriteGuard``, destroys
##                                            included) is not installed
## ``install-targets-ignore-alias-also``      a unit's ``[Install]`` is read
##                                            for ``WantedBy`` and
##                                            ``RequiredBy`` only: an
##                                            ``Alias``, ``Also`` or
##                                            ``UpheldBy`` is neither
##                                            decided nor ledgered
## ``kept-units-still-stopped``              (with the pause seam) a
##                                            removed unit step 2's
##                                            re-check keeps in place is
##                                            still stopped with the plan's
##                                            transitions
## ``apply-prints-reviewed-plan``            (with the pause seam) the
##                                            apply prints the reviewed
##                                            plan's transition list, not
##                                            the one steps 2 and 7 ran
##                                            after the re-check kept a
##                                            removed unit
## ``upholder-not-planned``                   the planner ignores
##                                            ``UpheldBy=``: an active
##                                            upholder is neither paused
##                                            around the unit, nor the
##                                            unit's own uphold link
##                                            removed first, nor refused
## ``secrets-on-disk``                        secrets are materialised under
##                                            ``/var/lib/repro/secrets`` (the
##                                            root filesystem) and the tmpfs
##                                            check is off
## ``secrets-on-tmpfs``                       a plain directory on /run's
##                                            tmpfs is accepted for the
##                                            secrets (no ramfs: its pages
##                                            can be swapped)
## ``secrets-single-retained-envelope``       a deploy agent's sealed
##                                            section replaces the one
##                                            retained envelope before its
##                                            apply, and every generation
##                                            materialises from it
## ``credentials-not-planned``                a credential change plans no
##                                            restart or stop-start
## ``rotation-not-reconciled``                a rotation cut short after its
##                                            rename is never completed
## ``secrets-plaintext-swappable``            plaintext buffers are not
##                                            locked in RAM and the
##                                            processes and units that hold
##                                            them run without
##                                            MemorySwapMax=0
## ``secrets-plaintext-unlocked``             plaintext buffers are not
##                                            locked in RAM (MemorySwapMax=0
##                                            is kept)
## ``replay-reverts-on-secrets``              a recovery replay whose
##                                            secrets cannot be
##                                            materialised reverts the
##                                            switch instead of finishing it
## ``retirement-not-resumed``                 a key retirement interrupted
##                                            between overwrite and rename
##                                            is never finished
## ``recipient-key-mode-unchecked``           the recipient key is used
##                                            whatever its owner and mode
## ``secrets-write-then-narrow``              a secret file is written by
##                                            path (following a link at its
##                                            temporary name) with the
##                                            umask's mode, then narrowed
## ``rotation-keeps-old-key``                 a rotation keeps the retired
##                                            recipient key and still opens
##                                            what is sealed to it (the
##                                            rotation gate's negative
##                                            control)
## ``apt-hook-without-timeout``               the apt hook runs the
##                                            verification with no
##                                            deadline, so a hung one
##                                            stalls dpkg
## ``apt-hook-without-exit0``                 the apt hook exits with the
##                                            verification's status, so a
##                                            failing or timed-out one
##                                            fails apt
## ``base-coupling-unflagged``                no unit is ever flagged
##                                            base-coupled
## ``base-matrix-unchecked``                  an apply against a base
##                                            outside the supported matrix
##                                            is not refused
## ``package-owner-absorbed``                 a ledger path a package came to
##                                            own is decided as the ledger's
##                                            (the pre-round-2 behaviour:
##                                            the plan absorbs the package's
##                                            ownership)
## ``hook-ignores-vendor-units``              the apt hook does not compare
##                                            vendor units with the
##                                            generation's record
## ``apt-closure-unrecorded``                 the apt closure realiser
##                                            renames its prefixes into the
##                                            store with no receipt or index
##                                            row (``apt_closure.nim``)
## ``apt-deb-reader-follows-symlinks``        the realiser's ``data.tar``
##                                            reader writes through a
##                                            symlink the archive planted,
##                                            and the union builder's link
##                                            check is off
## ``closure-prefixes-unrooted``              the switch does not attach its
##                                            units' apt closure prefixes to
##                                            the pending root, so the
##                                            committed generation's root
##                                            does not hold them and
##                                            ``repro store gc`` collects a
##                                            closure a current unit binds
##                                            (G38)
## ``apt-deb-reader-reads-whole-file``       the ``.deb`` reader
##                                            (``apt_jammy``) loads the whole
##                                            archive into memory
## ``floor-ignored``                          a failure after the flip reverts
##                                            even below the signed rollback
##                                            floor
## ``agent-apply-skips-recheck``              the agent's apply unit takes the
##                                            fetch unit's compiled profile
##                                            without its own re-check
## ``agent-allows-management-path``           an agent apply may carry an sshd
##                                            drop-in, firewall or network
##                                            resource
## ``agent-apply-has-network``                the apply unit has no
##                                            ``PrivateNetwork=`` /
##                                            ``IPAddressDeny=``
## ``agent-fetch-unrestricted-egress``        the fetch unit has no
##                                            ``IPAddressAllow=`` /
##                                            ``IPAddressDeny=`` pair
## ``agent-floor-in-fetch-state``             the sequence floor lives in the
##                                            fetch unit's state directory
## ``agent-compiles-in-apply``                the apply unit compiles a source
##                                            profile itself, as root
## ``agent-rereads-staging``                  the apply unit re-reads the
##                                            staging path after verifying
## ``agent-substitutes-untrusted``            the fetch unit substitutes with
##                                            trust enforcement off
## ``agent-extract-follows-links``            the fetch unit's archive
##                                            extraction writes through a
##                                            symlink component
## ``agent-install-copies-undeclared``       the apply unit copies every
##                                            staged entry, not only the
##                                            declared outputs
## ``agent-install-trusts-cwd``               a compiled action's ``cwd``
##                                            is checked by string prefix
## ``agent-dns-via-resolved``                 the fetch unit can reach
##                                            systemd-resolved / D-Bus
## ``agent-management-path-names-only``       ssh/firewall/network units
##                                            are matched by name only,
##                                            aliases not resolved
## ``agent-management-path-ignores-unit-names`` the management-path
##                                            refusal does not ask systemd
##                                            for a unit's ``Id``/``Names``
## ``agent-management-path-ignores-install-alias`` the refusal ignores the
##                                            ``Alias=`` a unit's own
##                                            ``[Install]`` would create
## ``agent-management-path-ignores-templates`` an instance (``ssh@x``) is
##                                            not matched by its template
## ``agent-staging-open-blocks``              the staging copy opens a file
##                                            without ``O_NONBLOCK`` or a
##                                            type re-check after the open
## ``agent-staging-reads-whole-file``         the staging copy reads each
##                                            file into memory before
##                                            writing it
## ``floor-only-on-confirm``                  the rollback floor bounds only
##                                            confirmation failures
## ``retargeted-address-accepted``           a resource whose address now
##                                            names another unit or path is
##                                            applied, leaving the old one
##                                            running and unledgered (A12)
## ``activity-edges-unselected``             an activity's store-package
##                                            edges are realised on every
##                                            host, selected or not (A12)
## ``addon-unit-renders-differently``         every unit the add-on writes
##                                            gains one comment line, so
##                                            its bytes differ from the
##                                            full realisation's (A12)
## ``confirm-overruns-deadline``              the confirm step keeps
##                                            probing for twice
##                                            ``confirmTimeout`` before it
##                                            gives up, so a failing or
##                                            hanging check holds the
##                                            switch past its deadline
## ``cross-prefix-glibc-unchecked``           preflight accepts a profile
##                                            compiler cross-built against a
##                                            newer glibc than the host's
##                                            (§7.9, the glibc exception)
## ``profile-cc-unresolved-unrefused``        a profile compile that resolves
##                                            no C compiler is handed to Nim
##                                            instead of refused (decision 31)
## ``apt-closure-adopts-unverified``          a realiser-v2 closure prefix is
##                                            adopted without verifying its
##                                            v2 hash or identity
## ``agent-management-path-ignores-dropin-prefixes``  a drop-in is judged by
##                                            its own unit name only, not by
##                                            the units systemd applies it to
##                                            (dash prefixes, template, type)
## ``agent-management-path-dropin-ignores-instance-forms``  a drop-in's
##                                            dash prefixes are taken from
##                                            the template only, so
##                                            ``serial-@ttyS0.service.d`` and
##                                            ``serial-@.service.d`` pass
## ``agent-management-path-dropin-ignores-unit-aliases``  the drop-in
##                                            directories of management
##                                            units' aliases (``dbus-.service``
##                                            via networkd's D-Bus alias) are
##                                            not derived
## ``agent-management-path-allows-login-slices``  slices are not management
##                                            units: drop-ins for
##                                            ``user.slice``, ``user-.slice``,
##                                            ``user-<uid>.slice``,
##                                            ``-.slice`` and ``slice`` pass
##                                            (decision 37)
## ``agent-management-path-allows-session-units``  login sessions and user
##                                            managers are not management
##                                            units: ``session-.scope``,
##                                            ``session-<n>.scope``,
##                                            ``user@.service`` and its
##                                            instances pass (decision 37,
##                                            extended; decision 38 adds
##                                            systemd-user-sessions and
##                                            user-runtime-dir@)
## ``tmpfiles-scope-unchecked``               a tmpfiles fragment's lines are
##                                            not parsed: any path, /etc
##                                            included, is written by
##                                            systemd-tmpfiles (spec §4.1)
## ``agent-management-path-ignores-tmpfiles`` an agent apply's tmpfiles rule
##                                            may act on /run/nologin and the
##                                            other management paths under
##                                            the tmpfiles class
## ``agent-management-path-names-fail-open``  a unit whose names systemd
##                                            cannot give is judged by its
##                                            own name alone
## ``agent-repin-keeps-allow-list``           ``agent-repin`` rewrites the
##                                            hosts file but leaves the fetch
##                                            unit's ``IPAddressAllow=`` on
##                                            the old addresses
## ``addon-agent-accepts-full-pin``           an add-on agent applies a
##                                            source profile pinned for no
##                                            system selection or for mode
##                                            ``full``
## ``full-host-restart-forgets-pending``      a full host's apply records no
##                                            pending restart, so a consumer
##                                            whose secret an early-returning
##                                            apply materialised is never
##                                            restarted
## ``full-host-boot-secrets-unlocked``        a full host's boot secrets step
##                                            writes without the host and
##                                            state apply locks
## ``unit-prefix-unchecked``                  a unit that runs from the
##                                            prefix of an activity edge its
##                                            host does not select is planned
## ``unit-prefix-bodies-only``                that check reads unit bodies
##                                            only, not drop-ins, health
##                                            checks, files or accounts
## ``failed-consumer-left-failed``            a unit whose secrets an apply
##                                            or the re-assert materialised
##                                            is try-restarted even when it
##                                            has failed (left failed)
## =========================================  ==============================

# The deploy agent's own mutations (``repro_deploy_agent/agent_mutations``)
# share this switch; a static add-on build accepts their names too.
from repro_deploy_agent/agent_mutations import KnownAgentMutations

const
  AddonMutation* {.strdefine: "reproAddonMutation".} = ""
  KnownAddonMutations* = ["uninstall-skips-diversion-removal",
                          # Not a falsifier: a failure injected once
                          # (while /var/tmp/repro-addon-fail-before-ledger
                          # exists) after the flip and before the ledger
                          # is written, so a gate drives the automatic
                          # revert of a switch whose ledger copy still
                          # describes the previous generation.
                          "switch-fails-before-ledger",
                          "bootstrap-installs-jq", "preflight-writes",
                          "recipient-key-0644", "provisions-publisher-key",
                          "apply-skips-kind-check",
                          "uninstall-discards-state-on-drift",
                          "observer-never-package-owned",
                          "observer-checks-path-text-only",
                          "exclusive-as-plain-restart",
                          "sysctl-in-apply-namespace",
                          "exclusive-exited-by-top-level-procs",
                          "plan-id-omits-unit-state",
                          "partof-not-propagated",
                          "trigger-not-paused",
                          "idle-unit-triggers-left-paused",
                          "removed-exclusive-stop-unconfirmed",
                          "unmanaged-predecessor-not-refused",
                          "exclusive-planned-by-active-state",
                          "path-based-write-follows-links",
                          "scope-accepts-unnormalised-paths",
                          "reassert-required-by-boot",
                          "reassert-skips-recovery",
                          "pause-before-write",
                          "pause-before-write-no-recheck",
                          "install-targets-ignore-alias-also",
                          "addon-target-in-boot-order",
                          "current-remove-then-create",
                          "nofollow-write-skips-fsync",
                          "refused-recovery-forgets-marker",
                          "secrets-after-recovery",
                          "kept-units-still-stopped",
                          "apply-prints-reviewed-plan",
                          "upholder-not-planned",
                          "secrets-on-disk",
                          "secrets-on-tmpfs",
                          "secrets-single-retained-envelope",
                          "credentials-not-planned",
                          "rotation-not-reconciled",
                          "secrets-plaintext-swappable",
                          # Milestone A12: the parity gate's falsifying build.
                          "addon-unit-renders-differently",
                          "retargeted-address-accepted",
                          # Read by repro_profile_compile's adapter_system.
                          "activity-edges-unselected",
                          "secrets-plaintext-unlocked",
                          "replay-reverts-on-secrets",
                          "retirement-not-resumed",
                          "recipient-key-mode-unchecked",
                          "secrets-write-then-narrow",
                          "rotation-keeps-old-key",
                          "apt-hook-without-timeout",
                          "apt-hook-without-exit0",
                          "base-coupling-unflagged",
                          "base-matrix-unchecked",
                          "package-owner-absorbed",
                          "hook-ignores-vendor-units",
                          # Read by repro_dsl_stdlib's apt_closure.nim, which
                          # cannot import this module; listed so a static
                          # build accepts them.
                          "apt-closure-unrecorded",
                          "apt-deb-reader-follows-symlinks",
                          # G38: the switch roots its units' closures.
                          "closure-prefixes-unrooted",
                          "apt-deb-reader-reads-whole-file",
                          # Milestone A8 (``agent_split``, ``generation0``,
                          # ``addon_apply``): each gate's falsifying build.
                          "floor-ignored",
                          "agent-apply-skips-recheck",
                          "agent-allows-management-path",
                          "agent-apply-has-network",
                          "agent-fetch-unrestricted-egress",
                          "agent-floor-in-fetch-state",
                          "agent-compiles-in-apply",
                          "agent-rereads-staging",
                          "agent-substitutes-untrusted",
                          "agent-extract-follows-links",
                          "agent-install-copies-undeclared",
                          "agent-install-trusts-cwd",
                          "agent-dns-via-resolved",
                          "agent-management-path-names-only",
                          "agent-management-path-ignores-unit-names",
                          "agent-management-path-ignores-install-alias",
                          "agent-management-path-ignores-templates",
                          "agent-staging-open-blocks",
                          "agent-staging-reads-whole-file",
                          "floor-only-on-confirm",
                          # Milestone A5: the confirm-or-revert gate's
                          # timing falsifier.
                          "confirm-overruns-deadline",
                          # §7.9: the cross prefix's glibc check.
                          "cross-prefix-glibc-unchecked",
                          # A8 review M5: agent-repin's falsifier.
                          "agent-repin-keeps-allow-list",
                          # Read by repro_profile_compile (compile.nim), which
                          # cannot import this module: decision 31's refusal.
                          "profile-cc-unresolved-unrefused",
                          # Read by repro_dsl_stdlib's apt_closure.nim: the
                          # legacy adoption without its verification.
                          "apt-closure-adopts-unverified",
                          # A8 round 3: drop-ins judged by exact name only.
                          "agent-management-path-ignores-dropin-prefixes",
                          # A8 round 4: the instance-form and alias-derived
                          # drop-in directories, and decision 37's slices.
                          "agent-management-path-dropin-ignores-instance-forms",
                          "agent-management-path-dropin-ignores-unit-aliases",
                          "agent-management-path-allows-login-slices",
                          "agent-management-path-allows-session-units",
                          # A8 round 5: tmpfiles lines held to the class and
                          # the management path; unit names fail closed.
                          "tmpfiles-scope-unchecked",
                          "agent-management-path-ignores-tmpfiles",
                          "agent-management-path-names-fail-open",
                          # A12 review finding 12: an add-on agent applies
                          # a pin compiled for no selection or for `full`.
                          "addon-agent-accepts-full-pin",
                          # A12 review finding 1: a full host's apply
                          # restarts only what this run materialised.
                          "full-host-restart-forgets-pending",
                          # A12 review finding 6: the full host's boot
                          # secrets step writes without the locks.
                          "full-host-boot-secrets-unlocked",
                          # A12 review finding 12: a unit may run from a
                          # prefix its host does not realise.
                          "unit-prefix-unchecked",
                          # A12 round-2 review: the round-1 check, which
                          # read unit bodies only.
                          "unit-prefix-bodies-only",
                          # A12 round-2 review: a consumer that failed for
                          # want of its secrets is try-restarted (left
                          # failed) once they are back.
                          "failed-consumer-left-failed",
                          # A9 (confinement): the apply unit without
                          # ProtectSystem=strict (t_addon_units_meet_
                          # confinement_floor); the store bind not read-only
                          # and the flip not re-checking the store
                          # (e2e_addon_store_is_read_only_to_everything_else);
                          # CAP_NET_ADMIN in the apply unit's bounding set
                          # (t_addon_agent_apply_unit_lacks_cap_net_admin);
                          # the re-assert unit with a network
                          # (e2e_addon_reassert_unit_has_no_network); the
                          # serviceFloor without its exec confinement or
                          # without MemoryDenyWriteExecute
                          # (e2e_addon_service_cannot_exec_outside_closure).
                          "apply-unit-without-protect-system",
                          "store-mount-writable",
                          "flip-skips-store-recheck",
                          "agent-apply-has-cap-net-admin",
                          "reassert-has-network",
                          "floor-without-noexec",
                          "floor-without-mdwe"]

when AddonMutation.len > 0 and AddonMutation notin KnownAddonMutations and
    AddonMutation notin KnownAgentMutations:
  {.error: "unknown -d:reproAddonMutation=" & AddonMutation.}

template mutated*(name: static string): bool =
  ## True only in the build compiled with ``-d:reproAddonMutation=<name>``.
  static:
    doAssert name in KnownAddonMutations, "unknown add-on mutation " & name
  AddonMutation == name

const TestPauseSeam* = AddonMutation in ["pause-before-write",
                                         "pause-before-write-no-recheck",
                                         "kept-units-still-stopped",
                                         "apply-prints-reviewed-plan"]
  ## The write-time re-check gate's pause seam is compiled in (a test-only
  ## build; see the table above). False in every product build.

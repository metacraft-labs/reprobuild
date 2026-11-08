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
## ``image-omits-gen0-ledger``                the image assembly (A16)
##                                            deletes the add-on's ledger
##                                            copy before power-off
## ``image-omits-store-closure``              the image assembly deletes
##                                            every apt closure's store
##                                            prefix before power-off
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
## ``state-units-not-checked``                a state backup or restore runs
##                                            whatever its units' control
##                                            groups say
## ``state-units-not-held``                   a state backup holds none of
##                                            its units (one can start again
##                                            before the conversion)
## ``state-archive-unchecked``                a restore reads an archive
##                                            whose SHA-256 it did not check
## ``state-restore-unverified``               a restore renames a staged
##                                            tree into place unchecked
## ``apply-ignores-carried-state``            an apply starts a unit whose
##                                            carried state is not restored
## ``import-writes-skeleton``                 the import keeps a copy of
##                                            its skeleton under ``/etc``
## ``pending-by-receipt-only``                carried state counts as
##                                            restored by the receipt
##                                            alone, whatever root it names
## ``carried-reach-by-unit-name``             the carried-state wait matches
##                                            units by name, not by what
##                                            they can reach
## ``owner-ids-unchecked``                    a carried tree's owner ids
##                                            are not compared with the
##                                            accounts the apply uses
## ``apply-ignores-hold``                     an apply runs while a state
##                                            backup holds the host
## ``hold-runtime-only``                      the hold is written in /run
##                                            (lost at a reboot)
## ``hardlinks-unchecked``                    the tree digest passes a file
##                                            with several hard links
## ``restore-leaves-staging``                 a retried restore leaves an
##                                            earlier staging directory
## ``restore-writes-dense``                   a restore writes zero blocks
##                                            (the file is not sparse)
## ``keep-without-mount-requirement``         a unit with a kept directory
##                                            gets no RequiresMountsFor=
## ``restore-after-start``                    the switch restores preserved
##                                            bytes after step 7 starts
##                                            the units (the old order)
## ``revert-refuses-restored``                a revert refuses a file the
##                                            failed switch restored
## ``import-copies-env-secret``               the import copies a secret
##                                            Environment= value into the
##                                            skeleton
## ``sink-credential-has-read-scope``         the Evidence sink answers a
##                                            list or a read from an
##                                            appender's credential
## ``ship-deletes-before-ack``                the shipping unit deletes an
##                                            outbox entry before the sink
##                                            acknowledged it
## ``attestation-unsigned``                   the attestation signature
##                                            covers other bytes than the
##                                            statement
## ``attestation-claims-host``                the statement's scope says
##                                            host attestation and drops
##                                            what it does not cover
## ``check-silence-as-idle``                  the off-host check reports a
##                                            silent detector as live-idle
## ``check-skips-attestation``                the off-host check compares
##                                            no attestation (DET-AO-9)
## ``lag-detector-disabled``                  the off-host check raises no
##                                            lag alert (DET-AO-10)
## ``tick-records-no-detection``              a tick's outcome leaves no
##                                            detection record
## ``evidence-ship-unrestricted-egress``      the shipping unit has no
##                                            egress allow-list
## ``evidence-ship-sees-agent-keys``          the shipping unit can read
##                                            the attestation and recipient
##                                            keys
## ``receipt-trusts-inode``                   the restore receipt counts a
##                                            directory as restored on its
##                                            device and inode alone
## ``account-as-written``                     a service's account is taken
##                                            as written (no specifiers,
##                                            no static account under
##                                            DynamicUser=yes, no uid
##                                            alias, no memberships)
## ``reach-host-dropins-ignored``             reach reads the profile's
##                                            drop-ins only, not the host's
## ``reach-timer-dropins-unread``             a profile timer is read
##                                            without its drop-ins
## ``reach-path-unit-paths-ignored``          a path unit's watched paths
##                                            reach nothing
## ``restore-requirement-by-manifest-only``   no apply adds the restore
##                                            requirement; only install-
##                                            unit's manifest units have it
## ``reach-values-as-text``                  setting values read as round 4
##                                           did: booleans from
##                                           yes/true/1/on only,
##                                           ProtectSystem= lower-cased
## ``confined-without-nnp-or-groups``        a confined service need not
##                                           have NoNewPrivileges=yes, and
##                                           may hold a privileged group
## ``account-dynamic-name-from-stem``        DynamicUser=yes without User=
##                                           names the account after the
##                                           unit's prefix and instance
## ``account-nss-unread``                    the account lookup reads no
##                                           userdb records and is always
##                                           authoritative
## ``reach-alias-dropins-unread``            reach reads the drop-ins of
##                                           the unit's own name only, not
##                                           of its aliases
## ``reach-stale-generation-dropins-skipped``reach skips every
##                                           50-repro-*.conf in the unit's
##                                           directory, declared or not
## ``restore-requirement-skips-activated``   the restore requirement is not
##                                           given to units the profile
##                                           starts but does not define
## ``restore-requirement-skips-dropin-targets`` the restore requirement is
##                                            not given to a unit only a
##                                            profile drop-in reaches
## ``unit-lines-continue-as-text``           round 5's line reading: a line
##                                           ending in ``\\`` or ``\ `` joins
##                                           the next (A13 review round 6)
## ``exec-first-command-only``               only the first command of an
##                                           ``Exec*=`` line is read
## ``alias-chain-first-link-only``           only a link straight to the unit
##                                           is an alias; a link to a link
##                                           is not followed
## ``dependency-links-unread``               host ``.wants/``, ``.requires/``
##                                           and ``.upholds/`` links are not
##                                           read
## ``requirement-name-not-reserved``         a profile drop-in named
##                                           ``state-restore`` replaces the
##                                           restore requirement
## ``privileged-daemons-unread``             polkit rules and D-Bus policy
##                                           are not read (§13 decision 58)
## ``restore-requirement-skips-closure``     a unit started only through a
##                                           distribution unit's dependencies
##                                           gets no requirement (decision 60)
## ``addon-live-reach-skipped``              the add-on switch does not run
##                                           the carried-state cross-check
## ``infra-live-reach-skipped``              a full apply does not run the
##                                           carried-state cross-check
##                                           (decision 59)
## ``optional-paths-ignored``              a ``-``-prefixed (optional) path
##                                           is taken as granting nothing
## ``live-units-chosen-after-writes``      the add-on switch chooses the
##                                           units it re-checks at step 6,
##                                           after its own reloads ran the
##                                           host's generators
## ``post-reload-refusal-skipped``           the carried-state refusal is not
##                                           decided again after a switch's
##                                           reload
## ``adopt-without-profile``                 ``repro system adopt`` takes
##                                           drifted bytes the profile does
##                                           not declare (decision 61)
## ``plan-ignores-profile-digest``           an apply of a stored plan does
##                                           not compare the plan's profile
##                                           digest with the text it runs
## ``full-apply-keeps-undeclared-dropins``   a full apply leaves the
##                                           drop-ins an earlier generation
##                                           declared and this one does not
## ``install-unit-reads-host-manifest``      install-unit and restore
##                                           --root read the running host's
##                                           carried directory
## ``live-reach-unchecked``                  the switch does not re-judge
##                                           reach from systemctl show
## ``receipt-no-fsync``                       the restore receipt is
##                                            renamed into place with
##                                            neither its file nor its
##                                            directory fsync'd
## ``reach-ignores-privileged-commands``      a "+"/"!" Exec*= command and
##                                            PermissionsStartOnly= do not
##                                            widen a unit's reach
## ``reach-dropin-judged-alone``              a collision="dropIn" unit is
##                                            judged by its drop-in only
## ``reach-trigger-units-reach-nothing``      what a unit activates (Wants=,
##                                            a timer's Unit=, ...) is not
##                                            followed
## ``backup-without-host-lock``               the backup runs without the
##                                            host apply lock and is not
##                                            re-checked after the hold
## ``restore-not-required-by-units``          the carried units do not
##                                            require the restore unit
## ``restore-unordered``                      the restore unit and the
##                                            carried units' drop-in carry
##                                            no ordering
## ``restore-required-by-link``               the requirement is a link in
##                                            .requires/ (removed by a
##                                            disable or a preset)
## ``carried-check-not-under-lock``           an apply does not decide
##                                            carried state again under the
##                                            host lock
## ``reach-default-allow``                    what the reach analysis does
##                                            not understand is allowed
##                                            (round 2's behaviour)
## ``reach-paths-as-text``                    reach compares paths as text
##                                            and ignores the legacy
##                                            ReadWriteDirectories=
## ``missing-manifest-allowed``               a manifest missing where
##                                            carried state was installed
##                                            counts as none
## ``engine-tick-unrecorded``                 the full engine's agent tick
##                                            on an add-on host leaves no
##                                            evidence record
## ``egress-observer-not-installed``          the egress observer's unit
##                                            never loads its nftables
##                                            table
## ``evidence-keys-adopted``                  creating the evidence keys
##                                            does not refuse keys that
##                                            are already there
## ``reassert-skips-digest-check``            the store verification after
##                                            boot compares no digest
## ``lag-from-newest-copy``                   DET-AO-10 counts a host's lag
##                                            from the newest re-signed copy
## ``evidence-path-rate-limited``             the shipping units keep the
##                                            default start/trigger limits
## ``check-ignores-ship-delay``               the check reads a stalled
##                                            shipping unit as live
## ``egress-state-survives-reload``           egress counts are compared
##                                            across a table reload
## ``egress-instance-ignores-boot``           a table loaded at another
##                                            boot, with the same handle,
##                                            is the same instance
## ``check-status-ignores-silence``           a detector's status is
##                                            live-idle beside its silence
##                                            alert
## ``check-forgets-enrolled-key``             the check ignores the hosts
##                                            file's enrolled key
## ``uninstall-keeps-fetch-state``            uninstall leaves the fetch
##                                            unit's state directory
## ``store-verify-trusts-receipt``           store verification expects
##                                            the digest the verified
##                                            path's own receipt names
## ``reassert-nft-in-own-netns``              the re-assert lists nftables
##                                            tables in its own private
##                                            network namespace
## ``reassert-store-trigger-missing``         a quarantined store object
##                                            in use is reported as
##                                            ``store-object-missing``
## ``custody-skips-file-sources``            the switch's store custody
##                                            leaves out the store files
##                                            an ``fs.systemFile`` copies
## ``custody-skips-closures``                 ... and the apt closures
## ``custody-admits-undigested``              an object with no recorded
##                                            digest is admitted on a host
##                                            under custody
## ``custody-cache-ignores-signature``        the digest cache answers for
##                                            a path whatever changed in it
## ``recovery-discards-evidence``             a recovered object's altered
##                                            bytes are deleted, not kept
## ``recovery-trusts-store-bytes``            a files prefix is recovered
##                                            from its own altered copy
## ``evidence-path-changed-only``            the shipping path unit uses
##                                            ``PathChanged=`` and a run
##                                            lists the outbox once (D1)
## ``sink-cli-equals-only``                   the sink's options parse
##                                            only as ``--name=value`` (D2)
## ``check-ignores-acks``                     an acknowledged detection
##                                            still alerts (D4)
## ``check-ignores-containment``              a contained host's agent
##                                            reads as silent (D5)
## ``contain-unsigned``                       the containment record is
##                                            not attested (D5)
## ``refusal-names-no-copy``                  the refusal record names no
##                                            staging copy or compiler (D6)
## ``handover-unverified``                    a key hand-over is followed
##                                            unverified (D7)
## ``check-ignores-probe-announcement``       the announced credential
##                                            self-test alerts (D9)
## ``sink-payload-unescaped``                 the sink prints a payload's
##                                            bytes raw (D3)
## ``apt-closure-member-stays-missing``       a closure whose union is
##                                            realised leaves a missing
##                                            member unrealised (review 1)
## ``fetch-skips-missing-member``             the fetch stages a member's
##                                            archive only when the union is
##                                            missing (review 1)
## ``fetch-unit-paths-diverge``               re-pinning renders the fetch
##                                            unit without its observed-unit
##                                            directives (review 2)
## ``containment-unbound``                    any attested containment
##                                            record counts, whatever its
##                                            statement (review 3)
## ``handover-to-enrolled-id``                a hand-over to an enrolled id,
##                                            or the sender's own, is
##                                            followed (review 4)
## ``retired-without-successor-ok``           a retired id without an
##                                            enrolled successor raises
##                                            nothing (review 4)
## ``tree-tear-by-shape``                     any static tree missing a file
##                                            is repaired as a crash tear
##                                            (review 5)
## ``contained-agent-applies``                the engine agent ticks and
##                                            applies on a contained host
##                                            (review 6)
## ``lag-ignores-check-state``                lag counts from the archive's
##                                            re-signed copy, not the
##                                            check's own first-seen state
##                                            (review 7)
## ``path-unit-not-migrated``                 the own-object migration
##                                            leaves a stale shipping path
##                                            unit (review 8)
## ``ack-by-sequence-only``                   an acknowledgement handles
##                                            every alert of its record
##                                            (review 9)
## ``custody-forgets-before-rebuild``         custody drops the expected
##                                            digest before the rebuild is
##                                            verified (review 10)
## ``evidence-copy-unbounded``                an altered object's cross-
##                                            filesystem copy has no size
##                                            bound (review 10)
## ``ship-no-backoff``                        the shipping unit retries a
##                                            failing upload with no backoff
##                                            (review 11)
## ``outbox-temporary-inside``                an outbox entry's temporary
##                                            file is written inside the
##                                            outbox (review 11)
## ``custody-prefixes-only``                  a store path outside every
##                                            prefix is not named to custody
##                                            (review 12)
## ``egress-ignores-counter``                 refused packets the full sets
##                                            do not attribute raise nothing
##                                            (review 13)
## ``evidence-aged-by-mtime``                 store evidence ages by its
##                                            mtime, not its name's stamp
##                                            (review 14)
## ``uninstall-discards-evidence-silently``   uninstall removes kept store
##                                            evidence without being told to
##                                            (review 14)
## ``self-test-any-verb``                     a self-test window absorbs any
##                                            verb, any number of times
##                                            (review 15)
## ``hosts-retired-fifth-only``               the hosts file's retired@ is
##                                            read only in the fifth field
##                                            (review 16)
## ``custody-ignores-leftovers``             an object a crashed recovery
##                                            renamed aside is never filed
##                                            as evidence (review 10)
## ``custody-skips-unrecorded``               an evidence entry a crash left
##                                            without its record is never
##                                            recorded (review 10)
## ``custody-rebuild-unsynced``              a recovered object is recorded
##                                            before its rebuilt bytes are
##                                            synced (review 10)
## ``ship-runs-concurrently``                two shipping runs ship the
##                                            same entry at once (review 3,
##                                            found by the drill gate)
## ``containment-duplicate-is-replay``        a containment statement
##                                            delivered twice reads as a
##                                            replay (review 3)
## ``probe-shares-connection``                the credential self-test's
##                                            probes use the appender's
##                                            connection (round 2)
## ``lag-state-fails-open``                   an unreadable check state
##                                            reads as empty and an
##                                            unwritable one is ignored
##                                            (round 2)
## ``ack-detections-only``                    only a detection or a refused
##                                            verb can be acknowledged
##                                            (round 2)
## ``successor-chain-one-step``               a retired id's successor must
##                                            itself be live; the chain is
##                                            not followed (round 2)
## ``ship-backoff-reaches-timeout``           the backoff ceiling and the
##                                            shipping unit's timeout are
##                                            both 300 s (round 2)
## ``egress-cap-advances-all``                destinations past the per-
##                                            check cap advance in the
##                                            state, unrecorded (round 2)
## ``uninstall-ignores-asides``               uninstall does not file an
##                                            object left aside (round 2)
## ``tree-marker-on-reuse``                   the tree marker is written for
##                                            every realisation and kept on
##                                            failure (round 2)
## ``containment-sequence-unsynced``          the containment sequence is a
##                                            bare counter, written without
##                                            fsync (round 2)
## ``egress-unit-ignores-table``              the egress observer unit does
##                                            not name the table it loads
##                                            (round 2)
## ``sink-close-in-finally``                  the sink's connection handler
##                                            awaits its close in a finally,
##                                            as before; red under Nim 2.2.4
##                                            (round 3)
## ``egress-owed-by-listing``                 owed egress destinations are
##                                            taken in the set's listing
##                                            order (round 3)
## ``egress-owed-dropped-at-reload``          owed egress destinations are
##                                            forgotten at a table reload
##                                            (round 3)
## ``egress-state-empty-is-valid``            an empty or headerless egress
##                                            state reads as a first check
##                                            (round 3)
## ``check-state-empty-is-valid``             an empty check state reads as
##                                            a valid empty state (round 3)
## ``probe-undelivered-is-refused``           a forbidden-verb probe with no
##                                            reply counts as refused (round
##                                            3)
## ``ack-rules-cli-only``                     the sink appends, and the
##                                            check honours, any
##                                            acknowledgement (round 3)
## ``uninstall-discards-unrecorded``          uninstall records nothing it
##                                            discards, and does not wait
##                                            for the sink (round 3)
## ``alert-seq-zero-is-none``                an alert on the sink store's
##                                            first entry (sequence 0)
##                                            prints and matches as one
##                                            without a sequence
## ``allow-source-field``                     the record redaction lets a
##                                            ``source`` field through
##                                            (round 4)
## ``uninstall-skips-ack-refusal``            uninstall discards when the
##                                            sink received the records but
##                                            did not acknowledge them
##                                            (round 4, decision 56)
## ``override-unrecorded``                    the explicit override
##                                            discards without writing its
##                                            signed record (decision 62)
## ``seq-zero-sentinel``                      sequence 0 reads as "no
##                                            sequence" in the sink's
##                                            commands, a retirement and a
##                                            beat before a containment
##                                            (round 4)
## ``containment-skew-ignored``               a containment stated more
##                                            than 10 minutes from its
##                                            receipt is honoured (round 4)
## ``signer-close-in-finally``                the Distributed Execution
##                                            signer awaits its close in a
##                                            finally, as before; red under
##                                            Nim 2.2.4 (round 4; the
##                                            signer's own switch,
##                                            ``repro_distributed_worker/
##                                            signer``)
## ``signer-constant-tuple-return``          the signer's client returns a
##                                            refusal as a constant tuple
##                                            literal, as before; SIGSEGV
##                                            under Nim 2.2.4 (round 4)
## ``override-signs-other-bytes``            the override record's signature
##                                            is over other bytes than the
##                                            file holds (decision 64)
## ``override-empty-signature``               the override record's signature
##                                            file is empty (decision 64)
## ``override-keyless-unsigned``              without the attestation key the
##                                            override writes an unsigned
##                                            record and discards (decision
##                                            63)
## ``override-write-error-swallowed``         an override record that cannot
##                                            be written does not stop the
##                                            discard (decision 62)
## ``sim-stop-in-finally``                    a CONTROL, not a falsifier: the
##                                            simulator's TLS smoke pass as
##                                            before round 4 (peers stopped
##                                            in a finally no return leaves
##                                            through); green under Nim
##                                            2.2.4 too (round 5)
## ``fresh-skips-included``                   fresh_binary ignores files a
##                                            module includes (decision 65)
## ``fresh-skips-outside-tree``               fresh_binary ignores modules
##                                            from outside the tree
##                                            (decision 65)
## ``fresh-skips-c-sources``                  fresh_binary ignores the C files
##                                            compiled with {.compile.}
##                                            (decision 65, round 6)
## ``fresh-skips-headers``                    fresh_binary ignores the headers
##                                            those C files include
## ``fresh-skips-static-reads``               fresh_binary ignores staticRead
##                                            and staticExec inputs
## ``fresh-ignores-list-binary``              fresh_binary accepts a list
##                                            written for another binary
## ``override-sig-write-error-swallowed``     a failed signature write does
##                                            not stop the discard (round 6)
## ``verify-accepts-missing-key``             verify-discard-record verifies
##                                            without --key (round 6)
## ``sim-skips-stop``                         the simulator's TLS smoke pass
##                                            never stops its peers
##                                            (round 6)
## ``stale-helper-accepted``                  a test's helper binary is used
##                                            however old it is
##                                            (``repro_test_support/
##                                            fresh_binary``; round 4)
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
                          # A16 (e2e_addon_zero_touch_image_synthesis_boots_
                          # converged): an image assembly that leaves the
                          # ledger, or an apt closure's store prefix, out of
                          # the image (image_assemble.runImageAssembly).
                          "image-omits-gen0-ledger", "image-omits-store-closure",
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
                          "floor-without-mdwe",
                          # A9 review: memfd_create left allowed (the
                          # exec gate's memfd step); stored generations
                          # parsed under today's floor default (the
                          # upgrade gate); drop-ins of floored units not
                          # judged (t_addon_service_floor); the root units'
                          # filter without @mount and @chown (the syscall
                          # trace gate).
                          "floor-allows-memfd",
                          "stored-profile-floored",
                          "floor-ignores-drop-ins",
                          "privileged-filter-without-mount-chown",
                          # A9 review round 2 (each the round-1 behaviour
                          # its finding names):
                          "floor-private-mounts-exec",
                          "floor-allows-sysv-shm",
                          "floor-proc-writable",
                          "floor-paths-unnormalised",
                          "floor-allows-images",
                          "floor-ignores-prefix-dropins",
                          "stored-floor-unversioned",
                          "floor-change-by-ledger-bytes",
                          "replay-forgets-stored-target",
                          "recheck-skips-dropin-prefixes",
                          "trace-attributes-by-window",
                          # A9 review round 3: the static half off (the
                          # effective-unit check alone), both halves off,
                          # and each point fix's round-2 behaviour.
                          "floor-static-r3-disabled",
                          "floor-unchecked",
                          "effective-check-skipped",
                          "stored-floor-guess",
                          "floor-change-ignores-exceptions",
                          "store-objects-by-string",
                          "trace-sampler-blind",
                          "template-observed-by-name",
                          # A9 review round 4.
                          "exception-lifts-root",
                          "instance-dropin-needs-provider",
                          "dropins-from-the-distribution-trusted",
                          "properties-not-default-denied",
                          "unnamed-instances-unchecked",
                          "floor-start-unheld",
                          # A9 review round 5.
                          "floor-round5-static-off",
                          "inert-families-by-pattern",
                          "privileged-groups-by-name",
                          "environment-files-trusted",
                          "activators-unchecked",
                          "start-hold-removes-directory",
                          "stale-start-holds-kept",
                          # A9 review round 6.
                          "dynamic-user-trusted",
                          "show-last-line-only",
                          "absent-property-passes",
                          "file-only-settings-unread",
                          "read-only-binds-unjudged",
                          "state-targets-allowed",
                          "activator-options-unchecked",
                          "environment-file-links-unchecked",
                          "environment-file-links-refused",
                          # A9 review round 7: the start hold a unit can
                          # satisfy; manager-created paths in the add-on's
                          # trees; a unix listener anywhere under /run;
                          # round 5's socket key list; the round-6
                          # direct-only state rule; EnvironmentFile= by
                          # owner and mode; a bind source by string prefix;
                          # the effective half without the parse-time rules;
                          # the profile's own memberships ignored; an
                          # activator's reported properties unjudged; a
                          # printed file-judged setting trusted.
                          "hold-path-creatable",
                          "manager-paths-unchecked",
                          "listeners-anywhere-under-run",
                          "socket-options-by-list",
                          "state-routes-direct-only",
                          "environment-files-by-mode",
                          "bind-sources-by-prefix",
                          "effective-skips-parse-rules",
                          "profile-memberships-ignored",
                          "activator-show-unjudged",
                          "printed-file-settings-trusted",
                          # §13 decision 50 (amended): an adopted
                          # EnvironmentFile= accepted whatever its bytes.
                          "adopted-files-unverified",
                          # spec §4.3: an owned file that drifted cannot be
                          # adopted again (the row before decision 50's
                          # amendment).
                          "owned-drift-not-adoptable",
                          # getent errors read as "no such account".
                          "getent-errors-as-absent",
                          # §13 decision 55: Conflicts= naming a unit the
                          # profile does not define, accepted.
                          "conflicts-unchecked",
                          # A9 review round 8: a *Directory= by its leaf
                          # only; owned store objects falling back to the
                          # unit's own references; a reached profile unit's
                          # Conflicts= unjudged.
                          "directory-names-unchecked",
                          "owned-objects-fall-back",
                          "reached-conflicts-unchecked",
                          # A9 review round 9 (§13 decision 57): a unit
                          # named after a base tree; an existing tree not
                          # created for the unit; the record of the unit's
                          # own directories ignored.
                          "base-tree-names-allowed",
                          "existing-trees-allowed",
                          "created-dirs-ignored",
                          # the effective reach ending at units the
                          # generation does not install; the parse-rule
                          # rerun reported beside the dedicated rule.
                          "reach-stops-at-base-units",
                          "rerun-not-suppressed",
                          # an own secret EnvironmentFile= read in the
                          # switch's own mount namespace, not PID 1's.
                          "secrets-read-in-own-namespace",
                          # shutdown.target and umount.target, which
                          # systemd adds itself, judged as the unit's own.
                          "implicit-conflicts-refused",
                          # an EnvironmentFile= in a writable place judged
                          # again by where it resolves (two rules, one
                          # refusal).
                          "writable-env-judged-twice",
                          # A9 review round 10 (§13 decisions 67-70):
                          # ownership as provenance; the record keyed by
                          # path alone; the record taken after the whole
                          # start step; a unit named after a base tree
                          # refused only through a directory; a longer
                          # name taken as the unit's own; the activator's
                          # reached units unchecked; refusal lines with no
                          # rule tag, and a gate that skips them.
                          "ownership-as-provenance",
                          "created-dirs-by-path",
                          "created-dirs-per-step",
                          "base-tree-units-by-directory",
                          "own-names-by-prefix",
                          "activator-reach-unchecked",
                          "refusal-lines-untagged",
                          "untagged-lines-skipped",
                          # a directory the unit's own restart made
                          # again not recorded again.
                          "created-dirs-not-rerecorded",
                          # §13 decision 71, one per condition: a
                          # directory not recorded for the unit, one not
                          # exactly declared, one systemd's state does not
                          # show it made, each taken as made again.
                          "recreated-unrecorded-accepted",
                          "recreated-any-path",
                          "recreated-systemd-unchecked",
                          # a directory decision 71 accepted, then made
                          # again by the same switch, not recorded again.
                          "accepted-not-rerecorded",
                          # §13 decision 72, the one-time migration:
                          # it runs again over an existing record; it
                          # takes a directory not exactly declared; a
                          # corrupt record counts as absent; it takes a
                          # unit the committed generation did not install.
                          "migration-reruns",
                          "migration-any-path",
                          "corrupt-record-as-absent",
                          "migration-any-unit",
                          # A13: a state backup or restore runs while a
                          # unit of the set may run.
                          "state-units-not-checked",
                          # A13: the backup does not hold the set's units,
                          # so one can start again before the conversion.
                          "state-units-not-held",
                          # A13: a restore reads an archive whose SHA-256
                          # it did not check against the manifest.
                          "state-archive-unchecked",
                          # A13: a restore renames a staged tree into place
                          # without checking its digest.
                          "state-restore-unverified",
                          # A13: an apply starts a unit whose carried state
                          # is not restored yet.
                          "apply-ignores-carried-state",
                          # A13: the import writes its skeleton on the host.
                          "import-writes-skeleton",
                          # A13 review: the falsifiers of the review's
                          # fixes (see the table above).
                          "pending-by-receipt-only",
                          "carried-reach-by-unit-name",
                          "owner-ids-unchecked",
                          "apply-ignores-hold",
                          "hold-runtime-only",
                          "hardlinks-unchecked",
                          "restore-leaves-staging",
                          "restore-writes-dense",
                          "keep-without-mount-requirement",
                          "import-copies-env-secret",
                          "restore-after-start",
                          "revert-refuses-restored",
                          # Milestone A11 (detection and capture). Read by
                          # repro_peer_cache/evidence.nim, which cannot
                          # import this module: the Evidence sink answers a
                          # list or a read from an appender (G34's gate).
                          "sink-credential-has-read-scope",
                          # The shipping unit deletes outbox entries before
                          # the sink acknowledged them (DET-6).
                          "ship-deletes-before-ack",
                          # The attestation is signed over other bytes than
                          # its statement (spec §10.5).
                          "attestation-unsigned",
                          # The statement presents itself as host
                          # attestation (spec §10.5's "never").
                          "attestation-claims-host",
                          # The off-host check: silence reported as idle
                          # (DET-5), attestations not compared (DET-AO-9),
                          # no lag alert (DET-AO-10).
                          "check-silence-as-idle",
                          "check-skips-attestation",
                          "lag-detector-disabled",
                          # A tick's outcome leaves no detection record.
                          "tick-records-no-detection",
                          # The shipping unit without its egress allow-list,
                          # and with the attestation and recipient keys
                          # visible to it.
                          "evidence-ship-unrestricted-egress",
                          "evidence-ship-sees-agent-keys",
                          # A13 review round 2.
                          "receipt-trusts-inode",
                          # A13 review round 3 item 11: the receipt
                          # written without its fsyncs (the hard-reset
                          # gate's receipt points).
                          "receipt-no-fsync",
                          # A13 review round 4 finding 1: the shared
                          # service-account resolver (repro_infra/
                          # service_account) takes the account as written.
                          "account-as-written",
                          # A13 review round 4, findings 2-5.
                          "reach-host-dropins-ignored",
                          "reach-timer-dropins-unread",
                          "reach-path-unit-paths-ignored",
                          "restore-requirement-by-manifest-only",
                          # A13 review round 5.
                          "reach-values-as-text",
                          "confined-without-nnp-or-groups",
                          "account-dynamic-name-from-stem",
                          "account-nss-unread",
                          "reach-alias-dropins-unread",
                          "reach-stale-generation-dropins-skipped",
                          "restore-requirement-skips-activated",
                          "restore-requirement-skips-dropin-targets",
                          "unit-lines-continue-as-text",
                          "exec-first-command-only",
                          "alias-chain-first-link-only",
                          "dependency-links-unread",
                          "requirement-name-not-reserved",
                          "privileged-daemons-unread",
                          "restore-requirement-skips-closure",
                          "addon-live-reach-skipped",
                          "infra-live-reach-skipped",
                          "adopt-without-profile",
                          "live-units-chosen-after-writes",
                          "optional-paths-ignored",
                          "post-reload-refusal-skipped",
                          "plan-ignores-profile-digest",
                          "full-apply-keeps-undeclared-dropins",
                          "install-unit-reads-host-manifest",
                          "live-reach-unchecked",
                          "reach-ignores-privileged-commands",
                          "reach-dropin-judged-alone",
                          "reach-trigger-units-reach-nothing",
                          "backup-without-host-lock",
                          "restore-not-required-by-units",
                          # A13 review round 3.
                          "restore-unordered",
                          "restore-required-by-link",
                          "carried-check-not-under-lock",
                          "missing-manifest-allowed",
                          "reach-default-allow",
                          "reach-paths-as-text",
                          # A11 review: the full engine's deploy-agent tick
                          # on an add-on host leaves no record.
                          "engine-tick-unrecorded",
                          # Owner decision 2026-11-04 (DET-AO-3): the egress
                          # observer's table is never loaded.
                          "egress-observer-not-installed",
                          # Owner decision 2026-11-04 (evidence-enrol): keys
                          # already on the host are not looked for.
                          "evidence-keys-adopted",
                          # Owner decision 2026-11-05 (G41): the store
                          # verification compares no digest.
                          "reassert-skips-digest-check",
                          # A11 audit F1: lag counted from the newest copy.
                          "lag-from-newest-copy",
                          # A11 audit F2: the shipping units rate-limited as
                          # before, and the check blind to a stall.
                          "evidence-path-rate-limited",
                          "check-ignores-ship-delay",
                          # A11 audit F3: egress counts kept across a reload.
                          "egress-state-survives-reload",
                          # The handle repeats at the next boot.
                          "egress-instance-ignores-boot",
                          # A11 audit F4: statuses beside their own alert.
                          "check-status-ignores-silence",
                          # A11 audit F6: the hosts file's enrolled key and
                          # generation 0 ignored.
                          "check-forgets-enrolled-key",
                          # A11 audit F5: uninstall keeps the fetch unit's
                          # state directory.
                          "uninstall-keeps-fetch-state",
                          # A11 audit session 2, G2: the expected digest
                          # read from the path being verified.
                          "store-verify-trusts-receipt",
                          # G4: the egress table listed in the re-assert
                          # unit's own (empty) network namespace.
                          "reassert-nft-in-own-netns",
                          # Session 2, low: one trigger for a missing and a
                          # quarantined store object.
                          "reassert-store-trigger-missing",
                          # Owner decisions 2026-11-05 (G1 / G42): store
                          # custody and recovery.
                          "custody-skips-file-sources",
                          "custody-skips-closures",
                          "custody-admits-undigested",
                          "custody-cache-ignores-signature",
                          "recovery-discards-evidence",
                          "recovery-trusts-store-bytes",
                          # The A11 drill's findings D1-D9.
                          "evidence-path-changed-only",
                          "sink-cli-equals-only", "check-ignores-acks",
                          "check-ignores-containment", "contain-unsigned",
                          "refusal-names-no-copy", "handover-unverified",
                          "check-ignores-probe-announcement",
                          "sink-payload-unescaped",
                          # The A11 code review's findings 1-16.
                          "apt-closure-member-stays-missing",
                          "fetch-skips-missing-member",
                          "fetch-unit-paths-diverge",
                          "containment-unbound", "handover-to-enrolled-id",
                          "retired-without-successor-ok",
                          "tree-tear-by-shape", "contained-agent-applies",
                          "lag-ignores-check-state", "path-unit-not-migrated",
                          "ack-by-sequence-only",
                          "custody-forgets-before-rebuild",
                          "evidence-copy-unbounded", "ship-no-backoff",
                          "outbox-temporary-inside", "custody-prefixes-only",
                          "egress-ignores-counter", "evidence-aged-by-mtime",
                          "uninstall-discards-evidence-silently",
                          "self-test-any-verb", "hosts-retired-fifth-only",
                          "custody-ignores-leftovers",
                          "custody-skips-unrecorded",
                          "custody-rebuild-unsynced",
                          "ship-runs-concurrently",
                          "containment-duplicate-is-replay",
                          # The A11 code review, round 2.
                          "probe-shares-connection", "lag-state-fails-open",
                          "ack-detections-only", "successor-chain-one-step",
                          "ship-backoff-reaches-timeout",
                          "egress-cap-advances-all", "uninstall-ignores-asides",
                          "tree-marker-on-reuse", "containment-sequence-unsynced",
                          "egress-unit-ignores-table",
                          # The A11 code review, round 3.
                          "sink-close-in-finally", "egress-owed-by-listing",
                          "egress-owed-dropped-at-reload",
                          "check-state-empty-is-valid",
                          "probe-undelivered-is-refused",
                          "ack-rules-cli-only",
                          "uninstall-discards-unrecorded",
                          "egress-state-empty-is-valid",
                          "alert-seq-zero-is-none",
                          # The A11 code review, round 4.
                          "allow-source-field", "uninstall-skips-ack-refusal",
                          "override-unrecorded", "seq-zero-sentinel",
                          "containment-skew-ignored",
                          "signer-close-in-finally",
                          "signer-constant-tuple-return",
                          "stale-helper-accepted",
                          "override-signs-other-bytes",
                          "override-empty-signature",
                          "override-keyless-unsigned",
                          "override-write-error-swallowed",
                          "sim-stop-in-finally", "fresh-skips-included",
                          "fresh-skips-outside-tree",
                          "fresh-skips-c-sources", "fresh-skips-headers",
                          "fresh-skips-static-reads",
                          "fresh-ignores-list-binary",
                          "override-sig-write-error-swallowed",
                          "verify-accepts-missing-key", "sim-skips-stop"]

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

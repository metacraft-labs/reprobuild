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
## =========================================  ==============================

const
  AddonMutation* {.strdefine: "reproAddonMutation".} = ""
  KnownAddonMutations* = ["uninstall-skips-diversion-removal",
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
                          "secrets-on-disk",
                          "secrets-on-tmpfs",
                          "secrets-single-retained-envelope",
                          "credentials-not-planned",
                          "rotation-not-reconciled",
                          "recipient-key-mode-unchecked",
                          "secrets-write-then-narrow",
                          "rotation-keeps-old-key"]

when AddonMutation.len > 0 and AddonMutation notin KnownAddonMutations:
  {.error: "unknown -d:reproAddonMutation=" & AddonMutation.}

template mutated*(name: static string): bool =
  ## True only in the build compiled with ``-d:reproAddonMutation=<name>``.
  static:
    doAssert name in KnownAddonMutations, "unknown add-on mutation " & name
  AddonMutation == name

const TestPauseSeam* = AddonMutation in ["pause-before-write",
                                         "pause-before-write-no-recheck",
                                         "kept-units-still-stopped"]
  ## The write-time re-check gate's pause seam is compiled in (a test-only
  ## build; see the table above). False in every product build.

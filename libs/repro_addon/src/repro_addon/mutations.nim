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
                          "path-based-write-follows-links",
                          "scope-accepts-unnormalised-paths",
                          "reassert-required-by-boot",
                          "reassert-skips-recovery",
                          "pause-before-write",
                          "pause-before-write-no-recheck",
                          "install-targets-ignore-alias-also"]

when AddonMutation.len > 0 and AddonMutation notin KnownAddonMutations:
  {.error: "unknown -d:reproAddonMutation=" & AddonMutation.}

template mutated*(name: static string): bool =
  ## True only in the build compiled with ``-d:reproAddonMutation=<name>``.
  static:
    doAssert name in KnownAddonMutations, "unknown add-on mutation " & name
  AddonMutation == name

const TestPauseSeam* = AddonMutation in ["pause-before-write",
                                         "pause-before-write-no-recheck",
                          "install-targets-ignore-alias-also"]
  ## The write-time re-check gate's pause seam is compiled in (a test-only
  ## build; see the table above). False in every product build.

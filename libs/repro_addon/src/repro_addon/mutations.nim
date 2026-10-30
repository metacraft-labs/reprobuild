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
##                                            file under ``/var/lib``
## ``recipient-key-0644``                     bootstrap writes the recipient
##                                            key group- and world-readable
## ``provisions-publisher-key``               bootstrap also leaves a binary
##                                            cache publisher keypair
## =========================================  ==============================

const
  AddonMutation* {.strdefine: "reproAddonMutation".} = ""
  KnownAddonMutations* = ["uninstall-skips-diversion-removal",
                          "bootstrap-installs-jq", "preflight-writes",
                          "recipient-key-0644", "provisions-publisher-key"]

when AddonMutation.len > 0 and AddonMutation notin KnownAddonMutations:
  {.error: "unknown -d:reproAddonMutation=" & AddonMutation.}

template mutated*(name: static string): bool =
  ## True only in the build compiled with ``-d:reproAddonMutation=<name>``.
  static:
    doAssert name in KnownAddonMutations, "unknown add-on mutation " & name
  AddonMutation == name

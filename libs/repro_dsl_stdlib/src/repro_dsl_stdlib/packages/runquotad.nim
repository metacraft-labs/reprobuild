## M9.R.14b.1 — stdlib provisioning stub for ``runquotad``.
##
## ``runquotad`` is the RunQuota daemon (the resource-lease coordinator
## reprobuild spawns to serialize concurrent provider builds). It lives
## in the sibling ``metacraft-labs/runquota`` repository, not in
## nixpkgs, so the Linux/macOS Nix channel here points at the flake
## URL directly (not at a ``nixpkgs#<attr>``).
##
## ## Why this stub exists
##
## Under ``--tool-provisioning=from-source`` the engine first looks for
## a sibling recipe at ``recipes/packages/source/runquotad/`` and then
## falls back to whatever provisioning channels the stdlib ``package
## runquotad:`` block declares. Prior to this milestone neither
## existed, so the from-source resolver failed closed for every recipe
## that depended on ``runquotad`` (i.e. every recipe; the engine spawns
## ``runquotad`` implicitly for the build-engine's runquota client).
##
## The fix is to provide a stdlib provisioning channel here. The
## ``M9.R.14a.4`` smoke (``expat --tool-provisioning=from-source``)
## surfaced this gap with a ~11-second trip:
##
##   daemon-hosted build failed: tool-resolution failed:
##   --tool-provisioning=from-source requested for "runquotad" (package
##   "runquotad") but no sibling recipe at
##   recipes/packages/source/runquotad/repro.nim and no stdlib
##   provisioning channel (nix / scoop / tarball) declared on the tool
##   use.
##
## ## Channel choice — flake URL nixPackage
##
## runquota is a Nim binary built from the upstream ``runquota.nimble``;
## it is NOT published to nixpkgs. The flake's ``packages.runquota``
## derivation produces both ``bin/runquota`` (client CLI) and
## ``bin/runquotad`` (daemon). The selector below is the GitHub flake
## URL pinned to the same revision as ``reprobuild`` 's
## ``flake.lock``'s ``runquota-src`` node so this stdlib provisioning
## tracks what CI / the reprobuild dev shell sees byte-for-byte.
##
## When the operator bumps the ``runquota-src`` input pin in
## ``flake.nix`` / ``flake.lock``, also bump the revision here so the
## two stay aligned.
##
## ## No Scoop / no tarball
##
## Scoop / direct tarball channels do not apply: runquota does not
## publish prebuilts on a Scoop bucket or a static download URL. The
## Windows from-source path will need a different channel (the sibling
## checkout at ``../runquota`` lifted by config.nims is what currently
## works there; a Windows-specific port lands in a later milestone).

import repro_project_dsl

package runquotad:
  provisioning:
    # Linux / macOS via the runquota flake URL pinned to the same
    # revision as ``flake.lock``'s ``runquota-src`` node. The selector
    # is passed verbatim to ``nix build`` so any operator with
    # ``experimental-features = nix-command flakes`` resolves the
    # daemon binary byte-identically with what the reprobuild dev shell
    # ships.
    nixPackage "github:metacraft-labs/runquota/87524764128109d433d0c3356d9b1edb5a60cbc6#runquota",
      executablePath = "bin/runquotad"

  executable runquotad:
    discard

## DSL-port M9.R.15o.3 — stdlib provisioning stub for ``wayland-scanner``.
##
## ``wayland-scanner`` is the protocol-stub code generator the wayland
## meson build ships at ``<prefix>/bin/wayland-scanner``. KF6 + Plasma
## + KWin recipes declare it as a ``nativeBuildDeps`` entry (it runs at
## the consumer's build time to generate ``*-protocol.c`` /
## ``*-protocol-client.h`` files from wayland XML).
##
## The sibling ``recipes/packages/source/wayland/`` recipe ships the
## binary at ``.repro/output/install/usr/bin/wayland-scanner`` under
## the from-source channel; this stub exposes the same binary via the
## Nix channel so recipes that pull ``wayland-scanner`` resolve under
## either ``--tool-provisioning=nix`` or ``--tool-provisioning=
## from-source`` (the from-source resolver walks the stdlib stub when
## no sibling recipe exists at ``source/wayland-scanner/``).
##
## TODO(M9.R.15p+): widen the channel set + add a tarball fallback for
## the offline-bootstrap path. The stub keeps the kio/kwindowsystem/
## plasma-framework/kwin chain unblocked; richer provisioning lands
## with the post-weekend Plasma/KWin campaign.

import repro_project_dsl

package `wayland-scanner`:
  provisioning:
    # nixpkgs ships wayland-scanner as its OWN top-level derivation
    # (the host-side code generator is split from the target-side
    # libwayland-client / libwayland-server / etc. so cross-compilers
    # can pull the scanner without the runtime libs). Same nixpkgsRev
    # pinned to match wayland_protocols.nim + qt6_tools.nim so the
    # cross-package fetch graph stays shareable.
    nixPackage "nixpkgs#wayland-scanner", executablePath = "bin/wayland-scanner",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

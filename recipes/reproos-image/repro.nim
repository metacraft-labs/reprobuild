## M9.R.50.2 -- reproos-image: NixOS-style build-artifact recipe.
##
## Spec: ``reprobuild-specs/ReproOS-Image-Recipe.md`` (M9.R.50.1).
##
## Architectural pivot from boot-time autorun-installer to a recipe
## whose ``build`` action produces a fully-installed
## ``reproos-installed-<de>.qcow2`` on the host.  The same machinery
## the engine uses to build any other recipe builds the whole OS
## image; failures surface as recipe-build errors on the host shell,
## with full stderr, in seconds -- not 90 minutes deep inside QEMU.
##
## Reuses (no reinvention):
##
##   - ``recipes/reproos-iso/scripts/stage-de-rootfs.sh`` produces
##     the Nix-style /repro/store + symlink-farm rootfs tree.
##   - ``recipes/reproos-iso/scripts/relocate-nix-to-repro.sh`` is
##     called by stage-de-rootfs.sh (M9.R.46 Phase 6b).
##   - ``repro disk apply --confirm <disko.json> --device <dev>``
##     partitions + formats the qcow2-as-block-device.
##   - ``repro infra install-root --target <mnt> --device <dev>
##     --disko <disko.json> --hostname <hn>`` rsyncs the staged tree,
##     writes fstab, copies kernel + initrd, grub-install + grub.cfg.
##
## All of the above were already debugged through M9.R.41 + M9.R.46;
## the only NEW driver code is
## ``scripts/build-reproos-image.sh`` which wires them together
## around a qcow2-as-block-device created via ``qemu-img create`` +
## ``qemu-nbd --connect``.
##
## Input contract:
##
##   - ``--config <auto-config.toml>`` (passed via ``--`` to ``repro
##     build``; the driver consumes ``$REPRO_AUTO_CONFIG``).
##   - All from-source DE recipe install-mirrors (sway, kwin, mutter,
##     plasmashell, sddm) declared as extraInputs via the per-recipe
##     output path so the engine refingerprints when any DE binary
##     changes.
##
## Output contract:
##
##   - ``build/reproos-installed.qcow2``: the bootable, fully-
##     installed disk image.  The engine copies it to
##     ``recipes/reproos-image/.repro/output/install/<sha256>-
##     reproos-installed.qcow2``.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package reproosImage:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    # Drive the image build through scripts/build-reproos-image.sh.
    # That script owns the unit-of-execution boundary: qemu-img
    # create, qemu-nbd connect, repro disk apply, mount, repro infra
    # install-root, unmount, qemu-nbd disconnect, sha256 self-report.
    #
    # ``REPRO_AUTO_CONFIG`` defaults to the smoke fixture; the wizard
    # / smoke harness overrides it at recipe-invocation time via
    # ``REPRO_AUTO_CONFIG=/path/to/auto-config.toml repro build
    # recipes/reproos-image``.  The path is also declared as an
    # extraInput so the engine refingerprints when the config bytes
    # change.
    #
    # ``SOURCE_DATE_EPOCH = 1735689600`` (2025-01-01T00:00:00Z) pins
    # every timestamp downstream.  ``LC_ALL=C`` + ``TZ=UTC`` pin
    # locale + timezone.  ``REPRO_QCOW2_SEED=<hex>`` is the random
    # seed disko's mkfs.ext4 + mkfs.vfat consume so UUIDs +
    # volume-serials are deterministic.
    shell(
      command = ("set -euo pipefail; " &
                 "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "REPRO_AUTO_CONFIG=\"${REPRO_AUTO_CONFIG:-../../tests/fixtures/auto-config-minimal.toml}\" " &
                 "REPRO_QCOW2_SEED=\"${REPRO_QCOW2_SEED:-deadbeefcafebabe}\" " &
                 "bash scripts/build-reproos-image.sh " &
                 "build/reproos-installed.qcow2"),
      actionId = "reproosImage.build_image",
      # extraInputs are resolved relative to the action's cwd (the
      # recipe directory).  The build script + the smoke fixture +
      # the reused scripts from reproos-iso all need to be
      # fingerprinted so the action cache invalidates when any of
      # them changes.
      extraInputs = @[
        "scripts/build-reproos-image.sh",
        "../../tests/fixtures/auto-config-minimal.toml",
        # Reuse the iso recipe's staging + relocation scripts; both
        # are content-stable and the engine refingerprints when
        # they change.
        "../reproos-iso/scripts/stage-de-rootfs.sh",
        "../reproos-iso/scripts/relocate-nix-to-repro.sh",
        "../reproos-iso/scripts/build-base-rootfs.sh",
      ],
      extraOutputs = @[
        "build/reproos-installed.qcow2",
      ])

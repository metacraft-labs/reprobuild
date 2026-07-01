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

# M9.R.53: reproos-image's build-time toolset is enumerated here as
# ``runtimeDeps`` (the tools the build-reproos-image.sh script needs
# on PATH when the recipe runs).  Under ``defaultToolProvisioning
# "path"`` the M9.N Batch B tool-identity resolver probes each name
# against the host PATH at build-plan time; a missing tool raises a
# structured "tool-resolution failed: <name> requested by uses ..."
# diagnostic BEFORE the shell action fires -- replacing the previous
# ad-hoc ``nix-shell -p qemu grub2 ...`` wrap that hid provisioning
# gaps behind ``command not found`` runtime failures.
#
# The list here is derived by ``grep``ing the invoked bare-name tools
# out of ``scripts/build-reproos-image.sh``; keep the two in lockstep
# (a follow-up milestone will add an audit test that walks the script
# and cross-checks against this seq).
#
# ``sudo`` is the sole host escape hatch (it needs setuid so it can't
# be provisioned by a store-managed catalog).  The build script
# references it as ``/usr/bin/sudo`` explicitly; it is NOT listed
# here because path-mode resolution would probe a non-setuid copy.
const reproosImageRuntimeTools = @[
  # QEMU disk image + NBD.  Host-provisioned (dev shell must supply
  # qemu-utils / nbd-client via env.ps1 or nixpkgs#qemu).
  "qemu-img",
  "qemu-nbd",
  # Disk partitioning + probe.
  "parted",
  "partprobe",
  "sgdisk",
  # Filesystem creation.
  "mkfs.ext4",
  "mkfs.vfat",
  # Boot loader install.
  "grub-install",
  "grub-mkconfig",
  # Tree-sync into the mount point.
  "rsync",
  # Kernel module management for the nbd module load/unload.
  "modprobe",
  "rmmod",
  "lsmod",
  # Mount / unmount / mount-point probe (util-linux).
  "mount",
  "umount",
  "mountpoint",
  # POSIX text utils used by the TOML awk-extractor + shadow-line
  # emitter + fstab/grub.cfg sed rewrite pass.
  "awk",
  "sed",
  "grep",
  # Coreutils bins the script invokes as bare names.  Every one is
  # part of GNU coreutils; declaring them individually keeps the
  # resolver's per-tool diagnostics granular (a missing ``sha256sum``
  # names ``sha256sum`` specifically, not a whole coreutils bundle).
  "sha256sum",
  "dirname",
  "basename",
  "chmod",
  "mv",
  "cp",
  "rm",
  "mkdir",
  "ls",
  "cat",
  "sleep",
  "sync",
  "touch",
  "du",
  "df",
  "tail",
]

package reproosImage:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "bash"
    # Tools the ``build:`` shell action invokes.  Duplicates the
    # ``runtimeDeps:`` entries below because the M9.N Batch B tool-
    # identity resolver walks ``ProjectInterface.toolUses`` (the
    # engine-side projection of ``uses:`` + ``nativeBuildDeps:``)
    # rather than the per-kind ``registeredRuntimeDeps`` slot.  Once
    # M9.R.53's macros_a fold lands (runtimeDeps -> toolUses) the
    # duplication collapses; until then the twin declaration keeps
    # both the semantic slot (``runtimeDeps:``) and the operational
    # slot (``uses:``) aligned.
    "qemu-img"
    "qemu-nbd"
    "parted"
    "partprobe"
    "sgdisk"
    "mkfs.ext4"
    "mkfs.vfat"
    "grub-install"
    "grub-mkconfig"
    "rsync"
    "modprobe"
    "rmmod"
    "lsmod"
    "mount"
    "umount"
    "mountpoint"
    "awk"
    "sed"
    "grep"
    "sha256sum"
    "dirname"
    "basename"
    "chmod"
    "mv"
    "cp"
    "rm"
    "mkdir"
    "ls"
    "cat"
    "sleep"
    "sync"
    "touch"
    "du"
    "df"
    "tail"

  runtimeDeps:
    # Semantic slot: these are the tools the shell script invokes
    # when the recipe runs.  Enumerated in ``reproosImageRuntimeTools``
    # above.  ``discard`` below satisfies the parser's expectation of
    # a block body; each individual tool literal is registered via
    # the ``uses:`` block for the M9.N Batch B resolver walk.
    #
    # TODO(M9.R.53.follow-up): fold ``runtimeDeps`` into ``toolUses``
    # inside ``macros_a.nim`` so the twin declaration in ``uses:``
    # above becomes redundant and the semantic split (build-time vs
    # runtime) survives without operational duplication.
    "qemu-img"
    "qemu-nbd"
    "parted"
    "partprobe"
    "sgdisk"
    "mkfs.ext4"
    "mkfs.vfat"
    "grub-install"
    "grub-mkconfig"
    "rsync"
    "modprobe"
    "rmmod"
    "lsmod"
    "mount"
    "umount"
    "mountpoint"
    "awk"
    "sed"
    "grep"
    "sha256sum"
    "dirname"
    "basename"
    "chmod"
    "mv"
    "cp"
    "rm"
    "mkdir"
    "ls"
    "cat"
    "sleep"
    "sync"
    "touch"
    "du"
    "df"
    "tail"

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
    let buildImageAction = shell(
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
    # M9.R.53: wire the runtime tool set into the shell action's
    # ``toolIdentityRefs`` so the M9.N Batch B resolver prepends each
    # tool's host-PATH parent dir to the action's PATH at fork time.
    # Without this the shell action carries an empty
    # ``toolIdentityRefs`` slot and the resolver skips PATH plumbing
    # entirely (the ``recordToolInvocation`` seam does not
    # auto-populate the slot from the package-level ``uses:`` block).
    appendRegisteredActionToolIdentityRefs(buildImageAction.id,
      reproosImageRuntimeTools)

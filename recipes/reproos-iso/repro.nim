## R2: deterministic hybrid (BIOS + UEFI) ReproOS ISO recipe.
##
## Wraps the ``scripts/build-iso.sh`` driver that calls grub-mkrescue +
## xorriso inside a WSL2 distro on Windows (the host does not ship
## xorriso) or directly on Linux. The recipe declares the typed
## ``(kernel, initramfs, scripts)`` -> ``iso`` action so the engine can
## fingerprint the inputs, action-cache the output, and emit one
## bit-identical ISO per build.
##
## R2 vs R10 input handling:
##
## * Today (R2): the kernel + initramfs are vendored from the upstream
##   Debian netinst ISO (see ``vendor/MANIFEST.md``); the recipe
##   consumes them via static repo-relative paths under ``vendor/``. The
##   netinst kernel + initrd are perfect for a "did the kernel reach
##   userspace?" boot-gate assertion target -- they're small, self-
##   contained, and produce a text-mode installer banner on serial
##   COM1 that the R0 vm-harness ``bootFromMedia`` boot gate tails.
##
## * Later (R10): the same recipe takes the R8 (from-source kernel)
##   and R7 (from-source initramfs) typed outputs as inputs -- only the
##   ``uses:`` dep edges change; the buildAction, the ISO layout, the
##   GRUB config, and the reproducibility flags stay byte-for-byte
##   identical. The R10 swap is a one-line edit (replace the two
##   ``./vendor/...`` paths with ``${reproosKernel.kernel}`` and
##   ``${reproosInitramfs.initramfs}`` selectors), and the recipe's
##   output sha256 stays bit-stable across the swap if the from-source
##   kernel + initramfs are themselves bit-identical to the vendored
##   ones (which they will be at the R10 acceptance criterion).
##
## This is the "promise" of typed reprobuild: the recipe layer is
## input-graph-agnostic; what counts is that the (inputs, environment,
## tool versions) tuple is deterministic.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package reproosIso:
  defaultToolProvisioning "path"

  uses:
    "sh"

  # The two vendored inputs. R10 will replace these with selectors into
  # the R8 + R7 typed packages; the rest of the recipe doesn't change.
  #
  # NOTE: the vendored blobs are gitignored (12 MB kernel + 24 MB
  # initramfs both exceed the project's <=10 MB committable rule). Run
  # ``pwsh recipes/reproos-iso/vendor/fetch.ps1`` to materialise them
  # before invoking the build. SHA256SUMS in the same directory pins
  # both against their upstream-extracted sha256.

  build:
    # Drive the ISO build through the build-iso.sh script. The script
    # is the unit-of-execution boundary: it brings up the mformat shim
    # (pinning the FAT volume serial), the grub-mkrescue / xorriso
    # invocation (pinning every other reproducibility-hazardous field),
    # and the sha256 self-report. The recipe layer above only
    # constrains the (inputs, env, output) contract.
    #
    # The ``sh`` typed-tool call below records the env + arg surface
    # the engine fingerprints. ``SOURCE_DATE_EPOCH = 1735689600`` is
    # 2025-01-01T00:00:00Z; that constant is the source of truth for
    # every timestamp downstream of this recipe. ``LC_ALL=C`` + ``TZ=UTC``
    # pin locale + timezone for ASCII-formatted timestamps in the PVD.
    #
    # Inputs declared as ``extraInputs`` so the engine recomputes the
    # action's fingerprint when any of (vendored kernel, vendored
    # initramfs, build script) changes:
    # The script is invoked relative to the recipe directory by the
    # ``cd`` prefix; the engine sets the working dir to the repo root
    # (the action picks up the recipe dir via the literal path). This
    # mirrors the ``apps/repro-*`` action shape that ``apps/repro.nim``
    # uses for the per-binary nim.c(...) calls.
    # M9.R.16.6 — the repro engine sets cwd to the recipe directory
    # (``recipes/reproos-iso``) before launching the shell action, so
    # the historical ``cd recipes/reproos-iso &&`` prefix bombs out
    # with ``No such file or directory``. Drop the prefix; paths are
    # already relative to the recipe dir.
    shell(
      command = ("SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "bash scripts/build-iso.sh " &
                 "vendor/vmlinuz-debian-netinst " &
                 "vendor/initrd.img-debian-netinst " &
                 "build/reproos.iso"),
      actionId = "reproosIso.build_iso",
      extraInputs = @[
        "recipes/reproos-iso/vendor/vmlinuz-debian-netinst",
        "recipes/reproos-iso/vendor/initrd.img-debian-netinst",
        "recipes/reproos-iso/vendor/SHA256SUMS",
        "recipes/reproos-iso/scripts/build-iso.sh",
      ],
      extraOutputs = @[
        "recipes/reproos-iso/build/reproos.iso",
      ])

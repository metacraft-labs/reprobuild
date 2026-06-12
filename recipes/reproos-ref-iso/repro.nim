## R1 stub recipe — ReproOS reference ISO.
##
## R1 (this milestone) is a HARNESS-LEVEL gate, not a deliverable:
## `boot-test.py` drives the R0 boot-harness against a vendored Debian
## bookworm rootfs to prove the ISO/rootfs -> harness -> systemd-userspace
## -> serial-assertion pipeline works END-TO-END. The actual typed-action
## reprobuild ISO recipe is the R2 deliverable.
##
## When R2 replaces this stub, it will declare:
##   - the boot-medium kind (ISO for Hyper-V/QEMU paths, rootfs tarball
##     for WSL2 path),
##   - the vendored kernel + initrd + bootloader (R1) or the
##     reprobuild-built ones (R10),
##   - the systemd userspace tree (R4-R8 build from source),
##   - a `boot-gate:` block that the test driver materialises into the
##     same `expected.json` schema this directory ships today.
##
## The companion `boot-test.py` is the standalone driver. It does not
## (yet) consume `repro.nim`; it reads `expected.json` directly. R2 will
## generate `expected.json` from `boot-gate:` and remove the duplication.

import repro_project_dsl

package reproosRefIso:
  uses:
    "vendored-upstream-binary"
  # R2: replace the vendored-upstream marker with the typed-action chain
  # that produces the ISO + kernel + initrd + rootfs squashfs from
  # source.

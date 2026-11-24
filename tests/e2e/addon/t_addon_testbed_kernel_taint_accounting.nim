## The add-on test bed's kernel-taint accounting
## (``addon_testbed.isDisplayVblankOnlyTaint``): which tainted kernels a
## gate's fingerprint comparison may treat as untainted.
##
## A gate fingerprints the whole host, ``kernel.tainted`` included. A taint
## is recorded as 0 only when it is exactly TAINT_WARN and every kernel
## report is a ``WARNING:`` from the emulated display's vblank wait (the
## Omarchy guest's ``bochs-drm`` under host load, measured 2026-11-24 at
## reprobuild ``daa0b43196``). Anything else, and a taint whose report the
## ring buffer has lost, must stay visible, or the accounting would hide a
## kernel problem a switch caused.
##
## No mocks: the function is pure, and the inputs are ``dmesg`` lines as
## the guest prints them. The vblank report is copied from the measured
## run's log.

import std/unittest

import ./addon_testbed

const
  VblankWarning = "WARNING: drivers/gpu/drm/drm_atomic_helper.c:1921 at " &
    "drm_atomic_helper_wait_for_vblanks.part.0+0x263/0x2c0, CPU#0: " &
    "kworker/0:1/10"
  OtherWarning = "WARNING: fs/btrfs/transaction.c:144 at " &
    "btrfs_put_transaction+0x91/0xa0, CPU#1: kworker/u8:3/211"

suite "add-on test bed: kernel taint accounting":
  test "a vblank-only TAINT_WARN is the display's":
    check isDisplayVblankOnlyTaint("512", VblankWarning & "\n")
    check isDisplayVblankOnlyTaint("512\n",
      VblankWarning & "\n" & VblankWarning & "\n")

  test "another taint bit is never accounted":
    # 512 + 4096 (TAINT_OOT_MODULE), and TAINT_DIE (128) alone.
    check not isDisplayVblankOnlyTaint("4608", VblankWarning)
    check not isDisplayVblankOnlyTaint("128", VblankWarning)
    check not isDisplayVblankOnlyTaint("0", VblankWarning)

  test "a warning from anywhere else keeps the taint":
    check not isDisplayVblankOnlyTaint("512", OtherWarning)
    check not isDisplayVblankOnlyTaint("512",
      VblankWarning & "\n" & OtherWarning)

  test "a BUG or an Oops beside the vblank warning keeps the taint":
    check not isDisplayVblankOnlyTaint("512",
      VblankWarning & "\nBUG: kernel NULL pointer dereference, address: 0")
    check not isDisplayVblankOnlyTaint("512",
      VblankWarning & "\nOops: 0000 [#1] PREEMPT SMP NOPTI")

  test "a taint with no report left is unexplained":
    check not isDisplayVblankOnlyTaint("512", "")
    check not isDisplayVblankOnlyTaint("512", "\n\n")

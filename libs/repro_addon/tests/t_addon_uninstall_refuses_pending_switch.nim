## Uninstall's step 0 (ReproOS Add-On Mode spec §6.4 step 0, §7.7; §13
## decision 122, assigned to A11 by the operator 2026-11-25): while any
## switch's pending marker exists, of any generation and on any base,
## uninstall refuses with ``EAddOnSwitchPending`` before it changes
## anything.
##
## ``pendingSwitchRefusal`` is what ``runAddonUninstall`` raises on, under
## the host apply lock and before the evidence gate. Its falsifying build,
## ``uninstall-skips-pending-check``, removes the call from
## ``runAddonUninstall``; the VM gate
## ``e2e_addon_uninstall_refuses_pending_switch`` holds that (a switch
## paused after its marker, its apply SIGKILLed with no reboot).
##
## No mocks: real state directories with a real marker written by the
## switch's own ``writePendingMarker``. The host's default state
## directories are searched too (``guardStateDirs``); on a build host they
## hold no marker.

import std/[os, posix, strutils, unittest]

import repro_addon/static_tree
import repro_addon/uninstall

let root = getTempDir() / ("addon-uninstall-pending-" & $getCurrentProcessId())
removeDir(root)
createDir(root)
let noPointer = root / "no-pointer"

suite "uninstall refuses while a switch is pending (§13 decision 122)":
  test "a state directory without a marker: no refusal":
    let st = root / "clean"
    createDir(st / "addon")
    check pendingSwitchRefusal(st, pointer = noPointer) == ""

  test "an ordinary switch's marker is refused, naming the marker":
    let st = root / "pending"
    writePendingMarker(st, PendingMarker(fromGeneration: "g1",
      planId: "p", status: "in-progress", purpose: "apply",
      attempt: "a1"))
    let why = pendingSwitchRefusal(st, pointer = noPointer)
    checkpoint why
    check why.startsWith("a switch is pending: " & pendingMarkerPath(st))
    check "attempt a1" in why and "from generation g1" in why
    check "repro system addon recover" in why
    check "Nothing was changed" in why

  test "a marker with no generation (the first switch) is refused too":
    let st = root / "first"
    writePendingMarker(st, PendingMarker(status: "in-progress"))
    check "from generation none" in pendingSwitchRefusal(st, pointer = noPointer)

  test "an unreadable marker still refuses":
    let st = root / "torn"
    createDir(st / "addon")
    writeFile(pendingMarkerPath(st), "\x00not a marker")
    let why = pendingSwitchRefusal(st, pointer = noPointer)
    check why.startsWith("a switch is pending: ")

  test "the state directory the pointer names is searched":
    let st = root / "pointed"
    writePendingMarker(st, PendingMarker(status: "failed"))
    let pointer = root / "pointer"
    writeAddonStateDirPointer(st, pointer)
    check pendingSwitchRefusal(root / "clean", pointer = pointer,
      pointerOwner = int(getuid())).startsWith("a switch is pending: ")

removeDir(root)

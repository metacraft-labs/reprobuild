## ``t_addon_retargeted_address_is_refused``: a resource whose address now
## names another object than in the previous generation -- a unit renamed,
## a file moved, while the profile kept its `address` -- is found by
## ``retargetedAddresses``, which the switch refuses on (ReproOS Add-On
## Mode §7.3, *Renames keep no address*).
##
## Found by the A12 validator gate (reprobuild-pm Measurements, 2026-11-01):
## the switch knew objects by address only, so a rename under a kept
## address removed nothing. The old unit file stayed on the host out of the
## ledger and its instance kept running while the new unit started beside
## it -- for an `exclusive` validator client, the overlap §7.3 forbids (the
## client's own database lock kept it from signing).
##
## Falsifying mutation: ``-d:reproAddonMutation=retargeted-address-accepted``
## compiles the switch's refusal out; this test checks the pure function,
## the validator gate checks the refusal on a host.
##
## *Mocking.* None: the production parser and function.

import std/unittest

import repro_infra
import repro_addon/addon_apply

proc unit(name, address: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Service]\n" &
    "ExecStart=/bin/true\n\"\n  address = \"" & address & "\"\n}\n\n"

proc file(path, address: string): string =
  "fs.systemFile {\n  path = \"" & path & "\"\n  content = \"x\n\"\n" &
    "  address = \"" & address & "\"\n}\n\n"

suite "retargeted addresses":
  test "a unit renamed under its old address is found":
    let before = parseSystemProfile(unit("a.service", "u"))
    let after = parseSystemProfile(unit("b.service", "u"))
    let m = retargetedAddresses(before.resources, after.resources)
    check m.len == 1
    check m[0].address == "u"
    check m[0].was == "systemd.systemUnit /etc/systemd/system/a.service"
    check m[0].now == "systemd.systemUnit /etc/systemd/system/b.service"

  test "a file moved under its old address is found":
    let before = parseSystemProfile(file("/etc/repro/a.conf", "f"))
    let after = parseSystemProfile(file("/etc/repro/b.conf", "f"))
    check retargetedAddresses(before.resources, after.resources).len == 1

  test "a rename with a new address, or a content change, is not":
    let before = parseSystemProfile(unit("a.service", "ua") &
                                    file("/etc/repro/a.conf", "f"))
    let renamed = parseSystemProfile(unit("b.service", "ub") &
                                     file("/etc/repro/a.conf", "f"))
    check retargetedAddresses(before.resources, renamed.resources).len == 0
    let same = parseSystemProfile(unit("a.service", "ua") &
      "fs.systemFile {\n  path = \"/etc/repro/a.conf\"\n  content = \"y\n\"\n" &
      "  address = \"f\"\n}\n\n")
    check retargetedAddresses(before.resources, same.resources).len == 0
